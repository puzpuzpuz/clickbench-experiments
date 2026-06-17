#!/usr/bin/env bash
#
# Scenario 2 — "Let Everyone Warm Up".
#
# Native storage, three passes:
#   original  vanilla, 3 tries.
#   modified  M1: keep the only fresh-process engine (DuckDB) alive. The
#             daemons (ClickHouse, QuestDB, CrateDB) are unchanged, so this
#             pass only re-runs engines that actually have a keep-alive overlay.
#   warmup    M2: 10 tries for ALL engines so JIT engines (JVM-based QuestDB,
#             CrateDB) reach steady state; DuckDB stays kept-alive. The hot
#             score is collapsed to the best warm run (--collapse-hot).
#             (A 100M-row scan blows past HotSpot's C2 threshold in a try or
#             two, so 10 is plenty; override with WARMUP_TRIES.)
#
# Results -> results/{original,modified,warmup}/<engine>.<machine>.json.
#
# Usage:
#   ./run.sh                                  # all engines, all passes
#   ./run.sh duckdb                           # one engine, all passes
#   PASSES="warmup" ./run.sh questdb          # one engine, one pass
#
# Env: CLICKBENCH_DIR, MACHINE (default ryzen9-7900), PASSES, WARMUP_TRIES (30).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
CB="${CLICKBENCH_DIR:-$repo/clickbench}"
MACHINE="${MACHINE:-ryzen9-7900}"
DATE="$(date -u +%Y-%m-%d)"
PASSES="${PASSES:-original modified warmup}"
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

has_overlay() { [ -d "$here/modified/$1" ]; }

apply_overlay() {
    local engine="$1"
    cp "$here/../lib/fifo-repl.sh" "$here/../lib/repl-engine.py" "$CB/lib/" 2>/dev/null || true
    cp "$here/modified/$engine/"* "$CB/$engine/"
    chmod +x "$CB/$engine/"{install,start,stop,check,query,load} 2>/dev/null || true
}

reset_overlay() {
    local engine="$1"
    git -C "$CB" checkout --quiet -- "$engine" lib 2>/dev/null || true
    rm -f "$CB/lib/fifo-repl.sh" "$CB/lib/repl-engine.py" \
          "$CB/$engine/repl.env" "$CB/$engine/".cb_* 2>/dev/null || true
}

run_phase() {
    local engine="$1" pass="$2"
    local outdir="$here/results/$pass"
    local log; log="$(mktemp)"
    local rc=0 tries=3 collapse=()
    mkdir -p "$outdir"

    local overlay=no
    case "$pass" in
        original) ;;
        modified) has_overlay "$engine" && overlay=yes ;;
        warmup)   has_overlay "$engine" && overlay=yes; tries="$WARMUP_TRIES"; collapse=(--collapse-hot) ;;
    esac

    echo ">>> [$pass] $engine (tries=$tries, overlay=$overlay)"
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
    [ "$rc" -eq 0 ] && rm -f "$log"
    return "$rc"
}

for engine in "${ENGINES[@]}"; do
    for pass in $PASSES; do
        if [ "$pass" = "modified" ] && ! has_overlay "$engine"; then
            # Daemon, unchanged by the keep-alive tweak — reuse its original
            # result so the modified group is self-contained for scoring.
            echo ">>> [modified] $engine — daemon, unchanged from original; reusing original result"
            mkdir -p "$here/results/modified"
            cp "$here/results/original/$engine."*.json "$here/results/modified/" 2>/dev/null || \
                echo "    (no original result yet; run the original pass first)"
            continue
        fi
        run_phase "$engine" "$pass"
    done
done

echo "Done. Results under $here/results/{original,modified,warmup}/"
echo "Tip: score a group with  ../lib/score.py results/original/*.json"
