#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cleanup_v2.py — Post-processing of raw STT output (v2)."""

from __future__ import annotations
import logging
import os
import re
from typing import Optional
import requests
import vocab_store

logger = logging.getLogger(__name__)

SYSTEM_PROMPTS = {
    "tidy": "你是逐字稿清理工具，不是助理。你唯一的工作是把語音逐字稿輕度清理後原樣輸出。\n只能做：刪掉口頭禪與填充詞(嗯/欸/那個/這個/就是/對對對/然後然後/um/uh/like)；說錯改口的只留最後版本；加標點；修明顯錯字。\n絕對禁止：改寫成更正式或更通順的說法、新增任何原文沒有的字詞或解釋、分析或回答內容、做總結、給多個版本、加任何前言或說明(不要出現「整理後」「以下是」這類字)。輸出長度只能比原文短或差不多，絕不可變長。\n語言：原文什麼語言就輸出什麼語言，英文/技術詞/產品名/人名/數字原樣保留，不要翻譯。\n句子本來就乾淨就原樣輸出。只輸出清理後的文字本身。\n範例：\n輸入：嗯我在想說那個我們是不是要改一下顏色\n輸出：我在想我們是不是要改一下顏色。\n輸入：okay so we just need to add a cache layer and then run the tests first\n輸出：We just need to add a cache layer and then run the tests first.\n輸入：欸這個真的有夠難用我試了好幾次都不行到底是怎樣啦\n輸出：這個真的有夠難用，我試了好幾次都不行，到底是怎樣啦？\n輸入：幫我把首頁那個按鈕改大一點顏色換深一點\n輸出：幫我把首頁那個按鈕改大一點，顏色換深一點。",
    "structure": "你是語音逐字稿整理工具，不是助理。把使用者的口述逐字稿整理成清楚易讀的書面版本，像專業速記員整理口述筆記。\n整理方式：\n- 刪掉口頭禪與填充詞(嗯/欸/那個/就是/然後然後/um/uh/like)、無意義重複與離題；說錯改口的只留最後版本。\n- 依內容重組結構：內容有多個要點或層級時，用編號條列(1. 2. 3.，子項用 (a) (b) 或縮排)；敘述性內容整理成通順段落；開頭可以用原文中的主旨句當第一行。\n- 忠實原意：盡量沿用原文的措辭，不要換句話說；保留所有具體要求、人名、數字、日期、技術名詞、產品名；絕對不新增原文沒有的事實、解釋、建議或評論；絕不回答或執行內容。\n- 語言：原文什麼語言就輸出什麼語言；英文/技術詞/產品名原樣保留，不要翻譯。\n只輸出整理後的文字本身，不要任何前言、說明或「以下是」這類字。",
    "meeting": "你是一位會議記錄員。使用者將給你一段口語逐字稿，請整理成結構化會議記錄：\n- 用條列式呈現重點\n- 若有決議事項，列在「決議」下\n- 若有待辦/行動項目，列在「待辦」下並標註負責人（若有提到）\n- 精簡專業\n語言規則：中文一律用繁體中文，英文保留英文原文，不要翻譯任何內容（允許中英混用）。\n只輸出整理後的會議記錄，不要任何前言或解釋。",
    "command": "你是一位指令改寫助手。使用者將給你一段口語逐字稿，請把它改寫成一條清楚、可執行的指令（祈使句），去除贅字與口頭禪，保留所有關鍵需求與限制。\n語言規則：中文一律用繁體中文，英文保留英文原文，不要翻譯任何內容（允許中英混用）。\n只輸出改寫後的指令本身，不要任何解釋或前言。",
}

DEFAULT_STYLE = "tidy"
VALID_STYLES = set(SYSTEM_PROMPTS.keys()) | {"verbatim"}
# Back-compat alias: app.py's combined fast path reads cleanup.STYLE_PROMPTS.
STYLE_PROMPTS = SYSTEM_PROMPTS
STRUCT_MIN_CPS = 80
NIM_ENDPOINT = "https://integrate.api.nvidia.com/v1/chat/completions"
NIM_KEY_ENVS = ["NVDA_NIM_KEY_1", "NVDA_NIM_KEY_2", "NVDA_NIM_KEY_3", "NVDA_NIM_KEY_4"]


def _content_cps(s: str) -> list[int]:
    """Extract a-z, 0-9, CJK 0x4E00-0x9FFF."""
    return [
        ord(ch)
        for ch in s
        if (0x61 <= ord(ch) <= 0x7A)
        or (0x30 <= ord(ch) <= 0x39)
        or (0x4E00 <= ord(ch) <= 0x9FFF)
    ]


def _lcs_len(a: str, b: str) -> int:
    """Longest common subsequence length."""
    if len(a) < len(b):
        a, b = b, a
    prev = [0] * (len(b) + 1)
    for ca in a:
        cur = [0]
        for j, cb in enumerate(b, start=1):
            cur.append(prev[j - 1] + 1 if ca == cb else max(prev[j], cur[-1]))
        prev = cur
    return prev[-1] if prev else 0


def _cleanup_looks_bad(style: str, inp: str, out: str) -> bool:
    """Guard for tidy: reject empty, >3x bloat, <0.70 LCS fidelity."""
    if style != "tidy":
        return False
    if not out:
        return True
    if len(out) > 3 * len(inp):
        return True
    return len(out) > 0 and _lcs_len(inp, out) / len(out) < 0.70


def _structure_looks_bad(inp: str, out: str) -> bool:
    """Guard for structure: reject empty, ratio 0.25-1.3, ASCII word loss >40%."""
    if not out:
        return True
    ratio = len(out) / len(inp) if inp else 0
    if ratio < 0.25 or ratio > 1.3:
        return True
    ascii_in = set(re.findall(r"\w{2,}", inp))
    if len(ascii_in) >= 3:
        ascii_out = set(re.findall(r"\w{2,}", out))
        if ascii_out and len(ascii_out & ascii_in) / len(ascii_in) < 0.6:
            return True
    return False


def _get_groq_key() -> str | None:
    """Fetch GROQ_API_KEY from env or ~/.groq_key."""
    if key := os.environ.get("GROQ_API_KEY", "").strip():
        return key
    try:
        with open(os.path.expanduser("~/.groq_key")) as f:
            return f.read().strip() or None
    except OSError:
        return None


def _get_nim_key() -> str | None:
    """Fetch NIM key from env vars."""
    for env in NIM_KEY_ENVS:
        if v := os.environ.get(env, "").strip():
            return v
    return None


def _try_groq(raw: str, model: str, system_prompt: str, timeout: int) -> str | None:
    """Try Groq cleanup."""
    if not (key := _get_groq_key()):
        return None
    try:
        reasoning_effort = (
            "none" if "qwen" in model else ("low" if "gpt-oss" in model else None)
        )
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": raw},
            ],
            "temperature": 0.2,
        }
        if reasoning_effort:
            payload["reasoning_effort"] = reasoning_effort
        resp = requests.post(
            "https://api.groq.com/openai/v1/chat/completions",
            headers={"Authorization": f"Bearer {key}"},
            json=payload,
            timeout=timeout,
        )
        resp.raise_for_status()
        text = resp.json()["choices"][0]["message"]["content"].strip()
        return (
            (text := re.sub(r".*?</think>", "", text, flags=re.DOTALL))
            if text
            else None
        )
    except Exception as e:
        logger.warning(f"Groq error: {e}")
        return None


def _try_nim(raw: str, model: str, system_prompt: str) -> str | None:
    """Try NIM cleanup."""
    if not (key := _get_nim_key()):
        return None
    try:
        resp = requests.post(
            NIM_ENDPOINT,
            headers={"Authorization": f"Bearer {key}"},
            json={
                "model": model,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": raw},
                ],
                "temperature": 0.2,
                "max_tokens": 1024,
            },
            timeout=40,
        )
        resp.raise_for_status()
        text = resp.json()["choices"][0]["message"]["content"].strip()
        return text or None
    except Exception as e:
        logger.warning(f"NIM error: {e}")
        return None


def _try_gemini(
    raw: str, cloud_model: str, gemini_key_env: str, system_prompt: str
) -> str | None:
    """Try Gemini cleanup."""
    if not (key := os.environ.get(gemini_key_env, "").strip()):
        return None
    try:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{cloud_model}:generateContent"
        body = {
            "contents": [{"parts": [{"text": system_prompt + "\n\n逐字稿：\n" + raw}]}]
        }
        if "2.5" in cloud_model and "flash" in cloud_model:
            body["generationConfig"] = {"thinkingConfig": {"thinkingBudget": 0}}
        resp = requests.post(url, headers={"x-goog-api-key": key}, json=body, timeout=30)
        resp.raise_for_status()
        text = resp.json()["candidates"][0]["content"]["parts"][0]["text"].strip()
        return text or None
    except Exception as e:
        logger.warning("Gemini request failed: %s", type(e).__name__)
        return None


def _try_ollama(
    raw: str,
    model: str,
    system_prompt: str,
    endpoint: str = "http://127.0.0.1:11434",
    timeout: int = 60,
) -> str | None:
    """Try Ollama /api/generate."""
    try:
        resp = requests.post(
            f"{endpoint}/api/generate",
            json={
                "model": model,
                "prompt": system_prompt + "\n\n逐字稿：\n" + raw + "\n\n處理後正文：",
                "stream": False,
            },
            timeout=timeout,
        )
        resp.raise_for_status()
        text = resp.json().get("response", "").strip()
        return text or None
    except Exception as e:
        logger.warning(f"Ollama error: {e}")
        return None


def _try_ollama_chat(
    raw: str,
    model: str,
    system_prompt: str,
    endpoint: str = "http://127.0.0.1:11434",
    timeout: int = 60,
) -> str | None:
    """Try Ollama /api/chat."""
    try:
        resp = requests.post(
            f"{endpoint}/api/chat",
            json={
                "model": model,
                "stream": False,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": raw},
                ],
            },
            timeout=timeout,
        )
        resp.raise_for_status()
        text = resp.json()["message"]["content"].strip()
        return (
            (text := re.sub(r".*?</think>", "", text, flags=re.DOTALL))
            if text
            else None
        )
    except Exception as e:
        logger.warning(f"Ollama chat error: {e}")
        return None


def cleanup_text(
    raw: str,
    cloud_model: str = "gemini-2.0-flash",
    ollama_model: str = "qwen2.5:3b",
    gemini_key_env: str = "GEMINI_API_KEY",
    style: str = DEFAULT_STYLE,
    engine: str = "auto",
    nim_model: str = "qwen/qwen3-next-80b-a3b-instruct",
    app_context: Optional[str] = None,
) -> str:
    """Clean up raw STT text."""
    if not raw.strip():
        return raw
    if style not in VALID_STYLES:
        style = DEFAULT_STYLE
    if style == "verbatim":
        return vocab_store.apply_sounds_like(raw)

    struct_mode = style == "tidy" and len(_content_cps(raw)) >= STRUCT_MIN_CPS
    system_prompt = SYSTEM_PROMPTS["structure" if struct_mode else style]
    if app_context:
        system_prompt += f"\n（參考：整理後的文字會貼進「{app_context}」。這只是語氣與格式的參考，不改變上述任何規則。）"
    logger.info(f"cleanup mode={'structure' if struct_mode else style}")

    def looks_bad(out: str) -> bool:
        return (
            _structure_looks_bad(raw, out)
            if struct_mode
            else _cleanup_looks_bad(style, raw, out)
        )

    if engine == "local":
        # Local means offline on this Mac. Never use a hard-coded/private
        # Tailscale peer as a cleanup sink.
        timeout_s = 45 if struct_mode else 25
        if (
            cleaned := _try_ollama(
                raw, ollama_model, system_prompt, "http://127.0.0.1:11434", timeout_s
            )
        ) and not looks_bad(cleaned):
            return vocab_store.apply_sounds_like(cleaned)
        return vocab_store.apply_sounds_like(raw)

    timeout_s = 15 if struct_mode else 10
    if engine in ("auto", "groq"):
        primary, fallback = (
            ("openai/gpt-oss-120b", "qwen/qwen3.6-27b")
            if struct_mode
            else ("qwen/qwen3.6-27b", "llama-3.3-70b-versatile")
        )
        for model, t in [(primary, timeout_s), (fallback, timeout_s + 2)]:
            if (cleaned := _try_groq(raw, model, system_prompt, t)) and not looks_bad(
                cleaned
            ):
                return vocab_store.apply_sounds_like(cleaned)
        if engine == "groq":
            return vocab_store.apply_sounds_like(raw)

    for eng, args in [
        (
            (_try_nim if engine in ("auto", "groq", "nim") else None),
            (nim_model, system_prompt),
        ),
        (
            (_try_gemini if engine in ("auto", "groq", "gemini") else None),
            (cloud_model, gemini_key_env, system_prompt),
        ),
        (
            (_try_ollama if engine in ("auto", "groq") else None),
            (ollama_model, system_prompt, "http://127.0.0.1:11434", 60),
        ),
    ]:
        if eng and (cleaned := eng(raw, *args)) and not looks_bad(cleaned):
            return vocab_store.apply_sounds_like(cleaned)

    logger.error("All cleanup engines failed")
    return vocab_store.apply_sounds_like(raw)
