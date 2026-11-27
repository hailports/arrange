#!/bin/bash
# MacBook only: install the just-built app to ~/Applications and point the LaunchAgent at it.
# Does not enable the agent (call scripts/enable-login.sh for that). Never run on the Mini.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Arrange.app"
DEST="$HOME/Applications/Arrange.app"
test -d "$APP" || { echo "build first: $ROOT/build.sh" >&2; exit 1; }
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
PLIST="$HOME/Library/LaunchAgents/com.hailports.arrange.plist"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hailports.arrange</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST/Contents/MacOS/Arrange</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ThrottleInterval</key>
  <integer>30</integer>
</dict>
</plist>
EOF
# Retire the old DisplayControl KeepAlive label if present.
if [ -f "$HOME/Library/LaunchAgents/com.local.arrange.plist" ]; then
  launchctl bootout "gui/$(id -u)/com.local.arrange" 2>/dev/null || true
  launchctl disable "gui/$(id -u)/com.local.arrange" 2>/dev/null || true
fi
echo "installed $DEST"
echo "plist $PLIST (not loaded — run scripts/enable-login.sh)"
