#!/bin/bash
# Install Mini LaunchAgent: pull+build+self-test only. Never installs Arrange.app for login.
set -euo pipefail
ROOT="${ARRANGE_ROOT:-$HOME/Developer/arrange}"
UID_NUM="$(id -u)"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
test -d "$ROOT/.git" || git clone https://github.com/hailports/arrange.git "$ROOT"

PLIST="$HOME/Library/LaunchAgents/com.hailports.arrange-verify.plist"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hailports.arrange-verify</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT/scripts/mini-verify.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/arrange-mini-verify.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/arrange-mini-verify.launchd.err.log</string>
</dict>
</plist>
EOF
# Ensure Arrange is not installed as a login item on the Mini.
launchctl bootout "gui/${UID_NUM}/com.hailports.arrange" 2>/dev/null || true
launchctl bootout "gui/${UID_NUM}/com.local.arrange" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.hailports.arrange.plist" \
      "$HOME/Library/LaunchAgents/com.local.arrange.plist"
rm -rf "$HOME/Applications/Arrange.app" "$ROOT/Arrange.app"

launchctl bootout "gui/${UID_NUM}/com.hailports.arrange-verify" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST"
echo "loaded com.hailports.arrange-verify (hourly, no app install)"
