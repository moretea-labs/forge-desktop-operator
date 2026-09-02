#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(awk -F'"' '/^[[:space:]]*"version"[[:space:]]*:/ {print $4; exit}' "$ROOT/forge-plugin.json")"
PROTOCOL_VERSION="$(awk -F'"' '/^[[:space:]]*"protocolVersion"[[:space:]]*:/ {print $4; exit}' "$ROOT/forge-plugin.json")"
[[ -n "$VERSION" && -n "$PROTOCOL_VERSION" ]] || { echo "forge-plugin.json is missing version/protocolVersion" >&2; exit 2; }
BUNDLE_ID="com.moretea.forge.desktop-operator"
LABEL="$BUNDLE_ID"
APP_NAME="Forge Desktop Operator"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_EXECUTABLE="$APP_CONTENTS/MacOS/desktop-operator"
APP_ROOT="$HOME/Library/Application Support/Forge/DesktopOperator"
RELEASE_ROOT="$APP_ROOT/releases/$VERSION"
RELEASE_BIN_DIR="$RELEASE_ROOT/bin"
REG_DIR="$APP_ROOT/registration"
RUN_DIR="$HOME/Library/Caches/Forge"
LOG_DIR="$APP_ROOT/logs"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SOCKET="$RUN_DIR/desktop-operator.sock"

LEGACY_LABEL="com.moretea.repo-harness.desktop-operator"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_SOCKET="$HOME/Library/Caches/repo-harness/desktop-operator.sock"

mkdir -p "$RELEASE_BIN_DIR" "$REG_DIR" "$RUN_DIR" "$LOG_DIR" "$HOME/Applications" "$(dirname "$PLIST")"
cd "$ROOT"
swift build -c release
install -m 755 "$ROOT/.build/release/desktop-operator" "$RELEASE_BIN_DIR/desktop-operator"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_CONTENTS/MacOS"
install -m 755 "$RELEASE_BIN_DIR/desktop-operator" "$APP_EXECUTABLE"
cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>desktop-operator</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSAppleEventsUsageDescription</key><string>Forge Desktop Operator uses Apple Events only for bounded browser automation requested through Forge.</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

SIGNING_IDENTITY="${FORGE_DESKTOP_OPERATOR_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | /usr/bin/head -n 1 || true)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | /usr/bin/head -n 1 || true)"
fi
if [[ -n "$SIGNING_IDENTITY" ]]; then
  /usr/bin/codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  SIGNING_MODE="identity:$SIGNING_IDENTITY"
else
  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
  SIGNING_MODE="ad-hoc"
  echo "WARNING: no persistent macOS code-signing identity was available; TCC consent may need to be granted again after binary updates." >&2
fi
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

install -m 644 "$ROOT/forge-plugin.json" "$REG_DIR/forge-plugin.json"
cat >"$REG_DIR/registration.json" <<JSON
{
  "schemaVersion": 1,
  "pluginId": "desktop_operator",
  "scope": "controller",
  "pluginVersion": "$VERSION",
  "protocolVersion": "$PROTOCOL_VERSION",
  "transport": "unix-socket-jsonl",
  "socketPath": "$SOCKET",
  "executablePath": "$APP_EXECUTABLE",
  "manifestPath": "$REG_DIR/forge-plugin.json",
  "serviceManager": "launchd-user-agent",
  "bundleIdentifier": "$BUNDLE_ID",
  "launchAgentLabel": "$LABEL",
  "expectedProgramContains": "$APP_NAME.app"
}
JSON

cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>-i</string>
    <string>HOME=$HOME</string>
    <string>PATH=/usr/bin:/bin:/usr/sbin:/sbin</string>
    <string>LANG=en_US.UTF-8</string>
    <string>TMPDIR=/tmp</string>
    <string>$APP_EXECUTABLE</string>
    <string>serve</string>
    <string>--socket</string>
    <string>$SOCKET</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG_DIR/stdout.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
PLIST

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootout "$DOMAIN/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$LEGACY_PLIST" "$LEGACY_SOCKET" "$LEGACY_SOCKET.lock"
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"

READY=0
for ((attempt=0; attempt<100; attempt++)); do
  if "$APP_EXECUTABLE" request --socket "$SOCKET" --method health --id install-readiness >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.05
done
if [[ "$READY" != "1" ]]; then
  echo "desktop_operator did not become ready on $SOCKET after launchctl bootstrap" >&2
  launchctl print "$DOMAIN/$LABEL" >&2 || true
  tail -40 "$LOG_DIR/stderr.log" >&2 || true
  exit 1
fi

echo "Installed desktop_operator"
echo "App: $APP_BUNDLE"
echo "Bundle ID: $BUNDLE_ID"
echo "Signing: $SIGNING_MODE"
echo "Registration: $REG_DIR/registration.json"
echo "Socket: $SOCKET"
echo "Grant Accessibility and Screen Recording once to: $APP_BUNDLE"
