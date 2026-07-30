"""
stt_router.py — STT routing logic for NexVoice.

Flow:
  1. Normalize incoming audio → 16kHz mono WAV via ffmpeg
  2. Resolve routing mode (cloud / local / auto)
  3. Transcribe via selected engine; auto falls back to local on cloud failure
  4. Apply vocab sounds_like replacements to raw output
  5. Return (raw_text, engine_name, model_name, duration_ms)
"""

from __future__ import annotations

import base64
import logging
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import requests

import vocab_store

logger = logging.getLogger(__name__)

FFMPEG = "/opt/homebrew/bin/ffmpeg"

# 2026-07-02 從 M5 nexvoice_locald.py 串回：工程雙語常用詞，恆常偏置進
# whisper 的 initial_prompt（與使用者字典疊加）。中英夾雜的口述裡英文術語
# 常被聽歪（"system prompt" -> "Cistum Punk"、"Typeless" -> "Tibular"），
# 先把預期詞彙種進 prompt 能直接提升辨識率。維持 ~40 詞以內不撐爆 prompt 窗。
BASE_TERMS = [
    "system prompt",
    "prompt",
    "model",
    "token",
    "fine-tune",
    "LLM",
    "embedding",
    "context",
    "inference",
    "API",
    "endpoint",
    "deploy",
    "staging",
    "production",
    "rollback",
    "function",
    "debug",
    "refactor",
    "framework",
    "backend",
    "frontend",
    "database",
    "cache",
    "latency",
    "async",
    "schema",
    "JSON",
    "regex",
    "repo",
    "commit",
    "merge",
    "Whisper",
    "Groq",
    "Typeless",
    "Wispr",
    "NexVoice",
    "NexPilot",
    "NexDesk",
    "Hammerspoon",
    "Obsidian",
]
MAX_WHISPER_PROMPT_BYTES = 2048


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


def transcribe(
    audio_bytes: bytes,
    mode: str,  # "auto" | "cloud" | "local"
    privacy_mode: bool,
    cloud_model: str,
    local_model: str,
    gemini_key_env: str,
) -> tuple[str, str, str, int]:
    """
    Transcribe *audio_bytes*.

    Returns:
        (raw_text, engine, model, duration_ms)
        engine is "cloud" or "local".
    """
    with tempfile.TemporaryDirectory(prefix="nexvoice_") as tmpdir:
        in_path = Path(tmpdir) / "input.audio"
        wav_path = Path(tmpdir) / "input.wav"
        in_path.write_bytes(audio_bytes)

        _to_wav(str(in_path), str(wav_path))

        # Silence guard: skip STT on near-silent audio (mic muted / no speech) so
        # the model can't hallucinate text from silence.
        if _audio_peak(str(wav_path)) < SILENCE_PEAK_THRESHOLD:
            logger.info("Audio below silence threshold — empty transcript")
            return "", "silent", "", 0

        t0 = time.monotonic()

        # Clean three-way routing. privacy_mode always forces local (audio never leaves the box).
        if privacy_mode or mode == "local":
            raw, engine, model = _run_local(str(wav_path), local_model)
        elif mode == "cloud":
            raw, engine, model = _run_cloud(str(wav_path), cloud_model, gemini_key_env)
        else:
            # auto: try cloud, fall back to local
            try:
                raw, engine, model = _run_cloud(
                    str(wav_path), cloud_model, gemini_key_env
                )
            except Exception as exc:
                logger.warning("Cloud STT failed (%s); falling back to local", type(exc).__name__)
                raw, engine, model = _run_local(str(wav_path), local_model)

        duration_ms = int((time.monotonic() - t0) * 1000)

    # Apply vocab sounds_like on raw before returning
    raw = vocab_store.apply_sounds_like(raw)
    return raw, engine, model, duration_ms


# ---------------------------------------------------------------------------
# Audio normalization
# ---------------------------------------------------------------------------


def _audio_peak(wav_path: str) -> float:
    """
    Return the PEAK absolute amplitude (0.0-1.0) of a 16-bit PCM WAV. 1.0 on error.

    Peak (not mean RMS) is used for the silence check: a real utterance buried in
    a mostly-quiet clip ("…[silence]… buy milk …[silence]…") has low mean RMS but
    a high peak, so RMS would wrongly drop it as silent. Peak only stays low when
    nothing was actually said (mic muted / no speech).
    """
    import wave

    try:
        with wave.open(wav_path, "rb") as w:
            if w.getsampwidth() != 2:
                return 1.0  # unknown format -> assume non-silent, let STT handle it
            frames = w.readframes(w.getnframes())
        if not frames:
            return 0.0
        import numpy as np

        a = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
        if a.size == 0:
            return 0.0
        return float(np.max(np.abs(a)))
    except Exception:
        return 1.0  # on any error, don't block transcription


# Below this PEAK amplitude the clip is treated as silence (mic muted / no speech)
# and we return an empty transcript instead of letting the model hallucinate
# ("優優獨播劇場", bias words, etc.). Set low because some Macs have low mic gain;
# real speech peaks well above this, ambient/quiet-room noise stays under it.
SILENCE_PEAK_THRESHOLD = 0.03


def _to_wav(in_path: str, out_path: str) -> None:
    """Convert any audio format to 16kHz mono WAV using ffmpeg."""
    cmd = [
        FFMPEG,
        "-y",
        "-i",
        in_path,
        "-ar",
        "16000",
        "-ac",
        "1",
        "-f",
        "wav",
        out_path,
    ]
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"ffmpeg conversion failed: {result.stderr.decode(errors='replace')}"
        )


# ---------------------------------------------------------------------------
# Cloud STT (Google Gemini)
# ---------------------------------------------------------------------------


def _run_cloud(wav_path: str, model: str, key_env: str) -> tuple[str, str, str]:
    """Transcribe via Google Gemini multimodal generateContent."""
    key = os.environ.get(key_env, "")
    if not key:
        raise ValueError(f"Gemini API key env '{key_env}' not set")

    wav_bytes = Path(wav_path).read_bytes()
    b64 = base64.b64encode(wav_bytes).decode()

    vocab_hint = vocab_store.get_bias_prompt()
    prompt = (
        "請把這段音訊逐字聽寫出來：中文一律用繁體中文，英文保留英文原文，"
        "不要翻譯（允許中英混用），只輸出逐字稿，不要任何解釋或標記。"
        "若音訊空白/靜音/過短/聽不清楚，請只回覆空字串，不要猜測或編造任何內容。"
    )
    if vocab_hint:
        prompt += (
            "\n（以下僅為『若音訊中有出現』才需正確寫出的可能專有名詞，音訊沒提到就不要使用）："
            + vocab_hint
        )

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    body: dict[str, Any] = {
        "contents": [
            {
                "parts": [
                    {"text": prompt},
                    {
                        "inline_data": {
                            "mime_type": "audio/wav",
                            "data": b64,
                        }
                    },
                ]
            }
        ],
        "generationConfig": _gen_config(model),
    }
    resp = requests.post(url, headers={"x-goog-api-key": key}, json=body, timeout=60)
    resp.raise_for_status()
    data = resp.json()
    text: str = data["candidates"][0]["content"]["parts"][0]["text"]
    return text.strip(), "cloud", model


def cloud_available(key_env: str) -> bool:
    """True if the Gemini API key is present in the environment."""
    return bool(os.environ.get(key_env, ""))


def _gen_config(model: str) -> dict[str, Any]:
    """
    Build generationConfig for a Gemini model. thinkingBudget=0 (disable thinking
    for speed) is ONLY valid on the 2.5 *flash* class. Gemini 2.5 Pro rejects
    budget=0 ("only works in thinking mode") and older/other models reject the
    field outright — both cause a 400 that silently drops us to local fallback.
    """
    if "2.5" in model and "flash" in model:
        return {"thinkingConfig": {"thinkingBudget": 0}}
    return {}


def transcribe_combined_cloud(
    audio_bytes: bytes,
    model: str,
    key_env: str,
    style_prompt: str,
) -> tuple[str, str, int]:
    """
    FAST PATH: transcribe + style in a SINGLE Gemini call (~3-5s) instead of
    two sequential calls (transcribe ~3s then cleanup ~4s). Returns the final
    styled text in Traditional Chinese, with vocab replacements applied.

    Returns (text, model, duration_ms). Raises on failure so the caller can
    fall back to the two-step path.
    """
    key = os.environ.get(key_env, "")
    if not key:
        raise ValueError(f"Gemini API key env '{key_env}' not set")

    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="nexvoice_") as tmpdir:
        in_path = Path(tmpdir) / "input.audio"
        wav_path = Path(tmpdir) / "input.wav"
        in_path.write_bytes(audio_bytes)
        _to_wav(str(in_path), str(wav_path))

        # Silence guard: don't send near-silent audio to the model (it hallucinates).
        if _audio_peak(str(wav_path)) < SILENCE_PEAK_THRESHOLD:
            return "", model, int((time.monotonic() - t0) * 1000)

        b64 = base64.b64encode(wav_path.read_bytes()).decode()

    vocab_hint = vocab_store.get_bias_prompt()
    prompt = (
        "請先把這段音訊逐字聽寫出來（中文用繁體中文，英文保留英文原文，不要翻譯，允許中英混用），"
        "然後依下列要求整理，直接只輸出最終結果（不要附逐字稿、不要任何解釋或標記）。\n"
        "⚠️ 極重要：若音訊是空白、靜音、過短或你聽不清楚實際內容，"
        "請『只回覆空字串』，絕對不要猜測、編造，也不要輸出任何範例詞或專有名詞。\n\n"
        + style_prompt
    )
    if vocab_hint:
        prompt += (
            "\n（以下僅為『若音訊中有出現』才需正確寫出的可能專有名詞，音訊沒提到就不要使用）："
            + vocab_hint
        )

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    body: dict[str, Any] = {
        "contents": [
            {
                "parts": [
                    {"text": prompt},
                    {"inline_data": {"mime_type": "audio/wav", "data": b64}},
                ]
            }
        ],
        # Disable "thinking" — transcription/cleanup need no reasoning, and the
        # thinking tokens roughly double latency. This is the main speed lever.
        "generationConfig": _gen_config(model),
    }
    resp = requests.post(url, headers={"x-goog-api-key": key}, json=body, timeout=60)
    resp.raise_for_status()
    data = resp.json()
    text: str = data["candidates"][0]["content"]["parts"][0]["text"].strip()
    text = vocab_store.apply_sounds_like(text)
    duration_ms = int((time.monotonic() - t0) * 1000)
    return text, model, duration_ms


# ---------------------------------------------------------------------------
# Local STT (mlx-whisper, lazy import)
# ---------------------------------------------------------------------------


def _run_local(wav_path: str, model: str) -> tuple[str, str, str]:
    """Transcribe locally via mlx-whisper + OpenCC s2twp conversion."""
    try:
        import mlx_whisper  # type: ignore[import]
    except ImportError as exc:
        raise RuntimeError(
            "mlx-whisper is not installed. Run: pip install mlx-whisper"
        ) from exc

    # language=None -> auto-detect, so full-English and Chinese both work
    # (Traditional Chinese + English mixed). OpenCC below only
    # touches Chinese characters, so English passes through untouched.
    #
    # 2026-07-02（M5 串回）：帶標點的 primer 句 + 常用詞/使用者字典偏置。
    # 完整句 primer 讓 whisper 願意輸出標點（裸關鍵詞列表反而抑制標點）；
    # 專有名詞疊加提升辨識率（Typeless 式 custom vocabulary 的辨識端本體）。
    primer = (
        "以下是一段繁體中文與英文混用的逐字稿，內容會正確使用標點符號，"
        "例如逗號、句號、問號？以及驚嘆號！"
    )
    seen: set[str] = set()
    terms: list[str] = []
    user_phrases = vocab_store.enabled_phrases()
    # User terms take precedence over the built-in engineering glossary.
    for t in user_phrases + BASE_TERMS:
        k = t.lower()
        if k not in seen:
            candidate_terms = terms + [t]
            candidate_prompt = primer + "可能出現的專有名詞：" + "、".join(candidate_terms) + "。"
            if len(candidate_prompt.encode("utf-8")) <= MAX_WHISPER_PROMPT_BYTES:
                seen.add(k)
                terms.append(t)
    if terms:
        primer += "可能出現的專有名詞：" + "、".join(terms) + "。"
    result = mlx_whisper.transcribe(
        wav_path,
        path_or_hf_repo=model,
        initial_prompt=primer,
    )
    raw: str = result["text"]

    # mlx-whisper outputs Simplified Chinese — convert to Traditional
    try:
        import opencc  # type: ignore[import]

        raw = opencc.OpenCC("s2twp").convert(raw)
    except ImportError:
        logger.warning(
            "opencc not installed; skipping Simplified→Traditional conversion"
        )

    return raw.strip(), "local", model
