#!/usr/bin/env python3
"""Decide whether a benchmark run passes or fails.

    ./scripts/bench_gate.py bench/results/<timestamp>

scripts/bench.sh always exits 0.  That is correct for a measuring
instrument -- a slow run is still a run, and the script's job is to
report, not to judge -- but a CI trigger needs a verdict, so the verdict
is made here, over the CSVs it wrote.

What is gated, and what deliberately is not
-------------------------------------------

Only this: every session completed.  A run that lost sessions is not a
slow run, it is not a result at all, and it is the signal that has
actually caught things in this runtime -- the Windows start-up race
showed up as 1,000 of 2,000 sessions lost, and the listen-backlog clamp
as 26-66% of a thousand connects refused.  Both were invisible in the
throughput column, which stayed entirely plausible.

Throughput is NOT gated, and should not be.  On a shared CI runner the
numbers drift far more than any regression worth catching, so a threshold
over them produces red builds nobody believes, which is worse than no
check.  Read `srv us/rt` in the summary by eye; do not automate it until
it runs somewhere quiet.

Two rows are excluded from the verdict, each for a reason established by
measurement rather than taste.  See CLAUDE.md.
"""

import csv
import os
import sys

STAGES = ("matrix.csv", "scaling.csv", "latency.csv")


def check(out):
    """Return a list of complaints; empty means the run passed."""
    bad = []
    rows = 0
    ada_rows = 0

    for name in STAGES:
        path = os.path.join(out, name)
        if not os.path.exists(path):
            bad.append(f"{name}: never written, so that stage did not run")
            continue

        with open(path, newline="") as handle:
            for row in csv.DictReader(handle):
                rows += 1
                pairing = row["pairing"]
                if pairing.startswith("ada"):
                    ada_rows += 1

                #  The Go client drops connections against every server,
                #  its own included: measured on this project at 211-305
                #  of 500 completing, five runs out of five.  So its rows
                #  say nothing about the server under test and cannot be
                #  part of a verdict about one.  It stays in the matrix
                #  because it is still a throughput generator on the runs
                #  where it does complete.
                if pairing.endswith("go-cli"):
                    continue

                where = (f"{name} {pairing} "
                         f"{row['connections']}x{row['rounds']} "
                         f"rep {row['rep']}")

                #  ok is the harness's own verdict on the pair of
                #  processes: both exited cleanly and neither hit
                #  runwait's deadline.
                if row["ok"] != "yes":
                    bad.append(f"{where}: did not finish cleanly "
                               f"(ok={row['ok']})")

                failed = row["failed_sessions"]
                if failed and int(failed) > 0:
                    bad.append(f"{where}: lost {failed} sessions")

    #  A run that produced nothing at all -- every server failing to come
    #  up, say -- looks exactly like a clean one to the loop above, because
    #  run_pair writes no row for a pair it could not start.
    if ada_rows == 0:
        bad.append("no rows for the Ada server anywhere; "
                   "the harness measured nothing")

    print(f"checked {rows} rows, {ada_rows} of them the Ada server's")
    return bad


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2

    bad = check(sys.argv[1])
    for complaint in bad:
        #  ::error:: is GitHub Actions' annotation syntax.  Outside CI it
        #  is merely a visible prefix, which is why nothing here checks
        #  whether it is running under Actions.
        print(f"::error::{complaint}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
