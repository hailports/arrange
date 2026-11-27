#!/bin/bash
# MacBook LaunchAgent helper: if origin/main moved past the latest GitHub release, ship.
# No-op when dirty, when gh is not hailports, or when signing identity is missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/Library/Logs/arrange-auto-ship.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== $(date) ==="
cd "$ROOT"

if ! gh api user --jq .login 2>/dev/null | grep -qx hailports; then
  echo "skip: gh not hailports"; exit 0
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "skip: working tree dirty"; exit 0
fi

LOCKDIR="$HOME/Library/Logs/arrange-auto-ship.lockdir"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -n "$(find "$LOCKDIR" -prune -mmin +45 2>/dev/null)" ]; then
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR"
  else
    echo "skip: another ship running"; exit 0
  fi
fi
trap 'rm -rf "$LOCKDIR"' EXIT

git fetch origin main --tags --quiet
git checkout -B main origin/main --quiet

HEAD="$(git rev-parse HEAD)"
LATEST_TAG="$(gh release view --json tagName -q .tagName 2>/dev/null || true)"
if [ -n "$LATEST_TAG" ]; then
  TAG_COMMIT="$(git rev-list -n 1 "$LATEST_TAG" 2>/dev/null || true)"
  if [ "$TAG_COMMIT" = "$HEAD" ]; then
    echo "up to date at $LATEST_TAG ($HEAD)"; exit 0
  fi
  # Script/docs-only commits should not mint a new DMG.
  if git diff --quiet "$LATEST_TAG"..HEAD -- Sources build.sh Info.plist; then
    echo "no app changes since $LATEST_TAG (HEAD $HEAD)"; exit 0
  fi
fi

echo "main $HEAD ahead of ${LATEST_TAG:-none}; shipping"
"$ROOT/scripts/ship.sh"
