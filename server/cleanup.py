"""
cleanup.py — Post-processing of raw STT output.

Primary engine  : Gemini text-only generateContent (繁體中文 best quality).
Fallback engine : local ollama (qwen2.5:3b or whatever cleanup_ollama_model is set to).
After AI cleanup: apply vocab sounds_like replacements.
"""

from __future__ import annotations

import logging
import os
from typing import Any

import requests

import vocab_store

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Cleanup styles — selectable per request (PWA / desktop / Telegram) or via
# the server default (settings.cleanup_style).
# ---------------------------------------------------------------------------

# 共用語言規則：中文用繁體、英文保留英文，不要翻譯（支援中英混用）。
_LANG_RULE = (
    "語言規則：中文一律用繁體中文，英文保留英文原文，不要翻譯任何內容（允許中英混用）。"
)

STYLE_PROMPTS: dict[str, str] = {
    # 智能整理（預設）：補標點、去口頭禪、修錯字，保留原意
    "tidy": (
        "你是一位文字編輯。使用者將給你一段口語逐字稿，請幫忙：\n"
        "1. 補上適當的標點符號\n"
        "2. 刪除口頭禪（呃、然後、就是、那個、這個、um、uh 等冗詞）\n"
        "3. 修正明顯的錯字\n"
        "4. 保留原本語意\n" + _LANG_RULE + "\n"
        "只輸出處理後的正文，不要任何解釋或說明。"
    ),
    # 會議記錄：整理成結構化筆記
    "meeting": (
        "你是一位會議記錄員。使用者將給你一段口語逐字稿，請整理成結構化會議記錄：\n"
        "- 用條列式呈現重點\n"
        "- 若有決議事項，列在「決議」下\n"
        "- 若有待辦/行動項目，列在「待辦」下並標註負責人（若有提到）\n"
        "- 精簡專業\n" + _LANG_RULE + "\n"
        "只輸出整理後的會議記錄，不要任何前言或解釋。"
    ),
    # 轉指令：改寫成清楚的指令，適合貼給 AI agent / 任務系統
    "command": (
        "你是一位指令改寫助手。使用者將給你一段口語逐字稿，請把它改寫成一條清楚、"
        "可執行的指令（祈使句），去除贅字與口頭禪，保留所有關鍵需求與限制。\n"
        + _LANG_RULE
        + "\n"
        "只輸出改寫後的指令本身，不要任何解釋或前言。"
    ),
}

DEFAULT_STYLE = "tidy"
VALID_STYLES = set(STYLE_PROMPTS.keys()) | {"verbatim"}


NIM_ENDPOINT = "https://integrate.api.nvidia.com/v1/chat/completions"
# NIM keys live in these env vars (any one that is set is used, first wins).
NIM_KEY_ENVS = ["NVDA_NIM_KEY_1", "NVDA_NIM_KEY_2", "NVDA_NIM_KEY_3", "NVDA_NIM_KEY_4"]


def cleanup_text(
    raw: str,
    cloud_model: str,
    ollama_model: str,
    gemini_key_env: str,
    style: str = DEFAULT_STYLE,
    engine: str = "auto",
    nim_model: str = "qwen/qwen3-next-80b-a3b-instruct",
) -> str:
    """
    Clean up raw STT text using the requested *style* via the chosen *engine*.

    engine:
      - "auto"   : Gemini -> NIM -> local ollama (first that works)
      - "gemini" : cloud Gemini (free, best 繁中); falls back to NIM then ollama
      - "nim"    : NVIDIA NIM cloud (free); falls back to ollama
      - "local"  : local ollama on the gateway box (offline)
    style:
      - "verbatim" : no LLM; return raw (only vocab replacement applied)
      - "tidy" / "meeting" / "command" : see STYLE_PROMPTS
    After cleanup, vocab sounds_like replacements are always applied.
    """
    if not raw.strip():
        return raw

    if style not in VALID_STYLES:
        style = DEFAULT_STYLE
    if style == "verbatim":
        return vocab_store.apply_sounds_like(raw)

    system_prompt = STYLE_PROMPTS[style]

    # Build the ordered list of engines to try for the requested preference.
    if engine == "local":
        chain = ["ollama"]
    elif engine == "nim":
        chain = ["nim", "ollama"]
    elif engine == "gemini":
        chain = ["gemini", "nim", "ollama"]
    else:  # auto
        chain = ["gemini", "nim", "ollama"]

    cleaned = None
    for eng in chain:
        if eng == "gemini":
            cleaned = _try_gemini(raw, cloud_model, gemini_key_env, system_prompt)
        elif eng == "nim":
            cleaned = _try_nim(raw, nim_model, system_prompt)
        elif eng == "ollama":
            cleaned = _try_ollama(raw, ollama_model, system_prompt)
        if cleaned is not None:
            break
        logger.warning("Cleanup engine '%s' failed; trying next", eng)

    if cleaned is None:
        logger.error("All cleanup engines failed; returning raw text")
        cleaned = raw

    cleaned = vocab_store.apply_sounds_like(cleaned)
    return cleaned


# ---------------------------------------------------------------------------
# Gemini text-only cleanup
# ---------------------------------------------------------------------------


def _try_gemini(raw: str, model: str, key_env: str, system_prompt: str) -> str | None:
    key = os.environ.get(key_env, "")
    if not key:
        return None

    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}"
        f":generateContent?key={key}"
    )
    body: dict[str, Any] = {
        "contents": [{"parts": [{"text": system_prompt + "\n\n逐字稿：\n" + raw}]}],
        # thinkingBudget=0 only valid on 2.5 flash class (pro/2.0 reject -> 400).
        "generationConfig": (
            {"thinkingConfig": {"thinkingBudget": 0}}
            if ("2.5" in model and "flash" in model)
            else {}
        ),
    }
    try:
        resp = requests.post(url, json=body, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        text = data["candidates"][0]["content"]["parts"][0]["text"]
        return text.strip()
    except Exception as exc:
        logger.warning("Gemini cleanup error: %s", exc)
        return None


# ---------------------------------------------------------------------------
# NVIDIA NIM cloud (free, OpenAI-compatible chat) — text cleanup only
# ---------------------------------------------------------------------------


def _nim_key() -> str | None:
    for env in NIM_KEY_ENVS:
        v = os.environ.get(env, "")
        if v:
            return v
    return None


def _try_nim(raw: str, model: str, system_prompt: str) -> str | None:
    key = _nim_key()
    if not key:
        return None
    try:
        resp = requests.post(
            NIM_ENDPOINT,
            headers={"Authorization": f"Bearer {key}"},
            json={
                "model": model,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": "逐字稿：\n" + raw},
                ],
                "temperature": 0.2,
                "max_tokens": 1024,
            },
            timeout=40,
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"].strip() or None
    except Exception as exc:
        logger.warning("NIM cleanup error: %s", exc)
        return None


# ---------------------------------------------------------------------------
# Ollama fallback
# ---------------------------------------------------------------------------


def _try_ollama(raw: str, model: str, system_prompt: str) -> str | None:
    prompt = system_prompt + "\n\n逐字稿：\n" + raw + "\n\n處理後正文："
    body = {"model": model, "prompt": prompt, "stream": False}
    try:
        resp = requests.post(
            "http://127.0.0.1:11434/api/generate", json=body, timeout=60
        )
        resp.raise_for_status()
        data = resp.json()
        return data.get("response", "").strip() or None
    except Exception as exc:
        logger.warning("Ollama cleanup error: %s", exc)
        return None
