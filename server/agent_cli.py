#!/usr/bin/env python3
"""
agent_cli.py — Agent-friendly inspection and configuration CLI for NexVoice Gateway.

Usage:
  python3 server/agent_cli.py capabilities [--json]
  python3 server/agent_cli.py doctor [--json]
  python3 server/agent_cli.py config-schema [--json]
  python3 server/agent_cli.py tune [--bench] [--sample FILE] [--apply]
  python3 server/agent_cli.py setup-local [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

_HERE = Path(__file__).parent
_PROJECT_ROOT = _HERE.parent
sys.path.insert(0, str(_HERE))

import settings_store  # noqa: E402
import autotune  # noqa: E402
import diagnostics  # noqa: E402


def get_capabilities() -> dict:
    key_env = os.environ.get("NEXVOICE_GEMINI_ENV", "GEMINI_API_KEY")
    has_gemini = bool(os.environ.get(key_env))
    has_groq = bool(os.environ.get("GROQ_API_KEY"))

    # Check local MLX helper readiness honestly
    mlx_available = False
    try:
        import mlx_whisper  # noqa: F401
        mlx_available = True
    except ImportError:
        mlx_available = False

    # Check Ollama readiness
    ollama_available = False
    try:
        import requests
        resp = requests.get("http://127.0.0.1:11434/api/tags", timeout=0.5)
        ollama_available = (resp.status_code == 200)
    except Exception:
        ollama_available = False

    return {
        "local_runtimes": {
            "mlx_whisper": {
                "bundled": True,
                "available": mlx_available,
                "default_model": "mlx-community/whisper-large-v3-turbo",
            },
            "ollama": {
                "available": ollama_available,
                "endpoint": "http://127.0.0.1:11434",
            },
        },
        "cloud_providers": {
            "gemini": {"configured": has_gemini, "env_var": key_env},
            "groq": {"configured": has_groq, "env_var": "GROQ_API_KEY"},
        },
        "security": {
            "auth_required": True,
            "token_header": "X-NexVoice-Token",
            "native_app_auth": "HMAC-SHA256 request/response challenge",
            "loopback_only": True,
            "shell_execution": False,
        },
    }


def get_doctor() -> dict:
    return diagnostics.run_doctor()


def get_config_schema() -> dict:
    model_str_schema = {
        "type": "string",
        "minLength": 1,
        "maxLength": 200,
    }
    return {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "title": "NexVoiceSettingsPatch",
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "cloud_enabled": {"type": "boolean", "default": False},
            "engine_default": {
                "type": "string",
                "enum": ["local", "cloud", "auto"],
                "default": "local",
            },
            "cleanup_enabled": {"type": "boolean", "default": False},
            "privacy_mode": {"type": "boolean", "default": False},
            "cloud_model": {**model_str_schema, "default": "gemini-2.5-flash"},
            "local_model": {
                **model_str_schema,
                "enum": sorted(settings_store.ALLOWED_LOCAL_STT_MODELS),
                "default": "mlx-community/whisper-large-v3-turbo",
            },
            "cleanup_style": {
                "type": "string",
                "enum": ["verbatim", "tidy", "meeting", "command"],
                "default": "tidy",
            },
            "cleanup_engine": {
                "type": "string",
                "enum": ["local", "gemini", "nim", "auto"],
                "default": "local",
            },
            "cleanup_nim_model": {**model_str_schema, "default": "qwen/qwen3-next-80b-a3b-instruct"},
            "cleanup_local_model": {**model_str_schema, "default": "qwen3:4b-instruct"},
        },
    }


def handle_setup_local() -> dict:
    """Return deterministic instructions without installing or prompting."""
    return {
        "schema_version": "1.0",
        "status": "READY",
        "supported_native_platform": "macOS 14+ on Apple Silicon",
        "next_commands": [
            "python3 server/agent_cli.py doctor --json",
            "python3 server/agent_cli.py tune --json",
            "zsh runtime/setup-runtime.sh",
            "zsh install.sh",
            "python3 server/agent_cli.py doctor --json",
        ],
        "optional_gateway_commands": [
            "python3 -m pip install -r server/requirements.txt",
            "python3 server/app.py",
        ],
        "human_steps": [
            "Grant Microphone permission to NexVoice in System Settings.",
            "Grant Accessibility permission to NexVoice in System Settings.",
        ],
        "windows_status": (
            "The authenticated HTTP gateway can be used by Windows clients, "
            "but the native NexVoice HUD app and MLX runtime currently require macOS."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="NexVoice Agent CLI")
    parser.add_argument(
        "command",
        choices=["capabilities", "doctor", "config-schema", "tune", "setup-local"],
    )
    parser.add_argument("--json", action="store_true", help="Output JSON (default)")
    parser.add_argument("--bench", action="store_true", help="Run a real MLX benchmark")
    parser.add_argument("--sample", help="WAV sample for --bench (max 30s / 10MB)")
    parser.add_argument(
        "--allow-download",
        action="store_true",
        help="Allow benchmark to download a missing model",
    )
    parser.add_argument("--apply", action="store_true", help="Apply local model settings")
    parser.add_argument(
        "--config",
        default=str(autotune.DEFAULT_CONFIG_PATH),
        help="JSON config path used by tune --apply",
    )

    args = parser.parse_args()

    if args.command == "capabilities":
        res = get_capabilities()
    elif args.command == "doctor":
        res = get_doctor()
    elif args.command == "config-schema":
        res = get_config_schema()
    elif args.command == "tune":
        res = autotune.run_tune(
            bench=args.bench,
            apply=args.apply,
            config_path=args.config,
            sample_path=args.sample,
            allow_download=args.allow_download,
        )
    elif args.command == "setup-local":
        res = handle_setup_local()
    else:
        res = {}

    print(json.dumps(res, indent=2, ensure_ascii=False))
    return 2 if res.get("status") == "BLOCKED" else 0


if __name__ == "__main__":
    raise SystemExit(main())
