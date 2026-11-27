#!/bin/bash
# MacBook only: enable + load the Arrange LaunchAgent.
set -euo pipefail
UID_NUM="$(id -u)"
PLIST="$HOME/Library/LaunchAgents/com.hailports.arrange.plist"
test -f "$PLIST" || { echo "run scripts/install-local.sh first" >&2; exit 1; }
launchctl enable "gui/${UID_NUM}/com.hailports.arrange" 2>/dev/null || true
launchctl bootout "gui/${UID_NUM}/com.hailports.arrange" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST"
launchctl kickstart -k "gui/${UID_NUM}/com.hailports.arrange"
echo "Arrange login agent loaded"
