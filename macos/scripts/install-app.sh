#!/bin/zsh
set -euo pipefail

# Single canonical install path. Two copies (~/Applications and /Applications)
# have different code signatures, so TCC (Microphone/Accessibility) treats
# them as different apps -> "granted in Settings, still shows unauthorized"
# because the running binary isn't the one the grant was bound to.

SCRIPT_DIR=${0:A:h}
MACOS_DIR=${SCRIPT_DIR:h}
ROOT_DIR=${MACOS_DIR:h}
DIST_APP="$ROOT_DIR/dist/NexVoice.app"
CANONICAL="$HOME/Applications/NexVoice.app"
STRAY="/Applications/NexVoice.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
NC="/usr/bin/nc"

# --- Install lock -----------------------------------------------------------
# Two concurrent installer runs would otherwise race on the shared dist/
# build output and on second-resolution backup directory names. A stale lock
# from a killed/crashed previous run must not deadlock every future install,
# so a lock directory whose recorded pid is no longer alive is reclaimed.
STATE_DIR="$HOME/.cache/nexvoice"
LOCK_DIR="$STATE_DIR/install.lock"
mkdir -p "$STATE_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  OLD_PID=""
  [[ -f "$LOCK_DIR/pid" ]] && OLD_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "error: another NexVoice install is already running (pid $OLD_PID)" >&2
    exit 1
  fi
  echo "warning: removing stale install lock (pid ${OLD_PID:-unknown} is not running)" >&2
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"

STAGING="$HOME/Applications/.NexVoice.app.staging.$$"
RUNTIME_ROOT="$HOME/.cache/nexvoice/runtime"
RUNTIME_VENV="$RUNTIME_ROOT/.venv"
RUNTIME_STAGE_ROOT=""
RUNTIME_LINK_STAGE=""
RUNTIME_BACKUP=""
cleanup() {
  rm -rf "$STAGING" 2>/dev/null || true
  if [[ -n "$RUNTIME_BACKUP" && -e "$RUNTIME_BACKUP" ]]; then
    if [[ -e "$RUNTIME_VENV" ]]; then
      rm -rf "$RUNTIME_BACKUP" 2>/dev/null || true
    else
      mv "$RUNTIME_BACKUP" "$RUNTIME_VENV" 2>/dev/null || true
    fi
  fi
  [[ -n "$RUNTIME_LINK_STAGE" ]] && rm -f "$RUNTIME_LINK_STAGE" 2>/dev/null || true
  if [[ -n "$RUNTIME_STAGE_ROOT" && ! -L "$RUNTIME_VENV" ]]; then
    rm -rf "$RUNTIME_STAGE_ROOT" 2>/dev/null || true
  fi
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

INSTALL_BUILD_KIND=${NEXVOICE_INSTALL_BUILD_KIND:-acceptance}
if [[ "$INSTALL_BUILD_KIND" == "dev" ]]; then
  echo "warning: installing an ad-hoc developer build may require Accessibility re-authorization" >&2
fi
NEXVOICE_BUILD_KIND="$INSTALL_BUILD_KIND" zsh "$SCRIPT_DIR/build-app.sh"

if [[ "${NEXVOICE_INSTALL_DRY_RUN:-0}" == "1" ]]; then
  # True no-op: verified before any environment mutation (runtime venv
  # creation/download, LaunchAgent checks, or file replacement) happens.
  echo "dry-run: built and signed $DIST_APP"
  codesign --verify --deep --strict "$DIST_APP"
  echo "dry-run: would install to $CANONICAL (no runtime setup, shutdown, or file replacement)"
  exit 0
fi

if [[ -e "$STRAY" ]]; then
  echo "error: duplicate install exists at $STRAY" >&2
  echo "move it aside manually, then run this installer again" >&2
  exit 1
fi

# The App is the single runtime owner. An old KeepAlive LaunchAgent would
# immediately reclaim 5112 after the App performs a safe shutdown. Both the
# current and a previously used legacy label are checked -- an install that
# only knows about the current name would leave an old daemon-label install
# free to reclaim the port right after this installer hands it over.
for LEGACY_LABEL in ai.nexvoice.local-runtime ai.nexvoice.locald; do
  if launchctl print "gui/$UID/$LEGACY_LABEL" >/dev/null 2>&1; then
    echo "error: legacy $LEGACY_LABEL LaunchAgent is still loaded" >&2
    echo "unload that known service before installing; the App now owns MLX lifecycle" >&2
    exit 1
  fi
done

if pgrep -x NexVoice >/dev/null 2>&1; then
  if [[ ! -x "$CANONICAL/Contents/MacOS/NexVoice" ]]; then
    echo "error: NexVoice is running but canonical app cannot request graceful shutdown" >&2
    exit 1
  fi
  "$CANONICAL/Contents/MacOS/NexVoice" --prepare-for-update >/dev/null 2>&1 || true
  for _ in {1..50}; do
    if ! pgrep -x NexVoice >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  if pgrep -x NexVoice >/dev/null 2>&1; then
    echo "error: running NexVoice did not complete graceful shutdown" >&2
    exit 1
  fi
fi

# Replacing the bundle while an old helper still owns 5112 can make the new
# App report a false green health state. Fail closed; never kill an arbitrary
# PID discovered from a port. A missing/broken `nc` must be a hard failure,
# not silently treated as "port is free" -- `if ! nc ...` cannot tell "port
# closed" apart from "command not found" by exit status alone.
if [[ ! -x "$NC" ]]; then
  echo "error: $NC is required to verify port 5112 is free and was not found" >&2
  exit 1
fi
PORT_FREE=0
for _ in {1..50}; do
  if ! "$NC" -z 127.0.0.1 5112 >/dev/null 2>&1; then
    PORT_FREE=1
    break
  fi
  sleep 0.1
done
if [[ "$PORT_FREE" != "1" ]]; then
  echo "error: port 5112 is still occupied after NexVoice shutdown" >&2
  echo "installation stopped without replacing the signed App" >&2
  exit 1
fi

OWNER_MARKER="$HOME/.cache/nexvoice/native-owner"
OWNER_RECORD="$HOME/.cache/nexvoice/hotkey-owner.json"
if [[ -f "$OWNER_MARKER" ]] && grep -qx "native" "$OWNER_MARKER"; then
  echo "error: NexVoice exited without handing back hotkey ownership" >&2
  exit 1
fi
if [[ -f "$OWNER_RECORD" ]] && grep -q '"owner":"native"' "$OWNER_RECORD"; then
  echo "error: hotkey owner record is still native; refusing replacement" >&2
  exit 1
fi

# One-command open-source onboarding: install the private per-user MLX runtime
# only after every pre-flight gate above has passed. Build it in a disposable
# root so pip cannot modify the active venv; publish it only after setup
# succeeds. After the first successful install, `.venv` is a stable symlink,
# so subsequent staged environments are activated with one atomic rename.
# Packagers can opt out when preparing an offline image.
if [[ "${NEXVOICE_SKIP_RUNTIME_SETUP:-0}" != "1" ]]; then
  RUNTIME_STAGE_ROOT="$RUNTIME_ROOT/.venv-runtime.$$"
  echo "staging local MLX runtime…"
  NEXVOICE_RUNTIME_DEST="$RUNTIME_STAGE_ROOT" \
    zsh "$ROOT_DIR/runtime/setup-runtime.sh"

  RUNTIME_STAGE_VENV="$RUNTIME_STAGE_ROOT/.venv"
  [[ -x "$RUNTIME_STAGE_VENV/bin/python3" ]] || {
    echo "error: staged local MLX runtime is missing its Python executable" >&2
    exit 1
  }

  mkdir -p "$RUNTIME_ROOT"
  RUNTIME_LINK_STAGE="$RUNTIME_ROOT/.venv-link.$$"
  ln -s "$RUNTIME_STAGE_VENV" "$RUNTIME_LINK_STAGE"

  if [[ -L "$RUNTIME_VENV" ]]; then
    if ! mv -f "$RUNTIME_LINK_STAGE" "$RUNTIME_VENV"; then
      echo "error: could not atomically publish staged local MLX runtime" >&2
      exit 1
    fi
    RUNTIME_LINK_STAGE=""
  else
    # Migrate an older directory-form venv only after the staged install has
    # succeeded. If the compatibility migration fails, restore the directory.
    RUNTIME_BACKUP="$RUNTIME_ROOT/.venv.previous.$$"
    if [[ -e "$RUNTIME_VENV" ]]; then
      mv "$RUNTIME_VENV" "$RUNTIME_BACKUP"
    fi
    if ! mv "$RUNTIME_LINK_STAGE" "$RUNTIME_VENV"; then
      echo "error: could not publish staged local MLX runtime; restoring previous venv" >&2
      if [[ -e "$RUNTIME_BACKUP" ]]; then
        mv "$RUNTIME_BACKUP" "$RUNTIME_VENV" || true
      fi
      exit 1
    fi
    RUNTIME_LINK_STAGE=""
  fi

  # The active symlink now owns the staged venv. Retain no obsolete copy from
  # a directory migration, while the EXIT trap can still restore it if a
  # failure occurs before this transaction completes.
  if [[ -n "$RUNTIME_BACKUP" ]]; then
    rm -rf "$RUNTIME_BACKUP"
  fi
  RUNTIME_STAGE_ROOT=""
  RUNTIME_BACKUP=""
fi

mkdir -p "$HOME/Applications"
BACKUP="$HOME/Applications/NexVoice.app.previous.$(date +%Y%m%d-%H%M%S)-$$"
cp -R "$DIST_APP" "$STAGING"
codesign --verify --deep --strict "$STAGING"

HAD_PREVIOUS=0
if [[ -e "$CANONICAL" ]]; then
  HAD_PREVIOUS=1
  "$LSREGISTER" -u "$CANONICAL" >/dev/null 2>&1 || true
  if ! mv "$CANONICAL" "$BACKUP"; then
    echo "error: could not move existing install aside; installation stopped without touching it" >&2
    exit 1
  fi
fi

# Transactional swap: any failure past this point must restore the previous
# install rather than leave the user with a half-replaced or missing App.
INSTALL_OK=1
if ! mv "$STAGING" "$CANONICAL"; then
  INSTALL_OK=0
elif ! "$LSREGISTER" -f "$CANONICAL" >/dev/null 2>&1; then
  INSTALL_OK=0
fi

if [[ "$INSTALL_OK" != "1" ]]; then
  echo "error: installing the new candidate failed; rolling back" >&2
  rm -rf "$CANONICAL" 2>/dev/null || true
  if [[ "$HAD_PREVIOUS" == "1" ]]; then
    if mv "$BACKUP" "$CANONICAL" 2>/dev/null && "$LSREGISTER" -f "$CANONICAL" >/dev/null 2>&1; then
      echo "rolled back to previous install: $CANONICAL" >&2
    else
      echo "error: automatic rollback also failed; previous install may still be at $BACKUP" >&2
    fi
  fi
  exit 1
fi

# Keep LaunchServices deterministic. Backup and dist copies share the bundle
# identifier but must never compete with the canonical signed install.
if [[ -e "$BACKUP" ]]; then
  "$LSREGISTER" -u "$BACKUP" >/dev/null 2>&1 || true
fi
"$LSREGISTER" -u "$DIST_APP" >/dev/null 2>&1 || true

echo "installed: $CANONICAL"
if [[ -e "$BACKUP" ]]; then
  echo "previous version: $BACKUP"
fi
codesign -dvvv "$CANONICAL" 2>&1 | grep -E "TeamIdentifier|CDHash|Signature="

# The App install transaction has already succeeded by this point. Gateway
# and App are independent services, so a gateway verification failure must
# not roll back the successfully installed App; report the manual recovery.
gateway_verification_failure() {
  echo "error: $1" >&2
  echo "App 已成功安裝（不 rollback，gateway 與 app 是獨立服務）；gateway 未驗證重啟，舊進程可能在服務過期代碼；手動補救（失敗的是哪個 label 就重啟哪個）：launchctl kickstart -k gui/\$UID/ai.nexvoice.gateway 或 gui/\$UID/ai.nexvoice.gateway.tailscale" >&2
  exit 1
}

# 票F (2026-08-30): the gateway LaunchAgents are long-lived uvicorn processes
# serving server/ straight from the checkout. Reinstalling without restarting
# them leaves stale code serving 5111 for days (real incident 2026-08-30: the
# 08-25 gateway kept answering with pre-translate-style code after ticket B2
# shipped, so every local-gateway translation failed).
GATEWAY_INSTALLED=0
GATEWAY_PID_BEFORE=""
for GATEWAY_LABEL in ai.nexvoice.gateway ai.nexvoice.gateway.tailscale; do
  if launchctl print "gui/$UID/$GATEWAY_LABEL" >/dev/null 2>&1; then
    if [[ "$GATEWAY_INSTALLED" == "0" ]]; then
      GATEWAY_PID_BEFORE=$(lsof -nP -ti :5111 2>/dev/null || true)
    fi
    GATEWAY_INSTALLED=1
    echo "restarting $GATEWAY_LABEL to pick up current server code…"
    if ! launchctl kickstart -k "gui/$UID/$GATEWAY_LABEL" >/dev/null 2>&1; then
      gateway_verification_failure "kickstart $GATEWAY_LABEL failed"
    fi
  fi
done

if [[ "$GATEWAY_INSTALLED" == "0" ]]; then
  echo "skipped: gateway LaunchAgent not installed (external prerequisite)"
else
  GATEWAY_PID_AFTER=""
  for _ in {1..20}; do
    GATEWAY_PID_AFTER=$(lsof -nP -ti :5111 2>/dev/null || true)
    if [[ -n "$GATEWAY_PID_AFTER" && "$GATEWAY_PID_AFTER" != "$GATEWAY_PID_BEFORE" ]]; then
      break
    fi
    sleep 0.5
  done
  if [[ -z "$GATEWAY_PID_AFTER" || "$GATEWAY_PID_AFTER" == "$GATEWAY_PID_BEFORE" ]]; then
    gateway_verification_failure "gateway restart did not replace the 5111 listener (pid=${GATEWAY_PID_AFTER:-none})"
  fi

  GATEWAY_HEALTH=""
  for _ in {1..20}; do
    GATEWAY_HEALTH=$(curl -s -m 2 http://127.0.0.1:5111/health 2>/dev/null || true)
    [[ "$GATEWAY_HEALTH" == *'"status":"ok"'* ]] && break
    sleep 0.5
  done
  if [[ "$GATEWAY_HEALTH" == *'"status":"ok"'* ]]; then
    echo "gateway restarted and healthy"
  else
    gateway_verification_failure "gateway /health not green after restart; it may still serve stale code"
  fi
fi
