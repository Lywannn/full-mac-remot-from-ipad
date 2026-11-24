#!/bin/bash
# Replace /Applications/RustDesk.app with another RustDesk bundle and restart
# RustDesk's launchd jobs. The ID, password and server settings live in
# ~/Library/Preferences/com.carriez.RustDesk and are not touched.
#
# Run it with sudo from an SSH session, because the RustDesk session drops
# while the app is replaced:
#   sudo bash scripts/rustdesk-swap.sh "$HOME/Downloads/rustdesk-1.5.3/RustDesk.app"
# Roll back by running it again with the backup bundle:
#   sudo bash scripts/rustdesk-swap.sh "$HOME/RustDesk-backup/RustDesk-1.4.9-x86_64.app"
set -euo pipefail

NEW="${1:?usage: sudo bash rustdesk-swap.sh /path/to/RustDesk.app}"
GUI_UID="${SUDO_UID:?run this with sudo}"
EXPECTED_TEAM="HZF9JMC8YN"
APP="/Applications/RustDesk.app"
DAEMON_PLIST="/Library/LaunchDaemons/com.carriez.RustDesk_service.plist"
AGENT_PLIST="/Library/LaunchAgents/com.carriez.RustDesk_server.plist"

# Check the new bundle before touching anything.
[ -x "$NEW/Contents/MacOS/RustDesk" ] && [ -x "$NEW/Contents/MacOS/service" ] \
  || { echo "not a RustDesk bundle: $NEW" >&2; exit 2; }
codesign --verify --deep --strict "$NEW" || { echo "signature check failed: $NEW" >&2; exit 3; }
team="$(codesign -dv "$NEW" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$team" = "$EXPECTED_TEAM" ] || { echo "unexpected TeamIdentifier '$team' (want $EXPECTED_TEAM)" >&2; exit 3; }
[ -f "$DAEMON_PLIST" ] && [ -f "$AGENT_PLIST" ] || { echo "RustDesk launchd plists missing" >&2; exit 4; }

echo "stopping RustDesk..."
launchctl bootout "gui/$GUI_UID/com.carriez.RustDesk_server" 2>/dev/null || true
launchctl bootout system/com.carriez.RustDesk_service 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
sleep 2

echo "replacing ${APP}..."
rm -rf "$APP"
ditto "$NEW" "$APP"

echo "starting RustDesk..."
launchctl bootstrap system "$DAEMON_PLIST"
launchctl bootstrap "gui/$GUI_UID" "$AGENT_PLIST"
sleep 3

echo "installed: $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) ($(lipo -archs "$APP/Contents/MacOS/RustDesk"))"
echo "service: $(launchctl print system/com.carriez.RustDesk_service 2>/dev/null | awk '/^\tstate = /{print $3; exit}')"
echo "server:  $(launchctl print "gui/$GUI_UID/com.carriez.RustDesk_server" 2>/dev/null | awk '/^\tstate = /{print $3; exit}')"
