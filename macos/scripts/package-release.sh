#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
MACOS_DIR=${SCRIPT_DIR:h}
ROOT_DIR=${MACOS_DIR:h}
VERSION=${NEXVOICE_VERSION:-dev}
VERSION=${VERSION#v}
OUT_DIR="$ROOT_DIR/dist/release"
APP_DIR="$ROOT_DIR/dist/NexVoice.app"
ZIP_PATH="$OUT_DIR/NexVoice-${VERSION}-macOS.zip"
DMG_PATH="$OUT_DIR/NexVoice-${VERSION}-macOS.dmg"
CHECKSUM_PATH="$OUT_DIR/SHA256SUMS"
DMG_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/nexvoice-dmg.XXXXXX")
ZIP_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/nexvoice-zip.XXXXXX")
cleanup() {
  rm -rf "$DMG_STAGE" "$ZIP_STAGE"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"

# Public community artifacts are intentionally ad-hoc unless the release
# environment explicitly provides a verified signing identity.
NEXVOICE_BUILD_KIND="${NEXVOICE_BUILD_KIND:-community}" \
  NEXVOICE_SIGN_IDENTITY="${NEXVOICE_SIGN_IDENTITY:--}" \
  zsh "$SCRIPT_DIR/build-app.sh"

codesign --verify --deep --strict "$APP_DIR"

ZIP_PAYLOAD="$ZIP_STAGE/NexVoice-${VERSION}"
mkdir -p "$ZIP_PAYLOAD"
ditto "$APP_DIR" "$ZIP_PAYLOAD/NexVoice.app"
cp "$SCRIPT_DIR/install-community.command" "$ZIP_PAYLOAD/Install NexVoice.command"
chmod 755 "$ZIP_PAYLOAD/Install NexVoice.command"
cat > "$ZIP_PAYLOAD/README.txt" <<'TXT'
NexVoice community prerelease

1. Double-click “Install NexVoice.command”.
2. The installer copies the App to ~/Applications, creates the private MLX
   runtime, and downloads the exact model revision recorded in the App bundle.
3. Grant Microphone and Accessibility permissions in macOS System Settings.

The App is ad-hoc signed and not notarized. macOS may require explicit approval
in Privacy & Security the first time it is opened.
TXT
ditto -c -k --sequesterRsrc --keepParent "$ZIP_PAYLOAD" "$ZIP_PATH"
ditto "$APP_DIR" "$DMG_STAGE/NexVoice.app"
cp "$SCRIPT_DIR/install-community.command" "$DMG_STAGE/Install NexVoice.command"
chmod 755 "$DMG_STAGE/Install NexVoice.command"
cp "$ZIP_PAYLOAD/README.txt" "$DMG_STAGE/README.txt"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "NexVoice ${VERSION}" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

(
  cd "$OUT_DIR"
  shasum -a 256 "${ZIP_PATH:t}" "${DMG_PATH:t}" > "${CHECKSUM_PATH:t}"
)

echo "$ZIP_PATH"
echo "$DMG_PATH"
echo "$CHECKSUM_PATH"
