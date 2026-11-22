#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Morphlo.app into ./build.
#   VERSION=0.1.0 ./scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: ..." ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="${APP_OUT:-build/Morphlo.app}" # APP_OUT: build somewhere else (e.g. while a release is notarizing)

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Morphlo" "$APP/Contents/MacOS/Morphlo"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Pick the best signing identity available: Developer ID > Apple Development > ad-hoc.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
  [ -z "$SIGN_IDENTITY" ] && SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)"
  [ -z "$SIGN_IDENTITY" ] && SIGN_IDENTITY="-"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --entitlements Resources/Morphlo.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION, signed with: $SIGN_IDENTITY)"
