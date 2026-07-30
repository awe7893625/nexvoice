#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
DEST="$HOME/.cache/nexvoice/runtime"
PYTHON="${NEXVOICE_PYTHON:-/opt/homebrew/bin/python3}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"
mkdir -p "$DEST"
"$PYTHON" -m venv "$DEST/.venv"
"$DEST/.venv/bin/pip" install --upgrade -r "$ROOT/requirements.txt"
MODEL_PATH=$("$DEST/.venv/bin/python3" - "$ROOT/model-manifest.json" <<'PY'
import json
import re
import sys
from huggingface_hub import snapshot_download

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
model = manifest.get("model")
revision = manifest.get("revision")
if not isinstance(model, str) or not model.strip():
    raise SystemExit("model manifest is missing model")
if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("model manifest requires an exact 40-character revision")
print(snapshot_download(repo_id=model, revision=revision))
PY
)
MODEL_PATH_TMP="$DEST/.model-path.$$"
print -r -- "$MODEL_PATH" > "$MODEL_PATH_TMP"
chmod 600 "$MODEL_PATH_TMP"
mv -f "$MODEL_PATH_TMP" "$DEST/model-path"
chmod 700 "$DEST" "$DEST/.venv"
print "NexVoice local MLX runtime installed at $DEST/.venv"
print "Pinned model snapshot: $MODEL_PATH"
