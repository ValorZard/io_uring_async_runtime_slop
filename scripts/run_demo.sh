#!/usr/bin/env bash
#
# Run the echo server and client against each other, in two phases.
#
#   ./scripts/run_demo.sh [connections] [rounds] [port]
#
# Phase 1 is small and traced, so you can read what the runtime is actually
# doing: shards coming up, connections being adopted by whichever core is
# free, fibers starting and finishing, shards going idle and waking.
#
# Phase 2 is the full run, untraced, for the throughput figure.  Tracing
# writes a line per scheduler decision with a blocking write, so tracing
# thousands of connections would measure the tracing.
#
set -uo pipefail
cd "$(dirname "$0")/.."

CONNECTIONS=${1:-2000}
ROUNDS=${2:-10}
PORT=${3:-9099}

TRACE_CONNECTIONS=6
TRACE_ROUNDS=2
TRACE_PORT=$((PORT + 1))

if [[ ! -x bin/echo_server || ! -x bin/echo_client ]]; then
    echo "run_demo: build first with 'make examples'" >&2
    exit 1
fi

SERVER_LOG=$(mktemp)
TRACE_SERVER_LOG=$(mktemp)
TRACE_CLIENT_LOG=$(mktemp)
trap 'rm -f "$SERVER_LOG" "$TRACE_SERVER_LOG" "$TRACE_CLIENT_LOG"' EXIT

# Wait for a listener rather than guessing at a sleep.
wait_for_listener() {
    local log=$1
    for _ in $(seq 1 200); do
        grep -q "listening on port" "$log" && return 0
        sleep 0.05
    done
    return 1
}

# ---------------------------------------------------------------------------
# Phase 1: small, traced
# ---------------------------------------------------------------------------

echo "=== phase 1: $TRACE_CONNECTIONS connections, traced ==="
echo

IOUR_TRACE=1 ./bin/echo_server "$TRACE_PORT" "$TRACE_CONNECTIONS" \
    > "$TRACE_SERVER_LOG" 2>&1 &
TRACE_SERVER_PID=$!

if ! wait_for_listener "$TRACE_SERVER_LOG"; then
    echo "run_demo: traced server never came up" >&2
    kill "$TRACE_SERVER_PID" 2>/dev/null
    exit 1
fi

IOUR_TRACE=1 ./bin/echo_client 127.0.0.1 "$TRACE_PORT" \
    "$TRACE_CONNECTIONS" "$TRACE_ROUNDS" > "$TRACE_CLIENT_LOG" 2>&1
wait "$TRACE_SERVER_PID"

# Both processes tag their lines "[iour] shard N:"; say which process each
# came from, and drop everything that is not a trace line.
{
    sed -n 's/^\[iour\] /server  /p' "$TRACE_SERVER_LOG"
    sed -n 's/^\[iour\] /client  /p' "$TRACE_CLIENT_LOG"
} | sed 's/^/  /'

echo
echo "  (server and client are separate processes, so their traces are"
echo "   shown one after the other, not interleaved in real time)"

# ---------------------------------------------------------------------------
# Phase 2: full scale, untraced
# ---------------------------------------------------------------------------

echo
echo "=== phase 2: $CONNECTIONS connections, untraced ==="
echo

./bin/echo_server "$PORT" "$CONNECTIONS" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

if ! wait_for_listener "$SERVER_LOG"; then
    echo "run_demo: server never came up" >&2
    kill "$SERVER_PID" 2>/dev/null
    exit 1
fi
head -2 "$SERVER_LOG"

echo
echo "--- client ---"
./bin/echo_client 127.0.0.1 "$PORT" "$CONNECTIONS" "$ROUNDS"
CLIENT_STATUS=$?

wait "$SERVER_PID"
SERVER_STATUS=$?

echo
echo "--- server ---"
tail -n +3 "$SERVER_LOG"

if [[ $CLIENT_STATUS -eq 0 && $SERVER_STATUS -eq 0 ]]; then
    echo
    echo "demo: PASS -- $CONNECTIONS connections, $ROUNDS round trips each"
    exit 0
fi
echo
echo "demo: FAIL (client=$CLIENT_STATUS server=$SERVER_STATUS)" >&2
exit 1
