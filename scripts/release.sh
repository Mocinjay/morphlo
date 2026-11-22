#!/bin/bash
# Builds a signed, notarized Morphlo release: Morphlo.dmg (download button), Morphlo.zip
# (Homebrew + npx), versioned copies, and checksums — everything goes in ./dist.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate (Xcode → Settings → Accounts →
#      Manage Certificates → + → Developer ID Application).
#   2. Store notary credentials in the keychain (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials morphlo-notary --apple-id <you> --team-id <TEAMID>
#
#   VERSION=0.1.0 ./scripts/release.sh            # full signed + notarized release
#   VERSION=0.1.0 SKIP_NOTARIZE=1 ./scripts/release.sh   # local test build (unsigned for others)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION, e.g. VERSION=0.1.0}"
PROFILE="${NOTARY_PROFILE:-morphlo-notary}"
DIST="dist"

IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
if [ -z "$IDENTITY" ] && [ -z "${SKIP_NOTARIZE:-}" ]; then
  echo "No Developer ID Application certificate found. See the header of this script."; exit 1
fi

SIGN_IDENTITY="${IDENTITY:-}" VERSION="$VERSION" ./scripts/build-app.sh
codesign --verify --strict --deep build/Morphlo.app

mkdir -p "$DIST"
ZIP="$DIST/Morphlo.zip"
DMG="$DIST/Morphlo.dmg"

notarize() { # $1 = file to submit
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

# 1) Zip → notarize → staple the app
ditto -c -k --keepParent build/Morphlo.app "$ZIP"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  notarize "$ZIP"
  xcrun stapler staple build/Morphlo.app
  ditto -c -k --keepParent build/Morphlo.app "$ZIP"   # re-zip with the stapled ticket
fi

# 2) DMG with a drag-to-Applications layout → sign → notarize → staple
STAGE="$(mktemp -d)"
cp -R build/Morphlo.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Morphlo" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [ -n "$IDENTITY" ]; then codesign --force --sign "$IDENTITY" --timestamp "$DMG"; fi
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type execute -v build/Morphlo.app
fi

# 3) Versioned copies (Homebrew pins a version) + checksums
cp "$ZIP" "$DIST/Morphlo-$VERSION.zip"
cp "$DMG" "$DIST/Morphlo-$VERSION.dmg"
( cd "$DIST" && shasum -a 256 Morphlo.zip Morphlo.dmg "Morphlo-$VERSION.zip" "Morphlo-$VERSION.dmg" > SHA256SUMS.txt )
SHA="$(shasum -a 256 "$DIST/Morphlo-$VERSION.zip" | cut -d' ' -f1)"

# 4) Keep the cask in sync
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/morphlo.rb

cat <<EOF

Release files in $DIST/:
$(ls -1 "$DIST")

Next:
  gh release create v$VERSION $DIST/Morphlo.dmg $DIST/Morphlo.zip $DIST/Morphlo-$VERSION.zip $DIST/Morphlo-$VERSION.dmg $DIST/SHA256SUMS.txt --title "Morphlo $VERSION"
  # then copy Casks/morphlo.rb into the Mocinjay/homebrew-tap repo, and: (cd npm && npm publish)
EOF
