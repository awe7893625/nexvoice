#!/usr/bin/env python3
"""Acceptance tests for the VAD pre-gate (feat/vad-pregate, commit 2e5a214).

Matrix (mirrors TEST_PLAN.md):
  Positive -- real speech must survive the gate at 0/-10/-20/-26 dB:
      say(Meijia, zh-TW) and say(Samantha, en-US), mono 16 kHz WAV.
  Negative -- non-speech must be gated before Whisper:
      digital silence, white noise (-26 dB, -40 dB), steady 220 Hz tone,
      single click impulse. A composite click + quiet sweep is a documented
      KNOWN-LIMITATION and is expected to pass the numpy gate.

Run:  python3 runtime/tests/test_vad_pregate.py
Exit 0 = all cases pass; nonzero = failures (each case listed).
"""
from __future__ import annotations

import io
import os
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

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


def synth_say(text: str, voice: str, workdir: Path) -> tuple[Path, str]:
    aiff = workdir / f"say_{voice}.aiff"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    wav = workdir / f"say_{voice}_16k.wav"
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
        check=True,
    )
    with wave.open(str(wav), "rb") as rendered:
        has_audio = rendered.getnframes() > 0
    if not has_audio:
        # A zero-frame render must never silently degrade TTS acceptance into
        # a synthetic-fixture pass. Portability mode (VAD_TEST_ALLOW_SYNTHETIC
        # =1) keeps the matrix runnable on headless runners, clearly labelled;
        # strict mode (default) blocks instead.
        if os.environ.get("VAD_TEST_ALLOW_SYNTHETIC") != "1":
            raise RuntimeError(
                f"say rendered 0 frames for voice {voice!r}; TTS acceptance blocked"
            )
        sample_rate = 16000
        t = np.arange(sample_rate, dtype=np.float32) / sample_rate
        active = (t >= 0.2) & (t < 0.8)
        active_time = t[active] - 0.2
        envelope = 0.3 + 0.3 * (0.5 + 0.5 * np.sin(2 * np.pi * 3 * active_time))
        samples = np.zeros_like(t)
        samples[active] = envelope * np.sin(2 * np.pi * 180 * active_time)
        with wave.open(str(wav), "wb") as fallback:
            fallback.setnchannels(1)
            fallback.setsampwidth(2)
            fallback.setframerate(sample_rate)
            fallback.writeframes((samples * 32768.0).astype("<i2").tobytes())
        print(f"synth {voice}: TTS returned 0 frames; source=synthetic-fallback")
        return wav, "synthetic-fallback"
    return wav, "say"


def read_wav(path: Path) -> tuple[np.ndarray, object]:
    with wave.open(str(path), "rb") as wav:
        params = wav.getparams()
        raw = wav.readframes(wav.getnframes())
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    return samples, params


def attenuate(samples: np.ndarray, db: float) -> np.ndarray:
    return samples * (10.0 ** (db / 20.0))


def to_wav_bytes(samples: np.ndarray, params) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setparams(params)
        wav.writeframes((samples * 32768.0).astype("<i2").tobytes())
    return buf.getvalue()


def main() -> int:
    print(f"NEXVOICE_VAD={rt._vad_enabled()}  tier={rt._select_vad_tier()}")
    with tempfile.TemporaryDirectory(prefix="nexvoice-vad-") as tmp:
        workdir = Path(tmp)
        speech = {}
        for voice, text in (("Meijia", ZH_TEXT), ("Samantha", EN_TEXT)):
            path, source = synth_say(text, voice, workdir)
            samples, params = read_wav(path)
            speech[voice] = (samples, params)
            dur = len(samples) / params.framerate
            print(f"synth {voice}: {dur:.2f}s @ {params.framerate} Hz source={source}")

        # Positive: real speech survives the gate at every level, and the trim
        # keeps the utterance (bounds must not eat more than the padding).
        for voice, (samples, params) in speech.items():
            for db in SPEECH_LEVELS_DB:
                name = f"speech:{voice}@{db:+d}dB survives"
                gated = rt._trim_wav_for_vad(to_wav_bytes(attenuate(samples, db), params))
                record(name, "kept", "gated" if gated == b"" else "kept")
                if gated:
                    trim_name = f"speech:{voice}@{db:+d}dB keeps>=50% length"
                    with wave.open(io.BytesIO(gated), "rb") as wav:
                        kept = wav.getnframes()
                    record(trim_name, "yes", "yes" if kept >= 0.5 * len(samples) else "no")

        # transcribe_wav gate path: gated noise must short-circuit to "".
        noise = np.random.default_rng(7).standard_normal(len(speech["Meijia"][0]))
        noise = noise / (np.max(np.abs(noise)) + 1e-12)
        params = speech["Meijia"][1]
        for db in (-26, -40):
            name = f"noise@{db}dB gated"
            out = rt._trim_wav_for_vad(to_wav_bytes(attenuate(noise, db), params))
            record(name, "gated", "gated" if out == b"" else "kept")

        # Silence: both the peak gate and the VAD must reject.
        out = rt._trim_wav_for_vad(to_wav_bytes(np.zeros_like(noise), params))
        record("digital silence gated", "gated", "gated" if out == b"" else "kept")

        # Steady tone: ZCR near zero must fail the crossing window.
        t = np.arange(len(noise)) / params.framerate
        tone = 0.25 * np.sin(2 * np.pi * 220.0 * t)
        out = rt._trim_wav_for_vad(to_wav_bytes(tone.astype(np.float32), params))
        record("220Hz tone gated", "gated", "gated" if out == b"" else "kept")

        # Single click: one impulse must not open the gate.
        click = np.zeros_like(noise)
        click[len(click) // 2] = 0.5
        out = rt._trim_wav_for_vad(to_wav_bytes(click, params))
        record("single click gated", "gated", "gated" if out == b"" else "kept")

        # KNOWN-LIMITATION: a high-amplitude click plus a quiet frequency
        # sweep (-26 dB) can pass this numpy gate. Silero/ONNX is the follow-up
        # tier; lock the current behavior here so it cannot drift silently.
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
            "KNOWN-LIMITATION composite click+sweep kept",
            "kept",
            "gated" if out == b"" else "kept",
        )

    print()
    passed = sum(1 for _, e, g in results if e == g)
    known = sum(1 for name, e, g in results if e == g and name.startswith("KNOWN-LIMITATION"))
    print(
        f"RESULT: {passed - known}/{len(results) - known} acceptance pass"
        f" (+{known} KNOWN-LIMITATION reproduced)"
    )
    if failures:
        print("FAILURES:")
        for line in failures:
            print(f"  - {line}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
