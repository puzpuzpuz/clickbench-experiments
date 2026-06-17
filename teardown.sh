#!/usr/bin/env bash
#
# teardown.sh — stop and uninstall every benchmark database, and delete all
# downloaded datasets and database directories, returning the box to a clean
# state. Safe to run repeatedly.
#
# With the default rootless ClickHouse/CrateDB, everything lives inside the
# ClickBench checkout (binaries, data, configs) and is removed by `git clean`,
# so no sudo is needed. The system-level removals below only fire if a *vanilla*
# (system-installed) ClickHouse/CrateDB is actually present — otherwise they're
# skipped, so this stays sudo-free for rootless runs.
#
# What it does:
#   1. Stops resident keep-alive sessions and all daemons (rootless + vanilla).
#   2. Uninstalls system-level databases IF present:
#        - ClickHouse  (only if /usr/bin/clickhouse or /var/lib/clickhouse exists)
#        - CrateDB     (only if the apt package is installed)
#        - DuckDB      (~/.duckdb always; /usr/local/bin/duckdb symlink if present)
#        - QuestDB     (~/.questdb data + config; user-owned, no sudo)
#   3. `git clean -xfd`s the checkout: datasets, hits.db, ch-data/crate-data,
#      the local clickhouse + crate binaries, venvs, FIFO plumbing.
#
# Leaves your results/ and the Rust toolchain (~/.cargo, ~/.rustup) untouched.
#
# Usage:
#   ./teardown.sh              # full teardown (asks for confirmation)
#   ./teardown.sh --dry-run    # print what would happen, change nothing
#   ./teardown.sh --yes        # skip the confirmation prompt
#   ./teardown.sh --nuke       # also rm -rf ./clickbench + /tmp validation artifacts
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

ch_system_installed() { [ -e /usr/bin/clickhouse ] || [ -d /var/lib/clickhouse ]; }
crate_pkg_installed() { dpkg -l crate >/dev/null 2>&1; }

if [ "$DRY" = no ] && [ "$YES" = no ]; then
    cat <<EOF
This will STOP and UNINSTALL all benchmark databases and DELETE all downloaded
datasets and database directories. With rootless ClickHouse/CrateDB this needs
no sudo; system-level removals only run if a vanilla install is present:
$(ch_system_installed && echo "    - ClickHouse system install DETECTED (will sudo-remove)" || echo "    - no ClickHouse system install")
$(crate_pkg_installed && echo "    - CrateDB apt package DETECTED (will sudo-purge)" || echo "    - no CrateDB apt package")
Plus: ~/.questdb, ~/.duckdb, and a 'git clean -xfd' inside $CB.
Your results in this repo are left untouched.
EOF
    if [ ! -t 0 ]; then echo "Non-interactive shell; re-run with --yes to proceed." >&2; exit 1; fi
    read -r -p "Proceed? type 'yes': " ans
    [ "$ans" = "yes" ] || { echo "aborted."; exit 1; }
fi

[ "$DRY" = yes ] && echo "(dry run — nothing will be changed)"

# 1. Stop resident sessions + daemons (rootless + vanilla) --------------------
step "Stopping resident keep-alive sessions and daemons"
act "pkill -f 'lib/repl-engine.py'  2>/dev/null"
act "pkill -f 'sleep 2147483647'    2>/dev/null"   # our FIFO holder
act "pkill -f 'duckdb .*hits.db'    2>/dev/null"
act "pkill -f 'clickhouse local'    2>/dev/null"
act "pkill -f 'clickhouse server'   2>/dev/null"   # rootless ClickHouse
act "pkill -f 'crate-server'        2>/dev/null"   # rootless CrateDB
act "pkill -f 'io.questdb'          2>/dev/null"   # QuestDB JVM
act "pkill -f 'polars.*server.py'   2>/dev/null"
ch_system_installed   && act "sudo clickhouse stop      2>/dev/null"
crate_pkg_installed   && act "sudo systemctl stop crate 2>/dev/null"

# 2. Uninstall system-level databases (only what's actually present) ----------
if ch_system_installed; then
    step "Uninstalling ClickHouse (system install)"
    act "sudo rm -rf /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client /etc/init.d/clickhouse-server /etc/cron.d/clickhouse-server"
    act "sudo bash -c 'rm -f /usr/bin/clickhouse*'"
    act "sudo userdel clickhouse 2>/dev/null; sudo groupdel clickhouse 2>/dev/null"
else
    step "ClickHouse: no system install (rootless) — its binary/data are in the checkout"
fi

step "Uninstalling QuestDB (data + config in ~/.questdb)"
act "rm -rf \"\$HOME/.questdb\""

step "Uninstalling DuckDB CLI"
act "rm -rf \"\$HOME/.duckdb\""
[ -e /usr/local/bin/duckdb ] && act "sudo rm -f /usr/local/bin/duckdb"

if crate_pkg_installed; then
    step "Uninstalling CrateDB (apt package + data + repo)"
    act "sudo apt-get purge -y crate 2>/dev/null"
    act "sudo rm -rf /var/lib/crate /etc/crate /var/log/crate"
    act "sudo rm -f /etc/apt/sources.list.d/crate-stable.list /etc/apt/trusted.gpg.d/cratedb.asc"
else
    step "CrateDB: no apt package (rootless tarball) — its binary/data are in the checkout"
fi

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
    act "rm -rf /tmp/duckdb_cli_bin /tmp/clickhouse /tmp/cbvenv /tmp/toy.parquet /tmp/toy2.parquet /tmp/crate-*.tar.gz"
fi

echo
[ "$DRY" = yes ] && echo "Dry run complete — nothing was changed." || echo "Teardown complete."
