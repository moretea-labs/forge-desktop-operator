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
STAGE_DIR="$HOME/Library/Application Support/Forge/DesktopOperator/.staging-$VERSION-$$"
STAGED_APP="$STAGE_DIR/$APP_NAME.app"
APP_CONTENTS="$STAGED_APP/Contents"
STAGED_EXECUTABLE="$APP_CONTENTS/MacOS/desktop-operator"
BACKUP_DIR="$HOME/Library/Application Support/Forge/DesktopOperator/backups/pre-$VERSION-$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_APP="$BACKUP_DIR/$APP_NAME.app"
INSTALL_LOCK="$HOME/Library/Application Support/Forge/DesktopOperator/.install-lock"
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

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo "Refusing uncommitted Desktop Operator source in production installer" >&2; exit 1; }
fi
mkdir -p "$RELEASE_BIN_DIR" "$REG_DIR" "$RUN_DIR" "$LOG_DIR" "$HOME/Applications" "$(dirname "$PLIST")" "$STAGE_DIR"
# Preflight failures must not leave abandoned signed candidates on disk.
# The transaction's full rollback trap replaces this after identity checks.
trap 'rm -rf "$STAGE_DIR"' EXIT
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


# Fail closed before changing the installed app or launchd. The candidate is
# fully built and signed in a private stage at this point.
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$LABEL"
if launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
  echo "Legacy LaunchAgent remains registered; reconcile its owner first" >&2
  exit 1
fi
if [[ -d "$APP_BUNDLE" ]]; then
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")" == "$BUNDLE_ID" ]] || { echo "Installed app identity mismatch" >&2; exit 1; }
  old_team="$(/usr/bin/codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  new_team="$(/usr/bin/codesign -dv --verbose=2 "$STAGED_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$old_team" == "$new_team" ]] || { echo "Refusing signed TCC identity change" >&2; exit 1; }
fi
lock_acquired=0
had_app=0
had_agent=0
had_plist=0
had_registration=0
had_manifest=0
old_bootout_attempted=0
old_pid=""
old_app_moved=0
new_app_installed=0
install_completed=0
[[ -d "$APP_BUNDLE" ]] && had_app=1

service_registered() { launchctl print "$TARGET" >/dev/null 2>&1; }
wait_service_gone() {
  local n
  for ((n=0;n<100;n++)); do
    if ! service_registered; then return 0; fi
    sleep 0.1
  done
  return 1
}
# A launchd label disappearing does not prove its previous worker has exited.
# Use one bounded observation of the attested PID and never signal an unknown PID.
wait_pid_exit() {
  local pid="$1"
  local attempt
  [[ -n "$pid" ]] || return 0
  for ((attempt=0; attempt<100; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
rollback_install() {
  local code=$?
  trap - EXIT
  # Deliberately retain install lock if service state is not proven.
  # Clearing it would permit concurrent duplicate provider installation.
  require_recovery() {
    local reason="$1"
    printf 'release=%s\nreason=%s\nbackup=%s\nstage=%s\n' \
      "$VERSION" "$reason" "$BACKUP_DIR" "$STAGE_DIR" \
      >"$INSTALL_LOCK/RECOVERY_REQUIRED" || true
    echo "RECOVERY_LOCK_RETAINED: $INSTALL_LOCK (reason=$reason)" >&2
    exit "$code"
  }
  if [[ "$code" -ne 0 && "$install_completed" -eq 0 ]]; then
    if [[ "$new_app_installed" -eq 1 ]]; then
      failed_pid=""
      if service_registered; then
        launchctl print "$TARGET" >"$STAGE_DIR/failed-service.txt"
        if ! grep -Fq "$APP_EXECUTABLE" "$STAGE_DIR/failed-service.txt"; then
          echo "ROLLBACK_BLOCKED: another service owns the label; preserve backup" >&2
          require_recovery "service_owner_changed"
        fi
        failed_pid="$(sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' "$STAGE_DIR/failed-service.txt" | head -n 1)"
        launchctl bootout "$TARGET" || true
      fi
      if ! wait_service_gone; then
        echo "ROLLBACK_BLOCKED: new service still registered; preserve backup" >&2
        require_recovery "candidate_launchd_still_registered"
      fi
      if ! wait_pid_exit "$failed_pid"; then
        echo "ROLLBACK_BLOCKED: candidate PID still running after bounded shutdown; preserve backup" >&2
        require_recovery "candidate_process_not_exited"
      fi
      mv "$APP_BUNDLE" "$BACKUP_DIR/failed-candidate.app"
    fi
    if [[ "$old_app_moved" -eq 1 ]]; then mv "$BACKUP_APP" "$APP_BUNDLE"; fi
    if [[ "$old_bootout_attempted" -eq 1 || "$new_app_installed" -eq 1 ]]; then
      if [[ "$had_plist" -eq 1 ]]; then cp -p "$BACKUP_DIR/original.plist" "$PLIST"; else rm -f "$PLIST"; fi
      if [[ "$had_registration" -eq 1 ]]; then cp -p "$BACKUP_DIR/registration.json" "$REG_DIR/registration.json"; else rm -f "$REG_DIR/registration.json"; fi
      if [[ "$had_manifest" -eq 1 ]]; then cp -p "$BACKUP_DIR/forge-plugin.json" "$REG_DIR/forge-plugin.json"; else rm -f "$REG_DIR/forge-plugin.json"; fi
      if [[ "$had_agent" -eq 1 ]] && ! service_registered; then
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
          echo "ROLLBACK_RECOVERY_REQUIRED: original PID is still running" >&2
          require_recovery "old_process_not_exited"
        fi
        if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
          echo "ROLLBACK_RECOVERY_REQUIRED: old service could not bootstrap" >&2
          require_recovery "old_launchd_bootstrap_failed"
        fi
      fi
      if [[ "$had_agent" -eq 1 ]]; then
        old_ready=0
        for ((check=0; check<100; check++)); do
          if "$APP_EXECUTABLE" request --socket "$SOCKET" --method health --id rollback-readiness >/dev/null 2>&1; then
            old_ready=1
            break
          fi
          sleep 0.05
        done
        if [[ "$old_ready" -ne 1 ]]; then
          echo "ROLLBACK_RECOVERY_REQUIRED: restored old service failed real health; retaining backup and install lock" >&2
          require_recovery "old_service_health_unproven"
        fi
      fi
    fi
  fi
  rm -rf "$STAGE_DIR"
  if [[ "$lock_acquired" -eq 1 ]]; then rmdir "$INSTALL_LOCK"; fi
  exit "$code"
}

trap rollback_install EXIT
if ! mkdir "$INSTALL_LOCK"; then
  echo "Another installation or unresolved recovery owns the install lock" >&2
  exit 1
fi
lock_acquired=1
mkdir -p "$BACKUP_DIR"
if service_registered; then
  launchctl print "$TARGET" >"$STAGE_DIR/old-service.txt"
  grep -Fq "$APP_EXECUTABLE" "$STAGE_DIR/old-service.txt" || { echo "Installed service executable mismatch" >&2; exit 1; }
  old_pid="$(sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' "$STAGE_DIR/old-service.txt" | head -n 1)"
  had_agent=1
fi
if [[ -f "$PLIST" ]]; then cp -p "$PLIST" "$BACKUP_DIR/original.plist"; had_plist=1; fi
if [[ -f "$REG_DIR/registration.json" ]]; then cp -p "$REG_DIR/registration.json" "$BACKUP_DIR/registration.json"; had_registration=1; fi
if [[ -f "$REG_DIR/forge-plugin.json" ]]; then cp -p "$REG_DIR/forge-plugin.json" "$BACKUP_DIR/forge-plugin.json"; had_manifest=1; fi

# Never replay an uncertain bootout. The old .app is untouched until the
# exact label is absent; unknown registration leaves install fail-closed.
if [[ "$had_agent" -eq 1 ]]; then
  old_bootout_attempted=1
  launchctl bootout "$TARGET" || true
  wait_service_gone || { echo "Old service still registered; installed app unchanged" >&2; exit 1; }
  wait_pid_exit "$old_pid" || { echo "Old provider PID remains alive; installed app unchanged" >&2; exit 1; }
fi
if [[ "$had_app" -eq 1 ]]; then
  mv "$APP_BUNDLE" "$BACKUP_APP"
  old_app_moved=1
fi
mv "$STAGED_APP" "$APP_BUNDLE"
new_app_installed=1

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
  if "$APP_EXECUTABLE" request --socket "$SOCKET" --method health --id install-readiness >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.05
done
if [[ "$READY" != "1" ]]; then
  echo "desktop_operator did not become ready; recovering signed previous app" >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")" == "$VERSION" ]]
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
launchctl print "$TARGET" >"$STAGE_DIR/installed-service.txt"
grep -Fq "$APP_EXECUTABLE" "$STAGE_DIR/installed-service.txt" || { echo "Installed service identity mismatch" >&2; exit 1; }
install_completed=1

echo "Installed desktop_operator"
echo "App: $APP_BUNDLE"
echo "Bundle ID: $BUNDLE_ID"
echo "Signing: $SIGNING_MODE"
echo "Backup: $BACKUP_DIR"
echo "Registration: $REG_DIR/registration.json"
echo "Socket: $SOCKET"
