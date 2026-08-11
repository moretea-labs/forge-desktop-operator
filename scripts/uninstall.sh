#!/bin/bash
set -euo pipefail

APP_ROOT="$HOME/Library/Application Support/Forge/DesktopOperator"
APP_BUNDLE="$HOME/Applications/Forge Desktop Operator.app"
LABEL="com.moretea.forge.desktop-operator"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SOCKET="$HOME/Library/Caches/Forge/desktop-operator.sock"
LEGACY_LABEL="com.moretea.repo-harness.desktop-operator"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_SOCKET="$HOME/Library/Caches/repo-harness/desktop-operator.sock"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootout "$DOMAIN/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$PLIST" "$LEGACY_PLIST" "$SOCKET" "$SOCKET.lock" "$LEGACY_SOCKET" "$LEGACY_SOCKET.lock"
rm -rf "$APP_BUNDLE"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$APP_ROOT"
fi
echo "Uninstalled desktop_operator${1:+ and purged Forge state}. Historical legacy Application Support data is intentionally not deleted."
