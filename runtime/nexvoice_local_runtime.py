#!/usr/bin/env python3
"""Minimal authenticated local-runtime contract for NexVoice.

The production distribution replaces `transcribe_wav` with the MLX Whisper
implementation. This boundary deliberately accepts audio bytes, never a path,
and requires the per-user token created by the macOS app.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import importlib
import importlib.metadata
import io
import json
import math
import os
import re
import tempfile
import threading
import time
import unicodedata
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# mlx-whisper shells out to `ffmpeg` for audio decoding. When the app is
# launched from Finder/Dock, the inherited PATH is the bare system default
# (/usr/bin:/bin:/usr/sbin:/sbin) and Homebrew's ffmpeg is invisible, which
# surfaces as FileNotFoundError on every transcription. Resolution must not
# depend on how the app was launched, so extend PATH here at process start.
for _extra_bin in ("/opt/homebrew/bin", "/usr/local/bin"):
    if _extra_bin not in os.environ.get("PATH", "").split(os.pathsep) and os.path.isdir(_extra_bin):
        os.environ["PATH"] = os.environ.get("PATH", "") + os.pathsep + _extra_bin

MAX_AUDIO_BYTES = 32 * 1024 * 1024
MAX_VOCAB_TERMS = 64
MAX_VOCAB_TERM_BYTES = 128
MAX_VOCAB_TOTAL_BYTES = 1536
MAX_PROMPT_BYTES = 2048
SILENCE_PEAK_THRESHOLD = 0.03
# Whisper's anti-repetition mechanism: when greedy (t=0) decoding fails the
# compression-ratio check (the signature of a "可以看到，可以看到，…" loop),
# decode_with_fallback retries at the next temperature. A scalar temperature=0
# disables that ladder entirely and returns the looped text as-is.
TEMPERATURE_FALLBACK = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
TOKEN = Path.home() / ".cache" / "nexvoice" / "local-runtime.token"
CONTRACT_VERSION = 2
# Freeze identity at process start. If an installer later replaces the bundle
# at the same path, this process must continue reporting the bytes it actually
# loaded instead of accidentally impersonating the new candidate.
RUNTIME_BUILD = "sha256:" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
EXPECTED_BUILD = os.environ.get("NEXVOICE_RUNTIME_EXPECTED_BUILD", "")
if EXPECTED_BUILD and EXPECTED_BUILD != RUNTIME_BUILD:
    raise SystemExit("bundled runtime build does not match signed manifest")
INSTANCE_ID = str(uuid.uuid4())
OWNER_NONCE = os.environ.get("NEXVOICE_RUNTIME_OWNER_NONCE", "")
try:
    PARENT_PID = int(os.environ.get("NEXVOICE_RUNTIME_PARENT_PID", "0")) or None
except ValueError:
    PARENT_PID = None
try:
    MLX_WHISPER_VERSION = importlib.metadata.version("mlx-whisper")
except importlib.metadata.PackageNotFoundError:
    MLX_WHISPER_VERSION = "unavailable"
CAPABILITIES = [
    "transcribe-v2", "identity-v1", "shutdown-v1", "parent-watchdog-v1", "challenge-response-v1",
]
_MODEL_LOCK = threading.Lock()
_PARTIAL_GATE = threading.Lock()
_MODEL_CACHE: dict[str, object] = {}
_SHUTTING_DOWN = threading.Event()

# Distinctive product names only. Whisper mirrors the *style* of the initial
# prompt, so a long "、"-separated glossary teaches the decoder to sprinkle
# 頓號 lists into ordinary speech (the "NexVoice、Jonel、…" artifact). Common
# tech words decode fine without hints and only bloat that list.
BASE_TERMS = [
    "NexVoice", "NexPilot", "NexDesk", "Typeless", "Whisper", "MLX",
    "Hammerspoon", "Obsidian",
]


class RuntimeBusy(RuntimeError):
    pass


def _secret_bytes() -> bytes | None:
    """Shared HMAC key. Never sent on the wire -- only used to compute and
    verify proofs, so a listener that has not read this 0600 file (e.g. a
    sandboxed local port squatter) cannot forge a request or a response,
    even though it can freely connect to 127.0.0.1:5112. See P0-E."""
    try:
        text = TOKEN.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not text:
        return None
    return text.encode("utf-8")


def _proof(secret: bytes, message: str) -> str:
    digest = hmac.new(secret, message.encode("utf-8"), hashlib.sha256).digest()
    return base64.b64encode(digest).decode("ascii")


def request_proof_message(method: str, path: str, nonce: str, body: bytes) -> str:
    body_hash = hashlib.sha256(body).hexdigest()
    return f"{method}\n{path}\n{nonce}\n{body_hash}"


def health_response_proof_message(nonce: str) -> str:
    return f"health\n{nonce}\n{INSTANCE_ID}\n{RUNTIME_BUILD}\n{OWNER_NONCE}\n{CONTRACT_VERSION}"


def transcribe_response_proof_message(nonce: str, session: str, sequence: int, text: str) -> str:
    return f"transcribe\n{nonce}\n{session}\n{sequence}\n{text}"


def shutdown_response_proof_message(nonce: str) -> str:
    return f"shutdown\n{nonce}\n{INSTANCE_ID}"


def health_payload(nonce: str, secret: bytes) -> dict:
    return {
        "status": "ok",
        "authenticated": True,
        "contract_version": CONTRACT_VERSION,
        "runtime_build": RUNTIME_BUILD,
        "instance_id": INSTANCE_ID,
        "owner_nonce": OWNER_NONCE,
        "parent_pid": PARENT_PID,
        "mlx_whisper_version": MLX_WHISPER_VERSION,
        "capabilities": CAPABILITIES,
        "response_proof": _proof(secret, health_response_proof_message(nonce)),
    }


def shutdown_identity_matches(value: object) -> bool:
    return (
        isinstance(value, dict)
        and bool(OWNER_NONCE)
        and value.get("instance_id") == INSTANCE_ID
        and value.get("runtime_build") == RUNTIME_BUILD
        and value.get("owner_nonce") == OWNER_NONCE
    )


def safe_vocab_terms(value: object) -> list[str]:
    """Validate user dictionary data without treating it as an instruction."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("vocab_terms must be a list")
    result: list[str] = []
    seen: set[str] = set()
    total_bytes = 0
    for raw in value:
        if not isinstance(raw, str):
            raise ValueError("vocab term must be a string")
        term = unicodedata.normalize("NFC", raw).strip()
        encoded = term.encode("utf-8")
        if not term or len(encoded) > MAX_VOCAB_TERM_BYTES:
            continue
        if any(
            unicodedata.category(char) in {"Cc", "Cf", "Zl", "Zp"}
            or char in "\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069"
            for char in term
        ):
            continue
        key = term.casefold()
        if key in seen:
            continue
        if len(result) >= MAX_VOCAB_TERMS or total_bytes + len(encoded) > MAX_VOCAB_TOTAL_BYTES:
            break
        seen.add(key)
        result.append(term)
        total_bytes += len(encoded)
    return result


# The decoder conditions on the initial prompt as if it were the preceding
# transcript, so the *last* sentences dominate the output style. The glossary
# therefore goes first (parenthesized, clearly out-of-band) and the primer
# ends with natural prose demonstrating the punctuation we want: 逗號 for
# pauses, 句號 to close a thought, no 頓號 lists.
STYLE_TAIL = (
    "以下是一段繁體中文與英文混用的口語聽寫逐字稿。"
    "說話的人會自然地講完整的句子，停頓的地方用逗號分隔，"
    "一件事說完就用句號結束，需要提問時才用問號。"
)


def build_initial_prompt(vocab_terms: list[str], *, partial: bool = False) -> str:
    # User terms take priority. Partial captions use a smaller hint set to keep
    # the preview fast; the final pass always receives the complete snapshot.
    requested = vocab_terms[:16] if partial else vocab_terms
    seen: set[str] = set()
    terms: list[str] = []
    for term in requested + BASE_TERMS:
        key = term.casefold()
        if key in seen:
            continue
        candidate = "（詞彙提示：" + "、".join(terms + [term]) + "。）" + STYLE_TAIL
        if len(candidate.encode("utf-8")) > MAX_PROMPT_BYTES:
            continue
        seen.add(key)
        terms.append(term)
    if terms:
        return "（詞彙提示：" + "、".join(terms) + "。）" + STYLE_TAIL
    return STYLE_TAIL


_SENTENCE_ENDERS = "，。！？；：、,.!?;:…"


def join_segments_with_punctuation(segments: list) -> str:
    """Rebuild the transcript from timed segments, closing audible pauses.

    Whisper often leaves clause boundaries unpunctuated in Mandarin. The
    segment timestamps carry the missing signal: a real pause between two
    segments is a spoken clause/sentence break, so supply 逗號 for short
    pauses and 句號 for long ones (ASCII context gets ", "/". ") whenever the
    decoder didn't already end the segment with punctuation.
    """
    out = ""
    prev_end = None
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        text = str(seg.get("text", ""))
        stripped = text.strip()
        if not stripped:
            continue
        try:
            start = float(seg.get("start", 0.0))
            end = float(seg.get("end", start))
        except (TypeError, ValueError):
            start = end = None
        tail = out.rstrip()
        if tail and prev_end is not None and start is not None:
            gap = start - prev_end
            if gap >= 0.6 and tail[-1] not in _SENTENCE_ENDERS:
                ascii_context = ord(tail[-1]) < 128 and ord(stripped[0]) < 128
                if gap >= 1.5:
                    mark = ". " if ascii_context else "。"
                else:
                    mark = ", " if ascii_context else "，"
                out = tail + mark
                text = text.lstrip()
        out += text
        prev_end = end if end is not None else prev_end
    return out.strip()


# A phrase (2-32 chars) repeated 3+ times back-to-back over a span of ≥10
# chars is a decoder loop, never real dictation. Short bursts ("哈哈哈哈哈哈")
# stay untouched via the span floor.
_REPEAT_RUN = re.compile(r"(.{2,32}?)(?:\1){2,}", re.DOTALL)


def collapse_repetition_loops(text: str) -> str:
    """Collapse decoder repetition loops the temperature ladder didn't break."""
    # Loops that split multi-byte tokens across segments leave U+FFFD noise.
    text = text.replace("�", "")

    def _collapse(match: re.Match[str]) -> str:
        if len(match.group(0)) < 10:
            return match.group(0)
        return match.group(1)

    prev = None
    while prev != text:
        prev = text
        text = _REPEAT_RUN.sub(_collapse, text)
    return text


def transcribe_wav(
    audio: bytes,
    *,
    quality: str = "final",
    vocab_terms: list[str] | None = None,
) -> str:
    """Run MLX Whisper when the optional local dependency is installed."""
    # Never ask Whisper to decode a muted/empty recording: Whisper can emit
    # memorized broadcast phrases for silence, which must never be pasted.
    try:
        with wave.open(__import__("io").BytesIO(audio), "rb") as wav:
            raw = wav.readframes(wav.getnframes())
        if not raw:
            return ""
        peak = max(abs(sample) for sample in __import__("array").array("h", raw)) / 32768.0
        if peak < SILENCE_PEAK_THRESHOLD:
            return ""
    except (OSError, ValueError, OverflowError):
        pass
    try:
        import mlx_whisper  # type: ignore
    except ImportError as exc:
        raise RuntimeError("mlx-whisper is not installed") from exc
    model = (
        os.environ.get("NEXVOICE_MLX_PARTIAL_MODEL", "mlx-community/whisper-tiny")
        if quality == "partial"
        else os.environ.get("NEXVOICE_MLX_MODEL", "mlx-community/whisper-large-v3-turbo")
    )
    partial_gate_acquired = quality != "partial" or _PARTIAL_GATE.acquire(blocking=False)
    if not partial_gate_acquired:
        raise RuntimeBusy("partial transcription already running")
    try:
        prompt = build_initial_prompt(vocab_terms or [], partial=quality == "partial")
        # MLX model execution is serialized. The non-blocking partial gate also
        # prevents stale live-caption requests from building an unbounded queue.
        with _MODEL_LOCK:
            holder = None
            try:
                holder = importlib.import_module("mlx_whisper.transcribe").ModelHolder
                if model in _MODEL_CACHE:
                    holder.model = _MODEL_CACHE[model]
                    holder.model_path = model
            except (AttributeError, ImportError):
                holder = None
            with tempfile.NamedTemporaryFile(suffix=".wav") as handle:
                handle.write(audio)
                handle.flush()
                result = mlx_whisper.transcribe(
                    handle.name,
                    path_or_hf_repo=model,
                    language=os.environ.get("NEXVOICE_LANGUAGE", "zh"),
                    temperature=TEMPERATURE_FALLBACK,
                    verbose=False,
                    condition_on_previous_text=False,
                    initial_prompt=prompt,
                )
            if holder is not None and holder.model is not None:
                # mlx-whisper's upstream ModelHolder keeps only one model. Keep
                # the tiny partial and large final model both warm on this M5,
                # avoiding a full reload every time recording stops.
                _MODEL_CACHE[model] = holder.model
    finally:
        if quality == "partial" and partial_gate_acquired:
            _PARTIAL_GATE.release()
    segments = result.get("segments")
    if isinstance(segments, list) and segments:
        text = join_segments_with_punctuation(segments)
    else:
        text = str(result.get("text", "")).strip()
    return collapse_repetition_loops(text)


def _make_warmup_wav() -> bytes:
    """1s of 16kHz mono audio for model warmup.

    A literal digital-silence WAV would be caught by transcribe_wav's own
    silence gate (peak < SILENCE_PEAK_THRESHOLD) and returned as "" before
    ever touching mlx_whisper -- defeating the point of warmup. Use a very
    quiet, inaudible-in-practice tone instead: loud enough to clear that
    gate, quiet enough that "silence" is still the right mental model.
    """
    sample_rate = 16000
    duration_seconds = 1.0
    frequency_hz = 220.0
    amplitude = int(32767 * 0.08)  # well above SILENCE_PEAK_THRESHOLD (0.03)
    frame_count = int(sample_rate * duration_seconds)
    samples = bytearray()
    for i in range(frame_count):
        value = int(amplitude * math.sin(2 * math.pi * frequency_hz * i / sample_rate))
        samples += value.to_bytes(2, byteorder="little", signed=True)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(bytes(samples))
    return buffer.getvalue()


def _warm_final_model() -> None:
    """Best-effort background warmup for the final (large-v3-turbo) model.

    First transcription used to pay mlx_whisper's >10s cold model load on
    the user's dime. Run one throwaway transcription against a near-silent
    clip at process start so the model is already resident in
    `_MODEL_CACHE` by the time a real recording arrives.

    This reuses `transcribe_wav` end to end (same model-selection env vars,
    same model path, same `_MODEL_LOCK` acquire/release scoped only around
    the actual inference call) rather than duplicating any of that logic,
    so it can never hold `_MODEL_LOCK` longer than a normal transcription
    would, and stays compatible with the partial-request gate (this call
    uses quality="final", so it never touches `_PARTIAL_GATE` at all).
    """
    started = time.monotonic()
    try:
        transcribe_wav(_make_warmup_wav(), quality="final")
    except Exception as exc:  # pragma: no cover - best-effort only, e.g. mlx-whisper missing
        print(f"warmup: final model failed: {type(exc).__name__}: {exc}", flush=True)
        return
    elapsed = time.monotonic() - started
    print(f"warmup: final model ready in {elapsed:.1f}s", flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "NexVoiceLocalRuntime/2"

    def _authorize(self, body: bytes) -> bytes | None:
        """Verifies the caller can prove possession of the shared secret file
        without that secret ever having been sent to us. Returns the secret
        (so callers can also sign their own response) or None if unauthorized."""
        secret = _secret_bytes()
        if secret is None:
            return None
        nonce = self.headers.get("X-NexVoice-Local-Nonce", "")
        supplied = self.headers.get("X-NexVoice-Local-Proof", "")
        if not nonce or not supplied:
            return None
        expected = _proof(secret, request_proof_message(self.command, self.path, nonce, body))
        if not hmac.compare_digest(expected, supplied):
            return None
        return secret

    def _json(self, status: int, body: dict) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            secret = self._authorize(b"")
            if secret is None:
                self._json(401, {"error": "unauthorized"})
                return
            nonce = self.headers.get("X-NexVoice-Local-Nonce", "")
            self._json(200, health_payload(nonce, secret))
        else:
            self._json(404, {"error": "not_found"})

    def _read_body(self, max_bytes: int) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > max_bytes:
            raise ValueError("invalid payload length")
        return self.rfile.read(length)

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/control/shutdown":
            try:
                raw = self._read_body(4096)
            except ValueError as exc:
                self._json(422, {"error": type(exc).__name__})
                return
            secret = self._authorize(raw)
            if secret is None:
                self._json(401, {"error": "unauthorized"})
                return
            try:
                body = json.loads(raw)
                if not shutdown_identity_matches(body):
                    self._json(409, {"error": "identity_mismatch"})
                    return
                nonce = self.headers.get("X-NexVoice-Local-Nonce", "")
                self._json(
                    202,
                    {
                        "status": "shutting_down",
                        "instance_id": INSTANCE_ID,
                        "response_proof": _proof(secret, shutdown_response_proof_message(nonce)),
                    },
                )
                _SHUTTING_DOWN.set()
                threading.Thread(target=_shutdown_and_close, args=(self.server,), daemon=True).start()
            except Exception as exc:
                self._json(422, {"error": type(exc).__name__})
            return
        if self.path != "/":
            self._json(404, {"error": "not_found"})
            return
        try:
            raw = self._read_body(MAX_AUDIO_BYTES * 2)
        except ValueError as exc:
            self._json(422, {"error": type(exc).__name__})
            return
        secret = self._authorize(raw)
        if secret is None:
            self._json(401, {"error": "unauthorized"})
            return
        if _SHUTTING_DOWN.is_set():
            self._json(503, {"error": "shutting_down"})
            return
        try:
            body = json.loads(raw)
            if not isinstance(body, dict):
                raise ValueError("body must be an object")
            audio = base64.b64decode(body["audio_base64"], validate=True)
            if not audio or len(audio) > MAX_AUDIO_BYTES:
                raise ValueError("audio too large")
            quality = body.get("quality", "final")
            if quality not in {"partial", "final"}:
                raise ValueError("invalid quality")
            session = body.get("session", "")
            if not isinstance(session, str) or str(uuid.UUID(session)) != session.lower():
                raise ValueError("invalid session")
            sequence = body.get("sequence", 0)
            if isinstance(sequence, bool) or not isinstance(sequence, int) or not 0 <= sequence <= 1_000_000:
                raise ValueError("invalid sequence")
            vocab_terms = safe_vocab_terms(body.get("vocab_terms", []))
            started = time.monotonic()
            text = transcribe_wav(audio, quality=quality, vocab_terms=vocab_terms)
            nonce = self.headers.get("X-NexVoice-Local-Nonce", "")
            self._json(
                200,
                {
                    "text": text,
                    "ms": int((time.monotonic() - started) * 1000),
                    "session": session,
                    "sequence": sequence,
                    "contract_version": CONTRACT_VERSION,
                    "runtime_build": RUNTIME_BUILD,
                    "instance_id": INSTANCE_ID,
                    "response_proof": _proof(
                        secret, transcribe_response_proof_message(nonce, session, sequence, text)
                    ),
                },
            )
        except RuntimeBusy:
            self._json(409, {"error": "busy"})
        except Exception as exc:  # do not expose paths or secrets
            self._json(422, {"error": type(exc).__name__})


def _shutdown_and_close(server: ThreadingHTTPServer) -> None:
    # shutdown() only stops the serve_forever() accept loop; already-running
    # handler threads (e.g. a long transcription) keep going until they
    # finish naturally (draining). server_close() releases the listening
    # socket so the port is free as soon as the accept loop actually exits.
    server.shutdown()
    server.server_close()


def watch_parent(server: ThreadingHTTPServer) -> None:
    if PARENT_PID is None:
        return
    while True:
        time.sleep(0.5)
        if os.getppid() != PARENT_PID:
            _SHUTTING_DOWN.set()
            _shutdown_and_close(server)
            return


class Server(ThreadingHTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    httpd = Server(
        ("127.0.0.1", int(os.environ.get("NEXVOICE_LOCAL_PORT", "5112"))),
        Handler,
    )
    threading.Thread(target=watch_parent, args=(httpd,), daemon=True).start()
    threading.Thread(target=_warm_final_model, daemon=True).start()
    httpd.serve_forever(poll_interval=0.25)
