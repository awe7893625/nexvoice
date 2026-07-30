#!/usr/bin/env python3
"""
agent_cli.py — Agent-friendly inspection and configuration CLI for NexVoice Gateway.

Usage:
  python3 server/agent_cli.py capabilities [--json]
  python3 server/agent_cli.py doctor [--json]
  python3 server/agent_cli.py config-schema [--json]
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
import stt_router  # noqa: E402


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
            "loopback_only": True,
            "shell_execution": False,
        },
    }


def get_doctor() -> dict:
    capabilities = get_capabilities()
    settings = settings_store.to_dict(settings_store.load())

    checks = []

    # Check 1: Privacy & Zero-cost compliance
    if settings["privacy_mode"]:
        checks.append({"name": "privacy_mode", "status": "PASS", "message": "Privacy mode active; cloud off"})
    else:
        checks.append({"name": "privacy_mode", "status": "INFO", "message": "Privacy mode inactive"})

    # Check 2: Gateway Auth Token
    token_path = Path.home() / ".cache" / "nexvoice" / "gateway.token"
    if token_path.exists() or os.environ.get("NEXVOICE_GATEWAY_TOKEN"):
        checks.append({"name": "gateway_token", "status": "PASS", "message": "Gateway token configured"})
    else:
        checks.append({"name": "gateway_token", "status": "WARN", "message": "Gateway token will be generated on startup"})

    # Check 3: Audio capability
    checks.append({"name": "ffmpeg", "status": "PASS" if Path("/opt/homebrew/bin/ffmpeg").exists() or Path("/usr/local/bin/ffmpeg").exists() else "WARN", "message": "ffmpeg check"})

    # Determine overall status dynamically based on diagnostics
    statuses = {c["status"] for c in checks}
    if "FAIL" in statuses:
        doctor_status = "UNHEALTHY"
    elif "WARN" in statuses:
        doctor_status = "DEGRADED"
    else:
        doctor_status = "HEALTHY"

    return {
        "status": doctor_status,
        "capabilities": capabilities,
        "current_settings": settings,
        "diagnostics": checks,
    }


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
            "local_model": {**model_str_schema, "default": "mlx-community/whisper-large-v3-turbo"},
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


def main() -> None:
    parser = argparse.ArgumentParser(description="NexVoice Agent CLI")
    parser.add_argument("command", choices=["capabilities", "doctor", "config-schema"])
    parser.add_argument("--json", action="store_true", default=True, help="Output JSON")

    args = parser.parse_args()

    if args.command == "capabilities":
        res = get_capabilities()
    elif args.command == "doctor":
        res = get_doctor()
    elif args.command == "config-schema":
        res = get_config_schema()
    else:
        res = {}

    print(json.dumps(res, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
