#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
source "$ROOT/Source/installer-support.sh"
TEST_DIR=$(mktemp -d /private/tmp/cellmori-installer-test.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
count=0
check() { if "$@"; then count=$((count+1)); else echo "FAIL: $*"; exit 1; fi; }
cm_run_bounded 1 /usr/bin/true
check test "$?" = 0
if cm_run_bounded 1 /usr/bin/false; then exit 1; else check test "$?" = 1; fi
if cm_run_bounded 1 /bin/sleep 5; then exit 1; else check test "$?" = 124; fi
check test -z "$CM_INSTALL_CHILD"
# Exercise the same handoff coordinator with isolated process/service substitutes.
cat > "$TEST_DIR/helper" <<'HELPER'
#!/bin/bash
[[ "$1" = prepare-update ]] || exit 8
printf 'prepare\n' >> "$CM_TEST_TRACE"
if [[ -f "$CM_TEST_DIR/blocked" ]]; then /bin/sleep 30; fi
[[ ! -f "$CM_TEST_DIR/fail" ]]
HELPER
chmod 755 "$TEST_DIR/helper"
export CM_TEST_DIR="$TEST_DIR" CM_TEST_TRACE="$TEST_DIR/trace"
cm_stop_service() { printf 'stop\n' >> "$CM_TEST_TRACE"; rm -f "$CM_TEST_DIR/blocked"; [[ ! -f "$CM_TEST_DIR/stop-fail" ]]; }
touch "$TEST_DIR/existing"
cm_prepare_upgrade "$TEST_DIR/helper" "$TEST_DIR/existing"
check test "$(cat "$TEST_DIR/trace")" = $'prepare\nstop\nprepare'
: > "$TEST_DIR/trace"
touch "$TEST_DIR/blocked"
cm_prepare_upgrade "$TEST_DIR/helper" "$TEST_DIR/existing"
check test "$(cat "$TEST_DIR/trace")" = $'prepare\nstop\nprepare'
touch "$TEST_DIR/fail"
if cm_prepare_upgrade "$TEST_DIR/helper" "$TEST_DIR/existing"; then exit 1; else count=$((count+1)); fi
rm "$TEST_DIR/fail"
touch "$TEST_DIR/stop-fail"
: > "$TEST_DIR/trace"
if cm_prepare_upgrade "$TEST_DIR/helper" "$TEST_DIR/existing"; then exit 1; else count=$((count+1)); fi
check test "$(cat "$TEST_DIR/trace")" = $'prepare\nstop'
/bin/bash -c 'exec 9>"$1"; /usr/bin/lockf -s -t 0 9 || exit 1; touch "$2"; exec /bin/sleep 30' bash "$TEST_DIR/install.lock" "$TEST_DIR/lock-ready" &
lock_owner=$!
for step in {1..30}; do [[ ! -f "$TEST_DIR/lock-ready" ]] || break; /bin/sleep 0.02; done
check test -f "$TEST_DIR/lock-ready"
if /usr/bin/lockf -s -k -t 0 "$TEST_DIR/install.lock" /usr/bin/true; then kill "$lock_owner"; exit 1; else count=$((count+1)); fi
kill "$lock_owner"
wait "$lock_owner" 2>/dev/null || true
/usr/bin/lockf -s -k -t 0 "$TEST_DIR/install.lock" /usr/bin/true
count=$((count+1))
echo "PASS: $count installer deadline and safe-handoff checks; isolated processes only"
