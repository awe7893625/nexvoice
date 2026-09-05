import array
import io
import math
import os
import sys
import types
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import nexvoice_local_runtime as runtime


def wav_for(samples, sample_rate=16000):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(sample_rate)
        out.writeframes(
            array.array(
                "h", [int(max(-1, min(1, sample)) * 32767) for sample in samples]
            ).tobytes()
        )
    return buf.getvalue()


def fake_mlx(calls):
    module = types.ModuleType("mlx_whisper")

    def transcribe(path, **kwargs):
        with wave.open(path, "rb") as audio:
            calls.append(audio.getnframes())
        return {"text": "spoken text"}

    module.transcribe = transcribe
    return module


def speech_samples(seconds=1.0, sample_rate=16000):
    count = int(seconds * sample_rate)
    return [
        (0.25 + 0.2 * (0.5 + 0.5 * math.sin(2 * math.pi * 3 * i / sample_rate)))
        * math.sin(2 * math.pi * 180 * i / sample_rate)
        for i in range(count)
    ]


class TestVad:
    def setup_method(self):
        self.vad_state = patch.object(runtime, "_VAD_TIER", None)
        self.vad_state.start()

    def teardown_method(self):
        self.vad_state.stop()

    def test_digital_silence_is_gated_without_model(self):
        calls = []
        audio = wav_for([0.0] * 16000)
        with patch.dict(sys.modules, {"mlx_whisper": fake_mlx(calls)}):
            assert runtime.transcribe_wav(audio) == ""
        assert calls == []

    def test_tone_and_white_noise_are_gated_by_vad(self):
        calls = []
        tone = wav_for(
            [0.2 * math.sin(2 * math.pi * 220 * i / 16000) for i in range(16000)]
        )
        noise = wav_for(np.random.default_rng(7).uniform(-0.2, 0.2, 16000))
        with patch.dict(sys.modules, {"mlx_whisper": fake_mlx(calls)}):
            assert runtime.transcribe_wav(tone) == ""
            assert runtime.transcribe_wav(noise) == ""
        assert calls == []

    def test_leading_silence_is_trimmed_but_speech_decodes(self):
        calls = []
        samples = [0.0] * (3 * 16000) + speech_samples() + [0.0] * (16000 // 2)
        # The synthetic AM-tone fixture is speech-like to the numpy energy
        # gate but is (correctly) rejected by the learned silero tier; this
        # test characterizes the numpy trim contract. Real-speech trim
        # coverage for the silero tier lives in tests/test_vad_silero.py.
        with patch.object(runtime, "_VAD_TIER", "numpy"), patch.dict(
            sys.modules, {"mlx_whisper": fake_mlx(calls)}
        ):
            assert runtime.transcribe_wav(wav_for(samples)) == "spoken text"
        assert len(calls) == 1
        assert 16000 < calls[0] < len(samples)
        assert calls[0] < len(samples) - 2 * 16000

    def test_environment_escape_hatch_skips_vad(self):
        calls = []
        tone = wav_for(
            [0.2 * math.sin(2 * math.pi * 220 * i / 16000) for i in range(16000)]
        )
        with patch.dict(os.environ, {"NEXVOICE_VAD": "0"}), patch.dict(
            sys.modules, {"mlx_whisper": fake_mlx(calls)}
        ):
            assert runtime.transcribe_wav(tone) == "spoken text"
        assert calls == [16000]

    def test_reenabling_vad_after_disabled_selection_still_gates(self):
        tone = wav_for(
            [0.2 * math.sin(2 * math.pi * 1000 * i / 16000) for i in range(5 * 16000)]
        )
        with patch.dict(os.environ, {"NEXVOICE_VAD": "0"}):
            # Tier selection is orthogonal to the master VAD switch; whatever
            # backend is selected, re-enabling must gate this steady tone.
            assert runtime._select_vad_tier() in {"numpy", "silero"}
        with patch.dict(os.environ, {"NEXVOICE_VAD": "1"}):
            assert runtime._trim_wav_for_vad(tone) == b""

    def test_silero_can_be_forced_off_before_session_creation(self):
        with patch.object(runtime, "_VAD_TIER", None), patch.object(
            runtime, "_SILERO_SESSION", None
        ), patch.object(runtime, "_SILERO_UNAVAILABLE", False), patch.object(
            runtime, "_SILERO_ENABLED", None
        ), patch.dict(
            os.environ, {"NEXVOICE_VAD_SILERO": "0"}
        ):
            assert runtime._silero_session() is None
            assert runtime._select_vad_tier() == "numpy"

    def test_tier_selection_contract(self):
        # numpy is the always-available floor (pure numpy, no model); silero is
        # auto-selected exactly when its onnxruntime backend and pinned model
        # resolve. Selection is cached per process.
        samples = np.asarray(speech_samples(), dtype=np.float32)
        tier = runtime._select_vad_tier()
        assert tier in {"numpy", "silero"}
        if tier == "silero":
            assert runtime._silero_session() is not None
            with patch.object(runtime, "_silero_vad", wraps=runtime._silero_vad) as silero_vad:
                runtime._vad_bounds(samples, 16000)
                assert silero_vad.called
        assert runtime._numpy_vad(samples, 16000)[0]
