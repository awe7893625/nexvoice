#!/bin/zsh
set -euo pipefail

# NexVoice one-command installer.
#
#   From a checkout:  zsh install.sh
#   Remote bootstrap: curl -fsSL https://raw.githubusercontent.com/awe7893625/nexvoice/main/install.sh | zsh
#
# Environment overrides:
#   NEXVOICE_REPO_URL            git URL to clone when not run from a checkout
#   NEXVOICE_INSTALL_BUILD_KIND  dev (default here; ad-hoc signature) | acceptance | release
#   NEXVOICE_SIGN_IDENTITY       "Developer ID Application: ..." for signed builds
#   NEXVOICE_EXPECTED_TEAM_ID    required for acceptance/release builds
#   NEXVOICE_SKIP_RUNTIME_SETUP  1 to skip the local MLX Python environment/model setup

REPO_URL=${NEXVOICE_REPO_URL:-https://github.com/awe7893625/nexvoice.git}
CLONE_DIR="$HOME/.local/share/nexvoice/src"

fail() { echo "error: $1" >&2; exit 1; }

# --- Prerequisites -----------------------------------------------------------
command -v git >/dev/null 2>&1 || fail "git is required"
xcode-select -p >/dev/null 2>&1 || fail "Xcode Command Line Tools are required: run 'xcode-select --install'"
command -v swift >/dev/null 2>&1 || fail "swift toolchain is required (comes with Xcode / CLT)"
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the local MLX runtime"
[[ "$(uname -m)" == "arm64" ]] || echo "warning: local MLX transcription requires Apple Silicon; Intel Macs need a cloud provider" >&2

# --- Locate or fetch the source tree -----------------------------------------
if [[ -f "./macos/scripts/install-app.sh" ]]; then
  ROOT="$PWD"
else
  echo "fetching NexVoice source into $CLONE_DIR ..."
  if [[ -d "$CLONE_DIR/.git" ]]; then
    git -C "$CLONE_DIR" pull --ff-only
  else
    mkdir -p "${CLONE_DIR:h}"
    git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
  fi
  ROOT="$CLONE_DIR"
fi

# --- Build + install ----------------------------------------------------------
# dev builds use an ad-hoc signature so no Developer ID certificate is needed.
# Note: macOS ties Accessibility permission to the code signature, so every
# ad-hoc rebuild requires re-granting Accessibility in System Settings.
# A stable Developer ID identity avoids that.
cd "$ROOT"
NEXVOICE_INSTALL_BUILD_KIND="${NEXVOICE_INSTALL_BUILD_KIND:-dev}" \
NEXVOICE_SWIFTPM_DISABLE_SANDBOX=1 \
zsh macos/scripts/install-app.sh

# --- Optional Gateway / Agent CLI Setup --------------------------------------
if [[ "${NEXVOICE_SETUP_GATEWAY:-0}" == "1" ]]; then
  echo "Setting up optional NexVoice Gateway & Agent CLI environment..."
  python3 -m pip install -q -r server/requirements.txt || fail "Failed to install Gateway requirements via pip"
  python3 server/agent_cli.py doctor || fail "Gateway agent_cli doctor check failed"
fi

echo
echo "NexVoice installed to ~/Applications/NexVoice.app"
echo "Next steps (must be done by a human):"
echo "  1. open ~/Applications/NexVoice.app"
echo "  2. Grant Microphone and Accessibility permission in System Settings"
echo "  3. Press Option once to start dictating, press again to stop"
echo "  4. (Optional) Run Python Gateway daemon: python3 server/app.py"

