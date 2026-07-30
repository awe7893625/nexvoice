"""Focused tests for NexVoice AI-ready diagnostics and safe auto-tuning."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import wave
from pathlib import Path

import pytest

import agent_cli
import autotune
import db
import diagnostics


@pytest.fixture
def isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    path = tmp_path / "state" / "nexvoice.db"
    monkeypatch.setenv("NEXVOICE_DB_PATH", str(path))
    return path


def test_fresh_clone_doctor_initializes_database_and_has_stable_schema(
    isolated_db: Path,
) -> None:
    result = diagnostics.run_doctor()
    assert isolated_db.exists()
    assert result["schema_version"] == "1.0"
    assert result["status"] in {"HEALTHY", "DEGRADED", "BLOCKED"}
    assert all(
        set(check) == {"id", "status", "message", "fix", "automatable"}
        for check in result["checks"]
    )
    by_id = {check["id"]: check for check in result["checks"]}
    assert by_id["tcc_microphone"]["status"] == "HUMAN"
    assert by_id["tcc_accessibility"]["automatable"] is False


def test_doctor_cli_fresh_database_outputs_json(
    tmp_path: Path,
) -> None:
    env = {
        **os.environ,
        "NEXVOICE_DB_PATH": str(tmp_path / "fresh" / "doctor.db"),
    }
    completed = subprocess.run(
        [sys.executable, "server/agent_cli.py", "doctor", "--json"],
        cwd=Path(__file__).resolve().parent.parent,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    payload = json.loads(completed.stdout)
    assert completed.returncode in {0, 2}
    assert payload["schema_version"] == "1.0"
    assert payload["checks"]


def test_doctor_never_exposes_secret_values(
    isolated_db: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    secrets = {
        "GEMINI_API_KEY": "gemini-secret-do-not-print",
        "GROQ_API_KEY": "groq-secret-do-not-print",
        "NVIDIA_API_KEY": "nim-secret-do-not-print",
        "NEXVOICE_GATEWAY_TOKEN": "gateway-secret-do-not-print",
    }
    for name, value in secrets.items():
        monkeypatch.setenv(name, value)
    encoded = json.dumps(diagnostics.run_doctor())
    assert all(value not in encoded for value in secrets.values())


def test_recommendations_cover_memory_and_architecture_boundaries() -> None:
    small = autotune.recommend_models({"architecture": "arm64", "ram_gb": 8})
    standard = autotune.recommend_models({"architecture": "arm64", "ram_gb": 16})
    large = autotune.recommend_models({"architecture": "arm64", "ram_gb": 32})
    unsupported = autotune.recommend_models({"architecture": "x86_64", "ram_gb": 32})

    assert small["local_model"] == "mlx-community/whisper-small"
    assert standard["local_model"] == "mlx-community/whisper-large-v3-turbo"
    assert standard["cleanup_local_model"] == "qwen2.5:3b"
    assert large["cleanup_local_model"] == "qwen2.5:7b"
    assert standard["partial_model"] == "mlx-community/whisper-tiny"
    assert unsupported["supported"] is False
    assert unsupported["local_model"] is None


def test_tune_dry_run_does_not_create_config(tmp_path: Path) -> None:
    config = tmp_path / "config.json"
    result = autotune.run_tune(config_path=config)
    assert result["apply"]["status"] == "DRY_RUN"
    assert not config.exists()


def test_apply_is_atomic_idempotent_and_preserves_private_cloud_fields(
    tmp_path: Path,
) -> None:
    config = tmp_path / "config.json"
    original = {
        "privacy_mode": True,
        "cloud_enabled": False,
        "provider_secret_reference": "GEMINI_API_KEY",
        "unknown_future_field": {"keep": True},
        "local_model": "old-model",
    }
    config.write_text(json.dumps(original), encoding="utf-8")
    recommendation = {
        "local_model": "mlx-community/whisper-large-v3-turbo",
        "cleanup_local_model": "qwen2.5:3b",
        "privacy_mode": False,
        "cloud_enabled": True,
    }

    first = autotune.apply_config(recommendation, config_path=config)
    after_first = config.read_bytes()
    second = autotune.apply_config(recommendation, config_path=config)
    updated = json.loads(after_first)

    assert first["status"] == "APPLIED"
    assert second["status"] == "UNCHANGED"
    assert config.read_bytes() == after_first
    assert updated["privacy_mode"] is True
    assert updated["cloud_enabled"] is False
    assert updated["provider_secret_reference"] == "GEMINI_API_KEY"
    assert updated["unknown_future_field"] == {"keep": True}
    assert updated["cleanup_local_model"] == "qwen2.5:3b"
    assert config.with_suffix(".json.bak").read_text(encoding="utf-8") == json.dumps(
        original
    )


def test_apply_rejects_symlink_and_non_object_config(tmp_path: Path) -> None:
    target = tmp_path / "target.json"
    target.write_text("{}", encoding="utf-8")
    symlink = tmp_path / "config.json"
    symlink.symlink_to(target)
    with pytest.raises(ValueError, match="symlinked"):
        autotune.apply_config({"local_model": "model"}, config_path=symlink)

    array_config = tmp_path / "array.json"
    array_config.write_text("[]", encoding="utf-8")
    with pytest.raises(ValueError, match="JSON object"):
        autotune.apply_config({"local_model": "model"}, config_path=array_config)


def test_apply_rolls_back_byte_identically_when_activation_verification_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config = tmp_path / "config.json"
    original = b'{"privacy_mode":true,"local_model":"before"}\n'
    config.write_bytes(original)
    real_read = autotune._read_config
    calls = 0

    def fail_verification(path: Path):
        nonlocal calls
        calls += 1
        if calls == 2:
            return {"local_model": "tampered"}, path.read_bytes()
        return real_read(path)

    monkeypatch.setattr(autotune, "_read_config", fail_verification)
    with pytest.raises(OSError, match="verification"):
        autotune.apply_config({"local_model": "after"}, config_path=config)
    assert config.read_bytes() == original


def test_benchmark_is_honest_when_prerequisites_are_missing(tmp_path: Path) -> None:
    missing_sample = autotune.benchmark_model("org/model")
    assert missing_sample["status"] == "NOT_RUN"
    assert "sample" in missing_sample["reason"].lower()

    sample = tmp_path / "sample.wav"
    with wave.open(str(sample), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\0\0" * 1_600)
    not_cached = autotune.benchmark_model("org/model", sample)
    assert not_cached["status"] == "NOT_RUN"
    assert "cached" in not_cached["reason"].lower()


def test_setup_local_is_noninteractive_and_explicit_about_windows() -> None:
    result = agent_cli.handle_setup_local()
    assert result["status"] == "READY"
    assert result["next_commands"][0].endswith("doctor --json")
    assert "Windows" in result["windows_status"]


def test_db_init_does_not_chmod_existing_external_parent(tmp_path: Path) -> None:
    parent = tmp_path / "shared"
    parent.mkdir(mode=0o755)
    before = parent.stat().st_mode & 0o777
    db.init_db(str(parent / "nexvoice.db"))
    assert parent.stat().st_mode & 0o777 == before
