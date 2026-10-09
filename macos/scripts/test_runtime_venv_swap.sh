#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nexvoice-runtime-swap.XXXXXX")
TMP_ROOT=${TMP_ROOT:A}
trap 'rm -rf "$TMP_ROOT"' EXIT

STAGE_ONE="$TMP_ROOT/stage-one/.venv"
STAGE_TWO="$TMP_ROOT/stage-two/.venv"
VENV_LINK="$TMP_ROOT/.venv"
mkdir -p "$STAGE_ONE" "$STAGE_TWO"
print -r -- "old" > "$STAGE_ONE/old-marker"
print -r -- "new" > "$STAGE_TWO/new-marker"

"$SCRIPT_DIR/publish-runtime-venv.py" "$STAGE_ONE" "$VENV_LINK"
[[ -L "$VENV_LINK" ]]
[[ "$(readlink "$VENV_LINK")" == "$STAGE_ONE" ]]

"$SCRIPT_DIR/publish-runtime-venv.py" "$STAGE_TWO" "$VENV_LINK"
[[ -L "$VENV_LINK" ]]
[[ "$(readlink "$VENV_LINK")" == "$STAGE_TWO" ]]
[[ -f "$STAGE_ONE/old-marker" ]]
[[ "$(find "$STAGE_ONE" -mindepth 1 -maxdepth 1 -print | sort)" == "$STAGE_ONE/old-marker" ]]

print "runtime venv symlink swap: PASS"
