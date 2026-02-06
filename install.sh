#!/bin/bash
# install.sh — Install pty-monitor: symlink, LaunchAgent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/pty-monitor.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.local.pty-monitor"
PLIST_PATH="${PLIST_DIR}/${PLIST_NAME}.plist"
LINK_DIR="$HOME/.local/bin"
LINK_PATH="${LINK_DIR}/pty-monitor"

# Detect node bin for PATH (needed for notify-telegram)
NODE_BIN=""
if command -v node &>/dev/null; then
  NODE_BIN="$(dirname "$(which node)")"
fi

echo "Installing pty-monitor..."

# 1. Symlink
mkdir -p "$LINK_DIR"
ln -sf "$SCRIPT_PATH" "$LINK_PATH"
echo "  Symlink: $LINK_PATH -> $SCRIPT_PATH"

# 2. Unload old agent if exists
launchctl unload "$PLIST_PATH" 2>/dev/null || true

# 3. Generate plist (no hardcoded paths)
ENV_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ -n "$NODE_BIN" ]] && ENV_PATH="${ENV_PATH}:${NODE_BIN}"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_PATH}</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/pty-monitor-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/pty-monitor-launchd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${ENV_PATH}</string>
    </dict>
</dict>
</plist>
EOF

echo "  LaunchAgent: $PLIST_PATH"

# 4. Load
launchctl load "$PLIST_PATH"
echo "  Loaded and running (every 5 minutes)"

echo ""
echo "Done. Commands:"
echo "  pty-monitor --status    # current PTY usage"
echo "  pty-monitor --force     # force alert now"
echo "  pty-monitor --dry-run   # preview without actions"
echo ""
echo "Uninstall:"
echo "  launchctl unload $PLIST_PATH"
echo "  rm $PLIST_PATH $LINK_PATH"
