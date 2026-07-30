#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
DEST="$HOME/.cache/nexvoice/runtime"
PYTHON="${NEXVOICE_PYTHON:-/opt/homebrew/bin/python3}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"
mkdir -p "$DEST"
"$PYTHON" -m venv "$DEST/.venv"
"$DEST/.venv/bin/pip" install --upgrade -r "$ROOT/requirements.txt"
chmod 700 "$DEST" "$DEST/.venv"
print "NexVoice local MLX runtime installed at $DEST/.venv"
