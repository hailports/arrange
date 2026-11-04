#!/bin/bash
# Builds Arrange.app. arm64 only (Sources/uc_self.S).
# Optional: ARRANGE_SIGN_IDENTITY="<name or SHA-1 of a codesigning identity>" keeps the
# Accessibility grant across rebuilds. Without it the app is ad-hoc signed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Arrange.app"
BIN="$APP/Contents/MacOS"
OBJ="$(mktemp -d)/uc_self.o"
rm -rf "$APP"
mkdir -p "$BIN"
clang -c -o "$OBJ" "$ROOT/Sources/uc_self.S"
swiftc -parse-as-library -O -swift-version 5 \
  -framework AppKit -framework CoreGraphics -framework SystemConfiguration -framework ApplicationServices \
  -o "$BIN/Arrange" \
  "$ROOT/Sources/Layout.swift" \
  "$ROOT/Sources/Services.swift" \
  "$ROOT/Sources/Arranger.swift" \
  "$ROOT/Sources/Panel.swift" \
  "$ROOT/Sources/main.swift" \
  "$OBJ"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign "${ARRANGE_SIGN_IDENTITY:--}" "$APP"
echo "built $APP"
