#!/usr/bin/env bash
#
# Benchmark this runtime's echo demo against the Tokio and Go equivalents
# in bench/tokio_echo and bench/go_echo.
#
#   ./scripts/bench.sh [stage ...]        stages: build matrix scaling latency
#                                         (default: all of them, in that order)
#
# What it measures
#
#   matrix    every server against every client -- Ada, Tokio, and Go --
#             at several connection counts.  The cross pairings are what
#             separate the server's ceiling from the client's.
#   scaling   the Ada server alone across 1, 2, 4 and 8 shards, driven by
#             the same tokio load generator, with Go and Tokio once each as
#             the reference line.  Shard_Count is compile-time, so this
#             builds one copy of the runtime per count under bench/build/;
#             the other two have no core count to sweep now that nothing
#             pins them.
#   latency   one connection, thousands of sequential round trips, against
#             an otherwise idle server.
#
# What is and is not held equal -- READ THIS BEFORE QUOTING A NUMBER
#
# The Go and Tokio programs are ordinary programs.  They were not always:
# they used to pin their worker threads to the same cores as the Ada
# shards, raise RLIMIT_NOFILE, and ask for a 4096 listen backlog through
# hand-written syscall bindings -- three things neither of them would
# otherwise contain, all of it there so the three servers met on the Ada
# server's terms.  That scaffolding is gone.  `bench/go_echo` and
# `bench/tokio_echo` are now plain safe Go and Rust with no libc, no
# kernel32 and no build tags, doing what `net.Listen`, `#[tokio::main]` and
# `TcpListener::bind` do by default.
#
# So the comparison is no longer "the same cores each".  It is:
#
#   * The Ada server on Shard_Count cores, because thread-per-core with a
#     static CPU per shard is what that runtime *is*; its pinning is the
#     thing under test, not a benchmark setting.
#   * Go and Tokio on the whole machine, as many threads as they choose.
#     On a 32-CPU host that is 32 against 4, and the wall-clock numbers
#     should be read knowing it.
#
# Which makes **server CPU per round trip the honest column**, not round
# trips per second: it is the one figure that does not depend on how many
# cores a runtime helped itself to.  The summary prints it as `srv us/rt`.
#
# Two consequences worth expecting rather than discovering:
#
#   * Listen backlog is now whatever each runtime asks for by default.  Go
#     passes SOMAXCONN and the Ada demo asks for it explicitly; Rust's
#     std -- and so tokio -- asks for 128.  A short accept queue is the
#     difference between a connect and a one-second SYN retransmit when a
#     thousand clients arrive at once, so a tokio row that loses sessions
#     at high connection counts is measuring that default, not the tokio
#     scheduler.
#   * Nothing raises RLIMIT_NOFILE for the Rust binaries any more.  Go's
#     runtime raises it for itself; on Linux a large run may need the
#     shell's ulimit raised before starting.
#
# Still held equal, because these are about the measurement and not about
# the runtimes:
#
#   * Every run records whether any session failed to complete, and on
#     Linux the change in the kernel's ListenOverflows counter as well.
#   * Runs wait for TIME_WAIT to drain below a threshold before starting,
#     so one run's litter is not the next run's connect latency.
#   * Every server is measured by the same wrapper for CPU and peak RSS,
#     and driven by the same clients.
#
# Runs on Linux and on Windows.  Everything that differs between them is in
# the "Platform" section below and nowhere else; the stages are the same
# code on both.  Two differences are worth knowing before reading numbers
# taken on Windows:
#
#   * There is no ListenOverflows counter, so a run that overflowed the
#     accept queue shows up as failed sessions rather than as a number.
#     The ok column is the one to read.
#   * The ephemeral port range starts wherever the machine says it does,
#     and it is often the whole port space.  The fixed listen ports below
#     can therefore collide with a client's outgoing port; a bind that
#     loses that race is retried on the next port rather than failing.
#
# One thing to know before reading Linux numbers: GNAT's ceiling-locking
# implementation uses priority-protect mutexes only when the process runs
# as root or holds CAP_SYS_NICE.  Unprivileged, protected objects are plain
# mutexes and cheaper.  Run this both ways if you can; BENCH_UNPRIVILEGED=1
# runs the Ada servers as BENCH_USER (default nobody) when you are root.
#
# Knobs (environment)
#
#   BENCH_REPS          repetitions per cell                      (3)
#   BENCH_SCALES        matrix "connections:rounds" list          ("100:1000 1000:100 2000:100 5000:40")
#   BENCH_CONNS/ROUNDS  scaling and latency load                  (2000 / 100)
#   BENCH_SHARDS        Ada core counts for the scaling sweep     ("1 2 4 8")
#   BENCH_CLIENT_FIRST_CPU  Ada CPU number for the client's shard 0 (10, i.e. Linux CPU 9)
#   BENCH_UNPRIVILEGED  1 to run Ada servers as BENCH_USER          (0)
#   BENCH_OUT           results directory                         (bench/results/<timestamp>)
#
# Needs: the Alire toolchain (alr), cargo, go, and python3 for the summary.
# On Linux, ss and nstat from iproute2 as well.
#
set -uo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPS=${BENCH_REPS:-3}
SCALES=${BENCH_SCALES:-"100:1000 1000:100 2000:100 5000:40"}
CONNS=${BENCH_CONNS:-2000}
ROUNDS=${BENCH_ROUNDS:-100}
SHARDS=${BENCH_SHARDS:-"1 2 4 8"}
CLIENT_FIRST_CPU=${BENCH_CLIENT_FIRST_CPU:-10}
UNPRIV=${BENCH_UNPRIVILEGED:-0}
BENCH_USER=${BENCH_USER:-nobody}
OUT=${BENCH_OUT:-bench/results/$(date +%Y%m%d-%H%M%S)}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------
#
# Six things differ between Linux and Windows, and they are all here.
# Everything below this section is the same code on both.

if [[ ${OS:-} == Windows_NT ]]; then HOST=windows; else HOST=linux; fi
EXE=""; [[ $HOST == windows ]] && EXE=".exe"

case $HOST in
windows)
    NCPU=${NUMBER_OF_PROCESSORS:-$(nproc)}

    # Windows keeps no listen-overflow counter.  A run that overflowed the
    # accept queue shows up in the ok column instead, because the client
    # counts the sessions that never completed.
    overflows() { echo 0; }

    # The ephemeral range is whatever netsh says, and on a default install
    # it is nearly the whole port space -- so there is no range of "safe"
    # ports to listen on the way there is on Linux, and a bind that loses
    # the race is retried rather than avoided.
    port_floor() { echo 65535; }

    # netstat -an is the portable spelling.  Get-NetTCPConnection is the
    # native one and takes three seconds a call, which would cost more
    # than the drain it is measuring.
    time_wait_count() { netstat -an | grep -c TIME_WAIT; }
    ;;
linux)
    NCPU=$(nproc)

    overflows() { nstat -az 2>/dev/null | awk '/TcpExtListenOverflows/{print $2}'; }

    # Ports must stay clear of the ephemeral range, or a listener's bind
    # races the client's own outgoing ports and fails intermittently.
    port_floor() { cut -f1 /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo 32768; }

    time_wait_count() { ss -tan state time-wait 2>/dev/null | wc -l; }
    ;;
esac
# The runtime's own pinning, read from the source.  It is reported rather
# than imposed: the Ada binaries pin themselves because thread-per-core is
# what they are, and nothing else here is pinned at all.
#
# Shard_Count is not in src/iour.ads and cannot be: it has to reach Ada as a
# static constant, and a GPR external is a string only the project file can
# see.  So the project selects one of the src/config/shards-<n> directories
# instead, each declaring Iour_Config.Shard_Count with a different value.
# Read the same directory the build will -- IOUR_SHARDS from the
# environment, which is where gprbuild looks for the external too, and
# failing that the default written into the project file.
IOUR_SHARDS_DEFAULT=$(sed -n \
    's/.*external *( *"IOUR_SHARDS" *, *"\([0-9]*\)" *).*/\1/p' \
    io_uring_async_runtime.gpr)
SHARDS_DIR=src/config/shards-${IOUR_SHARDS:-${IOUR_SHARDS_DEFAULT:-4}}
SHARD_COUNT=$(sed -n 's/^ *Shard_Count *: *constant *:= *\([0-9]*\);.*/\1/p' \
    "$SHARDS_DIR/iour_config.ads" 2> /dev/null)
FIRST_CPU=$(sed -n 's/^ *First_Shard_Cpu *: *constant *:= *\([0-9]*\);.*/\1/p' src/iour.ads)
MAX_FUTURES=$(sed -n 's/^ *Max_Futures *: *constant *:= *\([0-9_]*\);.*/\1/p' src/iour.ads | tr -d _)
MAX_FIBERS=$(sed -n 's/^ *Max_Fibers *: *constant *:= *\([0-9_]*\);.*/\1/p' src/iour.ads | tr -d _)

# Ada CPU 1 is the system's CPU 0, on both.
cpus_from() { local first=$1 count=$2; seq -s, $((first - 1)) $((first - 2 + count)); }
SERVER_CPUS=$(cpus_from "$FIRST_CPU" "$SHARD_COUNT")
CLIENT_CPUS=$(cpus_from "$CLIENT_FIRST_CPU" "$SHARD_COUNT")

TOKIO=bench/tokio_echo/target/release
GO_ECHO=bench/go_echo
GO=$GO_ECHO/go_echo_server$EXE
GO_CLIENT=$GO_ECHO/go_echo_client$EXE
BUILD=bench/build

# What /usr/bin/time -f '%U %S %M' used to do, in a form that exists on
# both systems.  See bench/runwait for why bash's own `time` builtin is
# not a substitute on Windows.
#
# The binary goes in $BUILD rather than next to its source, because
# bench/runwait is the source directory and on Linux -- where $EXE is empty
# -- "bench/runwait" would name both.  go build -o with an existing
# directory does not fail; it writes the binary inside it, so the build
# reported success and every run that followed tried to execute a
# directory.  Windows never saw it, the .exe keeping the two names apart.
RUNWAIT=$BUILD/runwait$EXE

log()  { printf '%s\n' "$*" | tee -a "$OUT/bench.log"; }
die()  { echo "bench: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

PORT=10100
port_low=$(port_floor)
next_port() {
    PORT=$((PORT + 1))
    [[ $PORT -lt $port_low ]] || die "ran out of ports below the ephemeral range ($port_low)"
}

# Thousands of loopback connections a second exhaust the ephemeral port
# space; wait for TIME_WAIT to drain rather than letting one run's litter
# become the next run's connect latency.
DRAIN_BELOW=${BENCH_DRAIN_BELOW:-8000}

# How long one side of a pairing may run before it is counted as a failure.
# Generous: the point is to keep a stuck run from stopping the benchmark,
# not to time anything out that is merely slow.
RUN_TIMEOUT=${BENCH_RUN_TIMEOUT:-120}
drain() {
    for _ in $(seq 1 90); do
        [[ $(time_wait_count) -lt $DRAIN_BELOW ]] && return
        sleep 2
    done
}

wait_for_listener() {
    local logfile=$1
    for _ in $(seq 1 500); do
        grep -q "listening on port" "$logfile" 2>/dev/null && return 0
        sleep 0.02
    done
    return 1
}

# Running as another user needs binaries that user can read and execute.
UNPRIV_DIR=
as_user() {
    local bin=$1
    if [[ $UNPRIV == 1 ]]; then
        [[ $(id -u) -eq 0 ]] || die "BENCH_UNPRIVILEGED needs root to switch user"
        [[ -n $UNPRIV_DIR ]] || { UNPRIV_DIR=$(mktemp -d /tmp/iour-bench.XXXXXX); chmod 755 "$UNPRIV_DIR"; }
        local copy=$UNPRIV_DIR/$(echo "$bin" | tr / _)
        [[ -x $copy ]] || { cp "$bin" "$copy"; chmod 755 "$copy"; }
        echo "runuser -u $BENCH_USER -- $copy"
    else
        echo "$bin"
    fi
}

# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

# One copy of the runtime with a different Shard_Count and/or
# First_Shard_Cpu.  Both are compile-time constants by design (Jorvik
# wants every task's CPU static), so a variant is a rebuild, not a flag.
build_variant() {
    local name=$1 shards=$2 first_cpu=$3 client_cpu=${4:-}
    local dir=$BUILD/$name
    # Reuse the existing build only if nothing it was built from has changed
    # since.  It used to reuse whatever was there, which is a cache keyed on
    # the directory existing and on nothing else: a run after any source
    # change measured the previous run's binaries and said nothing about it.
    # That is not a small error -- every variant in the scaling stage and
    # the Ada client used by the whole matrix come from here, so a stale
    # tree quietly turns the report into a report on yesterday's code.  It
    # cost one wrong conclusion already; see CLAUDE.md.
    if [[ -x $dir/bin/echo_server$EXE && -x $dir/bin/echo_client$EXE ]]; then
        local newer
        newer=$(find src examples tests *.gpr gnat.adc                      -newer "$dir/bin/echo_server$EXE" -print -quit 2>/dev/null)
        if [[ -z $newer ]]; then
            log "  reusing $name (unchanged since it was built)"
            return 0
        fi
        log "  rebuilding $name ($newer is newer than it)"
    fi
    # Both tables are banked per shard and both insist on exact division.
    if (( MAX_FUTURES % shards != 0 || MAX_FIBERS % shards != 0 )); then
        log "  skip $name: Shard_Count $shards divides neither Max_Futures" \
            "$MAX_FUTURES nor Max_Fibers $MAX_FIBERS exactly"
        return 1
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    cp -r src examples tests "$dir"/
    cp io_uring_async_runtime.gpr examples.gpr tests.gpr gnat.adc "$dir"/
    # Shard_Count arrives through -XIOUR_SHARDS below, which picks one of
    # the copied src/config directories; First_Shard_Cpu is the one tunable
    # here that is still an editable constant.
    sed -i "s/^\( *First_Shard_Cpu *: *constant *:= *\)[0-9]*;/\1$first_cpu;/" "$dir/src/iour.ads"
    if [[ -n $client_cpu ]]; then
        # The client's environment task is pinned too; keep it off the
        # server's cores.
        sed -i "s/^\(procedure Echo_Client with SPARK_Mode => On, CPU => \)[0-9]*/\1$client_cpu/" \
            "$dir/examples/echo_client.adb"
    fi
    ( cd "$dir" \
        && alr exec -- gprbuild -q -P io_uring_async_runtime.gpr \
                -XIOUR_SHARDS="$shards" -j0 \
        && alr exec -- gprbuild -q -P examples.gpr \
                -XIOUR_SHARDS="$shards" -j0 ) > "$OUT/build-$name.log" 2>&1 \
        || { log "  build of $name failed; see $OUT/build-$name.log"; return 1; }
    log "  built $name (Shard_Count $shards, First_Shard_Cpu $first_cpu)"
}

stage_build() {
    log "=== build ==="
    ( alr exec -- gprbuild -q -P io_uring_async_runtime.gpr -j0 \
        && alr exec -- gprbuild -q -P examples.gpr -j0 ) > "$OUT/build-repo.log" 2>&1 \
        || die "runtime build failed; see $OUT/build-repo.log"
    log "  built the runtime and examples (Shard_Count $SHARD_COUNT on CPUs $SERVER_CPUS)"

    ( cd bench/tokio_echo && cargo build --release ) > "$OUT/build-tokio.log" 2>&1 \
        || die "tokio build failed; see $OUT/build-tokio.log"
    log "  built bench/tokio_echo"

    ( cd "$GO_ECHO" && go build -o "go_echo_server$EXE" ./cmd/go_echo_server \
        && go build -o "go_echo_client$EXE" ./cmd/go_echo_client ) > "$OUT/build-go.log" 2>&1 \
        || die "go build failed; see $OUT/build-go.log"
    log "  built bench/go_echo"

    mkdir -p "$BUILD"
    ( cd bench/runwait && go build -o "../build/runwait$EXE" . ) > "$OUT/build-runwait.log" 2>&1 \
        || die "runwait build failed; see $OUT/build-runwait.log"
    log "  built $RUNWAIT"

    # The Ada client, moved off the server's cores.
    build_variant "client" "$SHARD_COUNT" "$CLIENT_FIRST_CPU" "$((CLIENT_FIRST_CPU - 1))" \
        || die "could not build the client variant"

    for n in $SHARDS; do
        if [[ $n == "$SHARD_COUNT" ]]; then continue; fi
        build_variant "shards_$n" "$n" "$FIRST_CPU" || true
    done
}

server_bin() {  # server_bin <shards>
    local n=$1
    if [[ $n == "$SHARD_COUNT" ]]; then echo "bin/echo_server$EXE"
    else echo "$BUILD/shards_$n/bin/echo_server$EXE"; fi
}

# ---------------------------------------------------------------------------
# One run
# ---------------------------------------------------------------------------

# run_pair <csv> <label> <conns> <rounds> <rep> <server cmd...> -- <client cmd...>
#
# A command may start with NAME=VALUE settings; runwait applies them to the
# child itself.  Putting `env` in front instead would make env the process
# runwait measures, and its CPU time is not the server's.
# The server gets "<port> <conns>" appended, the client "127.0.0.1 <port> <conns> <rounds>".
run_pair() {
    local csv=$1 label=$2 conns=$3 rounds=$4 rep=$5; shift 5
    local server=() client=()
    while [[ $# -gt 0 && $1 != -- ]]; do server+=("$1"); shift; done
    shift; client=("$@")

    drain
    local slog=$OUT/.srv.log clog=$OUT/.cli.log stime=$OUT/.srv.time ctime=$OUT/.cli.time
    local ov_before spid attempt

    # A listen that loses a race with a client's ephemeral port is a bind
    # failure, not a result.  Try a few ports before giving up, which is
    # what makes this work on a machine whose ephemeral range is the whole
    # port space.
    for attempt in 1 2 3 4 5; do
        next_port
        : > "$slog"; : > "$clog"; : > "$stime"; : > "$ctime"
        ov_before=$(overflows)
        # The server's deadline covers the client's plus the time it needs
        # to notice: a server whose accept queue overflowed is left waiting
        # for connections that will never arrive, and would otherwise hold
        # the whole benchmark up.  runwait owns the deadline because it is
        # the only process holding a handle on the child.
        RUNWAIT_TIMEOUT_S=$((RUN_TIMEOUT + 30))             "$RUNWAIT" "$stime" "${server[@]}" "$PORT" "$conns" > "$slog" 2>&1 &
        spid=$!
        wait_for_listener "$slog" && break
        kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
        spid=
    done
    if [[ -z ${spid:-} ]]; then
        log "  !! $label: server never came up ($(head -1 "$slog"))"
        return 1
    fi

    RUNWAIT_TIMEOUT_S=$RUN_TIMEOUT         "$RUNWAIT" "$ctime" "${client[@]}" 127.0.0.1 "$PORT" "$conns" "$rounds" > "$clog" 2>&1
    local cstatus=$?

    # Give the server its own grace period rather than waiting on it for
    # ever: its deadline above will end it, and this keeps the harness
    # moving if anything slips past that.
    local waited=0
    while kill -0 "$spid" 2>/dev/null && (( waited < (RUN_TIMEOUT + 40) * 5 )); do
        sleep 0.2; waited=$((waited + 1))
    done
    kill "$spid" 2>/dev/null
    wait "$spid" 2>/dev/null
    local sstatus=$?

    local elapsed rt frames failed ok ov su ss smax cu cs cmax
    elapsed=$(grep -oP 'elapsed\s+\K[0-9.E+-]+' "$clog" | head -1)
    rt=$(grep -oP 'round trips per second\s*\K[0-9.E+-]+' "$clog" | head -1)
    frames=$(grep -oP 'frames exchanged\s*\K[0-9]+' "$clog" | head -1)
    # Sessions the client could not finish.  On Linux this is the same
    # story ListenOverflows tells; on Windows, which has no such counter,
    # it is the whole story.
    failed=$(grep -oP 'failed\s*\K[0-9]+' "$clog" | head -1)
    ov=$(( $(overflows) - ov_before ))
    # Semicolon, not comma: this is the last field of a CSV row and it is
    # not quoted, so a comma inside it spills the rest into a column that
    # is not there.  Nothing here reads a field after ok, which is why the
    # damage was only ever a truncated status in someone else's reader.
    ok=$([[ $cstatus -eq 0 && $sstatus -eq 0 ]] && echo yes || echo "no(c=$cstatus;s=$sstatus)")
    read -r su ss smax < "$stime" 2>/dev/null || { su=; ss=; smax=; }
    read -r cu cs cmax < "$ctime" 2>/dev/null || { cu=; cs=; cmax=; }

    echo "$label,$conns,$rounds,$rep,$elapsed,$rt,$frames,${failed:-},$su,$ss,$smax,$cu,$cs,$cmax,$ov,$ok" >> "$csv"
    printf '  %-22s %5s x %-5s rep %s  %12s rt/s  %9ss  fail=%-5s %s\n' \
        "$label" "$conns" "$rounds" "$rep" "$rt" "$elapsed" "${failed:-?}" "$ok" | tee -a "$OUT/bench.log"
    sleep 0.3
}

csv_header() {
    echo "pairing,connections,rounds,rep,elapsed_s,rt_per_s,frames,failed_sessions,srv_user_s,srv_sys_s,srv_maxrss_kb,cli_user_s,cli_sys_s,cli_maxrss_kb,listen_overflows,ok" > "$1"
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

stage_matrix() {
    log "=== matrix: Ada server on CPUs $SERVER_CPUS, Ada client on CPUs"         "$CLIENT_CPUS; Go and Tokio unpinned on all $NCPU ==="
    local csv=$OUT/matrix.csv; csv_header "$csv"
    local ada_srv; ada_srv=$(as_user "bin/echo_server$EXE")
    local ada_cli=$BUILD/client/bin/echo_client$EXE
    local tok_srv="$TOKIO/tokio_echo_server$EXE"
    local tok_cli="$TOKIO/tokio_echo_client$EXE"
    local go_srv="$GO"
    local go_cli="$GO_CLIENT"
    for scale in $SCALES; do
        local conns=${scale%%:*} rounds=${scale##*:}
        for rep in $(seq 1 "$REPS"); do
            # shellcheck disable=SC2086
            run_pair "$csv" "ada-srv/ada-cli"     "$conns" "$rounds" "$rep" $ada_srv -- $ada_cli
            # shellcheck disable=SC2086
            run_pair "$csv" "tokio-srv/tokio-cli" "$conns" "$rounds" "$rep" $tok_srv -- $tok_cli
            # shellcheck disable=SC2086
            run_pair "$csv" "ada-srv/tokio-cli"   "$conns" "$rounds" "$rep" $ada_srv -- $tok_cli
            # shellcheck disable=SC2086
            run_pair "$csv" "tokio-srv/ada-cli"   "$conns" "$rounds" "$rep" $tok_srv -- $ada_cli
            # shellcheck disable=SC2086
            run_pair "$csv" "go-srv/ada-cli"     "$conns" "$rounds" "$rep" $go_srv -- $ada_cli
            # shellcheck disable=SC2086
            run_pair "$csv" "ada-srv/go-cli"     "$conns" "$rounds" "$rep" $ada_srv -- $go_cli
            # shellcheck disable=SC2086
            run_pair "$csv" "go-srv/tokio-cli"   "$conns" "$rounds" "$rep" $go_srv -- $tok_cli
            # shellcheck disable=SC2086
            run_pair "$csv" "tokio-srv/go-cli"   "$conns" "$rounds" "$rep" $tok_srv -- $go_cli
            # shellcheck disable=SC2086
            run_pair "$csv" "go-srv/go-cli"      "$conns" "$rounds" "$rep" $go_srv -- $go_cli
        done
    done
}

# Only the Ada server has a core count to sweep.  Go and Tokio decide for
# themselves how many threads to run, and the OS decides where -- which is
# the point of running them unconfigured -- so they appear once each, as the
# reference line the sweep is read against, rather than once per core count.
stage_scaling() {
    log "=== scaling: Ada across core counts, $CONNS x $ROUNDS ==="
    local csv=$OUT/scaling.csv; csv_header "$csv"
    local load="$TOKIO/tokio_echo_client$EXE"
    for rep in $(seq 1 "$REPS"); do
        for n in $SHARDS; do
            local srv; srv=$(server_bin "$n")
            if [[ -x $srv ]]; then
                # shellcheck disable=SC2086
                run_pair "$csv" "ada/$n-cores"   "$CONNS" "$ROUNDS" "$rep" $(as_user "$srv") -- $load
            fi
        done
        # shellcheck disable=SC2086
        run_pair "$csv" "tokio/default" "$CONNS" "$ROUNDS" "$rep" \
            "$TOKIO/tokio_echo_server$EXE" -- $load
        # shellcheck disable=SC2086
        run_pair "$csv" "go/default" "$CONNS" "$ROUNDS" "$rep" "$GO" -- $load
    done
}

stage_latency() {
    log "=== latency: one connection, 5000 sequential round trips ==="
    local csv=$OUT/latency.csv; csv_header "$csv"
    local load="$TOKIO/tokio_echo_client$EXE"
    for rep in $(seq 1 "$REPS"); do
        # shellcheck disable=SC2086
        run_pair "$csv" "ada"   1 5000 "$rep" $(as_user "bin/echo_server$EXE") -- $load
        # shellcheck disable=SC2086
        run_pair "$csv" "tokio" 1 5000 "$rep" "$TOKIO/tokio_echo_server$EXE" -- $load
        # shellcheck disable=SC2086
        run_pair "$csv" "go"    1 5000 "$rep" "$GO" -- $load
    done
}

stage_summary() {
    command -v python3 > /dev/null || { log "python3 not found; raw CSVs are in $OUT"; return; }
    python3 - "$OUT" <<'EOF' | tee "$OUT/summary.txt"
import csv, statistics, collections, os, sys
out = sys.argv[1]

def load(name):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        return []
    return [r for r in csv.DictReader(open(path)) if r["rt_per_s"]]

def med(rows, key, f=float):
    vals = [f(r[key]) for r in rows if r.get(key)]
    return statistics.median(vals) if vals else 0.0

def table(title, rows, keyf, order):
    if not rows:
        return
    g = collections.defaultdict(list)
    for r in rows:
        g[keyf(r)].append(r)
    print(title)
    print(f"  {'cell':<30} {'med rt/s':>11} {'min':>11} {'max':>11} {'med s':>8} "
          f"{'srv us/rt':>10} {'srv MB':>7} {'fail':>5} {'ovf':>4} {'ok':>3}")
    for k in order(g):
        rs = g[k]
        rts = sorted(float(r["rt_per_s"]) for r in rs)
        frames = int(rs[0]["frames"] or 1)
        cpu = med(rs, "srv_user_s") + med(rs, "srv_sys_s")
        rss = med(rs, "srv_maxrss_kb") / 1024
        fail = sum(int(r.get("failed_sessions") or 0) for r in rs)
        ovf = sum(int(r["listen_overflows"] or 0) for r in rs)
        ok = "yes" if all(r["ok"] == "yes" for r in rs) else "NO"
        print(f"  {k:<30} {statistics.median(rts):>11,.0f} {rts[0]:>11,.0f} {rts[-1]:>11,.0f} "
              f"{med(rs, 'elapsed_s'):>8.3f} {cpu / frames * 1e6:>10.2f} {rss:>7.1f} "
              f"{fail:>5} {ovf:>4} {ok:>3}")
    print()

m = load("matrix.csv")
table("matrix -- round trips/s, median over repetitions",
      m, lambda r: f"{r['connections']}x{r['rounds']:<5} {r['pairing']}",
      lambda g: sorted(g, key=lambda k: (int(k.split('x')[0]), k)))

s = load("scaling.csv")

# "ada/4-cores" sorts by its core count; "go/default" has none, and used to
# raise straight out of the script -- taking the latency table and the
# footnote with it, since one exception ends the whole summary.  Anything
# without a number sorts last within its runtime.
def scaling_key(k):
    runtime, _, rest = k.partition('/')
    head = rest.split('-')[0]
    return (runtime, int(head) if head.isdigit() else 1 << 30, rest)

table("scaling -- same tokio load generator, server alone",
      s, lambda r: r["pairing"], lambda g: sorted(g, key=scaling_key))

l = load("latency.csv")
if l:
    print("latency -- microseconds per sequential round trip, idle server")
    g = collections.defaultdict(list)
    for r in l:
        g[r["pairing"]].append(float(r["elapsed_s"]) / int(r["rounds"]) * 1e6)
    for k in sorted(g):
        print(f"  {k:<8} {statistics.median(g[k]):>8.1f} us")
    print()

if os.path.exists(os.path.join(out, "matrix.csv")):
    print("A row with fail > 0 did not complete every session, and a row with")
    print("ovf > 0 (Linux only) measured a SYN retransmit rather than a runtime.")
    print("Either way the number beside it is not a throughput figure; rerun it.")
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mkdir -p "$OUT"
[[ -n $SHARD_COUNT && -n $FIRST_CPU && -n $MAX_FUTURES && -n $MAX_FIBERS ]] \
    || die "could not read the tunables from src/iour.ads and $SHARDS_DIR"
command -v go > /dev/null || die "go not found (needed for bench/runwait as well as go_echo)"
if [[ $HOST == linux ]]; then
    command -v ss > /dev/null || die "ss (iproute2) not found"
    command -v nstat > /dev/null || log "nstat not found: listen-overflow counts will be blank"
    [[ -f /proc/sys/net/ipv4/ip_local_port_range ]] || log "no ip_local_port_range; assuming ports below 32768 are safe"
fi

cpu_model() {
    if [[ $HOST == windows ]]; then
        wmic cpu get name /value 2>/dev/null | sed -n 's/^Name=//p' | tr -d '\r' | head -1
    else
        grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //'
    fi
}

{
    echo "bench: $(date -Is)"
    echo "  host   $HOST, $(uname -sr), $NCPU CPUs, $(cpu_model)"
    echo "  runtime Shard_Count $SHARD_COUNT, First_Shard_Cpu $FIRST_CPU -> CPUs $SERVER_CPUS"
    echo "  user   $(id -un)$([[ $UNPRIV == 1 ]] && echo " (Ada servers as $BENCH_USER)")"
    echo "  reps   $REPS"
} | tee -a "$OUT/bench.log"

stages=("$@")
[[ ${#stages[@]} -gt 0 ]] || stages=(build matrix scaling latency)
for stage in "${stages[@]}"; do
    case $stage in
        build)   stage_build ;;
        matrix)  stage_matrix ;;
        scaling) stage_scaling ;;
        latency) stage_latency ;;
        *) die "unknown stage '$stage' (build matrix scaling latency)" ;;
    esac
done
stage_summary
[[ -n $UNPRIV_DIR ]] && rm -rf "$UNPRIV_DIR"
log "results in $OUT"
