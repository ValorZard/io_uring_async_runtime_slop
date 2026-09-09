#!/usr/bin/env bash
# Benchmark the fixed HTTP response contract across the Ada runtime, Go
# net/http and Axum. Every request uses a distinct connection because the
# Ada server currently responds with Connection: close.
set -euo pipefail

cd "$(dirname "$0")/.."

REPS=${BENCH_HTTP_REPS:-3}
SCALES=${BENCH_HTTP_SCALES:-"100:100 500:40"}
OUT=${BENCH_HTTP_OUT:-bench/results/http-$(date +%Y%m%d-%H%M%S)}
RUN_TIMEOUT=${BENCH_HTTP_RUN_TIMEOUT:-120}
mkdir -p "$OUT"

group() { echo "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'; }

fixed3() { awk -v v="$1" 'BEGIN { if (v != "") printf "%.3f", v + 0 }'; }

EXE=""
[[ ${OS:-} == Windows_NT ]] && EXE=.exe
GO_HTTP=bench/go_http
AXUM_HTTP=bench/axum_http/target/release
GO_SERVER=$GO_HTTP/go_http_server$EXE
GO_CLIENT=$GO_HTTP/go_http_client$EXE
AXUM_SERVER=$AXUM_HTTP/axum_http_server$EXE
AXUM_CLIENT=$AXUM_HTTP/axum_http_client$EXE
ADA_SERVER=bin/http_server$EXE
ADA_CLIENT=bin/http_client$EXE

(cd "$GO_HTTP" && go build -o "go_http_server$EXE" ./cmd/go_http_server &&
    go build -o "go_http_client$EXE" ./cmd/go_http_client)
(cd bench/axum_http && cargo build --release)

PORT=18080
next_port() { PORT=$((PORT + 1)); }

wait_for_listener() {
    local log=$1
    for _ in $(seq 1 500); do
        grep -q 'listening on port' "$log" 2>/dev/null && return 0
        sleep 0.02
    done
    return 1
}

run_pair() {
    local csv=$1 label=$2 connections=$3 rounds=$4 rep=$5 server=$6 client=$7
    local requests=$((connections * rounds))
    local server_log=$OUT/.server.log client_log=$OUT/.client.log
    next_port
    "$server" "$PORT" "$requests" > "$server_log" 2>&1 &
    local server_pid=$!
    if ! wait_for_listener "$server_log"; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        echo "$label,$connections,$rounds,$rep,,,,1,no" >> "$csv"
        return
    fi
    if "$client" 127.0.0.1 "$PORT" "$connections" "$rounds" > "$client_log" 2>&1; then
        client_status=0
    else
        client_status=$?
    fi
    local waited=0
    while kill -0 "$server_pid" 2>/dev/null && (( waited < RUN_TIMEOUT * 10 )); do
        sleep 0.1
        waited=$((waited + 1))
    done
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true

    local elapsed rate frames failed ok
    elapsed=$(grep -oP 'elapsed\s+\K[0-9.E+-]+\s*m?s' "$client_log" | head -1 |
        awk '{ value = $1 + 0; if ($2 == "ms") value /= 1000; printf "%.9f", value }' || true)
    rate=$(grep -oP 'round trips per second\s*\K[0-9.E+-]+' "$client_log" | head -1 || true)
    rate=$(awk -v value="$rate" 'BEGIN { if (value != "") printf "%.0f", value + 0 }')
    frames=$(grep -oP 'frames exchanged\s*\K[0-9]+' "$client_log" | head -1 || true)
    failed=$(grep -oP 'failed\s*\K[0-9]+' "$client_log" | head -1 || true)
    [[ ${failed:-1} == 0 && $client_status == 0 ]] && ok=yes || ok=no
    echo "$label,$connections,$rounds,$rep,${elapsed:-},${rate:-},${frames:-},${failed:-$requests},$ok" >> "$csv"
    printf '  %-22s %5s x %-5s rep %s  %11s rt/s  %8ss  fail=%-5s %s\n' \
        "$label" "$connections" "$rounds" "$rep" "$(group "${rate:-0}")" \
        "$(fixed3 "$elapsed")" "${failed:-?}" "$ok" | tee -a "$OUT/bench.log"
}

csv=$OUT/matrix.csv
echo 'pairing,connections,rounds,rep,elapsed_s,rt_per_s,frames,failed_sessions,ok' > "$csv"
for scale in $SCALES; do
    connections=${scale%%:*}
    rounds=${scale##*:}
    for rep in $(seq 1 "$REPS"); do
        run_pair "$csv" 'ada-srv/ada-cli' "$connections" "$rounds" "$rep" "$ADA_SERVER" "$ADA_CLIENT"
        run_pair "$csv" 'ada-srv/go-cli' "$connections" "$rounds" "$rep" "$ADA_SERVER" "$GO_CLIENT"
        run_pair "$csv" 'ada-srv/axum-cli' "$connections" "$rounds" "$rep" "$ADA_SERVER" "$AXUM_CLIENT"
        run_pair "$csv" 'go-srv/ada-cli' "$connections" "$rounds" "$rep" "$GO_SERVER" "$ADA_CLIENT"
        run_pair "$csv" 'go-srv/go-cli' "$connections" "$rounds" "$rep" "$GO_SERVER" "$GO_CLIENT"
        run_pair "$csv" 'axum-srv/axum-cli' "$connections" "$rounds" "$rep" "$AXUM_SERVER" "$AXUM_CLIENT"
        run_pair "$csv" 'go-srv/axum-cli' "$connections" "$rounds" "$rep" "$GO_SERVER" "$AXUM_CLIENT"
        run_pair "$csv" 'axum-srv/ada-cli' "$connections" "$rounds" "$rep" "$AXUM_SERVER" "$ADA_CLIENT"
        run_pair "$csv" 'axum-srv/go-cli' "$connections" "$rounds" "$rep" "$AXUM_SERVER" "$GO_CLIENT"
    done
done

if grep -q ',no$' "$csv"; then
    exit 1
fi
echo "HTTP benchmark results in $OUT"