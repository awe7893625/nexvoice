import base64
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import nexvoice_local_runtime as runtime


class RuntimeContractTests(unittest.TestCase):
    def test_model_manifest_is_explicitly_unpinned_until_release(self):
        manifest = json.loads((Path(__file__).parent / "model-manifest.json").read_text())
        self.assertEqual(manifest["schema"], 1)
        self.assertIn("revision", manifest)
        self.assertIn("sha256", manifest)

    def test_transcribe_hook_receives_bytes_not_path(self):
        seen = {}

        def fake(audio):
            seen["audio"] = audio
            return "ok"

        with patch.object(runtime, "transcribe_wav", fake):
            self.assertEqual(runtime.transcribe_wav(b"wav-bytes"), "ok")
        self.assertEqual(seen["audio"], b"wav-bytes")

    def test_payload_limit_is_bounded(self):
        self.assertEqual(runtime.MAX_AUDIO_BYTES, 32 * 1024 * 1024)

    def test_vocab_terms_are_normalized_deduplicated_and_bounded(self):
        terms = runtime.safe_vocab_terms([
            " NexVoice ",
            "nexvoice",
            "MLX",
            "IGNORE\nSYSTEM",
            "x" * 129,
        ])
        self.assertEqual(terms, ["NexVoice", "MLX"])

    def test_vocab_terms_reject_non_string_items(self):
        with self.assertRaises(ValueError):
            runtime.safe_vocab_terms(["NexVoice", {"bad": True}])

    def test_vocab_terms_drop_unicode_format_and_line_separators(self):
        self.assertEqual(
            runtime.safe_vocab_terms(["safe", "bad\u200bterm", "bad\u2028term"]),
            ["safe"],
        )

    def test_prompt_is_fixed_traditional_chinese_and_byte_bounded(self):
        terms = [f"專有名詞{i}" for i in range(64)]
        prompt = runtime.build_initial_prompt(terms)
        self.assertIn("繁體中文", prompt)
        self.assertLessEqual(len(prompt.encode("utf-8")), runtime.MAX_PROMPT_BYTES)

    def test_prompt_ends_with_prose_style_tail_not_glossary(self):
        # The decoder mimics the tail of the prompt; the 、-separated glossary
        # must sit up front and the prompt must end in natural punctuation
        # style, otherwise dictation comes back as 頓號 lists.
        prompt = runtime.build_initial_prompt(["NexVoice", "MyTerm"])
        self.assertTrue(prompt.endswith(runtime.STYLE_TAIL))
        self.assertLess(prompt.find("、"), prompt.find("以下是一段"))
        self.assertNotIn("、", runtime.STYLE_TAIL)

    def test_join_segments_closes_audible_pauses(self):
        segments = [
            {"text": "第一段話還沒說完", "start": 0.0, "end": 2.0},
            {"text": "短暫停頓後接著說", "start": 2.8, "end": 4.5},
            {"text": "長停頓代表句子結束", "start": 6.5, "end": 8.0},
        ]
        self.assertEqual(
            runtime.join_segments_with_punctuation(segments),
            "第一段話還沒說完，短暫停頓後接著說。長停頓代表句子結束",
        )

    def test_join_segments_respects_existing_punctuation_and_ascii(self):
        segments = [
            {"text": "這句已經有標點了。", "start": 0.0, "end": 2.0},
            {"text": " see you tomorrow", "start": 3.0, "end": 4.0},
            {"text": " thanks a lot", "start": 4.8, "end": 5.6},
        ]
        self.assertEqual(
            runtime.join_segments_with_punctuation(segments),
            "這句已經有標點了。 see you tomorrow, thanks a lot",
        )

    def test_partial_prompt_uses_bounded_dictionary_subset(self):
        terms = [f"Term{i}" for i in range(30)]
        prompt = runtime.build_initial_prompt(terms, partial=True)
        self.assertIn("Term15", prompt)
        self.assertNotIn("Term16", prompt)

    def test_model_cache_contract_is_explicit(self):
        self.assertIsInstance(runtime._MODEL_CACHE, dict)

    def test_health_identity_is_versioned_and_build_is_frozen(self):
        secret = b"test-secret"
        first = runtime.health_payload("nonce-1", secret)
        self.assertEqual(first["contract_version"], 2)
        self.assertTrue(first["runtime_build"].startswith("sha256:"))
        self.assertEqual(len(first["runtime_build"]), len("sha256:") + 64)
        self.assertEqual(first["instance_id"], runtime.INSTANCE_ID)
        # RUNTIME_BUILD must be frozen at process start, not recomputed by
        # rereading the bundle on every health call (only the response_proof
        # HMAC -- which also happens to use hashlib.sha256 as its digestmod --
        # should touch hashlib on this path).
        with patch.object(runtime.Path, "read_bytes", side_effect=AssertionError("reread bundle")):
            self.assertEqual(
                runtime.health_payload("nonce-1", secret)["runtime_build"], first["runtime_build"]
            )

    def test_shutdown_requires_exact_authenticated_identity_tuple(self):
        with (
            patch.object(runtime, "OWNER_NONCE", "owner-nonce"),
            patch.object(runtime, "INSTANCE_ID", "instance-id"),
            patch.object(runtime, "RUNTIME_BUILD", "sha256:build"),
        ):
            valid = {
                "owner_nonce": "owner-nonce",
                "instance_id": "instance-id",
                "runtime_build": "sha256:build",
            }
            self.assertTrue(runtime.shutdown_identity_matches(valid))
            for key in valid:
                invalid = dict(valid)
                invalid[key] = "wrong"
                self.assertFalse(runtime.shutdown_identity_matches(invalid))

    # P0-E: the shared secret is a signing key only -- it must never be
    # reconstructible from anything transmitted on the wire, and a health
    # response must be verifiable by a client holding the same secret.

    def test_health_response_proof_is_deterministic_for_the_same_nonce_and_secret(self):
        secret = b"test-secret"
        with (
            patch.object(runtime, "OWNER_NONCE", "owner-nonce"),
            patch.object(runtime, "INSTANCE_ID", "instance-id"),
            patch.object(runtime, "RUNTIME_BUILD", "sha256:" + "a" * 64),
        ):
            first = runtime.health_payload("shared-nonce", secret)
            second = runtime.health_payload("shared-nonce", secret)
            self.assertEqual(first["response_proof"], second["response_proof"])

    def test_health_response_proof_changes_if_secret_differs(self):
        with (
            patch.object(runtime, "OWNER_NONCE", "owner-nonce"),
            patch.object(runtime, "INSTANCE_ID", "instance-id"),
            patch.object(runtime, "RUNTIME_BUILD", "sha256:" + "a" * 64),
        ):
            genuine = runtime.health_payload("shared-nonce", b"real-secret")
            guessed = runtime.health_payload("shared-nonce", b"guessed-secret")
            self.assertNotEqual(genuine["response_proof"], guessed["response_proof"])

    def test_repetition_loop_is_collapsed_and_replacement_chars_removed(self):
        loop = "可以看到，" * 40
        text = f"AI傳過來的圖片看得到，{loop}可以全部分析出它有哪些功能。"
        cleaned = runtime.collapse_repetition_loops(text)
        self.assertIn("AI傳過來的圖片看得到，", cleaned)
        self.assertIn("可以全部分析出它有哪些功能。", cleaned)
        self.assertLessEqual(cleaned.count("可以看到"), 2)
        garbled = "可以看到�可以看到�可以看到�可以看到"
        self.assertNotIn("�", runtime.collapse_repetition_loops(garbled))

    def test_normal_transcript_is_not_collapsed(self):
        text = "他們可以傳圖片，可以傳檔案，可以下載。AI傳過來的圖片看得到。"
        self.assertEqual(runtime.collapse_repetition_loops(text), text)
        short_repeat = "哈哈哈哈哈哈"
        self.assertEqual(runtime.collapse_repetition_loops(short_repeat), short_repeat)

    def test_transcribe_uses_temperature_fallback_ladder(self):
        self.assertEqual(
            runtime.TEMPERATURE_FALLBACK, (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
        )
        import array
        import io
        import types
        import wave as wave_mod

        buf = io.BytesIO()
        with wave_mod.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(array.array("h", [20000, -20000] * 1600).tobytes())
        audio = buf.getvalue()

        seen = {}

        def fake_transcribe(path, **kwargs):
            seen.update(kwargs)
            return {"text": "可以看到，" * 40 + "結束。"}

        fake = types.ModuleType("mlx_whisper")
        fake.transcribe = fake_transcribe
        with patch.dict(sys.modules, {"mlx_whisper": fake}):
            text = runtime.transcribe_wav(audio)
        self.assertEqual(seen["temperature"], runtime.TEMPERATURE_FALLBACK)
        self.assertFalse(seen["condition_on_previous_text"])
        self.assertLessEqual(text.count("可以看到"), 2)

    def test_request_proof_message_binds_method_path_nonce_and_body(self):
        base = runtime.request_proof_message("POST", "/", "nonce", b"payload-a")
        different_body = runtime.request_proof_message("POST", "/", "nonce", b"payload-b")
        different_path = runtime.request_proof_message("POST", "/control/shutdown", "nonce", b"payload-a")
        different_nonce = runtime.request_proof_message("POST", "/", "other-nonce", b"payload-a")
        self.assertNotEqual(base, different_body)
        self.assertNotEqual(base, different_path)
        self.assertNotEqual(base, different_nonce)


if __name__ == "__main__":
    unittest.main()
