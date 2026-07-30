"""
app.py — NexVoice FastAPI gateway.

Endpoints:
  GET  /health
  POST /api/transcribe
  POST /v1/audio/transcriptions   (OpenAI-compatible)
  GET  /api/history
  GET  /api/vocab
  POST /api/vocab
  PUT  /api/vocab/{id}
  DELETE /api/vocab/{id}
  GET  /api/settings
  POST /api/settings

Static:
  /        -> web/pwa/   (index.html)
  /admin   -> web/admin/ (index.html)
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import logging
import os
import secrets
import sys
import threading
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

_HERE = Path(__file__).parent
_PROJECT_ROOT = _HERE.parent

DEFAULT_CONFIG: dict[str, Any] = {
    "port": 5111,
    "gemini_api_key_env": "GEMINI_API_KEY",
    "cloud_model": "gemini-2.5-flash",
    "local_model": "mlx-community/whisper-large-v3-turbo",
    "cleanup_ollama_model": "qwen2.5:3b",
    "db_path": str(_PROJECT_ROOT / "data" / "nexvoice.db"),
}


def _load_config() -> dict[str, Any]:
    cfg = dict(DEFAULT_CONFIG)
    candidates = [
        _PROJECT_ROOT / "config.json",
    ]
    for path in candidates:
        if path.exists():
            try:
                with open(path) as f:
                    override = json.load(f)
                cfg.update(override)
                break
            except Exception as exc:
                logging.warning("Could not load config from %s: %s", path, exc)
    return cfg


CONFIG = _load_config()

def _gateway_token() -> str:
    configured = os.environ.get("NEXVOICE_GATEWAY_TOKEN", "").strip()
    path = Path.home() / ".cache" / "nexvoice" / "gateway.token"
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    if configured:
        return configured
    if path.exists() and (value := path.read_text(encoding="utf-8").strip()):
        return value
    value = secrets.token_urlsafe(32)
    path.write_text(value + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
    return value

GATEWAY_TOKEN = _gateway_token()
_AUTH_NONCES: deque[str] = deque()
_AUTH_NONCE_SET: set[str] = set()
_AUTH_NONCE_LOCK = threading.Lock()
_MAX_AUTH_NONCES = 4096
_MAX_HMAC_BODY_BYTES = 1024 * 1024


def _hmac_b64(message: str) -> str:
    return base64.b64encode(
        hmac.new(
            GATEWAY_TOKEN.encode("utf-8"),
            message.encode("utf-8"),
            hashlib.sha256,
        ).digest()
    ).decode("ascii")


def _consume_hmac_nonce(nonce: str) -> bool:
    try:
        decoded = base64.b64decode(nonce, validate=True)
    except (ValueError, binascii.Error):
        return False
    if not 16 <= len(decoded) <= 64:
        return False
    with _AUTH_NONCE_LOCK:
        if nonce in _AUTH_NONCE_SET:
            return False
        _AUTH_NONCES.append(nonce)
        _AUTH_NONCE_SET.add(nonce)
        while len(_AUTH_NONCES) > _MAX_AUTH_NONCES:
            _AUTH_NONCE_SET.discard(_AUTH_NONCES.popleft())
    return True


def _verify_hmac_request(request, body: bytes) -> str | None:
    nonce = request.headers.get("X-NexVoice-Nonce", "")
    supplied = request.headers.get("X-NexVoice-Proof", "")
    if not nonce or not supplied or len(body) > _MAX_HMAC_BODY_BYTES:
        return None
    canonical_path = request.url.path
    if request.url.query:
        canonical_path += f"?{request.url.query}"
    body_hash = hashlib.sha256(body).hexdigest()
    expected = _hmac_b64(
        f"{request.method}\n{canonical_path}\n{nonce}\n{body_hash}"
    )
    if not secrets.compare_digest(supplied, expected):
        return None
    return nonce if _consume_hmac_nonce(nonce) else None

# ---------------------------------------------------------------------------
# DB + module init (must happen after CONFIG is ready)
# ---------------------------------------------------------------------------

# Add server/ to sys.path so sibling imports work when run from project root
sys.path.insert(0, str(_HERE))

import db  # noqa: E402
import vocab_store  # noqa: E402
import settings_store  # noqa: E402
import stt_router  # noqa: E402
import cleanup_v2 as cleanup  # noqa: E402  (2026-07-02 Typeless 級雙模式+守門, 舊版留檔備援)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("nexvoice")

# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(title="NexVoice Gateway", version="0.1.0")

class LocalAuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if request.url.path not in {"/health", "/", "/docs", "/openapi.json"}:
            supplied = request.headers.get("X-NexVoice-Token", "")
            authenticated_nonce = None
            if not supplied or not secrets.compare_digest(supplied, GATEWAY_TOKEN):
                body = await request.body()
                authenticated_nonce = _verify_hmac_request(request, body)
                if authenticated_nonce is None:
                    return JSONResponse({"detail": "unauthorized"}, status_code=401)
            response = await call_next(request)
            if authenticated_nonce is not None:
                canonical_path = request.url.path
                if request.url.query:
                    canonical_path += f"?{request.url.query}"
                message = (
                    f"gateway-response\n{request.method}\n{canonical_path}\n"
                    f"{authenticated_nonce}\n{response.status_code}"
                )
                response.headers["X-NexVoice-Response-Proof"] = _hmac_b64(message)
            return response
        return await call_next(request)

app.add_middleware(LocalAuthMiddleware)

app.add_middleware(
    CORSMiddleware,
    # The gateway is a local desktop service, not a browser API.  Do not grant
    # arbitrary websites read/write access to transcripts or settings.
    allow_origins=[],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=[
        "Content-Type",
        "X-NexVoice-Token",
        "X-NexVoice-Nonce",
        "X-NexVoice-Proof",
    ],
)

MAX_AUDIO_BYTES = 32 * 1024 * 1024


async def _read_bounded(upload: UploadFile) -> bytes:
    data = await upload.read(MAX_AUDIO_BYTES + 1)
    if len(data) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio payload too large")
    return data


@app.on_event("startup")
async def _startup() -> None:  # type: ignore[misc]
    """Initialise DB and prime vocab cache."""
    db.init_db(
        CONFIG["db_path"],
        defaults={
            "cloud_model": CONFIG["cloud_model"],
            "local_model": CONFIG["local_model"],
        },
    )
    vocab_store.reload()
    key_env = CONFIG.get("gemini_api_key_env", "GEMINI_API_KEY")
    has_key = bool(os.environ.get(key_env))
    logger.info(
        "NexVoice gateway started. DB: %s | Gemini key (%s): %s | cloud STT %s",
        CONFIG["db_path"],
        key_env,
        "present" if has_key else "MISSING",
        "available" if has_key else "DISABLED -> local-only fallback",
    )


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "version": "0.1.0"}


# ---------------------------------------------------------------------------
# Shared STT pipeline (fast single-call cloud path + two-step fallback)
# ---------------------------------------------------------------------------


def _run_pipeline(
    audio_bytes: bytes,
    mode: str,
    settings: "settings_store.SettingsView",
    do_cleanup: bool,
    eff_style: str,
) -> tuple[str, str, str, str, str, int]:
    """
    Run transcription (+ optional styled cleanup).

    Engine + model come from LIVE SETTINGS (editable in the admin page), not the
    static config.json — so changing 預設引擎 / 雲端模型 / 本地模型 in /admin takes
    effect immediately. config.json values are only the seed defaults.

    Mode resolution: an explicit request mode (cloud/local) always wins; mode=auto
    defers to settings.engine_default (cloud or local). privacy_mode forces local.

    Fast path: ONE combined Gemini call (transcribe+style) when resolved to cloud +
    cleanup + non-verbatim style — roughly halves latency vs two sequential calls.

    Returns (raw, cleaned, text, engine, model, duration_ms).
    """
    key_env = CONFIG["gemini_api_key_env"]
    cloud_model = settings.cloud_model or CONFIG["cloud_model"]
    local_model = settings.local_model or CONFIG["local_model"]
    privacy_mode = settings.privacy_mode
    cloud_enabled = settings.cloud_enabled

    # Cloud access requires BOTH cloud_enabled=True and privacy_mode=False.
    cloud_allowed = cloud_enabled and (not privacy_mode)

    # Resolve auto -> the user's preferred default engine.
    eff_mode = mode
    if mode == "auto":
        eff_mode = "local" if settings.engine_default == "local" else "auto"

    if not cloud_allowed:
        eff_mode = "local"

    # The combined single-call fast path is Gemini doing BOTH transcribe+cleanup,
    # so it only applies when the cleanup engine is Gemini (or auto, which prefers
    # Gemini). For nim/local cleanup we must do two steps (STT then that engine).
    # 2026-07-02: combined path ONLY when explicitly gemini — "auto" now goes
    # two-step so cleanup_v2's dual-mode (structure upgrade) + guards + Groq
    # bake-off models apply. Combined single-call has no guard/dual-mode.
    cleanup_via_gemini = settings.cleanup_engine == "gemini"
    use_combined = (
        do_cleanup
        and cleanup_via_gemini
        and eff_style != "verbatim"
        and cloud_allowed
        and eff_mode in ("auto", "cloud")
        and stt_router.cloud_available(key_env)
    )
    if use_combined:
        try:
            text, model_used, duration_ms = stt_router.transcribe_combined_cloud(
                audio_bytes,
                cloud_model,
                key_env,
                cleanup.STYLE_PROMPTS[eff_style],
            )
            return text, text, text, "cloud", model_used, duration_ms
        except Exception as exc:  # noqa: BLE001 — fall back gracefully
            logger.warning("Combined cloud path failed (%s); using two-step", type(exc).__name__)

    raw, engine, model_used, duration_ms = stt_router.transcribe(
        audio_bytes=audio_bytes,
        mode=eff_mode,
        privacy_mode=privacy_mode,
        cloud_model=cloud_model,
        local_model=local_model,
        gemini_key_env=key_env,
    )
    if do_cleanup and not privacy_mode:
        eff_cleanup_engine = settings.cleanup_engine
        if not cloud_allowed and eff_cleanup_engine != "local":
            eff_cleanup_engine = "local"
        cleaned = cleanup.cleanup_text(
            raw,
            cloud_model=cloud_model,
            ollama_model=settings.cleanup_local_model,
            gemini_key_env=key_env,
            style=eff_style,
            engine=eff_cleanup_engine,
            nim_model=settings.cleanup_nim_model,
        )
    else:
        cleaned = raw
    text = cleaned if do_cleanup else raw
    return raw, cleaned, text, engine, model_used, duration_ms


# ---------------------------------------------------------------------------
# Transcribe — primary endpoint
# ---------------------------------------------------------------------------


@app.post("/api/transcribe")
async def api_transcribe(
    audio: UploadFile = File(...),
    mode: str = Form("auto"),
    cleanup_flag: Optional[str] = Form(None, alias="cleanup"),
    style: Optional[str] = Form(None),
    source: str = Form("pwa"),
) -> JSONResponse:
    """
    Transcribe audio.

    mode    : auto | cloud | local
    cleanup : true | false (overrides server default if provided)
    style   : verbatim | tidy | meeting | command (overrides server default if provided)
    source  : pwa | desktop | test
    """
    audio_bytes = await _read_bounded(audio)
    settings = settings_store.load()

    # Resolve cleanup flag
    do_cleanup: bool
    if cleanup_flag is not None:
        do_cleanup = cleanup_flag.lower() in {"true", "1", "yes"}
    else:
        do_cleanup = settings.cleanup_enabled

    # Resolve cleanup style
    eff_style = style if style in cleanup.VALID_STYLES else settings.cleanup_style

    # Resolve effective mode (privacy_mode forces local)
    effective_mode = mode if mode in {"cloud", "local", "auto"} else "auto"

    raw, cleaned, text, engine, model_used, duration_ms = _run_pipeline(
        audio_bytes, effective_mode, settings, do_cleanup, eff_style
    )
    ts = _now_iso()

    record_id = db.insert_transcript(
        ts=ts,
        source=source,
        engine=engine,
        model=model_used,
        duration_ms=duration_ms,
        raw=raw,
        cleaned=cleaned,
        style=eff_style,
    )

    return JSONResponse(
        {
            "id": record_id,
            "raw": raw,
            "cleaned": cleaned,
            "text": text,
            "engine": engine,
            "model": model_used,
            "duration_ms": duration_ms,
            "style": eff_style,
        }
    )


# ---------------------------------------------------------------------------
# OpenAI-compatible transcription endpoint (desktop client)
# ---------------------------------------------------------------------------


@app.post("/v1/audio/transcriptions")
async def openai_transcribe(
    file: UploadFile = File(...),
    model: Optional[str] = Form(None),
    prompt: Optional[str] = Form(None),
    style: Optional[str] = Form(None),
    source: str = Form("desktop"),
) -> JSONResponse:
    """
    OpenAI-compatible audio transcription.
    Desktop clients (Hammerspoon / Windows AutoHotkey) send audio here and paste .text.
    Optional `style` form field overrides the server default cleanup style.
    """
    audio_bytes = await _read_bounded(file)
    settings = settings_store.load()

    eff_style = style if style in cleanup.VALID_STYLES else settings.cleanup_style

    requested_mode = "local" if settings.engine_default == "local" else "auto"
    raw, cleaned, text, engine, model_used, duration_ms = _run_pipeline(
        audio_bytes, requested_mode, settings, settings.cleanup_enabled, eff_style
    )
    ts = _now_iso()

    db.insert_transcript(
        ts=ts,
        source=source,
        engine=engine,
        model=model_used,
        duration_ms=duration_ms,
        raw=raw,
        cleaned=cleaned,
        style=eff_style,
    )

    return JSONResponse({"text": text})


# ---------------------------------------------------------------------------
# Text cleanup (punctuation / tidy) — used by the M5 local daemon's fast path,
# which transcribes locally (mlx-whisper, no punctuation) then sends the text
# here to get proper punctuation via the configured cleanup chain. Reuses the
# same cleanup engine + keys as the audio pipeline (single source of truth).
# ---------------------------------------------------------------------------


@app.post("/api/cleanup")
async def api_cleanup(body: dict) -> dict:
    raw = (body.get("text") or "").strip()
    if not raw:
        return {"text": ""}
    settings = settings_store.load()
    req_style = body.get("style")
    eff_style = (
        req_style if req_style in cleanup.VALID_STYLES else settings.cleanup_style
    )
    # Privacy mode or cloud disabled is an end-to-end guarantee: never send transcript text to
    # remote cleanup providers, and never use the private Tailscale helper.
    if settings.privacy_mode or not settings.cloud_enabled:
        return {"text": vocab_store.apply_sounds_like(raw), "style": eff_style}
    cleaned = cleanup.cleanup_text(
        raw,
        cloud_model=settings.cloud_model or CONFIG["cloud_model"],
        ollama_model=settings.cleanup_local_model,
        gemini_key_env=CONFIG["gemini_api_key_env"],
        style=eff_style,
        engine=settings.cleanup_engine,
        nim_model=settings.cleanup_nim_model,
    )
    return {"text": cleaned, "style": eff_style}


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------


@app.get("/api/history")
async def api_history(
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    q: Optional[str] = Query(None),
) -> list:
    return db.get_history(limit=limit, offset=offset, q=q)


# ---------------------------------------------------------------------------
# Vocab CRUD
# ---------------------------------------------------------------------------


@app.get("/api/vocab")
async def get_vocab() -> list:
    return vocab_store.get_all()


@app.post("/api/vocab", status_code=201)
async def create_vocab(body: dict) -> dict:
    if len(db.get_vocab()) >= vocab_store.MAX_ENTRIES:
        raise HTTPException(status_code=422, detail="vocabulary entry limit reached")
    try:
        phrase = vocab_store.normalize_phrase(body.get("phrase"))
        sounds_like = vocab_store.normalize_sounds_like(body.get("sounds_like"))
        enabled = vocab_store.normalize_enabled(body.get("enabled", 1))
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    projected = db.get_vocab() + [
        {"phrase": phrase, "sounds_like": sounds_like, "enabled": enabled}
    ]
    if vocab_store.vocabulary_data_bytes(projected) > vocab_store.MAX_VOCABULARY_DATA_BYTES:
        raise HTTPException(status_code=422, detail="vocabulary data limit reached")
    row = db.insert_vocab(
        phrase=phrase, sounds_like=sounds_like, enabled=enabled, ts=_now_iso()
    )
    vocab_store.reload()
    return row


@app.put("/api/vocab/{vid}")
async def update_vocab(vid: int, body: dict) -> dict:
    existing = db.get_vocab_by_id(vid)
    if existing is None:
        raise HTTPException(status_code=404, detail="vocab entry not found")

    allowed = {"phrase", "sounds_like", "enabled"}
    fields = {k: v for k, v in body.items() if k in allowed}
    try:
        if "phrase" in fields:
            fields["phrase"] = vocab_store.normalize_phrase(fields["phrase"])
        if "sounds_like" in fields:
            fields["sounds_like"] = vocab_store.normalize_sounds_like(fields["sounds_like"])
        if "enabled" in fields:
            fields["enabled"] = vocab_store.normalize_enabled(fields["enabled"])
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    projected = []
    for row in db.get_vocab():
        projected.append({**row, **fields} if row["id"] == vid else row)
    if vocab_store.vocabulary_data_bytes(projected) > vocab_store.MAX_VOCABULARY_DATA_BYTES:
        raise HTTPException(status_code=422, detail="vocabulary data limit reached")

    updated = db.update_vocab(vid, **fields)
    vocab_store.reload()
    return updated  # type: ignore[return-value]


@app.delete("/api/vocab/{vid}", status_code=204)
async def delete_vocab(vid: int) -> None:
    if not db.delete_vocab(vid):
        raise HTTPException(status_code=404, detail="vocab entry not found")
    vocab_store.reload()


@app.get("/api/vocab/export")
async def export_vocab() -> dict:
    """Export the whole vocab list as a portable JSON blob (for backup / sharing)."""
    rows = vocab_store.get_all()
    items = [
        {
            "phrase": r["phrase"],
            "sounds_like": r.get("sounds_like") or "",
            "enabled": int(r.get("enabled", 1)),
        }
        for r in rows
    ]
    return {"version": 1, "count": len(items), "vocab": items}


@app.post("/api/vocab/import")
async def import_vocab(body: dict) -> dict:
    """
    Import vocab entries from an exported blob: {"vocab": [{phrase, sounds_like?, enabled?}]}.
    Upserts by phrase (existing phrase -> update sounds_like/enabled; new -> insert).
    """
    items = body.get("vocab", [])
    if not isinstance(items, list):
        raise HTTPException(status_code=422, detail="vocab must be a list")
    if len(items) > vocab_store.MAX_ENTRIES:
        raise HTTPException(status_code=422, detail="too many vocabulary entries")
    validated: list[tuple[str, str, int]] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise HTTPException(status_code=422, detail=f"vocab[{index}] must be an object")
        try:
            validated.append(
                (
                    vocab_store.normalize_phrase(item.get("phrase")),
                    vocab_store.normalize_sounds_like(item.get("sounds_like")),
                    vocab_store.normalize_enabled(item.get("enabled", 1)),
                )
            )
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=f"vocab[{index}]: {exc}") from exc

    existing_rows = db.get_vocab()
    existing = {r["phrase"].casefold(): r for r in existing_rows}
    new_keys = {phrase.casefold() for phrase, _, _ in validated if phrase.casefold() not in existing}
    if len(existing_rows) + len(new_keys) > vocab_store.MAX_ENTRIES:
        raise HTTPException(status_code=422, detail="vocabulary entry limit reached")
    projected_by_key = {row["phrase"].casefold(): dict(row) for row in existing_rows}
    for phrase, sounds_like, enabled in validated:
        projected_by_key[phrase.casefold()] = {
            "phrase": phrase,
            "sounds_like": sounds_like,
            "enabled": enabled,
        }
    if (
        vocab_store.vocabulary_data_bytes(list(projected_by_key.values()))
        > vocab_store.MAX_VOCABULARY_DATA_BYTES
    ):
        raise HTTPException(status_code=422, detail="vocabulary data limit reached")
    added, updated = 0, 0
    for phrase, sounds_like, enabled in validated:
        key = phrase.casefold()
        if key in existing:
            db.update_vocab(
                existing[key]["id"], sounds_like=sounds_like, enabled=enabled
            )
            updated += 1
        else:
            inserted = db.insert_vocab(
                phrase=phrase, sounds_like=sounds_like, enabled=enabled, ts=_now_iso()
            )
            existing[key] = inserted
            added += 1
    vocab_store.reload()
    return {"added": added, "updated": updated, "total": added + updated}


@app.get("/api/vocab/suggest")
async def suggest_vocab(min_count: int = Query(3), limit: int = Query(20)) -> dict:
    """
    Mine the transcript history for frequent ASCII/Latin tokens (proper nouns,
    product names, English terms) not yet in the vocab — candidates to add so
    future transcriptions get them right.
    """
    import re
    from collections import Counter

    existing = {r["phrase"].lower() for r in db.get_vocab()}
    rows = db.get_history(limit=2000)
    counter: Counter = Counter()
    pat = re.compile(r"[A-Za-z][A-Za-z0-9]{2,}")
    common = {
        "the",
        "and",
        "for",
        "you",
        "are",
        "this",
        "that",
        "with",
        "have",
        "http",
        "https",
        "com",
        "www",
    }
    for r in rows:
        text = r.get("cleaned") or r.get("raw") or ""
        for tok in pat.findall(text):
            if tok.lower() in common or tok.lower() in existing:
                continue
            counter[tok] += 1
    suggestions = [
        {"phrase": w, "count": c}
        for w, c in counter.most_common(limit)
        if c >= min_count
    ]
    return {"suggestions": suggestions}


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------


@app.get("/api/settings")
async def get_settings() -> dict:
    sv = settings_store.load()
    return settings_store.to_dict(sv)


@app.post("/api/settings")
async def update_settings(body: dict) -> dict:
    try:
        sv = settings_store.apply_patch(body)
        return settings_store.to_dict(sv)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get("/api/agent/capabilities")
async def agent_capabilities() -> dict:
    import agent_cli
    return agent_cli.get_capabilities()


@app.get("/api/agent/doctor")
async def agent_doctor() -> dict:
    import agent_cli
    return agent_cli.get_doctor()


@app.get("/api/agent/config-schema")
async def agent_config_schema() -> dict:
    import agent_cli
    return agent_cli.get_config_schema()



# ---------------------------------------------------------------------------
# Static files (PWA + Admin)
# Must be mounted AFTER all API routes to avoid shadowing.
# ---------------------------------------------------------------------------

_PWA_DIR = _PROJECT_ROOT / "web" / "pwa"
_ADMIN_DIR = _PROJECT_ROOT / "web" / "admin"

if _ADMIN_DIR.exists():
    app.mount("/admin", StaticFiles(directory=str(_ADMIN_DIR), html=True), name="admin")
else:
    logger.warning("Admin static dir not found: %s (skipping mount)", _ADMIN_DIR)

if _PWA_DIR.exists():
    app.mount("/", StaticFiles(directory=str(_PWA_DIR), html=True), name="pwa")
else:
    logger.warning("PWA static dir not found: %s (skipping mount)", _PWA_DIR)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run(
        "app:app",
        host="127.0.0.1",
        port=int(CONFIG.get("port", 5111)),
        reload=False,
    )
