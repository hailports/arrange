#!/bin/bash
# Mac Mini only: pull main, build ad-hoc, run --self-test. Never installs or launches Arrange.
set -euo pipefail
ROOT="${ARRANGE_ROOT:-$HOME/Developer/arrange}"
LOG="$HOME/Library/Logs/arrange-mini-verify.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== $(date) host=$(hostname) ==="
cd "$ROOT"
git fetch origin --quiet
git checkout main --quiet
git pull --ff-only origin main --quiet
# Force ad-hoc on the Mini — no CLVXPad identity there, and we do not install.
ARRANGE_SIGN_IDENTITY="-" ./build.sh
./Arrange.app/Contents/MacOS/Arrange --self-test
# Do not leave a runnable menu-bar copy lying around as a temptation.
rm -rf ./Arrange.app
echo "verify ok $(git rev-parse --short HEAD)"
