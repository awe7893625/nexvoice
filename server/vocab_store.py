"""
vocab_store.py — In-process cache for vocab + sounds_like replacement logic.

The cache is rebuilt from DB on demand (call reload() after any CRUD mutation).
"""

from __future__ import annotations

import re
import unicodedata
from typing import Any

import db as _db


# ---------------------------------------------------------------------------
# In-memory cache
# ---------------------------------------------------------------------------

_cache: list[dict[str, Any]] = []

MAX_ENTRIES = 256
MAX_VARIANTS_PER_ENTRY = 8
MAX_FIELD_BYTES = 128
MAX_BIAS_PROMPT_BYTES = 1536
MAX_VOCABULARY_DATA_BYTES = 32 * 1024
_DELIMITER_RE = re.compile(r"[,，、]")
_BIDI_CONTROLS = set("\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069")


def reload() -> None:
    """Reload vocab from DB into the in-process cache."""
    global _cache
    _cache = _db.get_vocab()


def get_all() -> list[dict[str, Any]]:
    """Return the current vocab list (from cache)."""
    if not _cache:
        reload()
    return list(_cache)


def normalize_phrase(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("phrase must be a string")
    value = unicodedata.normalize("NFC", value).strip()
    if not value:
        raise ValueError("phrase is required")
    if len(value.encode("utf-8")) > MAX_FIELD_BYTES:
        raise ValueError("phrase is too long")
    if _contains_unsafe_control(value):
        raise ValueError("phrase contains control characters")
    return value


def normalize_sounds_like(value: object) -> str:
    if value is None or value == "":
        return ""
    if not isinstance(value, str):
        raise ValueError("sounds_like must be a string")
    variants: list[str] = []
    seen: set[str] = set()
    for raw in _DELIMITER_RE.split(value):
        variant = unicodedata.normalize("NFC", raw).strip()
        if not variant:
            continue
        if len(variant.encode("utf-8")) > MAX_FIELD_BYTES:
            raise ValueError("sounds_like variant is too long")
        if _contains_unsafe_control(variant):
            raise ValueError("sounds_like contains control characters")
        key = variant.casefold()
        if key in seen:
            continue
        if len(variants) >= MAX_VARIANTS_PER_ENTRY:
            raise ValueError("too many sounds_like variants")
        seen.add(key)
        variants.append(variant)
    return ",".join(variants)


def normalize_enabled(value: object) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int) and value in {0, 1}:
        return value
    raise ValueError("enabled must be boolean or 0/1")


def enabled_phrases(limit: int = MAX_ENTRIES) -> list[str]:
    phrases: list[str] = []
    seen: set[str] = set()
    for entry in get_all()[:MAX_ENTRIES]:
        if not entry.get("enabled", 1):
            continue
        try:
            phrase = normalize_phrase(entry.get("phrase"))
        except ValueError:
            continue
        key = phrase.casefold()
        if key in seen:
            continue
        seen.add(key)
        phrases.append(phrase)
        if len(phrases) >= limit:
            break
    return phrases


def _contains_unsafe_control(value: str) -> bool:
    return any(
        unicodedata.category(char) in {"Cc", "Cf", "Zl", "Zp"}
        or char in _BIDI_CONTROLS
        for char in value
    )


def vocabulary_data_bytes(entries: list[dict[str, Any]]) -> int:
    """Bound JSON/cache growth with conservative per-entry overhead."""
    total = 0
    for entry in entries[:MAX_ENTRIES + 1]:
        phrase = entry.get("phrase")
        sounds_like = entry.get("sounds_like") or ""
        if isinstance(phrase, str) and isinstance(sounds_like, str):
            total += len(phrase.encode("utf-8")) + len(sounds_like.encode("utf-8")) + 64
    return total


# ---------------------------------------------------------------------------
# Replacement helper
# ---------------------------------------------------------------------------


def apply_sounds_like(text: str) -> str:
    """
    For each enabled vocab entry that has sounds_like variants, replace every
    variant occurrence in *text* with the canonical phrase.

    Matches are collected from the original text, longest-first at the same
    position, then applied once without rescanning replacement output. Matching
    is case-insensitive because STT engines vary Latin casing.
    """
    if not isinstance(text, str) or not text:
        return text
    if not _cache:
        reload()

    # Collect literal matches against the original string, then apply a single
    # non-overlapping pass. Replacement output can therefore never trigger a
    # second dictionary rule (foo→bar→baz cascade), and backslashes in a
    # canonical phrase are treated as data rather than a regex template.
    candidates: list[tuple[int, int, int, int, str]] = []
    order = 0
    for entry in _cache[:MAX_ENTRIES]:
        if not entry.get("enabled", 1):
            continue
        try:
            phrase = normalize_phrase(entry.get("phrase"))
            sounds_like = normalize_sounds_like(entry.get("sounds_like") or "")
        except ValueError:
            continue
        phrase_key = phrase.casefold()
        variants = sorted(
            (v for v in sounds_like.split(",") if v),
            key=len,
            reverse=True,
        )
        for variant in variants:
            variant_key = variant.casefold()
            if variant_key == phrase_key or variant_key in phrase_key:
                continue
            escaped = re.escape(variant)
            prefix = r"(?<![A-Za-z0-9_])" if _ascii_word_edge(variant[0]) else ""
            suffix = r"(?![A-Za-z0-9_])" if _ascii_word_edge(variant[-1]) else ""
            pattern = re.compile(prefix + escaped + suffix, flags=re.IGNORECASE)
            for match in pattern.finditer(text):
                candidates.append(
                    (match.start(), match.end(), -(match.end() - match.start()), order, phrase)
                )
            order += 1

    candidates.sort(key=lambda item: (item[0], item[2], item[3]))
    selected: list[tuple[int, int, str]] = []
    cursor = 0
    for start, end, _negative_length, _order, phrase in candidates:
        if start < cursor:
            continue
        selected.append((start, end, phrase))
        cursor = end

    if not selected:
        return text
    output: list[str] = []
    cursor = 0
    for start, end, phrase in selected:
        output.append(text[cursor:start])
        output.append(phrase)
        cursor = end
    output.append(text[cursor:])
    return "".join(output)


def _ascii_word_edge(char: str) -> bool:
    return char.isascii() and (char.isalnum() or char == "_")


def get_bias_prompt() -> str:
    """Return a comma-joined list of enabled phrases for injection into STT prompt."""
    prefix = "可能出現的專有名詞："
    phrases: list[str] = []
    for phrase in enabled_phrases():
        candidate = prefix + "、".join(phrases + [phrase])
        if len(candidate.encode("utf-8")) > MAX_BIAS_PROMPT_BYTES:
            continue
        phrases.append(phrase)
    return prefix + "、".join(phrases) if phrases else ""
