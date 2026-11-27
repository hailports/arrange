#!/bin/bash
# Pack Arrange.app into Arrange-<version>.dmg (Applications symlink layout).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Arrange.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")"
DMG="$ROOT/Arrange-${VERSION}.dmg"
STAGE="$(mktemp -d)/arrange-dmg"
rm -f "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Arrange.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Arrange" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "$DMG"
