"""
settings_store.py — Typed wrapper around the key-value settings table.

Exposes a SettingsView dataclass and helpers to read/write individual keys.
"""

from __future__ import annotations

from dataclasses import dataclass, fields
from typing import Any

import db as _db

# Canonical setting keys
_KEYS = {
    "cloud_enabled",
    "engine_default",
    "cleanup_enabled",
    "privacy_mode",
    "cloud_model",
    "local_model",
    "cleanup_style",
    "cleanup_engine",
    "cleanup_nim_model",
    "cleanup_local_model",
}


@dataclass
class SettingsView:
    cloud_enabled: bool = False
    engine_default: str = "local"  # "cloud" | "local"
    cleanup_enabled: bool = False
    privacy_mode: bool = False
    cloud_model: str = "gemini-2.5-flash"
    local_model: str = "mlx-community/whisper-large-v3-turbo"
    cleanup_style: str = "tidy"  # verbatim | tidy | meeting | command
    # Which engine cleans up the transcript text:
    #   auto   = Gemini -> NIM -> local ollama (fallback chain)
    #   gemini = cloud Gemini (free, best 繁中)
    #   nim    = NVIDIA NIM cloud (free)
    #   local  = local ollama on the gateway box (offline)
    cleanup_engine: str = "local"
    cleanup_nim_model: str = "qwen/qwen3-next-80b-a3b-instruct"
    cleanup_local_model: str = "qwen3:4b-instruct"


def load() -> SettingsView:
    """Read all settings from DB and return a typed view."""
    raw = _db.get_all_settings()
    return SettingsView(
        cloud_enabled=_truthy(raw.get("cloud_enabled", "0")),
        engine_default=raw.get("engine_default", "local"),
        cleanup_enabled=_truthy(raw.get("cleanup_enabled", "0")),
        privacy_mode=_truthy(raw.get("privacy_mode", "0")),
        cloud_model=raw.get("cloud_model", "gemini-2.5-flash"),
        local_model=raw.get("local_model", "mlx-community/whisper-large-v3-turbo"),
        cleanup_style=raw.get("cleanup_style", "tidy"),
        cleanup_engine=raw.get("cleanup_engine", "local"),
        cleanup_nim_model=raw.get(
            "cleanup_nim_model", "qwen/qwen3-next-80b-a3b-instruct"
        ),
        cleanup_local_model=raw.get("cleanup_local_model", "qwen3:4b-instruct"),
    )


def to_dict(sv: SettingsView) -> dict:
    """Serialise SettingsView for JSON response."""
    return {
        "cloud_enabled": sv.cloud_enabled,
        "engine_default": sv.engine_default,
        "cleanup_enabled": sv.cleanup_enabled,
        "privacy_mode": sv.privacy_mode,
        "cloud_model": sv.cloud_model,
        "local_model": sv.local_model,
        "cleanup_style": sv.cleanup_style,
        "cleanup_engine": sv.cleanup_engine,
        "cleanup_nim_model": sv.cleanup_nim_model,
        "cleanup_local_model": sv.cleanup_local_model,
    }


def apply_patch(patch: dict) -> SettingsView:
    """
    Write whichever keys are present in *patch* to the DB.
    Returns the full updated settings view.
    Raises ValueError on invalid keys or values.
    """
    if not isinstance(patch, dict):
        raise ValueError("Patch must be a dictionary")

    allowed_fields = {f.name for f in fields(SettingsView)}
    unknown = set(patch.keys()) - allowed_fields
    if unknown:
        raise ValueError(f"Unknown settings keys: {', '.join(sorted(unknown))}")

    def _valid_model_str(v: Any) -> bool:
        if not isinstance(v, str):
            return False
        s = v.strip()
        return 1 <= len(s) <= 200

    validations = {
        "cloud_enabled": lambda v: isinstance(v, bool) or str(v).lower() in {"0", "1", "true", "false"},
        "engine_default": lambda v: v in {"local", "cloud", "auto"},
        "cleanup_style": lambda v: v in {"verbatim", "tidy", "meeting", "command"},
        "cleanup_engine": lambda v: v in {"local", "gemini", "nim", "auto"},
        "cleanup_enabled": lambda v: isinstance(v, bool) or str(v).lower() in {"0", "1", "true", "false"},
        "privacy_mode": lambda v: isinstance(v, bool) or str(v).lower() in {"0", "1", "true", "false"},
        "cloud_model": _valid_model_str,
        "local_model": _valid_model_str,
        "cleanup_nim_model": _valid_model_str,
        "cleanup_local_model": _valid_model_str,
    }

    validated_patch = {}
    for key, value in patch.items():
        if key in validations and not validations[key](value):
            raise ValueError(f"Invalid value for setting '{key}': {value}")

        # Normalise booleans to "1"/"0"
        if isinstance(value, bool):
            normalized_value = "1" if value else "0"
        else:
            normalized_value = str(value)
        validated_patch[key] = normalized_value

    for key, val in validated_patch.items():
        _db.set_setting(key, val)
    return load()



# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------


def _truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes"}
