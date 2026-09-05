import base64
import hashlib
import hmac
import io
import json
import sys
import types
import unittest
import wave
from contextlib import ExitStack
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import nexvoice_local_runtime as runtime  # noqa: E402


def _loud_wav() -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(16000)
        wav_file.writeframes((20000).to_bytes(2, "little", signed=True) * 1600)
    return buffer.getvalue()


class SRTExportTests(unittest.TestCase):
    def test_to_srt_formats_multiple_segments_and_carries_milliseconds(self):
        segments = [
            {"start": 0.0, "end": 1.2344, "text": " 第一段 "},
            {"start": 59.9996, "end": 3600.0015, "text": "第二段"},
        ]
        self.assertEqual(
            runtime.to_srt(segments),
            "1\n"
            "00:00:00,000 --> 00:00:01,234\n"
            "第一段\n\n"
            "2\n"
            "00:01:00,000 --> 01:00:00,002\n"
            "第二段",
        )

    def test_to_srt_empty_input_is_empty(self):
        self.assertEqual(runtime.to_srt([]), "")

    def test_transcribe_wav_keeps_string_contract_while_core_returns_segments(self):
        native_segments = [
            {"start": 0.0, "end": 0.8, "text": "hello"},
            {"start": 1.0, "end": 1.8, "text": "world"},
        ]

        def fake_transcribe(path, **kwargs):
            return {"text": "ignored", "segments": native_segments}

        fake_mlx = types.ModuleType("mlx_whisper")
        fake_mlx.transcribe = fake_transcribe
        with (
            patch.object(runtime, "pinned_model_path", side_effect=lambda model: model),
            patch.dict(sys.modules, {"mlx_whisper": fake_mlx}),
            patch.dict(runtime.os.environ, {"NEXVOICE_VAD": "0"}),
        ):
            text, segments = runtime._transcribe_core(_loud_wav())

        self.assertEqual(text, "helloworld")
        self.assertIs(segments, native_segments)
        with patch.object(runtime, "_transcribe_core", return_value=("contract text", native_segments)):
            self.assertEqual(runtime.transcribe_wav(b"wav-bytes"), "contract text")


class RuntimeHandlerSRTContractTests(unittest.TestCase):
    SECRET = b"test-token"
    SESSION = "00000000-0000-0000-0000-000000000000"

    def setUp(self):
        self.temp = TemporaryDirectory()
        token = Path(self.temp.name) / "token"
        token.write_bytes(self.SECRET)
        self.core_segments = [
            {"start": 0.0, "end": 1.25, "text": " first ", "id": 7},
            {"start": 2.0, "end": 3.0, "text": "second", "id": 8},
        ]
        self.stack = ExitStack()
        self.stack.enter_context(patch.object(runtime, "TOKEN", token))
        self.stack.enter_context(
            patch.object(runtime, "transcribe_wav", return_value="default text")
        )
        self.stack.enter_context(
            patch.object(
                runtime,
                "_transcribe_core",
                return_value=("timed text", self.core_segments),
            )
        )
    def tearDown(self):
        self.stack.close()
        self.temp.cleanup()

    def request(self, body):
        raw = json.dumps(body).encode()
        nonce = "test-nonce"
        proof = hmac.new(
            self.SECRET,
            runtime.request_proof_message("POST", "/", nonce, raw).encode(),
            hashlib.sha256,
        ).digest()
        handler = object.__new__(runtime.Handler)
        handler.path = "/"
        handler.command = "POST"
        handler.headers = {
            "Content-Length": str(len(raw)),
            "X-NexVoice-Local-Nonce": nonce,
            "X-NexVoice-Local-Proof": base64.b64encode(proof).decode(),
        }
        handler.rfile = io.BytesIO(raw)
        handler.wfile = io.BytesIO()
        handler.send_response = lambda status: None
        handler.send_header = lambda name, value: None
        handler.end_headers = lambda: None
        runtime.Handler.do_POST(handler)
        return json.loads(handler.wfile.getvalue())

    def base_body(self):
        return {
            "audio_base64": base64.b64encode(b"audio").decode(),
            "session": self.SESSION,
            "sequence": 0,
            "quality": "final",
        }

    def test_default_response_has_original_payload_shape(self):
        response = self.request(self.base_body())
        self.assertEqual(
            set(response),
            {
                "text",
                "ms",
                "session",
                "sequence",
                "contract_version",
                "runtime_build",
                "instance_id",
                "response_proof",
            },
        )
        self.assertEqual(response["text"], "default text")

    def test_opt_in_response_contains_segments_and_or_srt(self):
        segments_only = self.request(dict(self.base_body(), want_segments=True))
        self.assertEqual(
            segments_only["segments"],
            [
                {"start": 0.0, "end": 1.25, "text": "first"},
                {"start": 2.0, "end": 3.0, "text": "second"},
            ],
        )
        self.assertNotIn("srt", segments_only)

        srt_only = self.request(dict(self.base_body(), want_srt=True))
        self.assertIn("srt", srt_only)
        self.assertNotIn("segments", srt_only)
        self.assertIn("00:00:00,000 --> 00:00:01,250", srt_only["srt"])

        both = self.request(dict(self.base_body(), want_segments=True, want_srt=True))
        self.assertIn("segments", both)
        self.assertIn("srt", both)
        self.assertEqual(both["text"], "timed text")


if __name__ == "__main__":
    unittest.main()
