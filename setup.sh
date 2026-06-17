#!/usr/bin/env bash
#
# Fetch ClickBench from its canonical source at the pinned commit.
#
# We deliberately do NOT vendor ClickBench into this repo (it is CC BY-NC-SA
# 4.0 — see NOTICE). This clones it into ./clickbench (gitignored). Our
# overlays are applied on top of this checkout by the per-scenario run.sh.
#
# Override the destination or source:
#   CLICKBENCH_DIR=/path/to/checkout   ./setup.sh   # reuse an existing clone
#   CLICKBENCH_REPO=git@github.com:... ./setup.sh   # e.g. a fork
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pin="$(tr -d '[:space:]' < "$here/CLICKBENCH_COMMIT")"
dest="${CLICKBENCH_DIR:-$here/clickbench}"
repo="${CLICKBENCH_REPO:-https://github.com/ClickHouse/ClickBench.git}"

if [ ! -d "$dest/.git" ]; then
    echo "Cloning $repo -> $dest"
    git clone "$repo" "$dest"
fi

echo "Fetching and checking out pinned commit $pin"
git -C "$dest" fetch --quiet origin
git -C "$dest" checkout --quiet "$pin"

echo
echo "ClickBench is checked out at $pin in:"
echo "  $dest"
echo
echo "Next: run a scenario, e.g."
echo "  scenario-1-parquet/run.sh duckdb-parquet"
