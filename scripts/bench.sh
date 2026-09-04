#!/usr/bin/env bash
#
# Benchmark this runtime's echo demo against the tokio equivalent in
# bench/tokio_echo, the way the comparison in the README was made.
#
#   ./scripts/bench.sh [stage ...]        stages: build matrix scaling latency
#                                         (default: all of them, in that order)
#
# What it measures
#
#   matrix    every server against every client -- Ada/Ada, Ada/tokio,
#             tokio/Ada, tokio/tokio -- at several connection counts.  The
#             cross pairings are what separate the server's ceiling from the
#             client's.
#   scaling   each server alone, driven by the same tokio load generator,
#             with 1, 2, 4 and 8 cores.  The Ada server's core count is
#             Shard_Count, which is compile-time, so this builds one copy of
#             the runtime per count under bench/build/.
#   latency   one connection, thousands of sequential round trips, against
#             an otherwise idle server.
#
# How it keeps the comparison fair
#
#   * Servers are pinned to the CPUs the Ada shards use (First_Shard_Cpu
#     onward, in Linux numbering); the tokio server pins its workers to the
#     same set.  Clients run on a disjoint set, so the load generator never
#     competes with the server under test.  The Ada client is a rebuild
#     with First_Shard_Cpu moved, since its pinning is compile-time too.
#   * Listen backlog is 4096 on both sides.  Every run records the change
#     in the kernel's ListenOverflows counter: a run that overflowed was
#     measuring a one-second SYN retransmit, not a runtime.
#   * Runs wait for TIME_WAIT to drain below a threshold, and listen on
#     ports outside ip_local_port_range, where bind would otherwise race
#     the client's own ephemeral ports.
#
# One thing to know before reading the numbers: GNAT's ceiling-locking
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
#   BENCH_SHARDS        scaling core counts                       ("1 2 4 8")
#   BENCH_CLIENT_FIRST_CPU  Ada CPU number for the client's shard 0 (10, i.e. Linux CPU 9)
#   BENCH_LOAD_CPUS     Linux CPUs for the scaling load generator (upper half of the machine)
#   BENCH_UNPRIVILEGED  1 to run Ada servers as BENCH_USER          (0)
#   BENCH_OUT           results directory                         (bench/results/<timestamp>)
#
# Needs: the Alire toolchain (env.sh), cargo, /usr/bin/time, ss and nstat
# from iproute2, python3 for the summary.
#
set -uo pipefail

cd "$(dirname "$0")/.."

# env.sh appends to LD_LIBRARY_PATH, which set -u objects to when unset.
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}

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

NCPU=$(nproc)
LOAD_CPUS=${BENCH_LOAD_CPUS:-$(seq -s, $((NCPU / 2)) $((NCPU - 1)))}

# The runtime's own pinning, read from the source so the tokio server can
# be put on exactly the same cores.
SHARD_COUNT=$(sed -n 's/^ *Shard_Count *: *constant *:= *\([0-9]*\);.*/\1/p' src/iour.ads)
FIRST_CPU=$(sed -n 's/^ *First_Shard_Cpu *: *constant *:= *\([0-9]*\);.*/\1/p' src/iour.ads)
MAX_FUTURES=$(sed -n 's/^ *Max_Futures *: *constant *:= *\([0-9_]*\);.*/\1/p' src/iour.ads | tr -d _)

# Ada CPU 1 is Linux CPU 0.
cpus_from() { local first=$1 count=$2; seq -s, $((first - 1)) $((first - 2 + count)); }
SERVER_CPUS=$(cpus_from "$FIRST_CPU" "$SHARD_COUNT")
SERVER_MAIN=0
CLIENT_CPUS=$(cpus_from "$CLIENT_FIRST_CPU" "$SHARD_COUNT")
CLIENT_MAIN=$((CLIENT_FIRST_CPU - 2))

TOKIO=bench/tokio_echo/target/release
BUILD=bench/build

TIMEFMT='%U %S %M'

log()  { printf '%s\n' "$*" | tee -a "$OUT/bench.log"; }
die()  { echo "bench: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

# Ports must stay clear of the ephemeral range, or a listener's bind races
# the client's own outgoing ports and fails intermittently.
PORT=10100
port_low=$(cut -f1 /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo 32768)
next_port() {
    PORT=$((PORT + 1))
    [[ $PORT -lt $port_low ]] || die "ran out of ports below ip_local_port_range ($port_low)"
}

overflows() { nstat -az 2>/dev/null | awk '/TcpExtListenOverflows/{print $2}'; }

# Thousands of loopback connections a second exhaust the ephemeral port
# space; wait for TIME_WAIT to drain rather than letting one run's litter
# become the next run's connect latency.
drain() {
    for _ in $(seq 1 90); do
        [[ $(ss -tan state time-wait 2>/dev/null | wc -l) -lt 8000 ]] && return
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
    if [[ -x $dir/bin/echo_server && -x $dir/bin/echo_client ]]; then
        return 0
    fi
    if (( MAX_FUTURES % shards != 0 )); then
        log "  skip $name: Shard_Count $shards does not divide Max_Futures $MAX_FUTURES"
        return 1
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    cp -r src examples tests "$dir"/
    cp io_uring_async_runtime.gpr examples.gpr tests.gpr gnat.adc env.sh "$dir"/
    sed -i "s/^\( *Shard_Count *: *constant *:= *\)[0-9]*;/\1$shards;/" "$dir/src/iour.ads"
    sed -i "s/^\( *First_Shard_Cpu *: *constant *:= *\)[0-9]*;/\1$first_cpu;/" "$dir/src/iour.ads"
    if [[ -n $client_cpu ]]; then
        # The client's environment task is pinned too; keep it off the
        # server's cores.
        sed -i "s/^\(procedure Echo_Client with SPARK_Mode => On, CPU => \)[0-9]*/\1$client_cpu/" \
            "$dir/examples/echo_client.adb"
    fi
    ( cd "$dir" && source ./env.sh \
        && gprbuild -q -P io_uring_async_runtime.gpr -j0 \
        && gprbuild -q -P examples.gpr -j0 ) > "$OUT/build-$name.log" 2>&1 \
        || { log "  build of $name failed; see $OUT/build-$name.log"; return 1; }
    log "  built $name (Shard_Count $shards, First_Shard_Cpu $first_cpu)"
}

stage_build() {
    log "=== build ==="
    ( source ./env.sh && gprbuild -q -P io_uring_async_runtime.gpr -j0 \
        && gprbuild -q -P examples.gpr -j0 ) > "$OUT/build-repo.log" 2>&1 \
        || die "runtime build failed; see $OUT/build-repo.log"
    log "  built the runtime and examples (Shard_Count $SHARD_COUNT on Linux CPUs $SERVER_CPUS)"

    ( cd bench/tokio_echo && cargo build --release ) > "$OUT/build-tokio.log" 2>&1 \
        || die "tokio build failed; see $OUT/build-tokio.log"
    log "  built bench/tokio_echo"

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
    if [[ $n == "$SHARD_COUNT" ]]; then echo bin/echo_server
    else echo "$BUILD/shards_$n/bin/echo_server"; fi
}

# ---------------------------------------------------------------------------
# One run
# ---------------------------------------------------------------------------

# run_pair <csv> <label> <conns> <rounds> <rep> <server cmd...> -- <client cmd...>
# The server gets "<port> <conns>" appended, the client "127.0.0.1 <port> <conns> <rounds>".
run_pair() {
    local csv=$1 label=$2 conns=$3 rounds=$4 rep=$5; shift 5
    local server=() client=()
    while [[ $# -gt 0 && $1 != -- ]]; do server+=("$1"); shift; done
    shift; client=("$@")

    next_port; drain
    local slog=$OUT/.srv.log clog=$OUT/.cli.log stime=$OUT/.srv.time ctime=$OUT/.cli.time
    : > "$slog"; : > "$clog"; : > "$stime"; : > "$ctime"
    local ov_before; ov_before=$(overflows)

    /usr/bin/time -f "$TIMEFMT" -o "$stime" "${server[@]}" "$PORT" "$conns" > "$slog" 2>&1 &
    local spid=$!
    if ! wait_for_listener "$slog"; then
        log "  !! $label: server never came up ($(head -1 "$slog"))"
        kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
        return 1
    fi

    /usr/bin/time -f "$TIMEFMT" -o "$ctime" "${client[@]}" 127.0.0.1 "$PORT" "$conns" "$rounds" > "$clog" 2>&1
    local cstatus=$?
    wait "$spid" 2>/dev/null
    local sstatus=$?

    local elapsed rt frames ok ov su ss smax cu cs cmax
    elapsed=$(grep -oP 'elapsed\s+\K[0-9.E+-]+' "$clog" | head -1)
    rt=$(grep -oP 'round trips per second\s*\K[0-9.E+-]+' "$clog" | head -1)
    frames=$(grep -oP 'frames exchanged\s*\K[0-9]+' "$clog" | head -1)
    ov=$(( $(overflows) - ov_before ))
    ok=$([[ $cstatus -eq 0 && $sstatus -eq 0 ]] && echo yes || echo "no(c=$cstatus,s=$sstatus)")
    read -r su ss smax < "$stime" 2>/dev/null || { su=; ss=; smax=; }
    read -r cu cs cmax < "$ctime" 2>/dev/null || { cu=; cs=; cmax=; }

    echo "$label,$conns,$rounds,$rep,$elapsed,$rt,$frames,$su,$ss,$smax,$cu,$cs,$cmax,$ov,$ok" >> "$csv"
    printf '  %-22s %5s x %-5s rep %s  %12s rt/s  %9ss  ovf=%-3s %s\n' \
        "$label" "$conns" "$rounds" "$rep" "$rt" "$elapsed" "$ov" "$ok" | tee -a "$OUT/bench.log"
    sleep 0.3
}

csv_header() {
    echo "pairing,connections,rounds,rep,elapsed_s,rt_per_s,frames,srv_user_s,srv_sys_s,srv_maxrss_kb,cli_user_s,cli_sys_s,cli_maxrss_kb,listen_overflows,ok" > "$1"
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

stage_matrix() {
    log "=== matrix: server on CPUs $SERVER_CPUS, client on CPUs $CLIENT_CPUS ==="
    local csv=$OUT/matrix.csv; csv_header "$csv"
    local ada_srv; ada_srv=$(as_user bin/echo_server)
    local ada_cli=$BUILD/client/bin/echo_client
    local tok_srv="env IOUR_BENCH_CPUS=$SERVER_CPUS IOUR_BENCH_MAIN_CPU=$SERVER_MAIN $TOKIO/tokio_echo_server"
    local tok_cli="env IOUR_BENCH_CPUS=$CLIENT_CPUS IOUR_BENCH_MAIN_CPU=$CLIENT_MAIN $TOKIO/tokio_echo_client"
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
        done
    done
}

stage_scaling() {
    log "=== scaling: load generator on CPUs $LOAD_CPUS, $CONNS x $ROUNDS ==="
    local csv=$OUT/scaling.csv; csv_header "$csv"
    local load="env IOUR_BENCH_CPUS=$LOAD_CPUS IOUR_BENCH_MAIN_CPU=0 $TOKIO/tokio_echo_client"
    for rep in $(seq 1 "$REPS"); do
        for n in $SHARDS; do
            local srv; srv=$(server_bin "$n")
            local cpus; cpus=$(cpus_from "$FIRST_CPU" "$n")
            if [[ -x $srv ]]; then
                # shellcheck disable=SC2086
                run_pair "$csv" "ada/$n-cores"   "$CONNS" "$ROUNDS" "$rep" $(as_user "$srv") -- $load
            fi
            # shellcheck disable=SC2086
            run_pair "$csv" "tokio/$n-cores" "$CONNS" "$ROUNDS" "$rep" \
                env IOUR_BENCH_CPUS="$cpus" IOUR_BENCH_MAIN_CPU=$SERVER_MAIN $TOKIO/tokio_echo_server -- $load
        done
    done
}

stage_latency() {
    log "=== latency: one connection, 5000 sequential round trips ==="
    local csv=$OUT/latency.csv; csv_header "$csv"
    local load="env IOUR_BENCH_CPUS=${LOAD_CPUS%%,*} IOUR_BENCH_MAIN_CPU=0 $TOKIO/tokio_echo_client"
    for rep in $(seq 1 "$REPS"); do
        # shellcheck disable=SC2086
        run_pair "$csv" "ada"   1 5000 "$rep" $(as_user bin/echo_server) -- $load
        # shellcheck disable=SC2086
        run_pair "$csv" "tokio" 1 5000 "$rep" \
            env IOUR_BENCH_CPUS="$SERVER_CPUS" IOUR_BENCH_MAIN_CPU=$SERVER_MAIN $TOKIO/tokio_echo_server -- $load
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
    return statistics.median(f(r[key]) for r in rows)

def table(title, rows, keyf, order):
    if not rows:
        return
    g = collections.defaultdict(list)
    for r in rows:
        g[keyf(r)].append(r)
    print(title)
    print(f"  {'cell':<30} {'med rt/s':>11} {'min':>11} {'max':>11} {'med s':>8} {'srv us/rt':>10} {'ovf':>4} {'ok':>3}")
    for k in order(g):
        rs = g[k]
        rts = sorted(float(r["rt_per_s"]) for r in rs)
        frames = int(rs[0]["frames"] or 1)
        cpu = med(rs, "srv_user_s") + med(rs, "srv_sys_s")
        ovf = sum(int(r["listen_overflows"] or 0) for r in rs)
        ok = "yes" if all(r["ok"] == "yes" for r in rs) else "NO"
        print(f"  {k:<30} {statistics.median(rts):>11,.0f} {rts[0]:>11,.0f} {rts[-1]:>11,.0f} "
              f"{med(rs, 'elapsed_s'):>8.3f} {cpu / frames * 1e6:>10.2f} {ovf:>4} {ok:>3}")
    print()

m = load("matrix.csv")
table("matrix -- round trips/s, median over repetitions",
      m, lambda r: f"{r['connections']}x{r['rounds']:<5} {r['pairing']}",
      lambda g: sorted(g, key=lambda k: (int(k.split('x')[0]), k)))

s = load("scaling.csv")
table("scaling -- same tokio load generator, server alone",
      s, lambda r: r["pairing"],
      lambda g: sorted(g, key=lambda k: (k.split('/')[0], int(k.split('/')[1].split('-')[0]))))

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
    print("Any row with ovf > 0 measured a SYN retransmit, not a runtime; rerun it.")
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mkdir -p "$OUT"
[[ -n $SHARD_COUNT && -n $FIRST_CPU && -n $MAX_FUTURES ]] || die "could not read Shard_Count, First_Shard_Cpu and Max_Futures from src/iour.ads"
command -v /usr/bin/time > /dev/null || die "/usr/bin/time not found"
command -v ss > /dev/null || die "ss (iproute2) not found"
command -v nstat > /dev/null || log "nstat not found: listen-overflow counts will be blank"
[[ -f /proc/sys/net/ipv4/ip_local_port_range ]] || log "no ip_local_port_range; assuming ports below 32768 are safe"

{
    echo "bench: $(date -Is)"
    echo "  host   $(uname -r), $NCPU CPUs, $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
    echo "  runtime Shard_Count $SHARD_COUNT, First_Shard_Cpu $FIRST_CPU -> Linux CPUs $SERVER_CPUS"
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
