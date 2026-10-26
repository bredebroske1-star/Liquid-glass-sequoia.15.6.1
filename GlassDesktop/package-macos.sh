#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

swift build -c release --triple arm64-apple-macosx13.0 --scratch-path .build-arm64
swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path .build-x86_64

DIST="$ROOT/dist"
STAGING="$DIST/staging"
APP="$STAGING/Glass Desktop.app"
CONTENTS="$APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/GlassDesktop"
DMG="$DIST/Glass-Desktop-macOS.dmg"

mkdir -p "$CONTENTS/MacOS"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
lipo -create \
    "$ROOT/.build-arm64/arm64-apple-macosx/release/GlassDesktop" \
    "$ROOT/.build-x86_64/x86_64-apple-macosx/release/GlassDesktop" \
    -output "$EXECUTABLE"

mkdir -p "$DIST"
ln -sfn /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create \
    -volname "Glass Desktop" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

echo "Created $DMG"
shasum -a 256 "$DMG"
