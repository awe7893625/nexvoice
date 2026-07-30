"""Safe hardware recommendations and optional real MLX benchmark for NexVoice."""

from __future__ import annotations

import json
import os
import platform
import shutil
import sqlite3
import subprocess
import tempfile
import time
import wave
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "1.0"
SAFE_CONFIG_KEYS = {"local_model", "cleanup_local_model"}
DEFAULT_CONFIG_PATH = Path(
    os.environ.get(
        "NEXVOICE_CONFIG_PATH",
        str(Path(__file__).resolve().parent.parent / "config.json"),
    )
)
MAX_CONFIG_BYTES = 1024 * 1024
MAX_SAMPLE_BYTES = 10 * 1024 * 1024
MAX_SAMPLE_SECONDS = 30.0
_PROJECT_ROOT = Path(__file__).resolve().parent.parent


def _sysctl_value(name: str) -> str:
    executable = shutil.which("sysctl")
    if not executable:
        return ""
    try:
        return subprocess.check_output(
            [executable, "-n", name],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def get_hardware_info() -> dict[str, Any]:
    """Return non-sensitive hardware facts used by the recommendation policy."""
    memsize = _sysctl_value("hw.memsize")
    ram_gb = round(int(memsize) / (1024**3)) if memsize.isdigit() else 0
    chip_name = _sysctl_value("machdep.cpu.brand_string") or platform.processor()
    try:
        free_gb = round(shutil.disk_usage(Path.home()).free / (1024**3), 1)
    except OSError:
        free_gb = 0.0
    return {
        "architecture": platform.machine().lower(),
        "ram_gb": ram_gb,
        "disk_free_gb": free_gb,
        "chip_name": chip_name or "unknown",
    }


def recommend_models(hardware_info: dict[str, Any] | None = None) -> dict[str, Any]:
    """Recommend bounded local models; never download or change configuration."""
    hardware = hardware_info or get_hardware_info()
    architecture = str(hardware.get("architecture") or platform.machine()).lower()
    ram_gb = int(hardware.get("ram_gb") or 0)
    supported = architecture in {"arm64", "aarch64"}

    if not supported:
        return {
            "supported": False,
            "reason": "NexVoice local MLX transcription requires Apple Silicon (arm64).",
            "partial_model": None,
            "local_model": None,
            "cleanup_local_model": None,
        }

    return {
        "supported": True,
        "reason": "Recommendation is based on architecture and physical memory.",
        "partial_model": "mlx-community/whisper-tiny",
        "local_model": (
            "mlx-community/whisper-large-v3-turbo"
            if ram_gb >= 16
            else "mlx-community/whisper-small"
        ),
        "cleanup_local_model": "qwen2.5:7b" if ram_gb >= 32 else "qwen2.5:3b",
    }


def _model_cache_path(model: str) -> Path:
    cache_root = Path(
        os.environ.get(
            "HF_HOME",
            str(Path.home() / ".cache" / "huggingface"),
        )
    )
    return cache_root / "hub" / f"models--{model.replace('/', '--')}"


def _validate_wav_sample(path: Path) -> float:
    if path.is_symlink() or not path.is_file():
        raise ValueError("benchmark sample must be a regular WAV file")
    if path.stat().st_size > MAX_SAMPLE_BYTES:
        raise ValueError("benchmark sample exceeds 10 MB")
    try:
        with wave.open(str(path), "rb") as wav:
            duration = wav.getnframes() / max(1, wav.getframerate())
    except (OSError, EOFError, wave.Error) as exc:
        raise ValueError("benchmark sample must be a valid WAV file") from exc
    if duration <= 0 or duration > MAX_SAMPLE_SECONDS:
        raise ValueError("benchmark sample duration must be between 0 and 30 seconds")
    return duration


def benchmark_model(
    model: str,
    sample_path: str | os.PathLike[str] | None = None,
    *,
    allow_download: bool = False,
) -> dict[str, Any]:
    """Run a real benchmark or return an honest NOT_RUN reason."""
    if not sample_path:
        return {
            "status": "NOT_RUN",
            "model": model,
            "reason": "Provide --sample with a WAV file to run a real benchmark.",
        }

    sample = Path(sample_path).expanduser()
    try:
        duration = _validate_wav_sample(sample)
    except ValueError as exc:
        return {"status": "NOT_RUN", "model": model, "reason": str(exc)}

    if not allow_download and not _model_cache_path(model).exists():
        return {
            "status": "NOT_RUN",
            "model": model,
            "reason": "Model is not cached; pass --allow-download to permit a download.",
        }

    try:
        import mlx_whisper
    except ImportError:
        return {
            "status": "NOT_RUN",
            "model": model,
            "reason": "mlx_whisper is not installed in this Python environment.",
        }

    started = time.perf_counter()
    try:
        result = mlx_whisper.transcribe(str(sample), path_or_hf_repo=model)
    except Exception as exc:  # noqa: BLE001 - surfaced as bounded diagnostic
        return {
            "status": "ERROR",
            "model": model,
            "reason": f"Benchmark failed: {type(exc).__name__}",
        }
    elapsed = time.perf_counter() - started
    return {
        "status": "PASS",
        "model": model,
        "audio_seconds": round(duration, 3),
        "elapsed_seconds": round(elapsed, 3),
        "real_time_factor": round(elapsed / duration, 4),
        "transcript_characters": len(str(result.get("text", ""))),
    }


def _read_config(path: Path) -> tuple[dict[str, Any], bytes | None]:
    if path.is_symlink():
        raise ValueError("refusing to update a symlinked config")
    if not path.exists():
        return {}, None
    if not path.is_file() or path.stat().st_size > MAX_CONFIG_BYTES:
        raise ValueError("config must be a regular JSON file smaller than 1 MB")
    original = path.read_bytes()
    try:
        parsed = json.loads(original)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("config is not valid UTF-8 JSON") from exc
    if not isinstance(parsed, dict):
        raise ValueError("config root must be a JSON object")
    return parsed, original


def _atomic_write_bytes(path: Path, payload: bytes) -> None:
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
    except Exception:
        Path(temp_name).unlink(missing_ok=True)
        raise


def _gateway_db_path(config: dict[str, Any], config_path: Path) -> Path:
    configured = os.environ.get("NEXVOICE_DB_PATH") or config.get("db_path")
    if configured:
        path = Path(str(configured)).expanduser()
        return path if path.is_absolute() else _PROJECT_ROOT / path
    if config_path.resolve() == DEFAULT_CONFIG_PATH.resolve():
        return _PROJECT_ROOT / "data" / "nexvoice.db"
    return config_path.parent / "data" / "nexvoice.db"


def _sync_gateway_settings(db_path: Path, patch: dict[str, str]) -> bool:
    """Apply the approved local-model patch to the SQLite state Gateway reads."""
    if db_path.is_symlink():
        raise ValueError("refusing to update a symlinked gateway database")
    parent_was_missing = not db_path.parent.exists()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if parent_was_missing:
        os.chmod(db_path.parent, 0o700)

    changed = False
    connection = sqlite3.connect(db_path)
    try:
        connection.execute(
            "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)"
        )
        for key, value in patch.items():
            row = connection.execute(
                "SELECT value FROM settings WHERE key = ?", (key,)
            ).fetchone()
            changed = changed or row is None or row[0] != value
            connection.execute(
                """
                INSERT INTO settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                (key, value),
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    os.chmod(db_path, 0o600)
    return changed


def apply_config(
    recommendation: dict[str, Any],
    *,
    config_path: str | os.PathLike[str] = DEFAULT_CONFIG_PATH,
) -> dict[str, Any]:
    """Atomically apply only local model keys and preserve all other values."""
    path = Path(config_path).expanduser()
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    current, original = _read_config(path)
    safe_patch = {
        key: value
        for key, value in recommendation.items()
        if key in SAFE_CONFIG_KEYS and isinstance(value, str) and value.strip()
    }
    updated = {**current, **safe_patch}
    payload = (json.dumps(updated, indent=2, ensure_ascii=False) + "\n").encode()
    db_path = _gateway_db_path(updated, path)

    backup = path.with_suffix(path.suffix + ".bak")
    temp_name: str | None = None
    backup_written = False
    try:
        config_changed = original != payload
        if config_changed:
            if original is not None:
                if backup.is_symlink():
                    raise ValueError("refusing to overwrite a symlinked config backup")
                _atomic_write_bytes(backup, original)
                backup_written = True
            fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
            with os.fdopen(fd, "wb") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temp_name, 0o600)
            os.replace(temp_name, path)
            temp_name = None

            verified, _ = _read_config(path)
            if verified != updated:
                raise OSError("post-write config verification failed")

        database_changed = _sync_gateway_settings(db_path, safe_patch)
        changed = config_changed or database_changed
        return {
            "status": "APPLIED" if changed else "UNCHANGED",
            "changed": changed,
            "config_path": str(path),
            "backup_path": str(backup) if original is not None else None,
            "database_path": str(db_path),
            "activated_settings": safe_patch,
            "config": updated,
        }
    except Exception:
        if original is None:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
        elif backup_written and backup.exists():
            os.replace(backup, path)
        raise
    finally:
        if temp_name:
            try:
                Path(temp_name).unlink(missing_ok=True)
            except OSError:
                pass


def run_tune(
    *,
    bench: bool = False,
    apply: bool = False,
    config_path: str | os.PathLike[str] = DEFAULT_CONFIG_PATH,
    sample_path: str | os.PathLike[str] | None = None,
    allow_download: bool = False,
) -> dict[str, Any]:
    hardware = get_hardware_info()
    recommendation = recommend_models(hardware)
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "status": "READY" if recommendation["supported"] else "BLOCKED",
        "hardware": hardware,
        "recommendation": recommendation,
        "benchmark": {"status": "NOT_REQUESTED"},
        "apply": {"status": "DRY_RUN", "changed": False},
    }
    if bench and recommendation["local_model"]:
        result["benchmark"] = benchmark_model(
            recommendation["local_model"],
            sample_path,
            allow_download=allow_download,
        )
    if apply:
        if not recommendation["supported"]:
            result["apply"] = {"status": "BLOCKED", "changed": False}
        else:
            result["apply"] = apply_config(recommendation, config_path=config_path)
    return result
