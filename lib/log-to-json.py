#!/usr/bin/env python3
"""Turn a ClickBench benchmark.sh log into a dashboard-ready result JSON.

Upstream collects results by piping the run log into a ClickHouse `sink`
database and rendering with collect-results.sh. That needs a ClickHouse server
and the sink schema. For local, self-contained reproduction we parse the same
log lines directly: the 43 `[t1,t2,t3],` runtime rows, `Load time:`,
`Data size:`, and the optional concurrency lines, merged with the engine's
template.json metadata.

Usage:
    log-to-json.py [--collapse-hot] <template.json> <machine> <date> < benchmark.log > out.json

--collapse-hot is for the warmup pass (BENCH_TRIES > 3): the ClickBench
dashboard takes the hot run as min(2nd, 3rd) of a 3-element row, so for an
N-try row we collapse to [cold, best_warm, 2nd_best_warm] (cold = try 1; the
two best of the remaining warm tries). That makes the dashboard's hot metric
the fully-warmed-up best, while preserving a real cold number.
"""
import json
import re
import sys

argv = sys.argv[1:]
collapse_hot = "--collapse-hot" in argv
argv = [a for a in argv if a != "--collapse-hot"]
template_path, machine, date = argv[0], argv[1], argv[2]


def collapse(row):
    """[t1, t2, ..., tN] -> [cold, best_warm, 2nd_best_warm]."""
    if not row:
        return row
    cold = row[0]
    warm = sorted(v for v in row[1:] if isinstance(v, (int, float)))
    if not warm:
        return [cold, None, None]
    best = warm[0]
    second = warm[1] if len(warm) > 1 else warm[0]
    return [cold, best, second]
with open(template_path) as f:
    tpl = json.load(f)

results = []
load_time = 0
data_size = 0
qps = None
err_ratio = None
engine_version = None

for line in sys.stdin:
    s = line.strip()
    m = re.match(r"^(\[.*\]),?$", s)
    if m:
        try:
            row = json.loads(m.group(1))
            results.append(collapse(row) if collapse_hot else row)
        except json.JSONDecodeError:
            pass
        continue
    if s.startswith("Load time:"):
        try:
            load_time = float(s.split(":", 1)[1])
        except ValueError:
            pass
    elif s.startswith("Data size:"):
        try:
            data_size = int(float(s.split(":", 1)[1]))
        except ValueError:
            pass
    elif s.startswith("Concurrent QPS:"):
        v = s.split(":", 1)[1].strip()
        qps = None if v == "null" else float(v)
    elif s.startswith("Concurrent error ratio:"):
        v = s.split(":", 1)[1].strip()
        err_ratio = None if v == "null" else float(v)
    elif s.startswith("Engine version:"):
        # Emitted by the keep-alive overlays' ./load so the result records the
        # exact engine build that produced it (the library engines float to
        # pip-latest unless pinned). Last one wins.
        v = s.split(":", 1)[1].strip()
        engine_version = v or None

out = {
    "system": tpl["system"],
    "date": date,
    "machine": machine,
    "cluster_size": 1,
    "proprietary": tpl.get("proprietary", "no"),
    "hardware": tpl.get("hardware", "cpu"),
    "tuned": tpl.get("tuned", "no"),
    "tags": tpl.get("tags", []),
    "load_time": load_time,
    "data_size": data_size,
    "result": results,
}
if qps is not None:
    out["concurrent_qps"] = qps
if err_ratio is not None:
    out["concurrent_error_ratio"] = err_ratio
if engine_version is not None:
    out["engine_version"] = engine_version

if len(results) != 43:
    sys.stderr.write(
        f"log-to-json: warning: parsed {len(results)} runtime rows (expected 43)\n"
    )

json.dump(out, sys.stdout, indent=4)
sys.stdout.write("\n")
