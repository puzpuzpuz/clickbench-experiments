#!/usr/bin/env python3
"""Resident embedded-engine REPL for the keep-alive experiment.

ClickHouse-local, DataFusion-cli, and Hyper can't be driven as a clean
long-lived "CLI reading from a FIFO" (clickhouse-local batches stdin until EOF;
interactive mode needs a PTY and disables --time; etc.). So for these engines
we keep the SAME engine resident via its embedded Python library — chdb is
literally clickhouse-local as a library — reading queries from stdin and
answering from one persistent session, exactly like an analyst with a notebook
kernel left open. (DuckDB stays as its native CLI, which REPLs cleanly.)

This speaks the same line protocol lib/fifo-repl.sh expects from the DuckDB
CLI, so the harness and the duckdb-style repl.env parser are reused unchanged:

    .timer on|off   ignored (timing is always reported)
    .print X        prints X verbatim (the harness's sentinel marker)
    .load           reads ./create.sql and runs it against the session
    .quit | .exit   exits
    <blank>         ignored
    <anything else> a single-line SQL query: executed against the persistent
                    session, result printed, then a duckdb-style line
                    `Run Time (s): real <secs> ...` carrying the engine's own
                    query time.

Timing is each engine's internal/execute time, matching its vanilla ClickBench
script (chdb's reported elapsed; perf_counter around collect()/
execute_list_query for DataFusion/Hyper, mirroring datafusion-cli's `Elapsed`
and hyper's timeit). The ONLY thing that differs from vanilla is that the
process — and thus its caches — persists across the repeated runs.

Usage: repl-engine.py <chdb|datafusion|hyper>
"""
import sys
import time


def emit(s=""):
    sys.stdout.write(s if s.endswith("\n") else s + "\n")
    sys.stdout.flush()


def emit_timing(secs):
    emit(f"Run Time (s): real {secs:.6f} user 0.000 sys 0.000")


def split_statements(text):
    return [s.strip() for s in text.split(";") if s.strip()]


class ChdbEngine:
    name = "chdb"

    def __init__(self):
        from chdb import session as chs
        self.sess = chs.Session()

    def load(self, text):
        for stmt in split_statements(text):
            self.sess.query(stmt)

    def exec_sql(self, sql):
        r = self.sess.query(sql, "Pretty")
        return str(r), float(r.elapsed())


class DatafusionEngine:
    name = "datafusion"

    def __init__(self):
        from datafusion import SessionContext
        self.ctx = SessionContext()

    def load(self, text):
        for stmt in split_statements(text):
            self.ctx.sql(stmt)

    def exec_sql(self, sql):
        df = self.ctx.sql(sql)
        t = time.perf_counter()
        batches = df.collect()
        secs = time.perf_counter() - t
        nrows = sum(b.num_rows for b in batches)
        return f"{nrows} row(s)", secs


class HyperEngine:
    name = "hyper"

    def __init__(self):
        from tableauhyperapi import HyperProcess, Telemetry, Connection
        self._hp = HyperProcess(telemetry=Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU)
        self._conn = Connection(self._hp.endpoint)

    def load(self, text):
        # hyper's create.sql is a single `create temp external table ...` command.
        stmt = text.strip().rstrip(";")
        if stmt:
            self._conn.execute_command(stmt)

    def exec_sql(self, sql):
        t = time.perf_counter()
        rows = self._conn.execute_list_query(sql)
        secs = time.perf_counter() - t
        return f"{len(rows)} row(s)", secs


ENGINES = {"chdb": ChdbEngine, "datafusion": DatafusionEngine, "hyper": HyperEngine}


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "chdb"
    if which not in ENGINES:
        sys.stderr.write(f"repl-engine: unknown engine '{which}'\n")
        sys.exit(2)
    engine = ENGINES[which]()

    while True:
        line = sys.stdin.readline()
        if line == "":
            break  # EOF (all writers closed) -> shut down
        s = line.rstrip("\n").strip()
        if not s or s.startswith(".timer"):
            continue
        if s.startswith(".print "):
            emit(s[len(".print "):])
            continue
        if s.startswith(".load"):
            try:
                with open("create.sql") as f:
                    text = f.read()
                t = time.perf_counter()
                engine.load(text)
                emit("Ok.")
                emit_timing(time.perf_counter() - t)
            except Exception as e:  # noqa: BLE001
                emit(f"ERROR (load): {e}")
                emit_timing(0.0)
            continue
        if s in (".quit", ".exit"):
            break
        # A SQL query.
        try:
            render, secs = engine.exec_sql(line.rstrip("\n"))
            emit(render)
            emit_timing(secs)
        except Exception as e:  # noqa: BLE001
            # No Run Time line -> the harness parses no timing and the driver
            # records null for this query, matching vanilla failure handling.
            emit(f"ERROR: {e}")


if __name__ == "__main__":
    main()
