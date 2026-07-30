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
cleanup() {
  rm -rf "$DMG_STAGE"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"

# Public community artifacts are intentionally ad-hoc unless the release
# environment explicitly provides a verified signing identity.
NEXVOICE_BUILD_KIND="${NEXVOICE_BUILD_KIND:-dev}" \
  NEXVOICE_SIGN_IDENTITY="${NEXVOICE_SIGN_IDENTITY:--}" \
  zsh "$SCRIPT_DIR/build-app.sh"

codesign --verify --deep --strict "$APP_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
ditto "$APP_DIR" "$DMG_STAGE/NexVoice.app"
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
