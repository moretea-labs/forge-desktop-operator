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
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/desktop-operator"
APP_ROOT="$HOME/Library/Application Support/Forge/DesktopOperator"
STAGE_DIR="$APP_ROOT/.install-stage-$VERSION-$$"
STAGED_APP="$STAGE_DIR/$APP_NAME.app"
APP_CONTENTS="$STAGED_APP/Contents"
STAGED_EXECUTABLE="$APP_CONTENTS/MacOS/desktop-operator"
BACKUP_ROOT="$APP_ROOT/backups/pre-$VERSION-$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_APP="$BACKUP_ROOT/$APP_NAME.app"
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$LABEL"
LOCK_DIR="$APP_ROOT/.install-lock"
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

mkdir -p "$RELEASE_BIN_DIR" "$REG_DIR" "$RUN_DIR" "$LOG_DIR" "$HOME/Applications" "$(dirname "$PLIST")" "$STAGE_DIR"
cd "$ROOT"
swift build -c release
install -m 755 "$ROOT/.build/release/desktop-operator" "$RELEASE_BIN_DIR/desktop-operator"

mkdir -p "$APP_CONTENTS/MacOS"
install -m 755 "$RELEASE_BIN_DIR/desktop-operator" "$STAGED_EXECUTABLE"
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
  /usr/bin/codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$STAGED_APP"
  SIGNING_MODE="identity:$SIGNING_IDENTITY"
else
  /usr/bin/codesign --force --deep --sign - "$STAGED_APP"
  SIGNING_MODE="ad-hoc"
  echo "WARNING: no persistent macOS code-signing identity was available; TCC consent may need to be granted again after binary updates." >&2
fi
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"


# No production path has been touched yet: build, sign and verify the staged
# candidate first. An active owner label must resolve to our exact executable.
[[ ! -e "$APP_BUNDLE" || -d "$APP_BUNDLE" ]] || { echo "Installed path is not an app bundle" >&2; exit 1; }
if [[ -d "$APP_BUNDLE" ]]; then
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  old_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
  [[ "$old_bundle_id" == "$BUNDLE_ID" ]] || { echo "Unrecognized installed application" >&2; exit 1; }
  old_team="$(/usr/bin/codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  new_team="$(/usr/bin/codesign -dv --verbose=2 "$STAGED_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$old_team" == "$new_team" ]] || { echo "Signing/TCC principal changed; refusing replacement" >&2; exit 1; }
fi
if launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
  echo "Legacy service is still registered; its ownership must be reconciled separately" >&2
  exit 1
fi
mkdir "$LOCK_DIR" || { echo "Install lock exists; refusing concurrent or unconfirmed install" >&2; exit 1; }

had_service=0
had_app=0
had_plist=0
had_registration=0
had_manifest=0
old_moved=0
new_installed=0
complete=0
[[ -d "$APP_BUNDLE" ]] && had_app=1

# Failure after cutover restores the previous exact bundle and metadata.
# Never move app bytes while an uncertain launchd service remains registered.
finish_install() {
  local result=$?
  trap - EXIT
  if [[ "$result" != 0 && "$complete" == 0 ]]; then
    if [[ "$new_installed" == 1 ]] && launchctl print "$TARGET" >"$STAGE_DIR/failed-service.txt" 2>&1; then
      if ! grep -Fq "$APP_EXECUTABLE" "$STAGE_DIR/failed-service.txt"; then
        echo "ROLLBACK_BLOCKED: launchd service identity changed; app preserved" >&2
        rm -rf "$STAGE_DIR"
        rmdir "$LOCK_DIR" || true
        exit "$result"
      fi
      launchctl bootout "$TARGET" || true
    fi
    if [[ "$new_installed" == 1 ]]; then
      local removed=0
      for ((i=0; i<100; i++)); do
        if ! launchctl print "$TARGET" >/dev/null 2>&1; then removed=1; break; fi
        sleep 0.1
      done
      if [[ "$removed" != 1 ]]; then
        echo "ROLLBACK_INCOMPLETE: candidate service still registered; app preserved" >&2
        rm -rf "$STAGE_DIR"
        rmdir "$LOCK_DIR" || true
        exit "$result"
      fi
      mv "$APP_BUNDLE" "$BACKUP_ROOT/failed-candidate.app"
    fi
    if [[ "$old_moved" == 1 ]]; then mv "$BACKUP_APP" "$APP_BUNDLE"; fi
    if [[ "$had_plist" == 1 ]]; then cp "$BACKUP_ROOT/original.plist" "$PLIST"; else rm -f "$PLIST"; fi
    if [[ "$had_registration" == 1 ]]; then cp "$BACKUP_ROOT/registration.json" "$REG_DIR/registration.json"; else rm -f "$REG_DIR/registration.json"; fi
    if [[ "$had_manifest" == 1 ]]; then cp "$BACKUP_ROOT/forge-plugin.json" "$REG_DIR/forge-plugin.json"; else rm -f "$REG_DIR/forge-plugin.json"; fi
    if [[ "$had_service" == 1 ]] && ! launchctl print "$TARGET" >/dev/null 2>&1; then
      launchctl bootstrap "$DOMAIN" "$PLIST" || echo "ROLLBACK_RECOVERY_REQUIRED: previous launchd bootstrap failed" >&2
    fi
  fi
  rm -rf "$STAGE_DIR"
  rmdir "$LOCK_DIR" || true
  exit "$result"
}
trap finish_install EXIT

if launchctl print "$TARGET" >"$STAGE_DIR/launchd-before.txt" 2>&1; then
  grep -Fq "$APP_EXECUTABLE" "$STAGE_DIR/launchd-before.txt" || {
    echo "LaunchAgent executable identity mismatch; refusing bootout" >&2
    exit 1
  }
  had_service=1
  [[ "$had_app" == 1 ]] || { echo "Active service has no installed application" >&2; exit 1; }
fi
mkdir -p "$BACKUP_ROOT"
if [[ -f "$PLIST" ]]; then cp -p "$PLIST" "$BACKUP_ROOT/original.plist"; had_plist=1; fi
if [[ -f "$REG_DIR/registration.json" ]]; then cp -p "$REG_DIR/registration.json" "$BACKUP_ROOT/registration.json"; had_registration=1; fi
if [[ -f "$REG_DIR/forge-plugin.json" ]]; then cp -p "$REG_DIR/forge-plugin.json" "$BACKUP_ROOT/forge-plugin.json"; had_manifest=1; fi

# One bootout; reconcile the actual exact label rather than retrying an effect
# whose outcome is unknown. On failure, the old bundle remains intact.
if [[ "$had_service" == 1 ]]; then
  launchctl bootout "$TARGET" || true
  stopped=0
  for ((attempt=0; attempt<100; attempt++)); do
    if ! launchctl print "$TARGET" >/dev/null 2>&1; then stopped=1; break; fi
    sleep 0.1
  done
  [[ "$stopped" == 1 ]] || { echo "Original launchd service remains registered; app untouched" >&2; exit 1; }
fi

if [[ "$had_app" == 1 ]]; then mv "$APP_BUNDLE" "$BACKUP_APP"; old_moved=1; fi
mv "$STAGED_APP" "$APP_BUNDLE"
new_installed=1
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

launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$TARGET"
READY=0
for ((attempt=0; attempt<100; attempt++)); do
  if "$APP_EXECUTABLE" request --socket "$SOCKET" --method health --id install-readiness >/dev/null 2>&1; then READY=1; break; fi
  sleep 0.05
done
[[ "$READY" == 1 ]] || { echo "New service failed readiness; restoring old version" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")" == "$VERSION" ]]
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
complete=1
echo "Installed desktop_operator $VERSION"
echo "App: $APP_BUNDLE"
echo "Signing: $SIGNING_MODE"
echo "Backup: $BACKUP_ROOT"
echo "Socket: $SOCKET"
