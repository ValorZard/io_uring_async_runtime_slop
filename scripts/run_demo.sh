#!/usr/bin/env bash
#
# Run the echo server and client against each other and show both reports.
#
#   ./scripts/run_demo.sh [connections] [rounds] [port]
#
set -uo pipefail
cd "$(dirname "$0")/.."

CONNECTIONS=${1:-2000}
ROUNDS=${2:-10}
PORT=${3:-9099}

if [[ ! -x bin/echo_server || ! -x bin/echo_client ]]; then
    echo "run_demo: build first with 'make examples'" >&2
    exit 1
fi

SERVER_LOG=$(mktemp)
trap 'rm -f "$SERVER_LOG"' EXIT

echo "=== server ==="
./bin/echo_server "$PORT" "$CONNECTIONS" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for the listener to be up rather than guessing at a sleep.
for _ in $(seq 1 100); do
    grep -q "listening on port" "$SERVER_LOG" && break
    sleep 0.05
done
head -2 "$SERVER_LOG"

echo
echo "=== client ==="
./bin/echo_client 127.0.0.1 "$PORT" "$CONNECTIONS" "$ROUNDS"
CLIENT_STATUS=$?

wait "$SERVER_PID"
SERVER_STATUS=$?

echo
echo "=== server report ==="
tail -n +3 "$SERVER_LOG"

if [[ $CLIENT_STATUS -eq 0 && $SERVER_STATUS -eq 0 ]]; then
    echo
    echo "demo: PASS -- $CONNECTIONS connections, $ROUNDS round trips each"
    exit 0
fi
echo
echo "demo: FAIL (client=$CLIENT_STATUS server=$SERVER_STATUS)" >&2
exit 1
