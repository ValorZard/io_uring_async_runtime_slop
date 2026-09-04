# io_uring async runtime for Ada 2022 / SPARK

A thread-per-core asynchronous runtime built on `io_uring`, written in Ada 2022
under `SPARK_Mode => On` and the **Jorvik** tasking profile.

`Await` is an ordinary function call. When it cannot make progress it switches
the core to another task and returns later, exactly where it left off:

```ada
procedure Serve (Arg : Fiber_Argument) is
   Conn    : constant Net.Socket := Net.Socket (Arg);
   Request : Frame;
   Status  : Io_Result;
begin
   loop
      Net.Receive_Exact (Conn, Request, Status);   --  suspends here
      exit when Status <= 0;
      Net.Send_All (Conn, Request, Status);        --  and here
      exit when Status < 0;
   end loop;
   Net.Close (Conn, Status);
end Serve;
```

No callbacks, no continuations, no hand-rolled state machine, no `async`
colouring of the call graph. While that fiber sits inside `Receive_Exact` its
core is serving other connections.

## What it does

Measured on this machine, 4 shards, loopback:

| | |
|---|---|
| Simultaneous connections | 2000 |
| Operating system threads | 4 |
| Frames exchanged | 20000 |
| Errors | 0 |

Run it yourself with `make demo`, which shows a small traced run first so you
can watch the scheduler work, then the full 2000-connection run for the
figure.

## Architecture

```
                      Iour.Fibers.Spawn
                             |
                             v
                 +-----------------------+
                 |  global run queue     |   one queue, every shard pops
                 +-----------------------+
                   |       |       |
        +----------+       |       +----------+
        v                  v                  v
   +---------+        +---------+        +---------+
   | shard 0 |        | shard 1 |   ...  | shard N |   one Ada task each,
   | CPU 1   |        | CPU 2   |        | CPU N+1 |   pinned to one core
   +---------+        +---------+        +---------+
   | io_uring|        | io_uring|        | io_uring|   one ring per shard,
   |  ring   |<------>|  ring   |<------>|  ring   |   never shared
   +---------+ MSG_RING+---------+MSG_RING+---------+
     fibers             fibers             fibers      stackful, migrate
                                                       only before they start
```

* **Shards.** A fixed set of library-level Ada tasks, each pinned to one core
  by a *static* CPU aspect. Jorvik forbids dynamic CPU assignment and task
  hierarchies, so `Iour.Shards` writes out one task declaration per shard
  rather than declaring an array of them. That is what makes the
  thread-to-core map checkable at compile time.

* **Rings.** Each shard owns one `io_uring` outright. No other task submits to
  it or reaps from it, which is exactly the promise `IORING_SETUP_SINGLE_ISSUER`
  wants, and is why submission needs no cross-core synchronisation.

* **Fibers.** Work runs on stackful green threads. Because a fiber has a real
  stack, suspending is a matter of saving one machine context and restoring
  another, so `Await` can be a plain call. This is the model Seastar exposes as
  `seastar::thread`, and it is what the stack-per-task cost buys.

  The saved contexts themselves live on the C side and are named from Ada by
  slot index. That split is deliberate: a saved stack pointer is machine state
  whose only accessor is the assembly, and an Ada array that has to hand out
  addresses into itself can be neither a protected object nor anything SPARK
  will let an access type designate. Naming slots by integer leaves the Ada
  scheduler with no addresses to hand out and no shared array to race over.

* **Shard identity is arithmetic.** Shard N is pinned to Ada CPU
  `First_Shard_Cpu + N` by a static aspect, so the shard a thread belongs to is
  a function of the CPU the kernel reports. There is no lookup table to keep in
  step and nothing for two shards to race over.

* **Futures.** One global, shard-agnostic table of small integer handles. Any
  shard can resolve any future; the shard owning the waiting fiber is woken
  through `IORING_OP_MSG_RING`, so a cross-core handoff lands in the sibling's
  ordinary completion stream. There is no shared ready queue, no eventfd and no
  condition variable anywhere in the wakeup path.

* **Load balancing.** Everything `Spawn` creates goes on one globally
  accessible run queue that every shard pops from. A shard with spare capacity
  helps itself; nothing measures load or steals from a neighbour. Once a shard
  adopts a fiber, that fiber stays put, because its in-flight operations live
  in that shard's ring and their completions can be reaped nowhere else.

### The event loop

One pass, in `Iour.Scheduler.Run`:

1. Harvest every completion the kernel has finished, resolve its future, wake
   whoever was waiting.
2. Take new work off the global run queue and give it a stack.
3. Resume every ready fiber, up to a budget, so a stream of always-runnable
   fibers cannot starve completion harvesting.
4. Submit. If there is genuinely nothing left, sleep inside `io_uring_enter`.

Step 4 is the only place a shard blocks, and it blocks in the kernel on its own
ring. Going idle is announced before the final queue check, so a sibling
publishing work either sees the shard idle and messages it, or published early
enough for the re-check to catch it; the wakeup cannot be lost either way.

## Interfacing with liburing

**There is no C shim for `io_uring`.** The Ada code calls liburing directly.

That needs saying because the obvious reading of liburing's API is misleading.
Only 66 symbols are actually exported: `io_uring_queue_init`, `io_uring_setup`,
`io_uring_enter`, `io_uring_submit` and friends. Every `io_uring_prep_*`,
`io_uring_sqe_set_data`, `io_uring_cq_advance` and `io_uring_cq_ready` is
`static inline` in `<liburing.h>` and exports no symbol at all, so there is
nothing for an Ada `Import` to bind to.

What those inline functions manipulate, though, is not liburing's own data. It
is kernel UAPI: `struct io_uring_sqe`, `struct io_uring_cqe` and
`struct io_uring_params` come from `include/uapi/linux/io_uring.h` and are
frozen ABI, exactly like `struct sockaddr_in`. So `Iour.Ffi.Uring` mirrors those
three structures in Ada with explicit representation clauses, and
`Iour.Reactor` writes the submission protocol out in Ada: claim a slot, fill in
the operation, publish the tail with a release store, drain completions with an
acquire load. `tests/abi_check.c` asserts every offset, size and opcode against
the real headers at compile time, so a drift breaks the build rather than the
runtime.

Deliberately *not* mirrored: `struct io_uring` itself. That one is liburing's
private bookkeeping, it is not UAPI, and its layout has changed between
releases. The reactor maps the rings from the offsets `io_uring_setup` reports
and never needs it.

Memory ordering comes from Ada's `Atomic` aspect. On x86-64 GNAT compiles an
atomic store into a locked exchange and an atomic load into a plain move, which
is sequentially consistent and therefore at least as strong as the
acquire/release the ring protocol requires.

Sockets are the same story: `socket`, `bind`, `listen`, `setsockopt`,
`getsockname`, `shutdown` and `close` are all real libc symbols and are bound
directly. Byte-order conversion and dotted-quad parsing are done in Ada rather
than borrowed from `htons` and `inet_pton`, so the whole address path stays
analysable.

Where libc wants a pointer, the Ada binding takes an `access` parameter and the
caller passes `X'Access` from a declaration of its own. GNAT passes that as a
plain pointer, so the C side is unchanged, and no Ada code has to take the
address of an Ada object: SPARK can follow an access value where it cannot
follow an address.

### The one C file

`src/c/iour_fiber.c` is the only C in the project, and it is essentially
assembly: saving and restoring a machine context cannot be expressed in Ada at
all. It is about twenty instructions on x86-64 (an AArch64 path is included),
`mmap` for a fiber stack with a guard page below it, and the table of saved
contexts that the assembly reads and writes, indexed by slot.

The switch is deliberately tiny. It saves the SysV callee-saved registers on
the outgoing stack, swaps the stack pointer, and pops them back. It touches no
signal mask, so a switch costs tens of cycles rather than the microsecond
`swapcontext(3)` spends in `rt_sigprocmask`.

## SPARK status

Every unit is `SPARK_Mode => On`, and every unit compiles under GNAT's SPARK
legality rules. Neither SPARK nor Jorvik is disabled anywhere.

`gnatprove` goes further than the compiler, and there are two targets because
there are two honest answers.

**`make prove`** — everything inside SPARK's analysable subset, in full proof
mode. Expected to come back clean, and does:

```
Success: all checks proved (450 checks).

SPARK Analysis results     Total       Flow    Provers   Unproved
Data Dependencies             21         21          .          .
Flow Dependencies              5          5          .          .
Initialization               167        167          .          .
Run-time Checks              211          .        211          .
Assertions                     8          .          8          .
Functional Contracts          20          .         20          .
Termination                   18         18          .          .
```

Zero unproved checks, zero warnings, zero data races. That covers the fiber
scheduler, the per-shard event loop, the future table, the run queue, the
shard tasks, the submit-and-await primitive, promises, tracing, the
fiber-aware `Put_Line`, both libc binding packages, and the demo protocol.
Everything the runtime *decides* is in there.

Getting there meant fixing defects gnatprove found and the compiler did not:
an overflow when negating `Io_Result'First`; statistics counters that would
wrap on a long-lived server; free-list cursors whose index arithmetic was
correct but not provably so; an out-of-range shard conversion in the surplus
task declarations; an allocation inside a protected action; an IPv4 parser
whose accumulator could overflow before its bound was checked; a cross-shard
wakeup that was silently dropped if the submission queue happened to be full;
and a flush failure that would have left a shard in a silent hot loop. All are
fixed in the shipped code.

Three modelling decisions made the rest provable rather than assumed:

* The operating system is SPARK external state, `Iour.Ffi.Kernel`. A binding
  whose whole purpose is a side effect declares that it writes `Kernel`, so
  SPARK knows the call does something even though it cannot see what.
* Socket creation is declared with Ada 2022's `Side_Effects` aspect. A
  function that creates a kernel object is not pure, and saying so is what
  lets it stay a function without SPARK rejecting it.
* `Iour.Reactor`'s spec carries full `Global` and `Always_Terminates`
  contracts, so every caller is checked against a stated promise rather than
  an assumption of "no effect", even though the body itself is not analysed.

**`make prove-boundary`** — flow analysis over the *whole* runtime, including
the three bodies that must hand an object's address to the kernel. Expected to
end in `error during analysis`; its purpose is to list exactly those sites:

| Kind | Sites | Where |
|---|---|---|
| `X'Address` used as an expression (E0002) | 8 | `Iour.Net`, `Iour.Time`, `Iour.Reactor` |
| Memory-mapped overlay declared inside a subprogram (E0001) | 2 | `Iour.Reactor` |

Both are precisely what the `io_uring` interface needs, and neither has a
SPARK-legal substitute:

* An SQE carries a buffer's address as a 64-bit integer. SPARK forbids
  `Unchecked_Conversion` from an access type to an integer, deliberately: its
  ownership model depends on pointers not being forgeable as numbers.
* The ring words must be atomic, because the kernel writes them concurrently,
  and SPARK forbids an access type designating a volatile type. Marking the
  overlays `Volatile` instead trips the "not at library level" rule, since
  their addresses are only known after `mmap`. There is no annotation that
  satisfies both.

SPARK's own manual prescribes hoisting each site into a small subprogram whose
body is `SPARK_Mode => Off`, which would let `gnatprove` analyse the remaining
three bodies. **That is not done here, because the brief was not to turn SPARK
off anywhere.**

One toolchain note: GNAT 16.1 crashes (`exp_ch9.adb:8406`) on a
`pragma Warnings (GNATprove, ...)` placed inside a protected body. The
justifications for barrier-only entries are therefore placed around the whole
protected body instead.

## Rules for code built on this runtime

Three constraints are real, and two of them come from Jorvik rather than from
this design.

**Buffers must outlive the call.** Anything handed to `Receive`, `Send` or
`Connect` has to stay valid until the call returns. A local variable of the
fiber body satisfies this automatically, because the fiber's stack is exactly
what stays alive while it is suspended. A buffer that is not reachable for the
whole call — a slice of something being reused — is not safe, and the kernel
will write into whatever now occupies that memory.

**Never wait on a protected entry from a fiber.** An entry call blocks the
task, and the task is the whole shard: every other fiber on that core stops
with it. Wait on a promise instead (below), or `Iour.Time.Sleep`, and the core
stays busy. (The environment task is not a shard, so `Wait_For_Shutdown` there
is fine.)

**Use `Iour.Text.Put_Line`, not `Ada.Text_IO`, inside a fiber.**
`Ada.Text_IO` writes through C stdio and blocks the shard. `Iour.Text` builds
the line on the fiber's stack, hands it to the ring, and suspends only that
fiber. Off a fiber it falls back to a plain blocking write, so it is safe to
call from anywhere.

**Fiber bodies and shared state live at library level.** Jorvik's
`No_Local_Protected_Objects` puts protected objects at library level, and a
fiber body is passed as an access-to-subprogram value, so a nested procedure is
"deeper than the access type" and Ada will not let you take its access.
Application code is therefore written as library-level packages, with the main
subprogram reduced to starting the runtime and reporting. The examples show the
shape.

One more, for main programs: a Jorvik partition never ends on its own. The
environment task would block forever waiting on tasks that are not allowed to
terminate, so shutdown is an explicit `Iour.Ffi.Sys.Exit_Process` once the
runtime has drained.

## Promises

A promise is a future with the kernel taken out of the loop: one side awaits
it, any other side fulfils it, and the waiter wakes. It is the synchronisation
primitive for fibers, and the reason a fiber never has to queue on a protected
entry.

```ada
Done : Future_Ref;
Iour.Promises.Create (Done);
Iour.Fibers.Spawn (Worker'Access, Fiber_Argument (Done), Handle);
Iour.Promises.Await (Done, Result);           --  this fiber sleeps alone

--  in Worker, when finished:
Iour.Promises.Fulfil (Future_Id (Arg), 0);    --  the awaiter resumes
```

`Fulfil` works from any fiber on any shard, and from the environment task. A
wake sent from a shard reaches its target immediately over `MSG_RING`. The
environment task owns no ring, so its wakes go into the target shard's inbox
and are picked up on that shard's next pass, within its idle backoff if it was
asleep. The inbox exists rather than a direct enqueue because only a shard may
touch its own ready queue: a fiber caught between registering as a waiter and
switching out could otherwise be queued twice.

A promise resolves once. A second `Fulfil` is ignored, and fulfilling before
anyone awaits is fine: the value waits in the table.

## Watching it run

`make demo` runs in two phases. The first is small and traced, so the
scheduler's decisions are readable:

```
server  shard 2: up, ring ready
server  shard 2: adopted fiber 0
server  shard 2: fiber starts 0
server  shard 1: going idle, in flight 0
server  shard 2: going idle, in flight 1
server  shard 2: woke with work
server  shard 0: adopted fiber 2
server  shard 0: adopted fiber 3
server  shard 2: fiber finished 0
```

Read down that and you can see the whole design working: four shards come up,
one adopts the acceptor, the rest go idle rather than spin, connections land
on whichever core is free, and shards wake exactly when there is something to
do.

The second phase is the full 2000-connection run, untraced. Tracing is a
blocking write per decision, so tracing thousands of connections would measure
the tracing.

Any program can be traced directly:

```
IOUR_TRACE=1 ./bin/smoke
IOUR_TRACE=1 ./bin/echo_server 9099 100
```

Tracing is off by default and costs one atomic load per event when off. When
on, each event is one blocking `write(2)` from whatever context raised it.
That is deliberate: a trace that suspended the fiber it was reporting on would
change what it was reporting. Idle is reported on entering an idle spell
rather than on every re-arm of the backoff timer, so a quiet shard does not
bury the trace in repeats of its own polling.

## Layout

```
src/iour.ads                 core types, handles, tunables
src/ffi/                     direct bindings: liburing, libc sockets, libc
src/runtime/
  iour-reactor.adb           the io_uring submission/completion protocol, in Ada
  iour-fibers.adb            fiber table, context switching, Await, Spawn
  iour-futures.adb           global future table
  iour-run_queue.adb         the one globally accessible run queue
  iour-scheduler.adb         the per-shard event loop
  iour-shards.adb            the pinned tasks
  iour-async.adb             submit-and-await, the primitive everything uses
  iour-time.adb              Sleep that suspends a fiber, not a core
  iour-promises.adb          futures you fulfil by hand
  iour-text.adb              Put_Line that suspends a fiber, not a core
  iour-trace.adb             IOUR_TRACE: watch the scheduler decide
src/net/iour-net.adb         asynchronous sockets
src/c/iour_fiber.c           the context switch (the only C)
examples/                    echo server and client
tests/smoke.adb              runtime self-test
tests/abi_check.c            kernel-ABI conformance, checked at compile time
```

## Building

Needs `liburing` (2.5 here) and a GNAT toolchain with SPARK. Both are already
in place via Alire; `env.sh` puts them on `PATH`.

```
make examples     # library, server, client
make smoke        # runtime self-test
make demo         # server and client, 2000 connections
make abi-check    # kernel-ABI mirrors vs. this system's headers
make prove           # SPARK proof of everything analysable (expected clean)
make prove-boundary  # list the sites outside SPARK's subset (expected to error)
```

Run the demo by hand:

```
./bin/echo_server 9099 2000 &
./bin/echo_client 127.0.0.1 9099 2000 10
```

## Tuning

Everything is in `src/iour.ads`.

| Constant | Default | What it costs |
|---|---|---|
| `Shard_Count` | 4 | One pinned thread and one ring each |
| `Max_Shards` | 8 | Task declarations in `Iour.Shards` |
| `First_Shard_Cpu` | 2 | Ada CPU of shard 0; CPU 1 is left to the environment task |
| `Max_Fibers` | 4096 | Ceiling on concurrent tasks |
| `Fiber_Stack_Bytes` | 64 KiB | Memory per *live* fiber; stacks are mapped lazily and recycled |
| `Ring_Entries` | 4096 | Submission queue depth per shard |
| `Idle_Poll_Nanos` | 1 ms | Base of the idle backoff, which doubles to 128 ms |

Raising `Shard_Count` above `Max_Shards` is a compile-time error. Adding shards
past 8 means adding task declarations to `Iour.Shards`, because Jorvik requires
each CPU to be static.

## Prior art

* **Seastar** — thread-per-core, shared-nothing, and `seastar::thread` for the
  stackful model this runtime uses.
* **Glommio** — per-core `io_uring` rings and cross-ring messaging.
* **Zig `std.Io`** — the argument that an I/O interface should be a parameter
  and that suspension should not colour the call graph.
* **Ada-promises** (github.com/briot/Ada-promises) — futures and promises in
  Ada. This runtime takes the shape but not the representation: handles into a
  static table rather than access types, which is what keeps it inside SPARK
  and free of dynamic allocation.
