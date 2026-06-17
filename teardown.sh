#!/usr/bin/env bash
#
# teardown.sh — stop and uninstall every benchmark database, and delete all
# downloaded datasets and database directories, returning the box to a clean
# state. Safe to run repeatedly.
#
# What it does:
#   1. Stops resident keep-alive sessions and all daemons.
#   2. Uninstalls the system-level databases:
#        - ClickHouse  (sudo clickhouse stop; /var/lib/clickhouse, /etc/clickhouse-*,
#                       /usr/bin/clickhouse*, logs, the clickhouse user)
#        - QuestDB     (~/.questdb data + config)
#        - DuckDB      (~/.duckdb, /usr/local/bin/duckdb)
#        - CrateDB     (apt purge crate; /var/lib/crate, /etc/crate; apt repo + key)
#   3. Cleans the ClickBench checkout: `git clean -xfd` wipes every untracked
#      artifact inside it — datasets (hits.parquet/csv/tsv, partitioned files),
#      hits.db, the local ./clickhouse binary, arrow-datafusion, the questdb/
#      dir, all myenv/ venvs, and our .cb_* FIFO plumbing — and resets overlays.
#
# It does NOT touch your results in this repo (scenario-*/results/), nor the
# Rust toolchain (~/.cargo, ~/.rustup) — remove those by hand if you want.
#
# Usage:
#   ./teardown.sh              # full teardown (asks for confirmation)
#   ./teardown.sh --dry-run    # print what would happen, change nothing
#   ./teardown.sh --yes        # skip the confirmation prompt
#   ./teardown.sh --nuke       # also rm -rf the ./clickbench checkout and the
#                              #   /tmp validation artifacts
#
# System removals use sudo and will prompt for your password (they are not
# covered by the benchmark's NOPASSWD sudoers rule).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB="${CLICKBENCH_DIR:-$here/clickbench}"

DRY=no; YES=no; NUKE=no
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=yes ;;
        -y|--yes)  YES=yes ;;
        --nuke)    NUKE=yes ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

step() { echo; echo ">>> $1"; }
act()  { echo "    \$ $*"; [ "$DRY" = yes ] || eval "$*" || true; }

if [ "$DRY" = no ] && [ "$YES" = no ]; then
    cat <<EOF
This will STOP and UNINSTALL all benchmark databases and DELETE all downloaded
datasets and database directories, including (with sudo):
    /var/lib/clickhouse  /etc/clickhouse-*  /usr/bin/clickhouse*
    ~/.questdb  ~/.duckdb  /usr/local/bin/duckdb
    the 'crate' package + /var/lib/crate
and a 'git clean -xfd' inside $CB.
Your results in this repo are left untouched.
EOF
    if [ ! -t 0 ]; then echo "Non-interactive shell; re-run with --yes to proceed." >&2; exit 1; fi
    read -r -p "Proceed? type 'yes': " ans
    [ "$ans" = "yes" ] || { echo "aborted."; exit 1; }
fi

[ "$DRY" = yes ] && echo "(dry run — nothing will be changed)"

# 1. Stop resident sessions + daemons -----------------------------------------
step "Stopping resident keep-alive sessions and daemons"
act "pkill -f 'lib/repl-engine.py'        2>/dev/null"
act "pkill -f 'sleep 2147483647'          2>/dev/null"   # our FIFO holder
act "pkill -f 'duckdb .*hits.db'          2>/dev/null"
act "pkill -f 'clickhouse local'          2>/dev/null"
act "pkill -f 'io.questdb'                2>/dev/null"   # QuestDB JVM
act "pkill -f 'polars.*server.py'         2>/dev/null"
act "sudo clickhouse stop                 2>/dev/null"
act "sudo systemctl stop crate            2>/dev/null"

# 2. Uninstall system-level databases -----------------------------------------
step "Uninstalling ClickHouse (system install)"
act "sudo rm -rf /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client /etc/init.d/clickhouse-server /etc/cron.d/clickhouse-server"
act "sudo bash -c 'rm -f /usr/bin/clickhouse*'"
act "sudo userdel clickhouse 2>/dev/null; sudo groupdel clickhouse 2>/dev/null"

step "Uninstalling QuestDB (data + config in ~/.questdb)"
act "rm -rf \"\$HOME/.questdb\""

step "Uninstalling DuckDB CLI"
act "rm -rf \"\$HOME/.duckdb\""
act "sudo rm -f /usr/local/bin/duckdb"

step "Uninstalling CrateDB (apt package + data + repo)"
act "sudo apt-get purge -y crate 2>/dev/null"
act "sudo rm -rf /var/lib/crate /etc/crate /var/log/crate"
act "sudo rm -f /etc/apt/sources.list.d/crate-stable.list /etc/apt/trusted.gpg.d/cratedb.asc"

# 3. Clean the ClickBench checkout (datasets, DBs, venvs, binaries, plumbing) --
step "Cleaning the ClickBench checkout: $CB"
if [ -d "$CB/.git" ]; then
    act "git -C \"$CB\" checkout -- . 2>/dev/null"
    if [ "$DRY" = yes ]; then
        echo "    \$ git -C $CB clean -xnd   # (would remove:)"
        git -C "$CB" clean -xnd | sed 's/^/        /'
    else
        act "git -C \"$CB\" clean -xfd"
    fi
else
    echo "    (no checkout at $CB — nothing to clean)"
fi

# 4. Optional: remove the checkout + /tmp validation artifacts -----------------
if [ "$NUKE" = yes ]; then
    step "Nuking the checkout and /tmp validation artifacts"
    act "rm -rf \"$CB\""
    act "rm -rf /tmp/duckdb_cli_bin /tmp/clickhouse /tmp/cbvenv /tmp/toy.parquet /tmp/toy2.parquet"
fi

echo
[ "$DRY" = yes ] && echo "Dry run complete — nothing was changed." || echo "Teardown complete."
