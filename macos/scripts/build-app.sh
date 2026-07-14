#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
MACOS_DIR=${SCRIPT_DIR:h}
ROOT_DIR=${MACOS_DIR:h}
APP_DIR="$ROOT_DIR/dist/NexVoice.app"
BUILD_KIND=${NEXVOICE_BUILD_KIND:-dev}

SWIFTPM_ARGS=()
if [[ "${NEXVOICE_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
  SWIFTPM_ARGS+=(--disable-sandbox)
fi
swift build "${SWIFTPM_ARGS[@]}" -c release --package-path "$MACOS_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$MACOS_DIR/.build/release/NexVoice" "$APP_DIR/Contents/MacOS/NexVoice"
cp "$MACOS_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Ship the authenticated runtime contract and manifest with every candidate.
# Model weights remain a separately verified download; a release build must
# provide an immutable revision/hash rather than silently using "latest".
RUNTIME_SRC="$ROOT_DIR/runtime"
if [[ -d "$RUNTIME_SRC" ]]; then
  mkdir -p "$APP_DIR/Contents/Resources/NexVoiceRuntime"
  cp "$RUNTIME_SRC/nexvoice_local_runtime.py" "$APP_DIR/Contents/Resources/NexVoiceRuntime/"
  cp "$RUNTIME_SRC/model-manifest.json" "$APP_DIR/Contents/Resources/NexVoiceRuntime/"
  RUNTIME_BUILD="sha256:$(shasum -a 256 "$APP_DIR/Contents/Resources/NexVoiceRuntime/nexvoice_local_runtime.py" | awk '{print $1}')"
  printf '{"schema":1,"contract_version":2,"runtime_build":"%s"}\n' \
    "$RUNTIME_BUILD" \
    > "$APP_DIR/Contents/Resources/NexVoiceRuntime/runtime-contract.json"
if [[ "$BUILD_KIND" == "release" ]]; then
    /usr/bin/python3 - "$APP_DIR/Contents/Resources/NexVoiceRuntime/model-manifest.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if data.get("revision") in (None, "", "pin-before-release") or data.get("sha256") in (None, "", "pin-before-release", "directory-manifest-required-before-release"):
    raise SystemExit("release build requires pinned model revision and sha256")
PY
  fi
fi

# Brand assets: PNGs + AppIcon.icns for Dock / Finder / TCC list
RESOURCE_SRC="$MACOS_DIR/Sources/NexVoice/Resources"
if [[ -d "$RESOURCE_SRC" ]]; then
  find "$RESOURCE_SRC" -maxdepth 1 \( -name '*.png' -o -name '*.icns' \) -exec cp -f {} "$APP_DIR/Contents/Resources/" \;
fi
if [[ -f "$MACOS_DIR/AppIcon.icns" ]]; then
  cp -f "$MACOS_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
# Also pull SPM resource bundle if present
find "$MACOS_DIR/.build/release" -maxdepth 1 -name '*.bundle' -type d 2>/dev/null | while read -r bundle; do
  rsync -a "$bundle/" "$APP_DIR/Contents/Resources/" 2>/dev/null || cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

# Stable signing identity so TCC (Accessibility) grants survive rebuilds.
# Ad-hoc (`--sign -`) pins the designated requirement to the executable's
# cdhash, which changes on every build -> every rebuild silently invalidates
# any Accessibility grant the user already made. A real Developer ID cert
# gives a designated requirement anchored to the cert + bundle id instead,
# which stays constant across rebuilds. Open-source contributors may use an
# explicit dev build with ad-hoc signing; acceptance/install builds fail closed.
SIGN_IDENTITY=${NEXVOICE_SIGN_IDENTITY:-}
if [[ -z "$SIGN_IDENTITY" && "$BUILD_KIND" != "dev" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -1)
fi
if [[ -z "$SIGN_IDENTITY" ]] || ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  if [[ "$BUILD_KIND" == "dev" ]]; then
    echo "warning: Developer ID unavailable; creating an ad-hoc dev build" >&2
    SIGN_IDENTITY="-"
  else
    echo "error: acceptance build requires NEXVOICE_SIGN_IDENTITY or an installed Developer ID Application certificate" >&2
    exit 1
  fi
fi

ENTITLEMENTS="$MACOS_DIR/NexVoice.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
  codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"
if [[ "$BUILD_KIND" != "dev" ]]; then
  TEAM_ID=$(codesign -dvv "$APP_DIR" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  EXPECTED_TEAM_ID=${NEXVOICE_EXPECTED_TEAM_ID:-}
  if [[ -z "$TEAM_ID" ]]; then
    echo "error: acceptance build has no TeamIdentifier" >&2
    exit 1
  fi
  # An unset EXPECTED_TEAM_ID used to silently skip this check entirely, so a
  # keychain with more than one Developer ID Application certificate could
  # sign an acceptance/release candidate with whichever one `security
  # find-identity` happened to list first. Pin it: acceptance/release builds
  # must say which team they expect.
  if [[ -z "$EXPECTED_TEAM_ID" ]]; then
    echo "error: acceptance/release build requires NEXVOICE_EXPECTED_TEAM_ID to be set" >&2
    exit 1
  fi
  if [[ "$TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
    echo "error: unexpected TeamIdentifier: $TEAM_ID" >&2
    exit 1
  fi
fi

echo "$APP_DIR"
