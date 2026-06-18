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
cache its own driver defeats. (We *expected* Hyper to be the inert control —
its per-call `HyperProcess`/`create.sql` tax sits *outside* the timed region, so
keeping it alive "shouldn't" help the recorded number. It didn't pan out that
way: the timed query call *itself* carries first-query warmup in a fresh process.
Running it is how you find out — that's rather the point.)

### Scenario 2 — "Let Everyone Warm Up" (`scenario-2-native/`)

Native storage queried by **DuckDB**, **ClickHouse**, **QuestDB**, and
**CrateDB**, in three passes that build on each other (the post's narrative
order — vanilla, then warm everyone up, then keep DuckDB resident):
- `original` — vanilla, 3 tries.
- `warmup` — 10 tries for everyone, **no keep-alive**, so JIT engines (JVM-based
  QuestDB, CrateDB) reach steady state while AOT ClickHouse stays ~flat and
  DuckDB (fresh process per try) can't warm. Hot score is the best warm run. (A
  100M-row scan passes HotSpot's C2 threshold in a try or two, so 10 is plenty;
  override with `WARMUP_TRIES`.)
- `keepalive` — same 10 tries, but now also keep DuckDB (the only fresh-process
  engine) alive. The daemons have no keep-alive overlay and are identical to
  their `warmup` result, so this pass reuses it for them and only re-runs DuckDB.

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

This is exercised end-to-end against the real engines on the full
105-column `hits.parquet`/native datasets (the runs the post is built on);
`lib/selftest.sh` separately validates the FIFO transport with a mock (no engine
needed).

## Requirements

- Ubuntu 24.04+ (matches ClickBench's assumptions), `git`, `python3`, `jq`,
  `curl`, `unzip`, `bash`. Pre-installing `python3-venv gcc git` avoids the
  one-time `apt` prompts in some vanilla installers.
- **No passwordless sudo needed** for scenario 1, or for scenario-2 DuckDB and
  QuestDB. The `lib/nosudo/` shim (prepended to PATH by the run drivers)
  neutralizes the handful of `sudo` calls in the upstream scripts, each a
  provable no-op for hot-run-only measurement: the per-query cold-cache drop
  (`sudo tee /proc/sys/vm/drop_caches`, swallowed), the vanilla
  DataFusion/Hyper/Polars install-time `sudo apt-get` (skipped — those deps must
  be pre-installed, see below), and questdb's `sudo du` for data-size (run
  unprivileged on your own `~/.questdb`). Anything else is forwarded to the real
  sudo in non-interactive mode so it fails fast instead of hanging. Set
  `BENCH_REAL_DROP_CACHES=1` to restore real cold runs (that needs passwordless
  sudo for `tee /proc/sys/vm/drop_caches`).
- **Scenario-2 ClickHouse and CrateDB run rootless** (user-mode), so they need
  no daemon sudo: `scenario-2-native/rootless/` swaps in a clickhouse-server run
  as your user (local data dir + config, parquet read in place) and CrateDB from
  its tarball (`bin/crate`, not apt/systemctl). The vanilla per-query restart is
  preserved. Both are validated end-to-end including cross-restart persistence.
  `scenario-2-native/rootless/questdb/` is also applied the same way, but as a
  *version/config* override rather than a de-sudo one (QuestDB already runs
  rootless): it bumps QuestDB to the latest 9.4.3 — the pinned 9.3.1 lacks
  `length_bytes()` so Q27/Q28 DNF, and predates the `query.timeout.sec` →
  `query.timeout` config rename (ClickBench PR #902) — and makes the load
  idempotent (`DROP TABLE IF EXISTS`) so the warmup pass can reload cleanly.
- With `python3-venv gcc git postgresql-client` pre-installed and a `duckdb`
  binary already on your `PATH`, there are **zero** sudo prompts: the shim skips
  the install-time `apt-get`, and the vanilla DuckDB install's `sudo ln` symlink
  is guarded behind `command -v duckdb` so it never runs. (In a sandbox that
  blocks `curl | sh`, stage the engine binaries yourself — `duckdb` on PATH and a
  `clickhouse` binary in the `clickhouse*/` engine dirs — so the install scripts'
  fetch step is skipped by their `if`-guards.) None of this is per-query, so
  passwordless sudo is never required.
- Disk: the parquet dataset is ~15 GB; QuestDB's CSV load needs ~70 GB
  uncompressed transiently. Budget ~120 GB free.
- Engines install themselves on first run: vanilla engines via ClickBench's own
  per-engine `install`; the modified library engines create a local `myenv/` venv
  (`pip install chdb` / `datafusion==53.0.0` / `tableauhyperapi`); scenario-2
  ClickHouse and CrateDB use the rootless installs (binary / tarball, no system
  package). DataFusion is pinned to `53.0.0` (the PyPI bindings matching vanilla's
  datafusion-cli tag `53.1.0`) so the keep-alive delta isn't a hidden version
  bump; each scenario-1 keep-alive run also stamps the resolved engine build into
  its result JSON as `engine_version` (chdb/tableauhyperapi still resolve to
  pip-latest, so the stamp is how you see what actually ran).

## Quickstart

```bash
./setup.sh                              # clone ClickBench @ pinned commit into ./clickbench
bash lib/selftest.sh                    # validate the keep-alive harness (no engine needed)

# Scenario 1: vanilla + keep-alive (one engine, or all)
MACHINE=ryzen9-7900 scenario-1-parquet/run.sh duckdb-parquet
MACHINE=ryzen9-7900 scenario-1-parquet/run.sh

# Scenario 2: original / warmup (no keep-alive) / keepalive passes
MACHINE=ryzen9-7900 scenario-2-native/run.sh

# See the hot-run scores re-rank (lower is better):
lib/score.py scenario-1-parquet/results/original/*.json
lib/score.py scenario-1-parquet/results/modified/*.json
lib/score.py scenario-2-native/results/original/*.json
lib/score.py scenario-2-native/results/warmup/*.json
lib/score.py scenario-2-native/results/keepalive/*.json
```

Results are written to `scenario-1-parquet/results/{original,modified}/` and
`scenario-2-native/results/{original,warmup,keepalive}/` as `<engine>.<machine>.json`
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

Stops every daemon/resident session and `git clean -xfd`s the checkout to wipe
all datasets, `hits.db`, the rootless `ch-data`/`crate-data` + engine binaries,
venvs, and FIFO plumbing; it also removes `~/.questdb` and `~/.duckdb`. With the
default rootless ClickHouse/CrateDB this needs **no sudo** — system-level
removals (`/var/lib/clickhouse`, the `crate` apt package, the `/usr/local/bin`
duckdb symlink, …) run only if a *vanilla* system install is actually detected.
`--dry-run` prints the exact plan (including a `git clean -xnd` preview). Your
`results/` and the Rust toolchain (`~/.cargo`, `~/.rustup`) are left untouched.

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
  run.sh                      original / warmup / keepalive driver
  keepalive/duckdb/           keep-alive overlay (only fresh-process engine here)
  rootless/{clickhouse,cratedb}/   user-mode (no-sudo) daemon overrides
  rootless/questdb/                version (9.4.3) + timeout/load override (PR #902)
  results/{original,warmup,keepalive}/
```
