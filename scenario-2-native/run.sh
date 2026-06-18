#!/usr/bin/env bash
#
# Scenario 2 — "Let Everyone Warm Up".
#
# Native storage, three passes in the post's narrative order — vanilla, then
# warm everyone up, then keep DuckDB resident:
#   original   vanilla, 3 tries, fresh process per query for DuckDB.
#   warmup     10 tries for ALL engines, still fresh-process for DuckDB (NO
#              keep-alive). JIT engines (JVM-based QuestDB, CrateDB) reach
#              steady state; AOT ClickHouse stays ~flat; DuckDB can't warm
#              without persistence. Hot score collapsed to the best warm run
#              (--collapse-hot). (A 100M-row scan blows past HotSpot's C2
#              threshold in a try or two, so 10 is plenty; override WARMUP_TRIES.)
#   keepalive  10 tries AND keep the only fresh-process engine (DuckDB) alive via
#              its keep-alive overlay. The daemons (ClickHouse, QuestDB, CrateDB)
#              have no overlay and are byte-identical to their `warmup` result,
#              so this pass reuses that for them and only re-runs DuckDB.
#
# Results -> results/{original,warmup,keepalive}/<engine>.<machine>.json.
#
# Usage:
#   ./run.sh                                  # all engines, all passes
#   ./run.sh duckdb                           # one engine, all passes
#   PASSES="warmup" ./run.sh duckdb           # one engine, one pass
#
# Env: CLICKBENCH_DIR, MACHINE (default ryzen9-7900), PASSES, WARMUP_TRIES (10).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
CB="${CLICKBENCH_DIR:-$repo/clickbench}"
MACHINE="${MACHINE:-ryzen9-7900}"
DATE="$(date -u +%Y-%m-%d)"
PASSES="${PASSES:-original warmup keepalive}"
WARMUP_TRIES="${WARMUP_TRIES:-10}"

ALL_ENGINES=(duckdb clickhouse questdb cratedb)
ENGINES=("$@"); [ "$#" -eq 0 ] && ENGINES=("${ALL_ENGINES[@]}")

[ -d "$CB/.git" ] || { echo "ClickBench checkout not found at $CB; run ./setup.sh first." >&2; exit 1; }
export BENCH_CONCURRENT_DURATION=0   # skip the 600s QPS probe

# Hot-run only: shim out the per-query cold-cache drop so it needs no sudo.
# Zero effect on hot scores. Set BENCH_REAL_DROP_CACHES=1 to keep real cold runs.
# (Note: native ClickHouse + CrateDB still sudo for their daemons — see README.)
if [ -z "${BENCH_REAL_DROP_CACHES:-}" ]; then
    export PATH="$here/../lib/nosudo:$PATH"
fi

has_overlay()  { [ -d "$here/keepalive/$1" ]; }   # DuckDB keep-alive overlay
has_rootless() { [ -d "$here/rootless/$1" ]; }   # ClickHouse/CrateDB user-mode (no sudo)

apply_overlay() {
    local engine="$1"
    cp "$here/../lib/fifo-repl.sh" "$here/../lib/repl-engine.py" "$CB/lib/" 2>/dev/null || true
    cp "$here/keepalive/$engine/"* "$CB/$engine/"
    chmod +x "$CB/$engine/"{install,start,stop,check,query,load} 2>/dev/null || true
}

reset_overlay() {
    local engine="$1"
    git -C "$CB" checkout --quiet -- "$engine" lib 2>/dev/null || true
    rm -f "$CB/lib/fifo-repl.sh" "$CB/lib/repl-engine.py" \
          "$CB/$engine/repl.env" "$CB/$engine/".cb_* 2>/dev/null || true
}

apply_rootless() {
    local engine="$1" f
    for f in "$here/rootless/$engine/"*; do
        cp "$f" "$CB/$engine/"
        chmod +x "$CB/$engine/$(basename "$f")"
    done
}

reset_rootless() {
    local engine="$1"
    git -C "$CB" checkout --quiet -- "$engine" 2>/dev/null || true
    # Drop the user-mode runtime state so each pass loads fresh; keep the
    # downloaded engine binary (./clickhouse, crate/) to avoid re-downloading.
    rm -rf "$CB/$engine/ch-data" "$CB/$engine/ch-tmp" "$CB/$engine/ch-logs" \
           "$CB/$engine/ch-config.yaml" "$CB/$engine/ch-users.yaml" "$CB/$engine/ch.pid" \
           "$CB/$engine/crate-data" "$CB/$engine/crate-logs" "$CB/$engine/crate.pid" 2>/dev/null || true
}

run_phase() {
    local engine="$1" pass="$2"
    local outdir="$here/results/$pass"
    local log; log="$(mktemp)"
    local rc=0 tries=3 collapse=()
    mkdir -p "$outdir"

    local overlay=no
    case "$pass" in
        original)  ;;
        warmup)    tries="$WARMUP_TRIES"; collapse=(--collapse-hot) ;;   # 10t, NO keep-alive
        keepalive) has_overlay "$engine" && overlay=yes; tries="$WARMUP_TRIES"; collapse=(--collapse-hot) ;;
    esac

    local rootless=no
    has_rootless "$engine" && rootless=yes

    echo ">>> [$pass] $engine (tries=$tries, keepalive=$overlay, rootless=$rootless)"
    [ "$rootless" = yes ] && apply_rootless "$engine"
    [ "$overlay" = yes ] && apply_overlay "$engine"

    if ( cd "$CB/$engine" && BENCH_TRIES="$tries" ./benchmark.sh ) 2>&1 | tee "$log"; then
        python3 "$here/../lib/log-to-json.py" "${collapse[@]}" "$CB/$engine/template.json" \
            "$MACHINE" "$DATE" < "$log" > "$outdir/$engine.$MACHINE.json"
        echo "    wrote $outdir/$engine.$MACHINE.json"
    else
        echo "    !! benchmark.sh failed for [$pass] $engine; log kept at $log" >&2
        rc=1
    fi

    [ "$overlay" = yes ] && reset_overlay "$engine"
    [ "$rootless" = yes ] && reset_rootless "$engine"
    [ "$rc" -eq 0 ] && rm -f "$log"
    return "$rc"
}

for engine in "${ENGINES[@]}"; do
    for pass in $PASSES; do
        if [ "$pass" = "keepalive" ] && ! has_overlay "$engine"; then
            # Daemon, no keep-alive overlay — byte-identical to its 10-try
            # `warmup` result, so reuse that (no redundant 10-try daemon run)
            # to keep the keepalive group self-contained for scoring.
            echo ">>> [keepalive] $engine — daemon, no overlay; reusing its warmup result"
            mkdir -p "$here/results/keepalive"
            cp "$here/results/warmup/$engine."*.json "$here/results/keepalive/" 2>/dev/null || \
                echo "    (no warmup result yet; run the warmup pass first)"
            continue
        fi
        run_phase "$engine" "$pass"
    done
done

echo "Done. Results under $here/results/{original,warmup,keepalive}/"
echo "Tip: score a group with  ../lib/score.py results/original/*.json"
