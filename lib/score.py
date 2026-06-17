#!/usr/bin/env python3
"""Compute ClickBench's hot-run summary score for a group of result JSONs.

Reproduces the dashboard's "Hot Run" metric (see ClickBench's README "Results
Usage" section):
  - hot per query = min(2nd, 3rd run), or null if either is missing;
  - per query, baseline = the best (min) hot across the compared systems;
  - ratio = (0.01 + hot) / (0.01 + baseline), with a missing hot replaced by a
    penalty = 2 * max(300s, this system's worst hot);
  - score = geometric mean of the 43 ratios. Lower is better; 1.0 means fastest
    on every query.

The baseline is taken across exactly the files you pass, so to see a re-ranking
pass the group you want to compare, e.g.:
    lib/score.py scenario-1-parquet/results/original/*.json
    lib/score.py scenario-1-parquet/results/modified/*.json

Usage: score.py <result.json> [<result.json> ...]
"""
import json
import math
import sys


def hot_of(row):
    if len(row) >= 3 and isinstance(row[1], (int, float)) and isinstance(row[2], (int, float)):
        return min(row[1], row[2])
    return None


def main():
    files = sys.argv[1:]
    if not files:
        sys.exit("usage: score.py <result.json> [<result.json> ...]")

    systems = []
    for f in files:
        with open(f) as fh:
            d = json.load(fh)
        hots = [hot_of(r) for r in d.get("result", [])]
        systems.append({"name": d.get("system", f), "hots": hots})

    nq = max((len(s["hots"]) for s in systems), default=0)
    baselines = []
    for i in range(nq):
        vals = [s["hots"][i] for s in systems if i < len(s["hots"]) and s["hots"][i] is not None]
        baselines.append(min(vals) if vals else None)

    for s in systems:
        valid = [h for h in s["hots"] if h is not None]
        penalty = 2 * max(300.0, max(valid) if valid else 300.0)
        ratios = []
        for i in range(nq):
            base = baselines[i]
            if base is None:
                continue
            h = s["hots"][i] if i < len(s["hots"]) else None
            val = h if h is not None else penalty
            ratios.append((0.01 + val) / (0.01 + base))
        s["score"] = math.exp(sum(map(math.log, ratios)) / len(ratios)) if ratios else float("nan")
        s["complete"] = sum(1 for h in s["hots"] if h is not None)

    systems.sort(key=lambda s: s["score"])
    width = max((len(s["name"]) for s in systems), default=10)
    print(f"{'rank':>4}  {'system':<{width}}  {'hot score':>9}  {'queries':>7}")
    print("-" * (4 + 2 + width + 2 + 9 + 2 + 7))
    for rank, s in enumerate(systems, 1):
        print(f"{rank:>4}  {s['name']:<{width}}  {s['score']:>9.3f}  {s['complete']:>5}/43")


if __name__ == "__main__":
    main()
