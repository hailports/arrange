#!/bin/bash
# Build, tag, push, and publish a GitHub Release DMG.
# Run on the MacBook (has CLVXPad signing). Mini should use mini-verify.sh only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! gh api user --jq .login 2>/dev/null | grep -qx hailports; then
  echo "switch gh to hailports first: gh auth switch" >&2
  exit 1
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  CUR="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
  # bump minor: 1.0 -> 1.1, 1.1.0 -> 1.2
  MAJOR="${CUR%%.*}"
  REST="${CUR#*.}"
  MINOR="${REST%%.*}"
  VERSION="${MAJOR}.$((MINOR + 1))"
fi
BUILD="$(git rev-list --count HEAD)"
BUILD=$((BUILD + 1))

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist

./build.sh
./Arrange.app/Contents/MacOS/Arrange --self-test
DMG="$("$ROOT/scripts/make-dmg.sh")"
"$ROOT/scripts/install-local.sh"

# Never commit DMGs or the built app — Releases hold the binary.
git add Info.plist Sources build.sh scripts .github README.md .gitignore
git reset HEAD -- 'Arrange-*.dmg' 'Arrange.app' 2>/dev/null || true
if ! git diff --cached --quiet; then
  git commit -m "Arrange $VERSION"
fi
git push origin HEAD

TAG="v${VERSION}"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber
else
  git tag -f "$TAG"
  git push -f origin "$TAG"
  gh release create "$TAG" "$DMG" \
    --title "Arrange $VERSION" \
    --notes "Apple silicon. Signed for Accessibility continuity when possible.

SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
fi

echo "shipped $TAG → $DMG"
echo "installed ~/Applications/Arrange.app (enable login with scripts/enable-login.sh)"
