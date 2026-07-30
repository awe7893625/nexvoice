"""
test_agent_api.py — Focused tests for agent API, auth, settings validation, privacy enforcement, and payload limits.
"""

import base64
import hashlib
import hmac
import pytest
from fastapi.testclient import TestClient
import os
import sys
from pathlib import Path

_HERE = Path(__file__).parent
sys.path.insert(0, str(_HERE))

import app as gateway_app
import settings_store

client = TestClient(gateway_app.app)
TOKEN = gateway_app.GATEWAY_TOKEN


def hmac_headers(method: str, path: str, body: bytes = b"") -> dict[str, str]:
    nonce = base64.b64encode(os.urandom(18)).decode("ascii")
    message = f"{method}\n{path}\n{nonce}\n{hashlib.sha256(body).hexdigest()}"
    proof = base64.b64encode(
        hmac.new(TOKEN.encode(), message.encode(), hashlib.sha256).digest()
    ).decode("ascii")
    return {"X-NexVoice-Nonce": nonce, "X-NexVoice-Proof": proof}


@pytest.fixture(autouse=True)
def init_test_db(tmp_path):
    db_file = str(tmp_path / "test_nexvoice.db")
    gateway_app.db.init_db(db_file)
    gateway_app.vocab_store.reload()



def test_unauthorized_access():
    resp = client.get("/api/settings")
    assert resp.status_code == 401
    assert resp.json() == {"detail": "unauthorized"}


def test_hmac_auth_proves_gateway_identity_and_rejects_replay():
    path = "/api/settings"
    headers = hmac_headers("GET", path)
    response = client.get(path, headers=headers)
    assert response.status_code == 200

    response_message = (
        f"gateway-response\nGET\n{path}\n"
        f"{headers['X-NexVoice-Nonce']}\n200"
    )
    expected = base64.b64encode(
        hmac.new(TOKEN.encode(), response_message.encode(), hashlib.sha256).digest()
    ).decode("ascii")
    assert hmac.compare_digest(
        response.headers["X-NexVoice-Response-Proof"],
        expected,
    )

    replay = client.get(path, headers=headers)
    assert replay.status_code == 401

    forged = hmac_headers("GET", path)
    forged["X-NexVoice-Proof"] = base64.b64encode(b"wrong proof").decode()
    assert client.get(path, headers=forged).status_code == 401


def test_hmac_authenticated_settings_write_preserves_request_body():
    path = "/api/settings"
    body = b'{"local_model":"mlx-community/whisper-small"}'
    headers = {
        **hmac_headers("POST", path, body),
        "Content-Type": "application/json",
    }

    response = client.post(path, content=body, headers=headers)

    assert response.status_code == 200
    assert response.json()["local_model"] == "mlx-community/whisper-small"
    assert response.headers["X-NexVoice-Response-Proof"]


def test_authorized_agent_endpoints():
    headers = {"X-NexVoice-Token": TOKEN}
    
    # capabilities
    res = client.get("/api/agent/capabilities", headers=headers)
    assert res.status_code == 200
    caps = res.json()
    assert "local_runtimes" in caps
    assert caps["local_runtimes"]["mlx_whisper"]["bundled"] is True
    assert isinstance(caps["local_runtimes"]["mlx_whisper"]["available"], bool)

    # doctor
    res = client.get("/api/agent/doctor", headers=headers)
    assert res.status_code == 200
    assert res.json()["status"] in {"HEALTHY", "DEGRADED", "BLOCKED"}

    # config schema
    res = client.get("/api/agent/config-schema", headers=headers)
    assert res.status_code == 200
    assert res.json()["title"] == "NexVoiceSettingsPatch"
    assert "cloud_enabled" in res.json()["properties"]


# Minimal PCM WAV audio with non-zero sample data so silence check passes
MINIMAL_WAV = (
    b"RIFF\x28\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00"
    b"\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00data\x04\x00\x00\x00"
    b"\xff\x7f\x00\x80"
)


def test_cloud_enabled_default_and_key_not_enough(monkeypatch):
    headers = {"X-NexVoice-Token": TOKEN}
    
    # Verify default cloud_enabled is False
    res = client.get("/api/settings", headers=headers)
    assert res.status_code == 200
    assert res.json()["cloud_enabled"] is False

    # Mock GEMINI_API_KEY environment variable present
    monkeypatch.setenv("GEMINI_API_KEY", "fake_key")

    # Even with API key present, if cloud_enabled is False, _run_pipeline forces local
    sv = settings_store.load()
    raw, cleaned, text, engine, model_used, duration_ms = gateway_app._run_pipeline(
        audio_bytes=MINIMAL_WAV,
        mode="cloud",
        settings=sv,
        do_cleanup=False,
        eff_style="tidy",
    )
    assert engine == "local"


def test_invalid_settings_patch():
    headers = {"X-NexVoice-Token": TOKEN}

    # Unknown key
    res = client.post("/api/settings", json={"invalid_key": "val"}, headers=headers)
    assert res.status_code == 422

    # Invalid enum value
    res = client.post("/api/settings", json={"engine_default": "invalid_engine"}, headers=headers)
    assert res.status_code == 422

    # Empty model name rejected
    res = client.post("/api/settings", json={"cloud_model": ""}, headers=headers)
    assert res.status_code == 422

    # Model name > 200 chars rejected
    res = client.post("/api/settings", json={"cloud_model": "a" * 201}, headers=headers)
    assert res.status_code == 422

    # An authenticated client cannot turn model selection into an arbitrary
    # Hugging Face download.
    res = client.post(
        "/api/settings",
        json={"local_model": "attacker/huge-unapproved-model"},
        headers=headers,
    )
    assert res.status_code == 422

    res = client.post(
        "/api/settings",
        json={"local_model": "mlx-community/whisper-small"},
        headers=headers,
    )
    assert res.status_code == 200


def test_privacy_mode_enforcement(monkeypatch):
    headers = {"X-NexVoice-Token": TOKEN}

    # Enable cloud_enabled but set privacy_mode=True
    client.post("/api/settings", json={"cloud_enabled": True, "privacy_mode": True}, headers=headers)
    
    sv = settings_store.load()
    assert sv.cloud_enabled is True
    assert sv.privacy_mode is True

    # Even with API key present, privacy_mode=True forces local engine
    monkeypatch.setenv("GEMINI_API_KEY", "fake_key")
    raw, cleaned, text, engine, model_used, duration_ms = gateway_app._run_pipeline(
        audio_bytes=MINIMAL_WAV,
        mode="cloud",
        settings=sv,
        do_cleanup=False,
        eff_style="tidy",
    )
    assert engine == "local"

    # cleanup api under privacy mode
    res = client.post("/api/cleanup", json={"text": "hello world"}, headers=headers)
    assert res.status_code == 200
    assert res.json()["text"] == "hello world"

    # Revert privacy mode
    client.post("/api/settings", json={"privacy_mode": False, "cloud_enabled": False}, headers=headers)


def test_payload_limit():
    headers = {"X-NexVoice-Token": TOKEN}
    huge_data = b"0" * (33 * 1024 * 1024) # 33 MB > 32 MB limit
    files = {"audio": ("test.wav", huge_data, "audio/wav")}
    res = client.post("/api/transcribe", files=files, headers=headers)
    assert res.status_code == 413


def test_cleanup_demotes_to_local_when_cloud_disabled(monkeypatch):
    headers = {"X-NexVoice-Token": TOKEN}
    monkeypatch.setenv("GEMINI_API_KEY", "fake_key")

    # Assert API POST cleanup_engine=groq responds with 422 validation error
    res = client.post(
        "/api/settings",
        json={"cleanup_engine": "groq"},
        headers=headers,
    )
    assert res.status_code == 422

    # Directly construct SettingsView with legacy cleanup_engine="groq" and cloud_enabled=False
    sv = settings_store.SettingsView(
        cloud_enabled=False,
        privacy_mode=False,
        cleanup_enabled=True,
        cleanup_engine="groq",
    )
    captured_engine = None

    def mock_cleanup_text(raw, **kwargs):
        nonlocal captured_engine
        captured_engine = kwargs.get("engine")
        return raw

    monkeypatch.setattr(gateway_app.cleanup, "cleanup_text", mock_cleanup_text)
    monkeypatch.setattr(
        gateway_app.stt_router,
        "transcribe",
        lambda **kw: ("hello", "local", "mlx", 100),
    )

    gateway_app._run_pipeline(
        audio_bytes=MINIMAL_WAV,
        mode="auto",
        settings=sv,
        do_cleanup=True,
        eff_style="tidy",
    )

    assert captured_engine == "local"


def test_ordered_patch_atomic_failure_retains_privacy_mode():
    headers = {"X-NexVoice-Token": TOKEN}

    # Initial state: cloud_enabled=true, privacy_mode=true
    client.post(
        "/api/settings",
        json={"cloud_enabled": True, "privacy_mode": True},
        headers=headers,
    )

    sv_before = settings_store.load()
    assert sv_before.cloud_enabled is True
    assert sv_before.privacy_mode is True

    # Send ordered dict patch: privacy_mode=False first, then invalid cloud_model
    # Using JSON payload with privacy_mode first
    patch_payload = {
        "privacy_mode": False,
        "cloud_model": "",
    }

    res = client.post("/api/settings", json=patch_payload, headers=headers)
    assert res.status_code == 422

    # Verify DB was NOT updated partially and privacy_mode remains True
    sv_after = settings_store.load()
    assert sv_after.privacy_mode is True
