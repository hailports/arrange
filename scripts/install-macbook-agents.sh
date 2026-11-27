#!/bin/bash
# Install MacBook LaunchAgents: auto-ship when main advances. Does not load Arrange itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UID_NUM="$(id -u)"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

SHIP_PLIST="$HOME/Library/LaunchAgents/com.hailports.arrange-auto-ship.plist"
cat >"$SHIP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hailports.arrange-auto-ship</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT/scripts/auto-ship.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/arrange-auto-ship.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/arrange-auto-ship.launchd.err.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/${UID_NUM}/com.hailports.arrange-auto-ship" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$SHIP_PLIST"
echo "loaded com.hailports.arrange-auto-ship (every 30m)"
