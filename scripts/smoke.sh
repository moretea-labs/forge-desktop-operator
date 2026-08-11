#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/desktop-operator-smoke.XXXXXX")"
SOCKET="$TEMP_ROOT/operator.sock"
export REPO_HARNESS_DESKTOP_OPERATOR_HOME="$TEMP_ROOT/home"
cleanup() {
  if [[ -n "${PID:-}" ]]; then kill "$PID" 2>/dev/null || true; fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT
cd "$ROOT"
swift build >/dev/null
"$ROOT/.build/debug/desktop-operator" serve --socket "$SOCKET" >"$TEMP_ROOT/service.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
  [[ -S "$SOCKET" ]] && break
  sleep 0.05
done
[[ -S "$SOCKET" ]] || { cat "$TEMP_ROOT/service.log"; exit 1; }
RESPONSE="$("$ROOT/.build/debug/desktop-operator" request --socket "$SOCKET" --method handshake)"
printf '%s\n' "$RESPONSE" | grep -q '"ok":true'
printf '%s\n' "$RESPONSE" | grep -q '"pluginId":"desktop_operator"'
"$ROOT/.build/debug/desktop-operator" request --socket "$SOCKET" --method shutdown >/dev/null
wait "$PID"
echo "desktop-operator smoke passed"
