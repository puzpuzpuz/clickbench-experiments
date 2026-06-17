# clickbench-experiments

Companion repository for the QuestDB blog post **"Lies, Damn Lies and Database
Benchmarks"**. It reproduces a couple of small, *fair-but-different* tweaks to
[ClickBench](https://github.com/ClickHouse/ClickBench/) and shows how much the
overall hot-run scores move as a result — the point being that a tiny nuance
hidden in a benchmark's harness can change the ranking, so no single benchmark
number should be taken at face value.

This is **for entertainment and education**. Run it yourself; don't trust our
numbers (or anyone's) blindly.

## Attribution & license

ClickBench is the work of [Alexey Milovidov](https://github.com/alexey-milovidov)
and the ClickHouse team and is licensed **CC BY-NC-SA 4.0**. We **do not vendor
or redistribute** it here. `setup.sh` fetches it from its canonical source at a
pinned commit (see [`CLICKBENCH_COMMIT`](CLICKBENCH_COMMIT)), and our overlays
reference that checkout in place. The original tooling in this repo (the
keep-alive harness, overlays, run drivers, scorer) is Apache-2.0; see
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Always reference the original
benchmark: <https://benchmark.clickhouse.com/>.

## The one nuance everything hinges on

Every ClickBench `query` script records the engine's **own internal query
time** (DuckDB's `Run Time`, ClickHouse's `--time`, DataFusion's `Elapsed`,
QuestDB's `timings.execute`, …). **Process and client startup are not in the
recorded number.** So our tweaks change the score only through **process-local
cache warmth**, never by adding or removing a startup term. We keep the timing
method identical to upstream; the *only* thing that differs is process
persistence.

### Scenario 1 — "Parquet Tiling Competition" (`scenario-1-parquet/`)

A single `hits.parquet` queried by **DuckDB**, **ClickHouse**, **DataFusion**,
and **Hyper** — all of which ClickBench runs by spawning a fresh process for
*every* query, including the hot runs — versus **Polars**, which ClickBench
already runs as a persistent server.

**Tweak:** keep each fresh-process engine alive across the repeated runs. For
DuckDB this matters because `create.sql` enables `parquet_metadata_cache`, a
cache a fresh-process-per-query harness can never warm — ClickBench enables a
cache its own driver defeats. (Honest spoiler: **Hyper should barely move** —
its per-call `HyperProcess`/`create.sql` tax is *outside* the timed region, so
it's the experiment's control.)

### Scenario 2 — "Let Everyone Warm Up" (`scenario-2-native/`)

Native storage queried by **DuckDB**, **ClickHouse**, **QuestDB**, and
**CrateDB**, in three passes:
- `original` — vanilla, 3 tries.
- `modified` — keep DuckDB (the only fresh-process engine) alive.
- `warmup` — 10 tries for everyone so JIT engines (JVM-based QuestDB, CrateDB)
  reach steady state, with the hot score taken as the best warm run. (A
  100M-row scan passes HotSpot's C2 threshold in a try or two, so 10 is plenty;
  override with `WARMUP_TRIES`.)

## How the keep-alive is implemented

`lib/fifo-repl.sh` runs the engine as **one long-lived process reading queries
from a FIFO** ("the analyst who left their REPL/notebook open"), and each
`query` dispatches into that resident session. Two flavours:

- **DuckDB** uses its **native CLI** (`duckdb hits.db`), which behaves as a
  clean REPL over a pipe.
- **ClickHouse, DataFusion, Hyper** can't be driven that way (clickhouse-local
  batches stdin until EOF; interactive mode needs a PTY and disables `--time`;
  datafusion-cli is fragile over a pipe). So we keep the **same engine** resident
  via its embedded library — `chdb` is literally clickhouse-local as a library,
  plus `datafusion` and `tableauhyperapi` — driven by `lib/repl-engine.py`, which
  speaks the same line protocol so the harness and parser are shared. Timing is
  still each engine's internal/execute number.

This is validated end-to-end against the real engines on a tiny parquet; see
`lib/selftest.sh` (transport, no engine needed).

## Requirements

- Ubuntu 24.04+ (matches ClickBench's assumptions), `git`, `python3`, `jq`,
  `curl`, `unzip`, `bash`. Pre-installing `python3-venv gcc git` avoids the
  one-time `apt` prompts in some vanilla installers.
- **No passwordless sudo needed** for scenario 1, or for scenario-2 DuckDB and
  QuestDB. ClickBench's only per-query sudo is the cold-cache drop
  (`sudo tee /proc/sys/vm/drop_caches`); since we report hot runs only, the run
  drivers shim it out (`lib/nosudo/`) with zero effect on hot scores. Set
  `BENCH_REAL_DROP_CACHES=1` to restore real cold runs (that needs passwordless
  sudo for `tee /proc/sys/vm/drop_caches`).
- **Scenario-2 ClickHouse and CrateDB run rootless** (user-mode), so they need
  no daemon sudo: `scenario-2-native/rootless/` swaps in a clickhouse-server run
  as your user (local data dir + config, parquet read in place) and CrateDB from
  its tarball (`bin/crate`, not apt/systemctl). The vanilla per-query restart is
  preserved. Both are validated end-to-end including cross-restart persistence.
- The only remaining `sudo` is a few **one-time** install prompts: DuckDB's
  `/usr/local/bin/duckdb` symlink, CrateDB's `postgresql-client` (psql) if absent,
  and (vanilla DataFusion's) Rust/`gcc`. Pre-installing `python3-venv gcc git
  postgresql-client` and symlinking duckdb yourself avoids all of them — none are
  per-query, so passwordless sudo is never required.
- Disk: the parquet dataset is ~15 GB; QuestDB's CSV load needs ~70 GB
  uncompressed transiently. Budget ~120 GB free.
- Engines install on first run: vanilla via ClickBench's own per-engine
  `install`; the modified library engines create a local `myenv/` venv and
  `pip install chdb` / `datafusion` / `tableauhyperapi`.

## Quickstart

```bash
./setup.sh                              # clone ClickBench @ pinned commit into ./clickbench
bash lib/selftest.sh                    # validate the keep-alive harness (no engine needed)

# Scenario 1: vanilla + keep-alive (one engine, or all)
MACHINE=ryzen9-7900 scenario-1-parquet/run.sh duckdb-parquet
MACHINE=ryzen9-7900 scenario-1-parquet/run.sh

# Scenario 2: original / keep-alive / warmup passes
MACHINE=ryzen9-7900 scenario-2-native/run.sh

# See the hot-run scores re-rank (lower is better):
lib/score.py scenario-1-parquet/results/original/*.json
lib/score.py scenario-1-parquet/results/modified/*.json
```

Results are written to `scenario-*/results/{original,modified,warmup}/<engine>.<machine>.json`
in the ClickBench dashboard's schema. `lib/score.py` reproduces the dashboard's
hot-run geometric-mean metric for whatever group of result files you pass (the
per-query baseline is the best among them). To render the full interactive
dashboard instead, drop these JSONs into a ClickBench checkout's `<system>/results/`
and run its `generate-results.sh`.

`run.sh` overrides: `CLICKBENCH_DIR` (reuse an existing checkout), `MACHINE`,
`PASSES`/`PHASES`, `WARMUP_TRIES` (default 10). Both drivers skip the 600 s
concurrent-QPS probe (`BENCH_CONCURRENT_DURATION=0`).

### Teardown / reset

```bash
./teardown.sh --dry-run    # show exactly what would be removed
./teardown.sh              # stop + uninstall all DBs, wipe datasets & db dirs
./teardown.sh --nuke       # also remove the ./clickbench checkout
```

Stops every daemon/resident session, uninstalls the system-level databases
(ClickHouse, QuestDB, DuckDB, CrateDB — uses `sudo`), and `git clean -xfd`s the
checkout to wipe all datasets, `hits.db`, venvs, engine binaries, and FIFO
plumbing. Your `results/` are left untouched. The Rust toolchain
(`~/.cargo`, `~/.rustup`, from a vanilla-DataFusion run) is left for you to
remove by hand if you want.

## Layout

```
setup.sh                      fetch ClickBench @ pin (never vendored)
teardown.sh                   stop + uninstall all DBs, wipe datasets/db dirs (try --dry-run)
CLICKBENCH_COMMIT             the pin
lib/fifo-repl.sh              long-lived REPL-over-FIFO keep-alive harness
lib/repl-engine.py            resident embedded-engine server (chdb/datafusion/hyper)
lib/log-to-json.py            benchmark.sh log -> dashboard result JSON (+ --collapse-hot)
lib/score.py                  ClickBench hot-run geomean score for a group of results
lib/nosudo/sudo               PATH shim: no-ops the cold-cache drop (removes per-query sudo)
lib/selftest.sh, lib/mock-repl   harness validation (no engine needed)
scenario-1-parquet/
  run.sh                      vanilla + keep-alive driver
  modified/<engine>/          keep-alive overlay (start/stop/check/query/load + repl.env)
  results/{original,modified}/
scenario-2-native/
  run.sh                      original / keep-alive / warmup driver
  modified/duckdb/            keep-alive overlay (only fresh-process engine here)
  rootless/{clickhouse,cratedb}/   user-mode (no-sudo) daemon overrides
  results/{original,modified,warmup}/
```
