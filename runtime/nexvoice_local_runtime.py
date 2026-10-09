#!/usr/bin/env python3
"""Minimal authenticated local-runtime contract for NexVoice.

The production distribution replaces `transcribe_wav` with the MLX Whisper
implementation. This boundary deliberately accepts audio bytes, never a path,
and requires the per-user token created by the macOS app.
"""
from __future__ import annotations

import base64
import gc
import hashlib
import hmac
import importlib
import importlib.metadata
import io
import json
import logging
import math
import os
import re
import sys
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
# VAD deliberately stays a pre-gate, not a second transcription pipeline. A
# short frame and hop keep partial captions responsive while the padding keeps
# the model's timestamps useful. Internal gaps are never removed: punctuation
# inference below relies on the gap between Whisper segments.
VAD_FRAME_MS = 30
VAD_HOP_MS = 15
VAD_PADDING_MS = 120
VAD_MIN_SPEECH_MS = 90
# Silero v5 ONNX tier (票A follow-up, 2026-08-30). The sha256 is the real pin:
# it matches the model bundled with the silero-vad pip package this was
# verified against; the URL is only the fetch source and may drift.
SILERO_VAD_MODEL_URL = (
    "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"
)
SILERO_VAD_SHA256 = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
SILERO_VAD_CHUNK = 512    # silero v5 contract @16 kHz
SILERO_VAD_CONTEXT = 64   # trailing-context samples prepended to each chunk
SILERO_SPEECH_THRESHOLD = 0.5
SILERO_VAD_MAX_MODEL_BYTES = 16 * 1024 * 1024
VAD_LOGGER = logging.getLogger(__name__)
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
_ZH_CONVERTER = None
_ZH_CONVERTER_STATE: str | None = None
_ZH_CONVERTER_LOCK = threading.Lock()
# Idle unload (claude-c13r): the partial + final ASR weights (~3.5GB) used to
# stay resident for the whole process lifetime. After
# NEXVOICE_IDLE_UNLOAD_SEC with no request in flight the cache is dropped and
# the next request reloads lazily. <= 0 disables unloading.
_IDLE_STATE_LOCK = threading.Lock()
_CLOCK = time.monotonic
_LAST_USED = _CLOCK()
_IN_FLIGHT = 0
_UNLOADED_MODELS: set[str] = set()
_IDLE_CHECK_INTERVAL_SEC = 60.0
_VAD_TIER: str | None = None

# Distinctive product names only. Whisper mirrors the *style* of the initial
# prompt, so a long "、"-separated glossary teaches the decoder to sprinkle
# 頓號 lists into ordinary speech (the "NexVoice、Jonel、…" artifact). Common
# tech words decode fine without hints and only bloat that list.
# Tried and reverted 2026-08-16: adding "Claude Code" here does NOT stop either
# whisper-large-v3-turbo or Breeze ASR from decoding it as "cloud code" — the
# acoustic evidence for the ordinary English word beats a prompt hint. Measured,
# not assumed. The working fix is a sounds-like dictionary entry
# ("Claude Code" ← "cloud code"), which LocalTranscriptPostprocessor applies to
# the final transcript. Keep this list to terms that a hint actually changes.
BASE_TERMS = [
    "NexVoice", "NexPilot", "NexDesk", "Typeless", "Whisper", "MLX",
    "Hammerspoon", "Obsidian",
]


class RuntimeBusy(RuntimeError):
    pass


MODEL_MANIFEST = Path(__file__).with_name("model-manifest.json")
_PINNED_PATH_CACHE: dict[str, str] = {}


def pinned_model_path(model: str) -> str:
    """Resolve `model` to the exact manifest revision when one is pinned.

    mlx-whisper calls `snapshot_download(repo_id=...)` with no revision, so a
    bare repo id silently tracks whatever that repository's default branch
    points at today. The manifest has always recorded a `revision`, but nothing
    read it -- the pin was decorative. That matters more now that the default
    model is a third-party conversion rather than an `mlx-community` build.

    Returns a local snapshot path when the pin applies and resolves, otherwise
    the model string unchanged: a pin that cannot be honoured must never stop
    the user from dictating.
    """
    if model in _PINNED_PATH_CACHE:
        return _PINNED_PATH_CACHE[model]
    resolved = model
    try:
        manifest = json.loads(MODEL_MANIFEST.read_text(encoding="utf-8"))
        revision = manifest.get("revision") or ""
        # Only pin the model the manifest actually describes. A user who points
        # NEXVOICE_MLX_MODEL somewhere else gets that repo's own default.
        if manifest.get("model") == model and revision and not os.path.isdir(model):
            from huggingface_hub import snapshot_download  # type: ignore

            resolved = snapshot_download(repo_id=model, revision=revision)
    except Exception as exc:
        # Offline, no hub package, malformed manifest, revision withdrawn --
        # all fall back to the unpinned id rather than failing transcription.
        # The fallback is cached for the process lifetime (a retry per
        # transcription call would stall dictation on a flaky network), so say
        # so once and loudly: a silently unpinned model tracks the repo's
        # moving default revision instead of the manifest revision.
        VAD_LOGGER.warning(
            "pinned_model_path(%s): falling back to unpinned id for this "
            "process (%s: %s); model revision is no longer manifest-pinned",
            model, type(exc).__name__, exc,
        )
        resolved = model
    _PINNED_PATH_CACHE[model] = resolved
    return resolved


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
        "zh_convert": zh_convert_status(),
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


_CJK_RUN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0002FA1F]+")
_URL_SPAN = re.compile(r"(?i)(?:https?://|ftp://|www\.)[^\s<>()]+")
_MARKDOWN_CODE_SPAN = re.compile(r"```.*?```|`[^`\n]+`", re.DOTALL)


def _zh_convert_disabled() -> bool:
    return os.environ.get("NEXVOICE_ZH_CONVERT", "").strip().casefold() == "off"


def _zh_converter():
    """Return the process-wide OpenCC converter, loading it only on demand."""
    global _ZH_CONVERTER, _ZH_CONVERTER_STATE
    if _zh_convert_disabled():
        return None
    if _ZH_CONVERTER_STATE == "available":
        return _ZH_CONVERTER
    if _ZH_CONVERTER_STATE == "unavailable":
        return None
    with _ZH_CONVERTER_LOCK:
        if _ZH_CONVERTER_STATE == "available":
            return _ZH_CONVERTER
        if _ZH_CONVERTER_STATE == "unavailable":
            return None
        try:
            opencc = importlib.import_module("opencc")
            _ZH_CONVERTER = opencc.OpenCC("s2twp")
            _ZH_CONVERTER_STATE = "available"
        except Exception as exc:  # optional dependency; transcription must still work
            _ZH_CONVERTER = None
            _ZH_CONVERTER_STATE = "unavailable"
            VAD_LOGGER.warning(
                "Traditional-Chinese post-processing unavailable (%s: %s)",
                type(exc).__name__,
                exc,
            )
    return _ZH_CONVERTER


def zh_convert_status() -> str:
    """Report the health/status contract for Traditional-Chinese conversion."""
    if _zh_convert_disabled():
        return "off"
    return "available" if _zh_converter() is not None else "unavailable"


def convert_transcript(text: str, vocab_terms: list[str] | None = None) -> str:
    """Convert only CJK runs, preserving URLs, code spans, and user terms."""
    converter = _zh_converter()
    if converter is None or not text:
        return text

    protected: dict[str, str] = {}
    source = text
    token_index = 0

    def protect(pattern: re.Pattern[str]) -> None:
        nonlocal source, token_index

        def replacement(match: re.Match[str]) -> str:
            nonlocal token_index
            original = match.group(0)
            while True:
                token = f"\ue000NVZH{token_index}\ue001"
                token_index += 1
                if token not in source and token not in protected:
                    break
            protected[token] = original
            return token

        source = pattern.sub(replacement, source)

    # Protect broad spans first so a vocabulary term inside a URL or code span
    # cannot leave a partially protected span behind.
    protect(_URL_SPAN)
    protect(_MARKDOWN_CODE_SPAN)
    terms = sorted(
        {unicodedata.normalize("NFC", term) for term in (vocab_terms or []) if term},
        key=len,
        reverse=True,
    )
    if terms:
        protect(re.compile("|".join(re.escape(term) for term in terms)))

    converted = _CJK_RUN.sub(lambda match: converter.convert(match.group(0)), source)
    for token, original in protected.items():
        converted = converted.replace(token, original)
    return converted


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


def to_srt(segments: list[dict]) -> str:
    """Render Whisper segments as standard SubRip (SRT) text.

    Whisper timestamps are fractional seconds. SRT uses rounded milliseconds;
    carrying through the total millisecond count keeps values such as
    ``59.9996`` from producing an invalid ``00:00:59,1000`` timestamp.
    """

    def timestamp(seconds: object) -> str:
        try:
            total_milliseconds = max(0, int(float(seconds) * 1000 + 0.5))
        except (TypeError, ValueError, OverflowError):
            total_milliseconds = 0
        hours, remainder = divmod(total_milliseconds, 3_600_000)
        minutes, remainder = divmod(remainder, 60_000)
        whole_seconds, milliseconds = divmod(remainder, 1000)
        return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d},{milliseconds:03d}"

    blocks = []
    number = 0
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        number += 1
        text = str(segment.get("text", "")).strip()
        blocks.append(
            "\n".join(
                (
                    str(number),
                    f"{timestamp(segment.get('start', 0.0))} --> "
                    f"{timestamp(segment.get('end', segment.get('start', 0.0)))}",
                    text,
                )
            )
        )
    return "\n\n".join(blocks)


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


def _vad_enabled() -> bool:
    return os.environ.get("NEXVOICE_VAD", "1").strip().casefold() not in {"0", "false"}


def _numpy_vad(samples, sample_rate: int) -> tuple[bool, int, int]:
    """Find speech-like outer bounds with numpy energy and zero crossings.

    Energy alone mistakes clicks, tones, and HVAC noise for speech. The small
    zero-crossing test rejects those steady extremes while retaining ordinary
    voiced/unvoiced speech. This is a gate, not a speech recognizer.
    """
    import numpy as np

    if len(samples) == 0:
        return False, 0, 0
    frame_size = max(1, int(sample_rate * VAD_FRAME_MS / 1000))
    hop_size = max(1, int(sample_rate * VAD_HOP_MS / 1000))
    if len(samples) < frame_size:
        return False, 0, 0
    starts = np.arange(0, len(samples) - frame_size + 1, hop_size)
    frames = np.asarray(samples, dtype=np.float32)[starts[:, None] + np.arange(frame_size)]
    rms = np.sqrt(np.mean(frames * frames, axis=1) + 1e-12)
    crossings = np.mean((frames[:, 1:] * frames[:, :-1]) < 0, axis=1)
    noise_floor = float(np.percentile(rms, 20))
    # A 20th-percentile floor is still part of a quiet utterance when the
    # clip contains speech throughout, so a modest ratio keeps voiced frames
    # while the crossing/variation checks reject stationary noise.
    energy_cutoff = max(noise_floor * 1.35, 0.006)
    # White noise is near 0.5 crossings/sample; a steady tone is near zero.
    candidates = (rms >= energy_cutoff) & (crossings >= 0.01) & (crossings <= 0.35)
    if int(candidates.sum()) < max(3, int(VAD_MIN_SPEECH_MS / VAD_FRAME_MS)):
        return False, 0, 0
    # Steady tones can sit in the crossing range, so require movement in the
    # candidate envelope or in its crossing rate, as real speech has both.
    candidate_rms = rms[candidates]
    candidate_zcr = crossings[candidates]
    if float(np.ptp(candidate_rms)) < 0.01 and float(np.ptp(candidate_zcr)) < 0.02:
        return False, 0, 0
    indices = np.flatnonzero(candidates)
    pad = int(sample_rate * VAD_PADDING_MS / 1000)
    start = max(0, int(indices[0] * hop_size) - pad)
    end = min(len(samples), int(indices[-1] * hop_size + frame_size) + pad)
    if end - start < int(sample_rate * VAD_MIN_SPEECH_MS / 1000):
        return False, 0, 0
    return True, start, end


_SILERO_SESSION = None
_SILERO_UNAVAILABLE = False
_SILERO_ENABLED: bool | None = None
_SILERO_MODEL_LOCK = threading.Lock()


def silero_model_path() -> Path:
    """Resolve (downloading and sha256-verifying on first use) the pinned
    silero VAD model. A missing/corrupt/undownloadable model is remembered for
    the process lifetime so a transcription burst never stalls on retries."""
    global _SILERO_UNAVAILABLE
    path = Path.home() / ".cache" / "nexvoice" / "models" / "silero-vad" / "silero_vad.onnx"
    # The lock serializes resolve+download within this process. Each process
    # uses its own temporary file; sha256 verification before atomic rename
    # lets cross-process races converge on the same verified final bytes.
    with _SILERO_MODEL_LOCK:
        if _SILERO_UNAVAILABLE:
            return path
        tmp_path = None
        try:
            if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == SILERO_VAD_SHA256:
                return path
            path.parent.mkdir(parents=True, exist_ok=True)
            import urllib.request

            with tempfile.NamedTemporaryFile(
                dir=path.parent,
                prefix=f".{path.name}.",
                suffix=".tmp",
                delete=False,
            ) as tmp_file:
                tmp_path = Path(tmp_file.name)
                with urllib.request.urlopen(SILERO_VAD_MODEL_URL, timeout=30) as response:
                    model_bytes = response.read(SILERO_VAD_MAX_MODEL_BYTES + 1)
                if len(model_bytes) > SILERO_VAD_MAX_MODEL_BYTES:
                    raise ValueError(
                        f"silero VAD model exceeds {SILERO_VAD_MAX_MODEL_BYTES} bytes"
                    )
                tmp_file.write(model_bytes)
                tmp_file.flush()
                os.fsync(tmp_file.fileno())
            digest = hashlib.sha256(tmp_path.read_bytes()).hexdigest()
            if digest != SILERO_VAD_SHA256:
                raise ValueError(f"silero VAD model sha256 mismatch: {digest}")
            tmp_path.replace(path)
        except Exception as exc:
            _SILERO_UNAVAILABLE = True
            VAD_LOGGER.warning(
                "silero VAD model unavailable (%s: %s); VAD stays on the numpy energy gate",
                type(exc).__name__, exc,
            )
        finally:
            if tmp_path is not None:
                tmp_path.unlink(missing_ok=True)
    return path


def _silero_enabled() -> bool:
    global _SILERO_ENABLED
    if _SILERO_ENABLED is None:
        _SILERO_ENABLED = (
            os.environ.get("NEXVOICE_VAD_SILERO", "auto").strip().casefold()
            not in {"0", "false"}
        )
    return _SILERO_ENABLED


def _silero_session():
    """Lazily build the ONNX session, or None when the tier cannot run.

    NEXVOICE_VAD_SILERO has process-start semantics: it is read when the
    session is first constructed, and the resulting session is cached. It is
    not a runtime toggle.
    """
    global _SILERO_SESSION, _SILERO_UNAVAILABLE
    if _SILERO_UNAVAILABLE:
        return None
    if not _silero_enabled():
        return None
    if _SILERO_SESSION is not None:
        return _SILERO_SESSION
    try:
        import onnxruntime

        path = silero_model_path()
        if not path.exists():
            return None
        options = onnxruntime.SessionOptions()
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = 1
        _SILERO_SESSION = onnxruntime.InferenceSession(
            str(path), providers=["CPUExecutionProvider"], sess_options=options
        )
    except Exception as exc:
        _SILERO_UNAVAILABLE = True
        VAD_LOGGER.warning(
            "silero VAD backend unavailable (%s: %s); VAD stays on the numpy energy gate",
            type(exc).__name__, exc,
        )
        return None
    return _SILERO_SESSION


def _silero_vad(samples, sample_rate: int) -> tuple[bool, int, int] | None:
    """Silero streaming VAD with the same gate/outer-trim contract as
    _numpy_vad. Returns None when the backend failed and the caller should
    fall back to the energy gate for this clip. Per the official OnnxWrapper,
    each 512-sample chunk carries a 64-sample trailing-context prefix and the
    recurrent state threads through the whole clip."""
    import numpy as np

    global _SILERO_SESSION, _SILERO_UNAVAILABLE

    if sample_rate != 16000:
        return None
    session = _silero_session()
    if session is None:
        return None
    try:
        x = np.asarray(samples, dtype=np.float32)
        state = np.zeros((2, 1, 128), dtype=np.float32)
        context = np.zeros(SILERO_VAD_CONTEXT, dtype=np.float32)
        flags = []
        for i in range(0, len(x), SILERO_VAD_CHUNK):
            audio_chunk = x[i:i + SILERO_VAD_CHUNK]
            if len(audio_chunk) < SILERO_VAD_CHUNK:
                audio_chunk = np.pad(
                    audio_chunk,
                    (0, SILERO_VAD_CHUNK - len(audio_chunk)),
                    mode="constant",
                )
            chunk = np.concatenate([context, audio_chunk])
            prob, state = session.run(
                None,
                {
                    "input": chunk[None, :],
                    "state": state,
                    "sr": np.array(16000, dtype=np.int64),
                },
            )
            state = state.astype(np.float32)
            context = chunk[-SILERO_VAD_CONTEXT:].copy()
            flags.append(float(prob[0, 0]) >= SILERO_SPEECH_THRESHOLD)
        if not flags:
            return False, 0, 0
        speech = np.flatnonzero(flags)
        # Same gate accounting as the energy tier: count flagged chunks across
        # the whole clip, not a continuous speech duration.
        chunk_ms = SILERO_VAD_CHUNK * 1000 / sample_rate
        if len(speech) < max(3, int(VAD_MIN_SPEECH_MS / chunk_ms)):
            return False, 0, 0
        pad = int(sample_rate * VAD_PADDING_MS / 1000)
        start = max(0, int(speech[0] * SILERO_VAD_CHUNK) - pad)
        end = min(len(x), int((speech[-1] + 1) * SILERO_VAD_CHUNK) + pad)
        if end - start < int(sample_rate * VAD_MIN_SPEECH_MS / 1000):
            return False, 0, 0
        return True, start, end
    except Exception as exc:
        _SILERO_SESSION = None
        _SILERO_UNAVAILABLE = True
        VAD_LOGGER.warning(
            "silero VAD failed (%s: %s); falling back to the energy gate",
            type(exc).__name__, exc,
        )
        return None


def _select_vad_tier() -> str:
    """Choose and report the available VAD backend once per process.

    NEXVOICE_VAD_SILERO is a process-start setting, not a runtime toggle;
    tier selection is cached after the first call.
    """
    global _VAD_TIER
    if _VAD_TIER is not None:
        return _VAD_TIER
    tier = "numpy"
    if _silero_enabled() and _silero_session() is not None:
        tier = "silero"
    _VAD_TIER = tier
    VAD_LOGGER.info("NexVoice VAD tier: %s", tier)
    return _VAD_TIER


def _vad_bounds(samples, sample_rate: int) -> tuple[bool, int, int]:
    """Run the verified VAD backend."""
    if _select_vad_tier() == "silero":
        result = _silero_vad(samples, sample_rate)
        if result is not None:
            return result
    return _numpy_vad(samples, sample_rate)


def _trim_wav_for_vad(audio: bytes) -> bytes:
    """Reject or outer-trim a PCM WAV before paying the Whisper decode cost."""
    import numpy as np

    with wave.open(io.BytesIO(audio), "rb") as wav:
        params = wav.getparams()
        raw = wav.readframes(wav.getnframes())
    if not raw or params.sampwidth != 2:
        return audio
    samples = (
        np.frombuffer(raw, dtype="<i2")
        .reshape(-1, params.nchannels)
        .mean(axis=1)
        / 32768.0
    )
    speech, start, end = _vad_bounds(samples, params.framerate)
    if not speech:
        return b""
    if start == 0 and end >= len(samples):
        return audio
    frame_width = params.sampwidth * params.nchannels
    trimmed = raw[start * frame_width : end * frame_width]
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setparams(params)
        wav.writeframes(trimmed)
    return output.getvalue()


def _transcribe_core(
    audio: bytes,
    *,
    quality: str = "final",
    vocab_terms: list[str] | None = None,
    skip_vad: bool = False,
) -> tuple[str, list]:
    """Run MLX Whisper and return the cleaned text plus native segments."""
    # Never ask Whisper to decode a muted/empty recording: Whisper can emit
    # memorized broadcast phrases for silence, which must never be pasted.
    try:
        with wave.open(__import__("io").BytesIO(audio), "rb") as wav:
            raw = wav.readframes(wav.getnframes())
        if not raw:
            return "", []
        peak = max(abs(sample) for sample in __import__("array").array("h", raw)) / 32768.0
        if peak < SILENCE_PEAK_THRESHOLD:
            return "", []
    except (OSError, ValueError, OverflowError):
        pass
    audio_for_model = audio
    # Warmup clips are internal synthetic audio; bypass VAD so they always
    # exercise model loading while real user audio still pays the pre-gate.
    if _vad_enabled() and not skip_vad:
        try:
            audio_for_model = _trim_wav_for_vad(audio)
            if not audio_for_model:
                return "", []
        except (OSError, ValueError, OverflowError, ImportError):
            # Preserve the existing decode path for malformed or unsupported
            # WAVs; the peak gate above remains the cheap first pass.
            audio_for_model = audio
    try:
        import mlx_whisper  # type: ignore
    except ImportError as exc:
        raise RuntimeError("mlx-whisper is not installed") from exc
    model = (
        os.environ.get("NEXVOICE_MLX_PARTIAL_MODEL", "mlx-community/whisper-tiny")
        if quality == "partial"
        else os.environ.get("NEXVOICE_MLX_MODEL", "eoleedi/Breeze-ASR-25-mlx")
    )
    model = pinned_model_path(model)
    partial_gate_acquired = quality != "partial" or _PARTIAL_GATE.acquire(blocking=False)
    if not partial_gate_acquired:
        raise RuntimeBusy("partial transcription already running")
    _begin_model_use()
    try:
        prompt = build_initial_prompt(vocab_terms or [], partial=quality == "partial")
        # MLX model execution is serialized. The non-blocking partial gate also
        # prevents stale live-caption requests from building an unbounded queue.
        with _MODEL_LOCK:
            reloading = model not in _MODEL_CACHE and _consume_unloaded(model)
            load_started = time.monotonic()
            holder = None
            try:
                holder = importlib.import_module("mlx_whisper.transcribe").ModelHolder
                if model in _MODEL_CACHE:
                    holder.model = _MODEL_CACHE[model]
                    holder.model_path = model
            except (AttributeError, ImportError):
                holder = None
            with tempfile.NamedTemporaryFile(suffix=".wav") as handle:
                handle.write(audio_for_model)
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
            if reloading:
                print(
                    f"idle-unload: reloaded {quality} model in "
                    f"{time.monotonic() - load_started:.1f}s (incl. first inference)",
                    flush=True,
                )
    finally:
        _end_model_use()
        if quality == "partial" and partial_gate_acquired:
            _PARTIAL_GATE.release()
    segments = result.get("segments")
    if isinstance(segments, list) and segments:
        text = join_segments_with_punctuation(segments)
    else:
        segments = []
        text = str(result.get("text", "")).strip()
    text = convert_transcript(collapse_repetition_loops(text), vocab_terms)
    for segment in segments:
        if isinstance(segment, dict):
            segment["text"] = convert_transcript(str(segment.get("text", "")), vocab_terms)
    return text, segments


def _idle_unload_seconds() -> float:
    try:
        return float(os.environ.get("NEXVOICE_IDLE_UNLOAD_SEC", "1800"))
    except ValueError:
        return 1800.0


def _begin_model_use() -> None:
    global _IN_FLIGHT, _LAST_USED
    with _IDLE_STATE_LOCK:
        _IN_FLIGHT += 1
        _LAST_USED = _CLOCK()


def _end_model_use() -> None:
    global _IN_FLIGHT, _LAST_USED
    with _IDLE_STATE_LOCK:
        _IN_FLIGHT -= 1
        # Also stamp the end so a long transcription is not counted as idle time.
        _LAST_USED = _CLOCK()


def _consume_unloaded(model: str) -> bool:
    with _IDLE_STATE_LOCK:
        if model in _UNLOADED_MODELS:
            _UNLOADED_MODELS.discard(model)
            return True
        return False


def _mlx_clear_cache() -> None:
    """Return MLX's buffer cache to the OS, if MLX is loaded in this process.

    Looks MLX up in sys.modules instead of importing it: if no model was ever
    loaded there is nothing to clear, and importing (or re-importing) MLX's
    native extension from the unloader thread is never safe.
    """
    mx = sys.modules.get("mlx.core")
    if mx is None:
        return
    clear_cache = getattr(mx, "clear_cache", None)
    if clear_cache is None:
        clear_cache = getattr(getattr(mx, "metal", None), "clear_cache", None)
    if clear_cache is not None:
        clear_cache()


# Release hooks; tests replace these so they never touch MLX/Metal.
_GC_COLLECT = gc.collect
_CLEAR_CACHE = _mlx_clear_cache


def _loaded_model_holder():
    """mlx-whisper's single-model ModelHolder, only if already imported."""
    module = sys.modules.get("mlx_whisper.transcribe")
    return getattr(module, "ModelHolder", None) if module is not None else None


def maybe_unload_idle_models() -> bool:
    """Drop cached ASR models after an idle period; return True if unloaded.

    Never blocks or overlaps a transcription: it skips while a request is in
    flight or the model lock is held, and everything below -- dropping the
    references, gc and the MLX cache clear -- runs while holding _MODEL_LOCK,
    the same lock every mlx_whisper.transcribe call runs under. Both the final
    and the tiny partial model are dropped, including mlx-whisper's own
    ModelHolder reference (otherwise the last-used model would stay resident).
    The next request reloads lazily.
    """
    limit = _idle_unload_seconds()
    if limit <= 0:
        return False
    with _IDLE_STATE_LOCK:
        if _IN_FLIGHT > 0 or _CLOCK() - _LAST_USED < limit:
            return False
    if not _MODEL_LOCK.acquire(blocking=False):
        return False
    try:
        with _IDLE_STATE_LOCK:
            if _IN_FLIGHT > 0 or _CLOCK() - _LAST_USED < limit:
                return False
            idle = _CLOCK() - _LAST_USED
        holder = _loaded_model_holder()
        if not _MODEL_CACHE and (holder is None or getattr(holder, "model", None) is None):
            return False
        started = time.monotonic()
        names = sorted(_MODEL_CACHE)
        _MODEL_CACHE.clear()
        if holder is not None:
            holder.model = None
            holder.model_path = None
        _GC_COLLECT()
        try:
            _CLEAR_CACHE()
        except Exception as exc:  # pragma: no cover - best-effort only
            print(f"idle-unload: clear_cache failed: {type(exc).__name__}: {exc}", flush=True)
        with _IDLE_STATE_LOCK:
            _UNLOADED_MODELS.update(names)
        print(
            f"idle-unload: released {len(names)} model(s) after {idle:.0f}s idle "
            f"in {time.monotonic() - started:.2f}s",
            flush=True,
        )
        return True
    finally:
        _MODEL_LOCK.release()


class IdleUnloader:
    """Background thread that calls maybe_unload_idle_models periodically.

    Stoppable via stop(); also exits when the runtime is shutting down.
    """

    def __init__(self, interval: float = _IDLE_CHECK_INTERVAL_SEC) -> None:
        self.interval = interval
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name="nexvoice-idle-unload", daemon=True
        )

    def start(self) -> "IdleUnloader":
        self._thread.start()
        return self

    def stop(self, timeout: float | None = 5.0) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout)

    def is_alive(self) -> bool:
        return self._thread.is_alive()

    def _run(self) -> None:
        while not self._stop.wait(self.interval):
            if _SHUTTING_DOWN.is_set():
                return
            try:
                maybe_unload_idle_models()
            except Exception as exc:  # pragma: no cover - never kill the thread
                print(f"idle-unload: failed: {type(exc).__name__}: {exc}", flush=True)


def transcribe_wav(
    audio: bytes,
    *,
    quality: str = "final",
    vocab_terms: list[str] | None = None,
    skip_vad: bool = False,
) -> str:
    """Run MLX Whisper when the optional local dependency is installed."""
    text, _segments = _transcribe_core(
        audio, quality=quality, vocab_terms=vocab_terms, skip_vad=skip_vad
    )
    return text


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
        transcribe_wav(_make_warmup_wav(), quality="final", skip_vad=True)
    except Exception as exc:  # pragma: no cover - best-effort only, e.g. mlx-whisper missing
        print(f"warmup: final model failed: {type(exc).__name__}: {exc}", flush=True)
        return
    elapsed = time.monotonic() - started
    print(f"warmup: final model ready in {elapsed:.1f}s", flush=True)


def _warm_partial_model() -> None:
    """Best-effort background warmup for the partial (tiny) live-caption model.

    Same rationale and same reuse-of-transcribe_wav approach as
    `_warm_final_model`, but for quality="partial". This one DOES briefly
    hold `_PARTIAL_GATE` (non-blocking acquire, same as any real partial
    request) -- if a genuine live-caption request wins the race, this
    warmup simply raises RuntimeBusy, which is caught below like any other
    best-effort failure.
    """
    started = time.monotonic()
    try:
        transcribe_wav(_make_warmup_wav(), quality="partial", skip_vad=True)
    except Exception as exc:  # pragma: no cover - best-effort only, e.g. mlx-whisper missing
        print(f"warmup: partial model failed: {type(exc).__name__}: {exc}", flush=True)
        return
    elapsed = time.monotonic() - started
    print(f"warmup: partial model ready in {elapsed:.1f}s", flush=True)


def _warm_models() -> None:
    """Warm the partial (tiny) model before the final (large) model.

    Live caption calls the partial model on every keystroke while the user
    is still speaking, so warming it first shrinks the window right after
    launch during which live captions are empty/slow. The (heavier, less
    latency-sensitive) final model becomes warm slightly later as a result,
    which is the right tradeoff since it is only needed once recording
    stops.
    """
    _warm_partial_model()
    _warm_final_model()


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
            want_segments = body.get("want_segments", False)
            want_srt = body.get("want_srt", False)
            if not isinstance(want_segments, bool) or not isinstance(want_srt, bool):
                raise ValueError("want_segments and want_srt must be booleans")
            vocab_terms = safe_vocab_terms(body.get("vocab_terms", []))
            started = time.monotonic()
            if want_segments or want_srt:
                text, segments = _transcribe_core(
                    audio, quality=quality, vocab_terms=vocab_terms
                )
            else:
                text = transcribe_wav(audio, quality=quality, vocab_terms=vocab_terms)
                segments = []
            nonce = self.headers.get("X-NexVoice-Local-Nonce", "")
            response = {
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
            }
            if want_segments:
                response["segments"] = [
                    {
                        "start": segment.get("start"),
                        "end": segment.get("end"),
                        "text": str(segment.get("text", "")).strip(),
                    }
                    for segment in segments
                    if isinstance(segment, dict)
                ]
            if want_srt:
                response["srt"] = to_srt(segments)
            self._json(200, response)
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
    threading.Thread(target=_warm_models, daemon=True).start()
    IdleUnloader().start()
    httpd.serve_forever(poll_interval=0.25)
