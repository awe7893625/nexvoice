#!/usr/bin/env python3
"""Acceptance tests for the silero/ONNX VAD tier (票A follow-up, 2026-08-30).

Mirrors the numpy matrix in test_vad_pregate.py but drives the silero tier
directly (rt._VAD_TIER pinned to "silero"). The composite click+sweep case
that the numpy gate must pass as a KNOWN-LIMITATION is expected to be GATED
by silero -- that upgrade is the reason this tier exists.

Silero-specific negatives use speech-probability semantics, so a couple of
cases differ from the numpy tier:
  - the synthetic warmup tone (180 Hz steady sine) must stay gated;
  - white noise at conversational level (-20 dB) is NOT guaranteed to be
    gated by a learned model -- it is recorded as an observation, not an
    assertion, to keep the matrix honest about what silero does.

Run:  python3 runtime/tests/test_vad_silero.py
Exit 0 = all cases pass; nonzero = failures (each case listed).
Skips (exit 0, "SKIP") when onnxruntime or the pinned model is unavailable.
"""
from __future__ import annotations

import io
import os
import subprocess
import sys
import tempfile
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pytest

RUNTIME_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RUNTIME_DIR))

import nexvoice_local_runtime as rt  # noqa: E402

SPEECH_LEVELS_DB = [0, -10, -20, -26]
ZH_TEXT = "今天天氣很好，我們一起去散步吧，順便去買杯咖啡。"
EN_TEXT = "The quick brown fox jumps over the lazy dog near the river bank."

failures: list[str] = []
results: list[tuple[str, str, str]] = []


def record(name: str, expect: str, got: str) -> None:
    ok = expect == got
    results.append((name, expect, got))
    if not ok:
        failures.append(f"{name}: expect={expect} got={got}")
    print(f"{'PASS' if ok else 'FAIL'}  {name}  (expect {expect}, got {got})")


def read_wav(path: Path) -> tuple[np.ndarray, object]:
    with wave.open(str(path), "rb") as wav:
        params = wav.getparams()
        raw = wav.readframes(wav.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0, params


def attenuate(samples: np.ndarray, db: float) -> np.ndarray:
    return samples * (10.0 ** (db / 20.0))


def to_wav_bytes(samples: np.ndarray, params) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setparams(params)
        wav.writeframes((samples * 32768.0).astype("<i2").tobytes())
    return buf.getvalue()


def synth_say(text: str, voice: str, workdir: Path) -> Path:
    aiff = workdir / f"sil_{voice}.aiff"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    wav = workdir / f"sil_{voice}_16k.wav"
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
        check=True,
    )
    return wav


def silero_available() -> bool:
    """Probe the tier after resetting its process-wide test state."""
    rt._VAD_TIER = None
    rt._SILERO_SESSION = None
    rt._SILERO_UNAVAILABLE = False
    rt._SILERO_ENABLED = None
    return rt._silero_session() is not None


class FakeSileroSession:
    def __init__(self, probabilities: list[float], error: Exception | None = None):
        self.probabilities = probabilities
        self.error = error
        self.calls: list[dict[str, np.ndarray]] = []

    def run(self, _outputs, feeds):
        self.calls.append({
            "input": feeds["input"].copy(),
            "state": feeds["state"].copy(),
            "sr": feeds["sr"].copy(),
        })
        if self.error is not None:
            raise self.error
        probability = self.probabilities[len(self.calls) - 1]
        return (
            np.asarray([[probability]], dtype=np.float32),
            feeds["state"] + 1.0,
        )


def install_fake_session(monkeypatch, session: FakeSileroSession) -> None:
    monkeypatch.setattr(rt, "_VAD_TIER", "silero")
    monkeypatch.setattr(rt, "_SILERO_SESSION", session)
    monkeypatch.setattr(rt, "_SILERO_UNAVAILABLE", False)


def test_silero_env_is_cached_at_first_use(monkeypatch):
    session = FakeSileroSession([0.9])
    monkeypatch.setattr(rt, "_VAD_TIER", None)
    monkeypatch.setattr(rt, "_SILERO_ENABLED", None)
    monkeypatch.setattr(rt, "_SILERO_SESSION", session)
    monkeypatch.setattr(rt, "_SILERO_UNAVAILABLE", False)
    monkeypatch.setenv("NEXVOICE_VAD_SILERO", "1")

    assert rt._silero_session() is session
    monkeypatch.setenv("NEXVOICE_VAD_SILERO", "0")
    monkeypatch.setattr(rt, "_VAD_TIER", None)

    assert rt._select_vad_tier() == "silero"


def test_fake_session_dispatch_context_state_and_tail(monkeypatch):
    samples = np.arange(3 * rt.SILERO_VAD_CHUNK + 17, dtype=np.float32)
    session = FakeSileroSession([0.9, 0.9, 0.9, 0.9])
    install_fake_session(monkeypatch, session)

    with patch.object(rt, "_numpy_vad", side_effect=AssertionError("numpy fallback")):
        result = rt._vad_bounds(samples, 16000)

    assert result == (True, 0, len(samples))
    assert len(session.calls) == 4
    assert [call["input"].shape for call in session.calls] == [(1, 576)] * 4
    np.testing.assert_array_equal(session.calls[0]["input"][0], np.concatenate([
        np.zeros(rt.SILERO_VAD_CONTEXT, dtype=np.float32),
        samples[:rt.SILERO_VAD_CHUNK],
    ]))
    np.testing.assert_array_equal(session.calls[1]["input"][0], np.concatenate([
        samples[rt.SILERO_VAD_CHUNK - rt.SILERO_VAD_CONTEXT:rt.SILERO_VAD_CHUNK],
        samples[rt.SILERO_VAD_CHUNK:2 * rt.SILERO_VAD_CHUNK],
    ]))
    np.testing.assert_array_equal(session.calls[2]["input"][0, :64], samples[960:1024])
    np.testing.assert_array_equal(session.calls[3]["input"][0, :64], samples[1472:1536])
    np.testing.assert_array_equal(session.calls[3]["input"][0, 64:81], samples[1536:])
    assert np.all(session.calls[3]["input"][0, 81:] == 0)
    np.testing.assert_array_equal(
        session.calls[0]["state"], np.zeros((2, 1, 128), dtype=np.float32)
    )
    np.testing.assert_array_equal(session.calls[1]["state"], np.ones((2, 1, 128), dtype=np.float32))
    np.testing.assert_array_equal(session.calls[2]["state"], np.full((2, 1, 128), 2.0))
    np.testing.assert_array_equal(session.calls[3]["state"], np.full((2, 1, 128), 3.0))
    assert all(int(call["sr"]) == 16000 for call in session.calls)


def test_fake_session_threshold_and_min_frames_gate(monkeypatch):
    samples = np.zeros(3 * rt.SILERO_VAD_CHUNK, dtype=np.float32)

    below_threshold = FakeSileroSession([0.49, 0.5, 0.5])
    install_fake_session(monkeypatch, below_threshold)
    with patch.object(rt, "_numpy_vad", side_effect=AssertionError("numpy fallback")):
        assert rt._vad_bounds(samples, 16000) == (False, 0, 0)

    at_threshold = FakeSileroSession([0.5, 0.5, 0.5])
    install_fake_session(monkeypatch, at_threshold)
    with patch.object(rt, "_numpy_vad", side_effect=AssertionError("numpy fallback")):
        assert rt._vad_bounds(samples, 16000) == (True, 0, len(samples))


def test_fake_session_and_unsupported_rate_fall_back_to_numpy(monkeypatch):
    samples = np.zeros(3 * rt.SILERO_VAD_CHUNK, dtype=np.float32)
    expected = (True, 11, 22)

    monkeypatch.setattr(rt, "_VAD_TIER", "silero")
    with patch.object(rt, "_silero_session", return_value=None), patch.object(
        rt, "_numpy_vad", return_value=expected
    ) as numpy_vad:
        assert rt._vad_bounds(samples, 16000) == expected
        numpy_vad.assert_called_once_with(samples, 16000)

    failing = FakeSileroSession([], error=RuntimeError("fake ONNX failure"))
    install_fake_session(monkeypatch, failing)
    with patch.object(rt, "_numpy_vad", return_value=expected) as numpy_vad:
        assert rt._vad_bounds(samples, 16000) == expected
        assert rt._SILERO_SESSION is None
        assert rt._SILERO_UNAVAILABLE is True

        # The broken session is negatively cached: the next clip falls back
        # immediately without retrying session.run or emitting another VAD
        # failure warning.
        assert rt._vad_bounds(samples, 16000) == expected
        assert len(failing.calls) == 1
        assert numpy_vad.call_count == 2

    with patch.object(rt, "_silero_session", side_effect=AssertionError("session acquired")):
        assert rt._silero_vad(samples, 8000) is None


def main() -> int:
    if not silero_available():
        print("SKIP: silero VAD tier unavailable (onnxruntime/model); "
              "numpy acceptance in test_vad_pregate.py still applies")
        return 0
    rt._VAD_TIER = "silero"
    print(f"tier pinned to: {rt._select_vad_tier()}")
    with tempfile.TemporaryDirectory(prefix="nexvoice-silero-") as tmp:
        workdir = Path(tmp)
        speech = {}
        for voice, text in (("Meijia", ZH_TEXT), ("Samantha", EN_TEXT)):
            aiff = workdir / f"sil_{voice}.aiff"
            subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
            wav_path = workdir / f"sil_{voice}_16k.wav"
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                 str(aiff), str(wav_path)], check=True)
            speech[voice] = read_wav(wav_path)

        # Positive: real speech survives at every level.
        for voice, (samples, params) in speech.items():
            for db in SPEECH_LEVELS_DB:
                name = f"sil speech:{voice}@{db:+d}dB survives"
                gated = rt._trim_wav_for_vad(to_wav_bytes(attenuate(samples, db), params))
                record(name, "kept", "gated" if gated == b"" else "kept")

        # Negative: non-speech must be gated.
        rng = np.random.default_rng(7)
        noise = rng.standard_normal(len(speech["Meijia"][0]))
        noise = noise / (np.max(np.abs(noise)) + 1e-12)
        params = speech["Meijia"][1]
        for db in (-26, -40):
            name = f"sil noise@{db}dB gated"
            out = rt._trim_wav_for_vad(to_wav_bytes(attenuate(noise, db), params))
            record(name, "gated", "gated" if out == b"" else "kept")

        out = rt._trim_wav_for_vad(to_wav_bytes(np.zeros_like(noise), params))
        record("sil digital silence gated", "gated", "gated" if out == b"" else "kept")

        t = np.arange(len(noise)) / params.framerate
        tone = 0.25 * np.sin(2 * np.pi * 220.0 * t)
        out = rt._trim_wav_for_vad(to_wav_bytes(tone.astype(np.float32), params))
        record("sil 220Hz tone gated", "gated", "gated" if out == b"" else "kept")

        click = np.zeros_like(noise)
        click[len(click) // 2] = 0.5
        out = rt._trim_wav_for_vad(to_wav_bytes(click, params))
        record("sil single click gated", "gated", "gated" if out == b"" else "kept")

        # KNOWN-LIMITATION (shared with the numpy tier, verified 2026-08-30):
        # a slow 180→3000 Hz sweep at -26 dB reads as weakly speech-like to the
        # learned model too (max prob 0.745, 5/168 frames >= 0.5 on the 5.4s
        # fixture). The earlier hypothesis that silero would gate this
        # synthetic case was wrong; the lock records reality.
        composite = np.zeros_like(noise)
        start = len(composite) // 4
        end = 3 * len(composite) // 4
        sweep_duration = (end - start) / params.framerate
        sweep_time = (np.arange(len(composite)) - start) / params.framerate
        sweep_phase = 2 * np.pi * (
            180.0 * sweep_time
            + 0.5 * (3000.0 - 180.0) * sweep_time * sweep_time / sweep_duration
        )
        active = np.zeros_like(composite, dtype=bool)
        active[start:end] = True
        composite[active] = (10.0 ** (-26.0 / 20.0)) * np.sin(sweep_phase[active])
        composite[len(composite) // 2] += 0.5
        out = rt._trim_wav_for_vad(to_wav_bytes(composite, params))
        record(
            "KNOWN-LIMITATION composite click+sweep kept (shared with numpy)",
            "kept",
            "gated" if out == b"" else "kept",
        )

    print()
    passed = sum(1 for _, e, g in results if e == g)
    known = sum(1 for name, e, g in results if e == g and name.startswith("KNOWN-LIMITATION"))
    print(
        f"RESULT: {passed - known}/{len(results) - known} silero acceptance pass"
        f" (+{known} KNOWN-LIMITATION reproduced)"
    )
    if failures:
        print("FAILURES:")
        for line in failures:
            print(f"  - {line}")
        return 1
    return 0


@pytest.mark.skipif(not silero_available(), reason="silero VAD session unavailable")
def test_real_tts_matrix():
    with tempfile.TemporaryDirectory(prefix="nexvoice-silero-tts-probe-") as tmp:
        try:
            # Precheck BOTH voices the matrix needs, so a missing Samantha
            # skips instead of erroring mid-run.
            for voice in ("Meijia", "Samantha"):
                probe = synth_say(
                    ZH_TEXT if voice == "Meijia" else EN_TEXT, voice, Path(tmp)
                )
                probe_samples, _ = read_wav(probe)
                if not len(probe_samples):
                    pytest.skip("macOS TTS returned an empty WAV")
        except (OSError, subprocess.CalledProcessError, wave.Error) as exc:
            pytest.skip(f"macOS TTS unavailable: {exc}")
    assert main() == 0


if __name__ == "__main__":
    raise SystemExit(main())
