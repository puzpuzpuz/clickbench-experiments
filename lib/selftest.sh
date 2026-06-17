#!/bin/bash
#
# selftest.sh — validate the fifo-repl.sh transport against a mock CLI.
#
# This exercises the request/response framing, the sentinel-marker delimiting,
# the byte-offset log slicing, and engine-reported timing extraction — without
# needing duckdb/clickhouse/etc. installed. It does NOT validate any real
# engine's output buffering; that is confirmed on a real run.
set -e

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/fifo-repl.sh"

work="$(mktemp -d)"
trap 'cd /; repl_stop 2>/dev/null || true; rm -rf "$work"' EXIT
cd "$work"

REPL_NAME="mock"
REPL_CMD="python3 '$here/mock-repl'"
REPL_INIT_CMDS=$'.timer on'
REPL_SENTINEL_EMIT='.print %s'
REPL_PROBE_SQL='SELECT 1;'
REPL_QUIT='.quit'
repl_parse_timing() { awk '/^Run Time/ { print $5 }'; }
repl_result_filter() { grep -v '^Run Time ' | grep -v '^CBDONE_'; }

fail() { echo "SELFTEST FAIL: $*" >&2; exit 1; }

echo "[selftest] starting resident mock session..."
repl_start || fail "repl_start did not become ready"
repl_is_up || fail "repl_is_up false after start"

echo "[selftest] running 3 queries through the SAME resident process..."
pid_before="$(cat .cb_pid)"
for i in 1 2 3; do
    out="$(repl_query "SELECT count(*) FROM hits WHERE i=$i;" 2>/tmp/cb_timing.$$)"
    timing="$(cat /tmp/cb_timing.$$)"
    rm -f /tmp/cb_timing.$$
    echo "    try $i: timing='$timing' result='$out'"
    [ "$timing" = "0.042" ] || fail "expected timing 0.042, got '$timing'"
    printf '%s' "$out" | grep -q 'fake_result_for' || fail "result missing"
    printf '%s' "$out" | grep -q 'Run Time' && fail "timing leaked into result"
    printf '%s' "$out" | grep -q 'CBDONE_' && fail "marker leaked into result"
done
pid_after="$(cat .cb_pid)"
[ "$pid_before" = "$pid_after" ] || fail "process was not kept alive (pid changed)"
echo "[selftest] process pid $pid_after unchanged across all 3 queries (kept alive) ✓"

echo "[selftest] checking probe + clean stop..."
repl_probe || fail "probe failed"
repl_stop
repl_is_up && fail "still up after stop"

echo "SELFTEST PASS"
