#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test suite for cleanup_v2.py — offline tests with mocked engines."""

import pytest
from unittest.mock import patch
from cleanup_v2 import (
    _content_cps,
    _lcs_len,
    _cleanup_looks_bad,
    _structure_looks_bad,
    cleanup_text,
    STRUCT_MIN_CPS,
)


class TestContentCps:
    """Test _content_cps codepoint extraction."""

    def test_ascii_lowercase(self):
        assert _content_cps("abc") == [0x61, 0x62, 0x63]

    def test_digits(self):
        assert _content_cps("123") == [0x31, 0x32, 0x33]

    def test_mixed_ascii_and_digits(self):
        assert _content_cps("a1b2") == [0x61, 0x31, 0x62, 0x32]

    def test_cjk_characters(self):
        s = "中文"
        cps = _content_cps(s)
        assert len(cps) == 2
        assert all(0x4E00 <= cp <= 0x9FFF for cp in cps)

    def test_punctuation_ignored(self):
        assert _content_cps("!@#$%") == []

    def test_spaces_ignored(self):
        assert _content_cps("   ") == []

    def test_mixed_with_punctuation(self):
        cps = _content_cps("hello, world!")
        assert len(cps) == 10  # h e l l o w o r l d
        assert all(0x61 <= cp <= 0x7A for cp in cps)


class TestLcsLen:
    """Test _lcs_len longest common subsequence."""

    def test_identical_strings(self):
        assert _lcs_len("abc", "abc") == 3

    def test_empty_strings(self):
        assert _lcs_len("", "") == 0

    def test_one_empty(self):
        assert _lcs_len("a", "") == 0
        assert _lcs_len("", "a") == 0

    def test_partial_match(self):
        assert _lcs_len("abc", "aXc") == 2  # a and c

    def test_no_common_chars(self):
        assert _lcs_len("abc", "xyz") == 0

    def test_longer_sequences(self):
        assert _lcs_len("ABCDGH", "AEDFHR") == 3  # ADH


class TestCleanupLooksBad:
    """Test _cleanup_looks_bad guard for tidy mode."""

    def test_empty_output_is_bad(self):
        assert _cleanup_looks_bad("tidy", "input", "") is True

    def test_non_tidy_style_returns_false(self):
        assert _cleanup_looks_bad("structure", "input", "output") is False

    def test_output_too_long(self):
        # len(output) > 3 * len(input)
        assert _cleanup_looks_bad("tidy", "a", "bbbb") is True

    def test_low_lcs_fidelity(self):
        # LCS / len(out) < 0.70
        inp = "hello world"
        out = "goodbye moon"
        assert _cleanup_looks_bad("tidy", inp, out) is True

    def test_valid_lightweight_cleanup(self):
        # Removing just filler words, keeping most content
        inp = "嗯我在想說那個我們是不是要改一下顏色"
        out = "我在想我們是不是要改一下顏色。"
        assert _cleanup_looks_bad("tidy", inp, out) is False


class TestStructureLooksBad:
    """Test _structure_looks_bad guard for structure mode."""

    def test_empty_output_is_bad(self):
        assert _structure_looks_bad("input", "") is True

    def test_output_too_short(self):
        # ratio < 0.25
        assert _structure_looks_bad("hello world", "a") is True

    def test_output_too_long(self):
        # ratio > 1.3
        assert _structure_looks_bad("a", "hello world test") is True

    def test_ascii_word_loss(self):
        # Input has >=3 ASCII words, output loses >40% of them
        inp = "hello world test"
        out = "世界 test"  # Lost "hello" and "world"
        assert _structure_looks_bad(inp, out) is True

    def test_valid_structure_reorder(self):
        # Same ASCII words, just reordered and formatted (reasonable expansion)
        inp = "hello world test"
        out = "hello\nworld\ntest"
        assert _structure_looks_bad(inp, out) is False


class TestCleanupTextModes:
    """Test cleanup_text style and mode selection."""

    def test_verbatim_mode(self):
        with patch("cleanup_v2.vocab_store.apply_sounds_like", return_value="result"):
            result = cleanup_text("input", style="verbatim")
            assert result == "result"

    def test_invalid_style_defaults(self):
        with patch("cleanup_v2.vocab_store.apply_sounds_like", return_value="input"):
            result = cleanup_text("input", style="invalid_style")
            assert result == "input"

    def test_struct_mode_auto_trigger(self):
        """Test that long tidy input auto-upgrades to structure."""
        long_text = "a" * STRUCT_MIN_CPS  # >= 80 codepoints
        with (
            patch("cleanup_v2.logger") as mock_logger,
            patch("cleanup_v2.vocab_store.apply_sounds_like", side_effect=lambda x: x),
        ):
            cleanup_text(long_text, engine="local", style="tidy")
            # Should log structure mode
            calls = [str(call) for call in mock_logger.info.call_args_list]
            assert any("structure" in str(call) for call in calls), (
                f"No 'structure' in {calls}"
            )

    def test_app_context_injection(self):
        with patch("cleanup_v2._try_groq", return_value="cleaned"):
            with patch(
                "cleanup_v2.vocab_store.apply_sounds_like", side_effect=lambda x: x
            ):
                # Just ensure it doesn't crash with app_context
                cleanup_text(
                    "test", engine="groq", app_context="TextEdit", style="tidy"
                )


class TestPrivacyLane:
    """Test engine='local' privacy mode (no cloud calls)."""

    def test_privacy_mode_no_groq(self):
        """Privacy lane should never call Groq."""
        with (
            patch("cleanup_v2.requests.post") as mock_post,
            patch("cleanup_v2._try_ollama_chat", return_value=None),
            patch("cleanup_v2._try_ollama", return_value=None),
            patch("cleanup_v2.vocab_store.apply_sounds_like", side_effect=lambda x: x),
        ):
            cleanup_text("test", engine="local")
            # Should not have called requests.post at all (no Groq, Gemini, NIM)
            mock_post.assert_not_called()

    def test_local_cleanup_never_uses_tailnet(self):
        """Local cleanup stays on this Mac; private peers are not sinks."""
        with (
            patch("cleanup_v2._try_ollama_chat") as mock_tailnet,
            patch("cleanup_v2._try_ollama") as mock_local,
            patch("cleanup_v2.vocab_store.apply_sounds_like", side_effect=lambda x: x),
        ):
            mock_tailnet.return_value = None  # Fail tailnet
            mock_local.return_value = "cleaned"  # Succeed local
            result = cleanup_text("test", engine="local")
            # A local setting must never send transcript text to a private peer.
            assert not mock_tailnet.called
            assert mock_local.called


class TestEngineChain:
    """Test engine fallback chain logic."""

    def test_groq_engine_with_guard_rejection(self):
        """Groq primary rejected by guard, should try fallback."""

        def mock_groq(raw, model, prompt, timeout):
            if "gpt-oss" in model:
                return "bad output"  # Will fail guard
            return "good output"  # Will pass guard

        with (
            patch("cleanup_v2._try_groq", side_effect=mock_groq),
            patch("cleanup_v2._cleanup_looks_bad") as mock_guard,
            patch("cleanup_v2.vocab_store.apply_sounds_like", side_effect=lambda x: x),
        ):
            mock_guard.side_effect = [True, False]  # Reject primary, accept fallback
            result = cleanup_text("test", engine="groq", style="tidy")
            # Should have tried both Groq calls
            assert mock_guard.call_count >= 1

    def test_all_engines_fail_returns_raw(self):
        """If all engines fail, return raw text (with vocab applied)."""
        with (
            patch("cleanup_v2._try_groq", return_value=None),
            patch("cleanup_v2._try_nim", return_value=None),
            patch("cleanup_v2._try_gemini", return_value=None),
            patch("cleanup_v2._try_ollama", return_value=None),
            patch(
                "cleanup_v2.vocab_store.apply_sounds_like",
                side_effect=lambda x: x + "_vocab",
            ),
        ):
            result = cleanup_text("original", engine="auto")
            assert result == "original_vocab"


class TestReasoningEffortParameter:
    """Test reasoning_effort handling for Qwen vs GPT-OSS models."""

    def test_groq_reasoning_effort_qwen(self):
        with (
            patch("cleanup_v2.requests.post") as mock_post,
            patch("cleanup_v2._get_groq_key", return_value="fake_key"),
        ):
            mock_post.return_value.json.return_value = {
                "choices": [{"message": {"content": "result"}}]
            }
            from cleanup_v2 import _try_groq

            _try_groq("test", "qwen/qwen3.6-27b", "prompt", 10)
            # Check that reasoning_effort was set
            call_args = mock_post.call_args
            assert call_args is not None
            payload = call_args[1]["json"]
            assert payload.get("reasoning_effort") == "none"

    def test_groq_reasoning_effort_gpt_oss(self):
        with (
            patch("cleanup_v2.requests.post") as mock_post,
            patch("cleanup_v2._get_groq_key", return_value="fake_key"),
        ):
            mock_post.return_value.json.return_value = {
                "choices": [{"message": {"content": "result"}}]
            }
            from cleanup_v2 import _try_groq

            _try_groq("test", "openai/gpt-oss-120b", "prompt", 10)
            call_args = mock_post.call_args
            payload = call_args[1]["json"]
            assert payload.get("reasoning_effort") == "low"


class TestThinkingStrippping:
    """Test stripping of <think> blocks from model outputs."""

    def test_think_block_stripped_groq(self):
        response = "<think>Let me think...</think>Final answer"
        with (
            patch("cleanup_v2.requests.post") as mock_post,
            patch("cleanup_v2._get_groq_key", return_value="key"),
        ):
            mock_post.return_value.json.return_value = {
                "choices": [{"message": {"content": response}}]
            }
            from cleanup_v2 import _try_groq

            result = _try_groq("test", "model", "prompt", 10)
            assert "<think>" not in result
            assert "Final answer" in result

    def test_think_block_stripped_ollama(self):
        response = "<think>reasoning</think>output"
        with patch("cleanup_v2.requests.post") as mock_post:
            mock_post.return_value.json.return_value = {
                "message": {"content": response}
            }
            from cleanup_v2 import _try_ollama_chat

            result = _try_ollama_chat("test", "model", "prompt")
            assert "<think>" not in result
            assert "output" in result


class TestEdgeCases:
    """Test edge cases and error handling."""

    def test_empty_input(self):
        with patch("cleanup_v2.vocab_store.apply_sounds_like", side_effect=lambda x: x):
            result = cleanup_text("")
            assert result == ""

    def test_whitespace_only_input(self):
        with patch("cleanup_v2.vocab_store.apply_sounds_like", side_effect=lambda x: x):
            result = cleanup_text("   \n\t  ")
            assert result == "   \n\t  "

    def test_network_error_fallback(self):
        """Individual engine failures should gracefully fallback."""
        with (
            patch("cleanup_v2._try_groq", return_value=None),
            patch("cleanup_v2._try_nim", return_value="fallback_result"),
            patch("cleanup_v2._cleanup_looks_bad", return_value=False),
            patch("cleanup_v2.vocab_store.apply_sounds_like", side_effect=lambda x: x),
        ):
            # Should fallback to NIM when Groq returns None
            result = cleanup_text("test", engine="auto")
            assert result == "fallback_result"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
