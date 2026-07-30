#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
SOURCE_APP="$SCRIPT_DIR/NexVoice.app"
APPLICATIONS_DIR="$HOME/Applications"
DEST_APP="$APPLICATIONS_DIR/NexVoice.app"
TEMP_APP="$APPLICATIONS_DIR/.NexVoice.installing.$$"
BACKUP_APP="$APPLICATIONS_DIR/.NexVoice.backup.$$"
STATE_DIR="$HOME/.cache/nexvoice"
LOCK_FILE="$STATE_DIR/community-install.pid"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "NexVoice 原生 App 目前需要 Apple Silicon macOS。"
  exit 1
fi
if [[ ! -d "$SOURCE_APP" ]]; then
  print -u2 "找不到同一下載包內的 NexVoice.app。"
  exit 1
fi

mkdir -p "$APPLICATIONS_DIR"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
if ! /usr/bin/shlock -f "$LOCK_FILE" -p "$$"; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || print "unknown")
  print -u2 "另一個 NexVoice Installer 正在執行（pid $LOCK_PID）。"
  exit 1
fi
cleanup() {
  rm -rf "$TEMP_APP"
  if [[ -f "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
    rm -f "$LOCK_FILE"
  fi
}
trap cleanup EXIT

ditto "$SOURCE_APP" "$TEMP_APP"
codesign --verify --deep --strict "$TEMP_APP"
if [[ -e "$DEST_APP" ]]; then
  mv "$DEST_APP" "$BACKUP_APP"
fi
if ! mv "$TEMP_APP" "$DEST_APP"; then
  [[ -e "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$DEST_APP"
  exit 1
fi

RUNTIME_SETUP="$DEST_APP/Contents/Resources/NexVoiceRuntime/setup-runtime.sh"
if ! zsh "$RUNTIME_SETUP"; then
  rm -rf "$DEST_APP"
  [[ -e "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$DEST_APP"
  print -u2 "Runtime 安裝失敗，已還原舊版 App。"
  exit 1
fi
rm -rf "$BACKUP_APP"

print "NexVoice 已安裝到 $DEST_APP"
print "接著請在系統設定授予 Microphone 與 Accessibility 權限。"
open "$DEST_APP"
