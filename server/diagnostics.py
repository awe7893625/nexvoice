"""Non-interactive, secret-safe diagnostics for NexVoice and AI installers."""

from __future__ import annotations

import importlib.util
import json
import os
import platform
import shutil
import socket
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

import db
import settings_store

SCHEMA_VERSION = "1.0"
VALID_CHECK_STATUSES = {"PASS", "WARN", "FAIL", "HUMAN", "BLOCKED"}
_PROJECT_ROOT = Path(__file__).resolve().parent.parent


def _gateway_db_path() -> Path:
    if configured := os.environ.get("NEXVOICE_DB_PATH"):
        return Path(configured).expanduser()
    config_path = Path(
        os.environ.get("NEXVOICE_CONFIG_PATH", str(_PROJECT_ROOT / "config.json"))
    ).expanduser()
    configured_db: str | None = None
    try:
        if (
            config_path.is_file()
            and not config_path.is_symlink()
            and config_path.stat().st_size <= 1024 * 1024
        ):
            config = json.loads(config_path.read_text(encoding="utf-8"))
            if isinstance(config, dict) and isinstance(config.get("db_path"), str):
                configured_db = config["db_path"]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        configured_db = None
    path = Path(configured_db or (_PROJECT_ROOT / "data" / "nexvoice.db")).expanduser()
    return path if path.is_absolute() else _PROJECT_ROOT / path


def _runtime_venv_path() -> Path:
    return Path.home() / ".cache" / "nexvoice" / "runtime" / ".venv"


def _check(
    check_id: str,
    status: str,
    message: str,
    fix: str = "",
    *,
    automatable: bool,
) -> dict[str, Any]:
    if status not in VALID_CHECK_STATUSES:
        raise ValueError(f"invalid diagnostic status: {status}")
    return {
        "id": check_id,
        "status": status,
        "message": message,
        "fix": fix,
        "automatable": automatable,
    }


def _command_ok(command: list[str]) -> bool:
    try:
        return (
            subprocess.run(
                command,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
                check=False,
            ).returncode
            == 0
        )
    except (OSError, subprocess.SubprocessError):
        return False


def _port_state(port: int) -> str:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            return "listening"
    except OSError:
        return "available"


def _physical_memory_gb() -> int:
    sysctl = shutil.which("sysctl")
    if not sysctl:
        return 0
    try:
        value = subprocess.check_output(
            [sysctl, "-n", "hw.memsize"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        ).strip()
        return round(int(value) / (1024**3))
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0


def _token_check() -> dict[str, Any]:
    if os.environ.get("NEXVOICE_GATEWAY_TOKEN", "").strip():
        return _check(
            "gateway_token",
            "PASS",
            "Gateway token is configured through the environment.",
            automatable=True,
        )
    token_path = Path.home() / ".cache" / "nexvoice" / "gateway.token"
    if not token_path.exists():
        return _check(
            "gateway_token",
            "WARN",
            "Gateway token is not created yet.",
            "Start the gateway once to create a per-user token.",
            automatable=True,
        )
    try:
        mode = stat.S_IMODE(token_path.stat().st_mode)
    except OSError:
        return _check(
            "gateway_token",
            "WARN",
            "Gateway token exists but permissions could not be inspected.",
            "Set token permissions to 0600.",
            automatable=True,
        )
    if mode & 0o077:
        return _check(
            "gateway_token",
            "WARN",
            f"Gateway token permissions are {mode:04o}; expected 0600.",
            f"chmod 600 {token_path}",
            automatable=True,
        )
    return _check(
        "gateway_token",
        "PASS",
        "Gateway token exists with private file permissions.",
        automatable=True,
    )


def _cloud_key_check() -> dict[str, Any]:
    gemini_env = os.environ.get("NEXVOICE_GEMINI_ENV", "GEMINI_API_KEY")
    providers = {
        "Gemini": bool(os.environ.get(gemini_env)),
        "Groq": bool(os.environ.get("GROQ_API_KEY")),
        "NVIDIA NIM": bool(os.environ.get("NVIDIA_API_KEY")),
    }
    summary = ", ".join(
        f"{name}: {'present' if present else 'absent'}"
        for name, present in providers.items()
    )
    return _check(
        "cloud_keys",
        "PASS",
        f"Optional provider key presence — {summary}. Values are never displayed.",
        automatable=True,
    )


def _model_cache_check(model: str) -> dict[str, Any]:
    cache_root = Path(
        os.environ.get("HF_HOME", str(Path.home() / ".cache" / "huggingface"))
    )
    model_dir = cache_root / "hub" / f"models--{model.replace('/', '--')}"
    cached = model_dir.is_dir()
    return _check(
        "model_cache",
        "PASS" if cached else "WARN",
        f"Recommended final model is {'cached' if cached else 'not cached'} locally.",
        "Run runtime/setup-runtime.sh to install the local runtime and model."
        if not cached
        else "",
        automatable=True,
    )


def run_doctor() -> dict[str, Any]:
    """Run bounded checks without TCC prompts, credential dialogs, or downloads."""
    db_path = str(_gateway_db_path())
    if os.environ.get("NEXVOICE_DB_PATH") or not db.is_initialized():
        db.init_db(db_path)
    current_settings = settings_store.to_dict(settings_store.load())
    checks: list[dict[str, Any]] = []

    mac_version = platform.mac_ver()[0] or "not-macOS"
    try:
        mac_major = int(mac_version.split(".", 1)[0])
    except ValueError:
        mac_major = 0
    checks.append(
        _check(
            "macos_version",
            "PASS" if mac_major >= 14 else "FAIL",
            f"Operating system: {platform.system()} {mac_version}.",
            "Use macOS 14 or newer for the native NexVoice app."
            if mac_major < 14
            else "",
            automatable=False,
        )
    )

    architecture = platform.machine().lower()
    checks.append(
        _check(
            "architecture",
            "PASS" if architecture == "arm64" else "FAIL",
            f"Architecture: {architecture or 'unknown'}.",
            "Local MLX transcription requires an Apple Silicon Mac."
            if architecture != "arm64"
            else "",
            automatable=False,
        )
    )

    python_ok = sys.version_info >= (3, 10)
    checks.append(
        _check(
            "python_version",
            "PASS" if python_ok else "FAIL",
            f"Python: {platform.python_version()}.",
            "Install Python 3.10 or newer." if not python_ok else "",
            automatable=False,
        )
    )

    xcode_select = shutil.which("xcode-select")
    swift = shutil.which("swift")
    tools_ok = bool(xcode_select and swift and _command_ok([xcode_select, "-p"]))
    checks.append(
        _check(
            "developer_tools",
            "PASS" if tools_ok else "FAIL",
            "Xcode Command Line Tools and Swift are available."
            if tools_ok
            else "Xcode Command Line Tools or Swift are unavailable.",
            "Run xcode-select --install, then verify swift --version."
            if not tools_ok
            else "",
            automatable=False,
        )
    )

    try:
        free_gb = round(shutil.disk_usage(Path.home()).free / (1024**3), 1)
    except OSError:
        free_gb = 0.0
    checks.append(
        _check(
            "disk_space",
            "PASS" if free_gb >= 4 else "WARN",
            f"Free disk space: {free_gb} GB.",
            "Free at least 4 GB for the app, runtime, and model cache."
            if free_gb < 4
            else "",
            automatable=False,
        )
    )

    ram_gb = _physical_memory_gb()
    checks.append(
        _check(
            "physical_memory",
            "PASS" if ram_gb >= 8 else "WARN",
            f"Physical memory: {ram_gb or 'unknown'} GB.",
            "Use a smaller local model or a Mac with at least 8 GB RAM."
            if 0 < ram_gb < 8
            else "",
            automatable=False,
        )
    )

    runtime_venv = _runtime_venv_path()
    mlx_available = importlib.util.find_spec("mlx_whisper") is not None
    checks.append(
        _check(
            "local_runtime",
            "PASS" if (runtime_venv.exists() or mlx_available) else "WARN",
            "Local MLX runtime is available."
            if (runtime_venv.exists() or mlx_available)
            else "Local MLX runtime is not installed yet.",
            "Run runtime/setup-runtime.sh." if not (runtime_venv.exists() or mlx_available) else "",
            automatable=True,
        )
    )
    checks.append(_model_cache_check(current_settings["local_model"]))
    checks.append(_token_check())

    port_summary = ", ".join(
        f"{port}: {_port_state(port)}" for port in (5111, 5112)
    )
    checks.append(
        _check(
            "loopback_ports",
            "PASS",
            f"Loopback port state — {port_summary}.",
            automatable=True,
        )
    )

    ollama = shutil.which("ollama")
    ollama_running = _port_state(11434) == "listening"
    checks.append(
        _check(
            "ollama",
            "PASS" if ollama_running else "WARN",
            "Ollama is listening on loopback."
            if ollama_running
            else f"Ollama is {'installed but not running' if ollama else 'not installed'}.",
            "Install Ollama and run ollama serve if local text cleanup is desired."
            if not ollama_running
            else "",
            automatable=True,
        )
    )
    checks.append(_cloud_key_check())

    for check_id, label in (
        ("tcc_microphone", "Microphone"),
        ("tcc_accessibility", "Accessibility"),
    ):
        checks.append(
            _check(
                check_id,
                "HUMAN",
                f"{label} permission must be confirmed by the user in System Settings.",
                f"System Settings → Privacy & Security → {label} → enable NexVoice.",
                automatable=False,
            )
        )

    statuses = {item["status"] for item in checks}
    overall = (
        "BLOCKED"
        if statuses & {"FAIL", "BLOCKED"}
        else "DEGRADED"
        if statuses & {"WARN", "HUMAN"}
        else "HEALTHY"
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "status": overall,
        "platform": {
            "system": platform.system(),
            "version": mac_version,
            "architecture": architecture,
        },
        "current_settings": current_settings,
        "checks": checks,
    }
