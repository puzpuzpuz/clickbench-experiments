#!/usr/bin/env bash
#
# Scenario 1 — "Parquet Tiling Competition".
#
# Runs the vanilla (upstream, fresh-process-per-query) benchmark and then,
# for engines that have a keep-alive overlay in ./modified/, the modified
# (one resident process kept alive via lib/fifo-repl.sh) benchmark. Results
# land in results/{original,modified}/<engine>.<machine>.json in the exact
# schema the ClickBench dashboard consumes.
#
# Only process persistence differs between the two; timing is still the
# engine's own internal number, exactly as upstream records it.
#
# Usage:
#   ./run.sh                       # all scenario-1 engines
#   ./run.sh duckdb-parquet        # just one
#   PHASES="modified" ./run.sh duckdb-parquet   # only the modified pass
#
# Env:
#   CLICKBENCH_DIR  pinned ClickBench checkout (default ../clickbench, see setup.sh)
#   MACHINE         label for the result file + dashboard (default ryzen9-7900)
#   PHASES          which passes to run: "original modified" (default both)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
CB="${CLICKBENCH_DIR:-$repo/clickbench}"
MACHINE="${MACHINE:-ryzen9-7900}"
DATE="$(date -u +%Y-%m-%d)"
PHASES="${PHASES:-original modified}"

ALL_ENGINES=(duckdb-parquet clickhouse-parquet datafusion hyper-parquet polars)
ENGINES=("$@"); [ "$#" -eq 0 ] && ENGINES=("${ALL_ENGINES[@]}")

[ -d "$CB/.git" ] || { echo "ClickBench checkout not found at $CB; run ./setup.sh first." >&2; exit 1; }

# Skip the 600s concurrent-QPS probe everywhere — it's irrelevant to the
# hot-run thesis and just burns ~10 min per run.
export BENCH_CONCURRENT_DURATION=0

apply_overlay() {
    local engine="$1"
    cp "$here/../lib/fifo-repl.sh" "$here/../lib/repl-engine.py" "$CB/lib/"
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
    local engine="$1" phase="$2"
    local outdir="$here/results/$phase"
    local log; log="$(mktemp)"
    local rc=0
    mkdir -p "$outdir"

    echo ">>> [$phase] $engine"
    if [ "$phase" = "modified" ]; then apply_overlay "$engine"; fi

    if ( cd "$CB/$engine" && ./benchmark.sh ) 2>&1 | tee "$log"; then
        python3 "$here/../lib/log-to-json.py" "$CB/$engine/template.json" \
            "$MACHINE" "$DATE" < "$log" > "$outdir/$engine.$MACHINE.json"
        echo "    wrote $outdir/$engine.$MACHINE.json"
    else
        echo "    !! benchmark.sh failed for [$phase] $engine; log kept at $log" >&2
        rc=1
    fi

    # Always restore the checkout to pristine, success or failure.
    if [ "$phase" = "modified" ]; then reset_overlay "$engine"; fi
    [ "$rc" -eq 0 ] && rm -f "$log"
    return "$rc"
}

for engine in "${ENGINES[@]}"; do
    for phase in $PHASES; do
        if [ "$phase" = "modified" ] && [ ! -d "$here/modified/$engine" ]; then
            # Already persistent upstream (e.g. polars) — unchanged by the tweak.
            # Copy its original result into the modified group so the group is
            # self-contained for scoring.
            echo ">>> [modified] $engine — already persistent upstream; reusing original result"
            mkdir -p "$here/results/modified"
            cp "$here/results/original/$engine."*.json "$here/results/modified/" 2>/dev/null || \
                echo "    (no original result yet; run the original phase first)"
            continue
        fi
        run_phase "$engine" "$phase"
    done
done

echo "Done. Results under $here/results/{original,modified}/"
