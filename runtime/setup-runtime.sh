#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
# Installers can point this helper at a disposable staging root. Keeping the
# default unchanged preserves the standalone developer setup command.
DEST="${NEXVOICE_RUNTIME_DEST:-$HOME/.cache/nexvoice/runtime}"
PYTHON="${NEXVOICE_PYTHON:-/opt/homebrew/bin/python3}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"
mkdir -p "$DEST"
"$PYTHON" -m venv "$DEST/.venv"
"$DEST/.venv/bin/pip" install --upgrade -r "$ROOT/requirements.txt"
chmod 700 "$DEST" "$DEST/.venv"
print "NexVoice local MLX runtime installed at $DEST/.venv"
