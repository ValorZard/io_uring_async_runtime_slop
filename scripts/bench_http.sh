#!/usr/bin/env bash
# Bounded loopback regression benchmark for this repository's HTTP server
# and client. It deliberately does not compare other runtimes: matching Go
# and Axum HTTP peers have not been added yet.
set -euo pipefail

cd "$(dirname "$0")/.."

REPS=${BENCH_HTTP_REPS:-10}
OUT=${BENCH_HTTP_OUT:-bench/results/http-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

ALR=${ALR:-}
if [[ -z $ALR ]]; then
    ALR=$(type -P alr || true)
fi
if [[ ! -x "$ALR" ]]; then
    ALR='/c/Program Files/Alire/bin/alr.exe'
fi
[[ -x "$ALR" ]] || { echo "alr not found" >&2; exit 127; }

"$ALR" exec -- gprbuild -q -P io_uring_async_runtime.gpr -j0
"$ALR" exec -- gprbuild -q -P examples.gpr -j0

echo "rep,elapsed_ms,ok" > "$OUT/http.csv"
for rep in $(seq 1 "$REPS"); do
    started=$(date +%s%N)
    if make demo-http > "$OUT/rep-$rep.log" 2>&1; then
        ok=yes
    else
        ok=no
    fi
    ended=$(date +%s%N)
    elapsed_ms=$(( (ended - started) / 1000000 ))
    echo "$rep,$elapsed_ms,$ok" | tee -a "$OUT/http.csv"
done

if grep -q ',no$' "$OUT/http.csv"; then
    exit 1
fi
echo "HTTP benchmark results in $OUT"