#!/bin/bash
#
# fifo-repl.sh — a long-lived "REPL left open" harness for ClickBench.
#
# ClickBench runs embedded CLIs (duckdb, clickhouse-local, datafusion-cli, ...)
# by spawning a fresh process for *every* query invocation — including the two
# "hot" runs. That throws away every process-local cache (e.g. DuckDB's
# parquet_metadata_cache, which create.sql explicitly enables but which a fresh
# process per query defeats). This harness instead launches the CLI ONCE,
# keeps it alive reading queries from a FIFO, and dispatches each query into
# that resident session — the way an engineer with their REPL open would.
#
# The recorded timing is still the engine's own internal number (DuckDB's
# `Run Time`, etc.) — exactly what upstream ClickBench records — so the ONLY
# thing that changes vs. the vanilla scripts is process persistence. Nothing
# about how the query is timed changes.
#
# A per-engine `repl.env` provides the engine specifics by setting:
#   REPL_NAME            label for diagnostics
#   REPL_CMD             shell command that launches the resident CLI; its
#                        stdin is the request FIFO, stdout+stderr -> log
#   REPL_INIT_CMDS       (optional) lines sent right after launch, e.g.
#                        ".timer on" + pragmas. One command per line.
#   REPL_SENTINEL_EMIT   printf format taking one %s (a unique marker) that,
#                        when sent to the CLI, makes the marker appear in the
#                        output stream. e.g. ".print %s" or "SELECT '%s';"
#   REPL_PROBE_SQL       (optional) a trivial query for readiness/health,
#                        default "SELECT 1;"
#   REPL_QUIT            (optional) a clean-quit command, e.g. ".quit"
#   REPL_TIMEOUT         (optional) per-query timeout seconds, default 600
# and by defining two shell functions:
#   repl_parse_timing    reads a response slice on stdin, prints fractional
#                        seconds (the query's engine-reported time) on stdout
#   repl_result_filter   (optional) reads the slice on stdin, prints the
#                        human-facing result (timing/marker lines stripped)
#
# This file is meant to be *sourced* by the per-engine start/stop/check/query/
# load scripts, so it deliberately avoids `set -e`/`set -u` (which would leak
# into and surprise the caller); required vars are guarded with `:?` instead.

_repl_paths() {
    REQ="${REPL_REQ:-.cb_req}"
    LOG="${REPL_LOG:-.cb_log}"
    PIDF="${REPL_PIDF:-.cb_pid}"
    HOLDF="${REPL_HOLDF:-.cb_hold}"
}

repl_is_up() {
    _repl_paths
    [ -f "$PIDF" ] || return 1
    local p; p="$(cat "$PIDF" 2>/dev/null || true)"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# Send raw text into the resident session. The holder process keeps a writer
# fd open on the FIFO, so each open/write/close here does not deliver EOF to
# the CLI.
repl_send() {
    _repl_paths
    printf '%s\n' "$1" > "$REQ"
}

repl_start() {
    _repl_paths
    : "${REPL_CMD:?repl.env must set REPL_CMD}"
    : "${REPL_SENTINEL_EMIT:?repl.env must set REPL_SENTINEL_EMIT}"

    if repl_is_up; then return 0; fi

    rm -f "$REQ" "$LOG" "$PIDF" "$HOLDF"
    mkfifo "$REQ"
    : > "$LOG"

    # Holder: keeps the FIFO's write end open for the lifetime of the session
    # so the CLI (the reader) never sees EOF between queries. sleep writes
    # nothing; it just pins the fd.
    ( exec sleep 2147483647 ) > "$REQ" &
    echo $! > "$HOLDF"

    # The resident CLI: stdin from the FIFO, stdout+stderr merged into LOG.
    # stdbuf nudges line buffering so per-statement output lands promptly.
    ( exec stdbuf -oL -eL bash -c "$REPL_CMD" ) < "$REQ" > "$LOG" 2>&1 &
    echo $! > "$PIDF"

    if [ -n "${REPL_INIT_CMDS:-}" ]; then
        printf '%s\n' "$REPL_INIT_CMDS" > "$REQ"
    fi

    local i
    for i in $(seq 1 120); do
        if ! repl_is_up; then
            echo "repl_start: $REPL_NAME process exited during startup; log:" >&2
            sed 's/^/    /' "$LOG" >&2
            return 1
        fi
        if repl_probe; then return 0; fi
        sleep 0.5
    done
    echo "repl_start: $REPL_NAME did not become ready within 60s; log tail:" >&2
    tail -n 20 "$LOG" | sed 's/^/    /' >&2
    return 1
}

# Run one query in the resident session and emit:
#   stdout: the result (timing/marker stripped)
#   stderr (last line): the engine-reported time in fractional seconds
# Exit non-zero on timeout or if no timing could be parsed.
repl_query() {
    _repl_paths
    local sql="$1"
    local nonce="cbq_${$}_${RANDOM}${RANDOM}"
    local marker="CBDONE_${nonce}"
    local before; before="$(wc -c < "$LOG")"

    {
        printf '%s\n' "$sql"
        # shellcheck disable=SC2059
        printf "${REPL_SENTINEL_EMIT}\n" "$marker"
    } > "$REQ"

    local maxwait="${REPL_TIMEOUT:-600}"
    local deadline=$(( $(date +%s) + maxwait ))
    while :; do
        if tail -c "+$((before + 1))" "$LOG" 2>/dev/null | grep -q "$marker"; then
            break
        fi
        if ! repl_is_up; then
            echo "repl_query: $REPL_NAME process died; log tail:" >&2
            tail -n 20 "$LOG" | sed 's/^/    /' >&2
            return 1
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "repl_query: timeout (${maxwait}s) waiting for $REPL_NAME" >&2
            return 1
        fi
        sleep 0.05
    done

    # Response slice: everything appended since `before`, up to and including
    # the marker line. The query's timing line is emitted before the marker;
    # the sentinel's own timing (if any) is after it and thus excluded.
    local slice
    slice="$(tail -c "+$((before + 1))" "$LOG" | sed "/$marker/q")"

    local timing
    timing="$(printf '%s\n' "$slice" | repl_parse_timing | tail -n 1)"

    if declare -F repl_result_filter >/dev/null 2>&1; then
        printf '%s\n' "$slice" | repl_result_filter
    else
        printf '%s\n' "$slice" | grep -v "$marker"
    fi

    if [ -z "$timing" ]; then
        echo "repl_query: could not parse a timing for $REPL_NAME" >&2
        return 1
    fi
    printf '%s\n' "$timing" >&2
}

# Readiness/health: a probe query that round-trips and yields a numeric time.
repl_probe() {
    local t
    t="$(repl_query "${REPL_PROBE_SQL:-SELECT 1;}" 2>&1 1>/dev/null)" || return 1
    printf '%s' "$t" | grep -qE '[0-9]'
}

repl_stop() {
    _repl_paths
    if [ -f "$PIDF" ]; then
        local p; p="$(cat "$PIDF" 2>/dev/null || true)"
        if [ -n "${REPL_QUIT:-}" ] && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            repl_send "$REPL_QUIT" 2>/dev/null || true
            local i
            for i in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$p" 2>/dev/null || break
                sleep 0.3
            done
        fi
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    fi
    if [ -f "$HOLDF" ]; then
        kill "$(cat "$HOLDF" 2>/dev/null)" 2>/dev/null || true
    fi
    rm -f "$REQ" "$LOG" "$PIDF" "$HOLDF"
}
