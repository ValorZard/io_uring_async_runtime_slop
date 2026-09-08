# A ring-based async runtime for Ada 2022 / SPARK

A thread-per-core asynchronous runtime built on the operating system's own
completion machinery — `io_uring` on Linux, **I/O completion ports** on
Windows — written entirely in Ada 2022 under the **Jorvik** tasking profile
and proved with SPARK.

One runtime, two backends, and the seam between them is a single package
spec. Everything above `Iour.Reactor` — the scheduler, the fibers, the
futures, the sockets a program actually calls — is compiled unchanged on
both systems.

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

Measured on this machine, 4 shards, loopback, `make demo`:

| | Linux (io_uring) | Windows (IOCP) |
|---|---|---|
| Simultaneous connections | 2000 | 2000 |
| Operating system threads | 4 | 4 |
| Frames exchanged | 20000 | 20000 |
| Errors | 0 | 0 |

And against the Tokio and Go equivalents in `bench/`, on Windows. Those two
are ordinary programs — `net.Listen` and default `GOMAXPROCS`,
`#[tokio::main]` and `TcpListener::bind` — so on this 32-CPU machine they use
all of it while the Ada server uses the four cores its `Shard_Count` names.
That asymmetry is deliberate: thread-per-core pinning is what this runtime
*is*, not a benchmark setting. It also means **CPU per round trip is the
column to read**, since it does not depend on how many cores a runtime helped
itself to.

| 2000 connections × 100 rounds, same client | Ada | Go | Tokio |
|---|---|---|---|
| round trips per second | **243,673** | 207,365 | 115,772 |
| server µs of CPU per round trip | **11.4** | 47.0 | 41.9 |
| peak RSS, MB | 27 | 21 | 8 |

| one connection, sequential | Ada | Go | Tokio |
|---|---|---|---|
| µs per round trip | **12.8** | 13.0 | 14.0 |

Spreading a latency-bound loopback workload over 32 cores costs Go and Tokio
two to four times the CPU per round trip: every wakeup becomes a cross-core
interrupt onto a cold cache. The memory goes the other way — one 64 KiB fiber
stack per live connection is what this runtime pays.

`make bench` runs the whole matrix; `bench/results/` has the CSVs, and the
header of `scripts/bench.sh` says exactly what is and is not held equal.

Run it yourself with `make demo`, which shows a small traced run first so you
can watch the scheduler work, then the full 2000-connection run for the
figure. The same command on either system.

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
   |  ring   |        |  ring   |        |  ring   |   one ring per shard,
   |         |<------>|         |<------>|         |   never shared
   +---------+ wakeup +---------+ wakeup +---------+
     fibers             fibers             fibers      stackful, migrate
                                                       only before they start
```

* **Shards.** A fixed set of library-level Ada tasks, each pinned to one core
  by a *static* CPU aspect. Jorvik forbids dynamic CPU assignment and task
  hierarchies, so `Iour.Shards` writes out one task declaration per shard
  rather than declaring an array of them. That is what makes the
  thread-to-core map checkable at compile time. An array is not merely
  unidiomatic here, it is rejected: a task type carries one CPU aspect for
  every object of it, and threading the core through a discriminant is a
  `No_Dynamic_Cpu_Assignment` violation under the profile.

  So `Max_Shards` declarations exist whatever `Shard_Count` is. A shard whose
  index is `>= Shard_Count` takes no part — see *Shards past `Shard_Count`*
  under Tuning, which is also where the one thing it cannot opt out of is.

* **Rings and ports.** Each shard owns its completion machinery outright: one
  `io_uring` on Linux, one completion port on Windows. No other task submits
  to it or reaps from it. On Linux that is exactly the promise
  `IORING_SETUP_SINGLE_ISSUER` wants; on Windows it is what lets a port be
  created with a concurrency of one and every per-shard structure behind it be
  a plain variable. It is the same invariant either way, and it is why
  submission needs no cross-core synchronisation.

* **Fibers.** Work runs on stackful green threads. Because a fiber has a real
  stack, suspending is a matter of saving one machine context and restoring
  another, so `Await` can be a plain call. This is the model Seastar exposes as
  `seastar::thread`, and it is what the stack-per-task cost buys.

  The saved contexts themselves live in the fiber primitive's own table and
  are named by slot index. That split is deliberate: a saved stack pointer is machine state
  whose only accessor is the assembly, and an Ada array that has to hand out
  addresses into itself can be neither a protected object nor anything SPARK
  will let an access type designate. Naming slots by integer leaves the Ada
  scheduler with no addresses to hand out and no shared array to race over.

* **Shard identity is one load.** A shard says who it is once, into
  thread-local storage, and every later question is a load from it
  (`Iour.Ffi.Identity`). No lookup table to keep in step, nothing for two
  shards to race over, and — unlike the `sched_getcpu` arithmetic this
  replaced — no dependence on every thread that matters being pinned. Which
  matters, because GNAT for Windows accepts Ada's `CPU` aspect and does
  nothing with it; a shard there asks for its core itself, with
  `SetThreadAffinityMask`, and pinning is a performance measure rather than
  the thing correctness rests on.

* **Futures.** One global, shard-agnostic table of small integer handles. Any
  shard can resolve any future; the shard owning the waiting fiber is woken by
  putting a completion straight into its stream — `IORING_OP_MSG_RING` on
  Linux, `PostQueuedCompletionStatus` on Windows — so a cross-core handoff
  arrives as an ordinary completion. There is no shared ready queue, no
  eventfd and no condition variable anywhere in the wakeup path.

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
4. Submit. If there is genuinely nothing left, sleep in the kernel —
   `io_uring_enter` on Linux, `GetQueuedCompletionStatusEx` on Windows.

Step 4 is the only place a shard blocks, and it blocks in the kernel on state
it owns. Going idle is announced before the final queue check, so a sibling
publishing work either sees the shard idle and messages it, or published early
enough for the re-check to catch it; the wakeup cannot be lost either way.

## The two backends

`Iour.Reactor` is the whole surface onto asynchronous I/O: nine operation
constructors, a submit, a harvest, and a wakeup. Two bodies implement it,
under `src/os/linux` and `src/os/windows`, and the project file picks one
from the host. Nothing above that spec knows which it got.

The operations are expressed in terms both systems can honour rather than in
either one's vocabulary — an `Op_Spec` naming a kind, a descriptor, a buffer
and a token. `Op_Timeout` takes the interval by value, for instance, because
`IORING_OP_TIMEOUT` wants a `struct __kernel_timespec` that outlives the
submission and Windows wants a number; the Linux backend stages the timespec
itself, indexed by submission slot, and no caller has to keep one alive
across a suspension.

### Linux: interfacing with liburing

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
analysable — and, being ordinary arithmetic on a structure that is the same
sixteen bytes on both systems, it is shared with the Windows backend
(`Iour.Ffi.Inet`) rather than written twice.

Where libc wants a pointer, the Ada binding takes an `access` parameter and the
caller passes `X'Access` from a declaration of its own. GNAT passes that as a
plain pointer, so libc sees what it expects, and no Ada code has to take the
address of an Ada object: SPARK can follow an access value where it cannot
follow an address.

### Windows: a completion port, and the ring that used to be here

Every shard owns one I/O completion port. Every operation the backend performs
either is an overlapped Win32 call whose completion the kernel delivers to
that port, or is finished by the runtime itself and announced on the port with
`PostQueuedCompletionStatus`. So a shard has one place to look and one place
to sleep, and `GetQueuedCompletionStatusEx` is doing three jobs in a single
system call: the wait, the batch collection, and — because a sibling's post
lands in the same queue — the cross-core wakeup.

* **Reads and writes** are `WSARecv` and `WSASend` with an `OVERLAPPED`.
* **Accept** is `AcceptEx`, which needs the listener on the port.
* **Connect** is a blocking `connect(2)` on a thread-pool thread.
* **Timeouts** are thread-pool timers, which post their result to the port.
* **`Op_Write` to a standard stream is synchronous.** Overlapped I/O needs a
  handle opened for asynchronous access and a console handle has no overlapped
  mode to ask for, so the write happens in place and the completion is posted.
  `Iour.Text` then behaves the same on both systems.

A socket is associated with a port by whichever shard issues the first
operation on it — which is the shard that will serve that connection for its
whole life, not necessarily the one that accepted it. A per-shard cache keeps
that to one `CreateIoCompletionPort` per socket rather than one per read.

#### Why there is no IoRing here any more

Windows 11 has a real submission ring, and this backend used to use it:
`CreateIoRing` gives a queue the process fills without a system call per
operation and `SubmitIoRing` hands the batch over in one, which is the same
bargain io_uring offers. It carried the data plane while the port carried
accept, connect and timeouts, with the ring's completion event bridged onto
the port by a registered wait so that a shard still had one place to sleep.

It was removed, and the reason is not the one the Linux side would suggest.

The ring's opcodes are read, write, register-files, register-buffers, cancel
and flush — that is the whole list. No accept, no connect, no timeout, nothing
like `MSG_RING`. So the completion port had to exist anyway, and the ring's
only real saving was one system call per *batch* of submissions. Against that
it cost a wakeup: a ring completion signals an event that a shard waits on,
where a port completion is handed to a waiting thread by the I/O manager
directly. It also cost a rule —

> **A socket that has been associated with an I/O completion port cannot be
> read or written through an IoRing.** The builders refuse it with
> `E_INVALIDARG`.

— which is documented nowhere, was established by experiment, and shaped the
whole backend around keeping data sockets off the port. It is why connect was
handed to a thread pool rather than spelled `ConnectEx`: `ConnectEx` needs the
socket on a port, and that socket would then have spent the rest of its life
off the ring for the sake of one call at the start of it.

Both paths were built from one binary and run alternately, rep by rep, so that
machine drift hit both equally — absolute throughput here moves by a third
between batches an hour apart, so only paired readings inside one batch mean
anything.

| | runs the port won | typical |
|---|---|---|
| 1 connection, sequential | 33 of 36 | 32.2k against 41.8k rt/s, and 40% less CPU |
| 100 connections × 1000 | 3 of 5 | 243k against 266k rt/s |
| 500 connections × 200 | 6 of 12 | 141k against 139k rt/s |
| 2000 connections × 100 | 10 of 16 | 229k against 223k rt/s |

A tie once there is enough concurrency to batch, and a clear loss for the ring
at one connection, where there is no batch to amortise and only the wakeup is
left. Nothing in the table justified keeping a second data plane, an
undocumented rule, a thread-pool bridge and a set of entry points resolved by
`GetProcAddress`, so none of them are here.

Removing it was not itself a speedup — measured, the port path is the same
before and after the deletion, 4 paired wins to 2 at 2000 connections and 4 to
4 at one. What it bought is what was around it: a socket may now go on a port
freely, so the accept path has no rule to keep; a shard has one sleep rather
than two and needs no thread-pool bridge between them; and nothing has to be
told by an event that a wakeup has been posted, because the post *is* the
wakeup.

`Iour.Reactor.Ring_Carries_Sockets` still exists and now answers False on
Windows, which is what the echo server prints in its banner:

```
echo_server: Windows IOCP, no ring, one listener, ...
```

Two other differences are visible to a program rather than hidden:

* **There is no `SO_REUSEPORT`.** Windows' `SO_REUSEADDR` is not the same
  thing: a second bind to a live port takes it over rather than joining it, so
  a server that asked for one listener per core would run on one core and look
  like it was running on all of them. `Iour.Net.Port_Sharing_Available` says
  so, and the echo server puts a single acceptor on one core and deals the
  connections it accepts round the others.

* **There are no registered files.** They are an io_uring idea: a table the
  kernel indexes instead of resolving a descriptor, filled by accept and
  referenced by everything after it. Nothing on a completion port takes an
  index in place of a handle, so `Has_Fixed_Files` is False on Windows and
  every descriptor is an ordinary one — which is a path the runtime already
  had for kernels that refuse the registration.

### The context switch

There is no C in this runtime. The one thing no library provides, saving and
restoring a machine context, is GNAT inline `Asm` inside `naked` subprograms —
[SysV](src/arch/x86_64-sysv/iour-ffi-fiber.adb) and
[Win64](src/arch/x86_64-win64/iour-ffi-fiber.adb), one body per calling
convention against one spec. `naked` tells GCC to emit no prologue or
epilogue, so the `Asm` text *is* the function and the stack pointer is exactly
what the caller left.

The design follows [minicoro](https://github.com/edubart/minicoro) closely
enough to be checked against it side by side: registers go in a 64-byte
context buffer rather than on the stack, a two-instruction trampoline receives
the entry point in `r12` and its argument in `r13`, and the initial stack
carries a dummy return address so the entry sees the alignment a `call` would
have left. The switch touches no signal mask, so it costs tens of cycles rather
than the microsecond `swapcontext(3)` spends in `rt_sigprocmask`.

Win64 differs in three ways, and the second is the one that is easy to miss:

* **More registers are callee-saved.** `rdi` and `rsi` are scratch on Linux
  and preserved here, and `xmm6`–`xmm15` are preserved as well — 160 bytes of
  them. A switch that dropped those would corrupt any fiber in the middle of
  vectorised code, which on a modern compiler includes `memcpy`.

* **The thread's stack bounds live in the TEB**, and things read them: the
  stack-probe sequences the compiler inserts for large frames, and the
  unwinder. A fiber runs on a stack the thread's TEB knows nothing about, so
  the switch moves `StackBase`, `StackLimit` and `DeallocationStack` across
  with the registers. This is what boost.context does on the same platform.

* **No red zone, but a shadow store.** A Win64 function may write the
  thirty-two bytes above its return address without allocating them, so `Prime`
  leaves that room where the SysV body leaves the 128-byte red zone.

Both bodies are `SPARK_Mode => Off`; see *SPARK status*. Stacks get a guard
page below them, which is this runtime's addition to the minicoro layout:
`mmap` plus `PROT_NONE` on Linux, `VirtualAlloc` plus `PAGE_NOACCESS` on
Windows — not `PAGE_GUARD`, which arms once and then becomes ordinary memory
and would let the second overrun through silently.

### The switch is proved, even though the assembly cannot be

Inline `Asm` in a `naked` subprogram is not analysable code, so those two
bodies will always be `SPARK_Mode => Off`. Everything the assembly is
*supposed to be*, though, is ordinary Ada, and it lives in
[`Iour.Ffi.Fiber.Machine`](src/arch/x86_64-sysv/iour-ffi-fiber-machine.ads) —
one per ABI, beside its body, `SPARK_Mode => On` and proved.

It is split in two. What every context switch has in common is portable and
lives in [`src/ffi/`](src/ffi/) — the abstract machine
(`Fiber.Frames`), the exchange theorem and the text walk (`Fiber.Target`),
the assembler-text scanner (`Fiber.Text`) and the stack arithmetic
(`Fiber.Layout`). What describes one machine — the locations, their offsets,
the instruction sequence, and the assembler text — is per target.

**`Fiber.Target` is the interface an assembly target implements**, and it
implements it by instantiating it.

> **Instantiation alone checks only profiles.** SPARK will not accept
> contracts on generic formal subprograms — gnatprove rejects every
> instantiation if you try — so the generic cannot state its requirement the
> way an Ada `interface` or a C++ concept would. Nothing about *what*
> `Save_One` must do is enforced by the instantiation itself.

What makes it an interface anyway is that `Target` states the obligation
itself, as the ghost predicates `Save_Obligation` and `Load_Obligation`, and
`Model_Switch`'s body asserts them after every call and is proved **from**
them. So the requirement is written once where a new target's author reads
it, every target is held to the same one rather than merely to one strong
enough for its own instance, and a target that misses it fails at its
instantiation naming the predicate it broke.

That last is checked, not asserted: a stand-in target whose `Save_One`
treats the instruction pointer like any other register — and whose own
postcondition says so, so that it is internally consistent — fails with
`assertion might fail … Save_Obligation`.

Two ideas, from two papers:

* Rutter, *Using a high level language as a cross assembler* (SIGPLAN Notices
  16(2), 1981), is why the instructions are **values rather than characters**.
  A save instruction carries the location it saves, and both its displacement
  and its register name are derived from that one field, so `movq %r14,
  40(%rdi)` — the register at its neighbour's offset, the classic
  context-switch typo — is not expressible.

* Crary, *Toward a Foundational Typed Assembly Language* (POPL 2003), is why
  there is a **theorem rather than a checklist**. TAL states the callee-saved
  convention as a type the callee must hand back unchanged; a context switch
  is that obligation and nothing else. So `Model_Switch`'s postcondition is
  exactly that, quantified over the whole location set:

  ```ada
  Post =>
    (for all L in Location =>
       S.Out_Ctx (L) =
         (if L = L_Rip then Resume_Address else S.Live'Old (L)))
    and then (for all L in Restorable => S.Live (L) = S.In_Ctx'Old (L))
    and then S.In_Ctx = S.In_Ctx'Old;
  ```

  A duplicated offset, a load from the wrong slot and a save that never
  happens all make it false. Dropping `xmm11` from the Win64 switch's
  fifty-nine instructions is an easy mistake and a nearly undebuggable one —
  it corrupts only fibers suspended inside vectorised code, which on a modern
  compiler means inside `memcpy` — and it is caught not by this theorem but
  by `Layout_Tiles_Context`, which requires the offsets to be a chain with no
  holes. That lemma exists because the theorem alone did *not* catch it: a
  register deleted from `Location` outright, with its offset, its template
  lines and its record field, once compiled and proved clean and passed the
  start-up check. Measured, on `r14`.

**What none of it can check** is that `Location` is the ABI's callee-saved
set in the first place, that `Apply` means what the instruction means, or
that `Emit` renders the instruction it names. Those three are trusted input.
The model proves that a *description* of the switch is internally consistent
— layout, coverage, composition, text — and that the assembled text is that
description; it cannot prove the description is right for the machine. The
argument for the arrangement is that what is left trusted is a line each and
reviewable by eye.

The first of the three can at least be cross-checked against something that
is not this model, and it is worth doing because the failure it guards
against is silent rather than loud: a register the switch drops corrupts
data, and faults only if the value happened to be a pointer. GCC emits
`.seh_pushreg` and `.seh_savexmm` only for registers it is *obliged* to
preserve, so two throwaway C functions with enough live values will name the
Win64 callee-saved set without anyone typing it — `rbx`, `rbp`, `rdi`,
`rsi`, `r12`–`r15` and `xmm6`–`xmm15`, which is exactly `Location` minus
`L_Rip`, `L_Rsp`, the two control words and the three TEB fields. Eighteen
of the twenty-five locations, agreed by an oracle that does not derive from
`Location`. That last part is the whole value of it: every other artefact
here does derive from `Location`, so none of them can disagree with it. The
remaining seven are still read off the ABI by a human.

**On stack-based TAL, and what this model does not do.** Behind the POPL paper
is Morrisett, Crary and Glew's *Stack-Based Typed Assembly Language* (JFP
13(5), 2003; TIC '98 before that). It is the closer ancestor of this
particular problem, and worth naming separately, because it is where *both*
halves of a context switch are already typed.

Both halves, and this model takes one of them. First, callee-saved registers
are handled by making the callee **hold their type abstract** and requiring
the same type back at the return — which is `Model_Switch`'s postcondition
read backwards: `Location` is that abstract set, and "hand it
back unchanged" is the whole contract. Second, a **stack type variable** lets
a function be polymorphic in the shape of the stack it was called on and
obliges it to restore that shape before it can jump to its return address.
That second one is what a context switch is: two stacks, each of a shape its
own fiber knows and the switch does not, exchanged without either being
disturbed.

The second half is the one left on the table. `L_Rsp` is one more location
that round-trips, so what is proved is that the stack *pointer* is exchanged
intact — not anything about what is on either stack. A real STAL
typing would carry the frame layout as well, and the switch would be
`∀ρ₁ρ₂`-polymorphic in both. What stands in for it here is much weaker and
much more local: `Return_Slot_Offset` proves the one frame this runtime builds
itself, the initial one, is where the ABI says a fresh frame goes. Every
frame after that is GCC's, and is outside anything proved here. Saying so
matters, because "the context switch is proved" is easy to read as more than
it is: the register file is proved exchanged, and the stack is proved only to
be pointed at.

The `Prime` arithmetic is proved in the same package rather than commented:
`Return_Slot_Offset`'s postcondition is that a fiber's first frame is 8 modulo
16 — the alignment a `call` leaves — that it is above the guard page, and that
the red zone or shadow store above it is inside the mapping.

**What is proved and what is checked.** GNAT requires an `Asm` template to be
a static string, so the emitted text cannot itself be the rendered one: the
template is written out, once, in the model package that the proof is about.
`Emitted_Matches_Model` closes the gap by walking the proved instruction
sequence and comparing its rendering with that constant, character for
character. `Iour.Fibers.Reserve_Contexts` asks it before any shard starts, so
a binary whose assembly and whose proof had drifted apart refuses to run
rather than switching contexts wrongly. `make smoke` reports it, and names the
character where a divergence begins.

### Spawning from SPARK, and why it is a number rather than a pointer

A fiber body reaches the runtime by instantiating a generic, not by handing
over a subprogram pointer:

```ada
procedure Serve (Arg : Fiber_Argument);
package Serve_Job is new Iour.Fibers.Job (Work => Serve);
...
Serve_Job.Spawn_Here (Fiber_Argument (Conn), Started);
```

That shape is forced, and the reason is worth knowing before reaching for
`'Access`. SPARK gives an access-to-subprogram type an implicit
`Global => null` and then allows `'Access` only on a subprogram that meets
it. A fiber body that does any I/O has global effects by definition, so
`Spawn (Handler'Access, ...)` is **rejected outright** —

```
error: access to subprogram with global effects is not allowed in SPARK
```

— and a runtime whose spawn takes a pointer cannot be called from SPARK at
all, for the one thing it exists to do. So `Spawn`, `Spawn_Here` and
`Spawn_On` take a `Job_Id`: a small integer into a table, the same shape as
every other handle here. The one `'Access` in the whole runtime lives in the
private part of `Iour.Fibers.Job`, and that private part is the only
`SPARK_Mode => Off` a consumer's code is ever anywhere near.

`make prove-consumers` is what keeps this true. It proves the echo server,
the echo client, `smoke` and `multi_await` — all four `SPARK_Mode => On`,
and none of them covered by `make prove`, which sees only the library.
`CLAUDE.md` has the full account, including the three Ada rules that shape
the generic.

## Deadlock and data races: what is proved, and what is not

"Written in SPARK" is often taken to mean "proved concurrency-safe". Here is
what that actually amounts to.

**Data-race freedom is checked.** SPARK's concurrency rules are legality
rules — reported by `gnatprove --mode=check_all` and by flow analysis rather
than as unproved checks — and what they establish is that no unsynchronized
object is reachable from two tasks. Everything shared in this runtime is a
protected object, an `Atomic` scalar (one per shard, through
`Iour.Per_Shard` — an array with `Atomic_Components` is *not* itself a
synchronized object, which is why that package holds `Max_Shards` separate
scalars), or a `Synchronous` state abstraction made of those.

**Deadlock freedom is structural rather than proved.** SPARK establishes no
liveness property at all. What holds here is a consequence of the code's
shape, and it rests on four premises, each cheap to re-check:

1. **No protected body calls anything outside itself.** True of all eight —
   the fiber banks, the ready cells, the job registry, the future banks, the
   run queue, the scheduler's control block, the parking barrier and the
   Linux reactor's ring cell. No nested protected call means no
   lock-acquisition cycle, and it also makes "no potentially blocking
   operation inside a protected action" true trivially rather than by
   inspection. This is the property to preserve; nothing in the language
   warns when it breaks.
2. **One priority in the partition.** Every task runs at `Runtime_Priority`
   and every protected object declares it as its ceiling, so under Jorvik's
   ceiling locking there is no ceiling violation possible and no priority
   inversion to invert.
3. **Three entries, all pure barriers.** Two are monotone counters that
   every shard advances exactly once on every path, including the path where
   its ring failed to open — which is why that path counts itself in and out
   rather than simply returning.
4. **One barrier never opens, deliberately**: a surplus or finished shard
   parks there for good, because Jorvik forbids a task body to run off its
   end.

**What neither covers: fibers.** SPARK's concurrency reasoning is about Ada
tasks. A fiber body is reached through the assembly trampoline, so nothing
in SPARK's call graph connects it to a shard task, and gnatprove analyses
the fiber entry point as a subprogram nothing calls. The consequence is
precise and it is a consumer's to act on: **state shared between fiber
bodies is not checked for races.** Fibers on one shard cannot preempt each
other — they switch only at explicit suspension points — so sharing within a
shard is safe by construction. Fibers on different shards genuinely race,
and a program that shares state between them has to synchronize it itself,
the same way the runtime does.

Two smaller gaps belong beside that one. `Ffi.Identity`'s body is `Off`
because SPARK ignores `pragma Thread_Local_Storage` and would model one
per-thread slot as one shared variable — so shard identity, the fact the
whole shared-nothing design rests on, is asserted rather than verified. And
`Iour.Ffi.Fiber.Switch` carries `Always_Terminates`, which its own comment
admits is false for a finished fiber's last switch.

## SPARK status

Every unit is `SPARK_Mode => On` except the platform boundary, which is the
trusted base by design:

| Body | What it holds | Why it's Off |
|---|---|---|
| `Iour.Ffi.Fiber` (per ABI) | the context switch: inline Asm in `naked` subprograms, the slot table, stack mapping | assembly, and addresses of context slots |
| `Iour.Ffi.Memory` | address-of for buffers handed to the kernel | taking addresses |
| `Iour.Ffi.Uring.Memory` (Linux) | atomic ring-word access, SQE/CQE overlays, the timeout backing store | overlays at run-time addresses |
| `Iour.Ffi.Identity` | one thread-local: which shard this thread is | per-thread state SPARK has no model for |
| `Iour.Ffi.Win32` body (Windows) | the two lazily resolved Winsock extension pointers | `Unchecked_Conversion` to access-to-subprogram |
| `Iour.Reactor` (Windows) | the completion-port engine | overlays records on completion-port pointers, and is re-entered from thread-pool threads |
| `Iour.Fibers.Job` (the generic) | one `'Access` per registered fiber body, and the wrappers around it | SPARK forbids `'Access` of a subprogram with global effects, and a fiber body has them |
| `Iour.Fibers.Invoke`'s body | the one indirect call, from job number to fiber body | SPARK models a call through an access-to-subprogram as touching nothing |

`Iour.Ffi.Fiber` is the one of these that has a proved companion rather than
only a proved spec: `Iour.Ffi.Fiber.Machine` states what the assembly is meant
to do and proves it, and the `Off` body is reduced to the `Asm` calls, two
slot addresses and one write through a computed address. See *The switch is
proved, even though the assembly cannot be*.

Every one of these has a reason of the same kind. `Ffi.Win32`'s *spec* is
`On` — every import carries a `Global`, and the two entry points it resolves
at run time are declared as part of `Ffi.Kernel` — so `Ffi.Sys` and `Ffi.Net`
are `On` on Windows exactly as they are on Linux. What stays `Off` there is
the body that does the resolving, because there is no way to turn an address
from `GetProcAddress` into a callable subprogram without
`Unchecked_Conversion`, and the reactor. `CLAUDE.md` has the detail.

One caveat belongs here rather than only next to the code, because it bounds
what "proved" means for the context switch. `Iour.Ffi.Fiber.Target` is the
interface each ABI's model implements, and **instantiating it checks only
profiles** — SPARK does not accept contracts on generic formal subprograms.
The semantics are carried by the ghost predicates `Save_Obligation` and
`Load_Obligation`, which the shared `Model_Switch` asserts after every call
and is proved from. That is what holds every target to the same obligation;
it is a proof obligation, not a language rule, and anyone reworking that
generic has to keep the assertions or the interface silently stops binding.

Both backends are written in SPARK, and `make prove` runs against either. The
Windows reactor is a trusted body in the same sense the context switch is: its spec is in SPARK with full contracts, and every client above it
— the scheduler, the fibers, the sockets — is verified against that spec
rather than through the body.

Every one of these specs is in SPARK with full contracts, and every caller is
verified against them. This is the shape SPARK's own manual prescribes for a
hardware or kernel boundary: hoist each operation the language cannot express
into a subprogram with a SPARK declaration and an Off body, then verify
everything above it. On the Linux side each Off body is a few lines per
subprogram; the Windows reactor is larger, and that is the honest cost of a
backend that has to assemble accept, connect and a timeout out of three
different Win32 mechanisms.

**`make prove`** — full proof of the Linux build, every analysable body
included:

```
Success: all checks proved (1217 checks).

SPARK Analysis results     Total       Flow    Provers   Justified   Unproved
Data Dependencies            139        137          .           2          .
Flow Dependencies             23         23          .           .          .
Initialization               354        354          .           .          .
Run-time Checks              412          .        412           .          .
Assertions                    52          .         52           .          .
Functional Contracts         136          .        136           .          .
Termination                  101         97          4           .          .
```

The same command with `-XIOUR_OS=Windows_NT` proves the other backend, from
either system — it generates no code. Delete `obj/gnatprove` first: the two
configurations share it, and a run that inherits the other one's session
reports a check count several higher than a clean run does.

```
Success: all checks proved (1037 checks).

SPARK Analysis results     Total       Flow    Provers   Justified   Unproved
Data Dependencies             87         86          .           1          .
Flow Dependencies              9          9          .           .          .
Initialization               238        238          .           .          .
Run-time Checks              459          .        459           .          .
Assertions                    49          .         49           .          .
Functional Contracts         118          .        118           .          .
Termination                   77         74          3           .          .
```

**`make prove-consumers`** — the same treatment for the programs that *use*
the library, which is a different question and was never asked until now:

```
Success: all checks proved (1343 checks).
```

That covers the echo server, the echo client, `smoke` and `multi_await`,
every one of them `SPARK_Mode => On`. The first time it ran it found eight
legality errors, three of them the same one: no SPARK program could spawn a
fiber. See *Spawning from SPARK* above.

Zero unproved, zero warnings, zero C — and no data race that SPARK's rules
can see, which is a narrower claim than "no data race" and is spelled out in
*Deadlock and data races* above.

Every justified check is the same one, and it is a consequence of having two
backends behind one spec. `Ffi.Net.Initialize` and `Ffi.Sys.Bind_To_Cpu` both
declare `In_Out => Ffi.Kernel`, because that is the union of what the two
bodies do: the Windows ones call `WSAStartup` and `SetThreadAffinityMask`, the
Linux ones have nothing to prepare and only confirm what the `CPU` aspect
already arranged. `Ffi.Sys.Ignore_Broken_Pipe` is the same trade running the
other way — the Linux body installs `SIG_IGN` for `SIGPIPE` and the Windows
one has no such signal to ignore — which is why the Linux proof carries two
justifications and the Windows proof one. Narrowing a contract to fit the body
that does less would make it wrong for the one that does more, so the
justification says so at each site.

### What the contracts say, and what they cannot

Memory's contracts say what can be said about memory: an address handed to
the kernel is never null, a ring index is inside the ring, a load or store
targets a non-null word. They cannot say that the bytes at an address mean
what the caller believes. That gap is exactly the trust the Off bodies carry,
and it is the same gap every verified kernel interface has.

Two modelling decisions deserve a sentence each:

* **A buffer the kernel fills is an `out` parameter of the trusted body.**
  `Receive` promises to initialise its buffer, but the kernel does the
  writing, invisibly to SPARK. `Ffi.Memory.Of_Output` takes the buffer as
  `out`, so once its address has been handed over SPARK counts it initialised.
  The promise "the kernel writes before the completion arrives" now lives
  where all the other kernel promises live.

* **Nothing that waits on a peer claims `Always_Terminates`.** A `Receive` on
  a socket whose peer never sends does not return, and a contract saying
  otherwise would be false. Reactor operations keep the claim: a flush that
  waits is always backed by an armed timer.

### What the proof says about concurrency, and what it does not

Worth stating plainly, because "a concurrent runtime, proved with SPARK" is
easy to read as more than it is. Three separate claims, of decreasing
strength.

**Data races between tasks are ruled out statically, by construction.** This
is the strongest concurrency result here and it is not a run-time check.
SPARK rejects unsynchronized shared state outright: an object two tasks can
reach must be a protected object, an atomic object, or `Part_Of` a
synchronized abstract state. Everything shared here is one of those —
`Registry`, `Table`, `Cells` and `Engines` are `Abstract_State (… with
Synchronous, External)`, and their mutable interiors are protected types. A
plain global that two shards wrote would have been *rejected*, not merely
left unproved. That class of bug is gone rather than absent.

**One family of deadlocks is unrepresentable, by profile rather than by
proof.** Jorvik forbids nested entry calls, allows one entry per protected
object, and forbids potentially-blocking operations inside a protected
action; ceiling locking does the rest. The classic lock-ordering deadlock
has nowhere to live. That is a structural argument, not a theorem, and a
ceiling violation is a run-time `Program_Error`.

**Deadlock and livelock in general are not proved, and neither is progress.**
SPARK establishes partial correctness and absence of run-time errors. Nothing
here rules out a fiber awaiting a future no one resolves, or every shard
asleep with work outstanding. The runtime is careful about this — see
*Nothing that waits on a peer claims `Always_Terminates`* above — but careful
is not proved.

**And fibers are outside the model entirely.** This is the limit specific to
this design, and the one most worth knowing. SPARK's concurrency reasoning is
about Ada *tasks*. The context switch reaches it as

```ada
procedure Switch (From : C_Long; To : C_Long)
  with Global => (In_Out => Kernel), Always_Terminates;
```

— an ordinary procedure that perturbs some state and returns. SPARK has no
notion that it exchanges stacks, that control resumes in another fiber, or
that a finished fiber's last switch never returns at all. So the data-race
result above is a result about *shards*; the interleaving that fibers create
is invisible to it. In practice fibers on one shard cannot preempt each
other, so the property very likely holds — but it holds by design, not
because anything checked it.

Two smaller gaps in the same direction. `Switch`'s `Always_Terminates` is
false in exactly one case, which its own comment admits and which
`Iour.Fibers` makes safe with a loop that cannot be left. And
`Iour.Ffi.Identity` is analysed as a *different program*: SPARK ignores
`pragma Thread_Local_Storage` and would model the one per-thread slot as one
shared variable, which is why that body is `SPARK_Mode => Off` — so "a shard
knows which shard it is", the fact the whole shared-nothing design rests on,
is asserted rather than verified.

The honest summary: **free of data races in the analysed portion by
construction, free of lock-ordering deadlock by profile, not proved free of
deadlock or livelock, and with fiber-level interleaving outside the model.**
The first clause is more than most concurrent runtimes can say. It is not
"no concurrency bugs".

### Bugs the proof found

Getting to zero meant fixing defects gnatprove found and the compiler did
not: an overflow negating `Io_Result'First`; statistics counters that would
wrap on a long-lived server; free-list cursors whose index arithmetic was
correct but not provably so; an out-of-range shard conversion in the surplus
task declarations; an allocation inside a protected action; an IPv4 parser
that could overflow before checking its bound; a cross-shard wakeup silently
dropped when the submission queue was full; a flush failure that would have
left a shard in a silent hot loop; a ring descriptor conversion that could
fail on a negative value; and memory accesses inside protected operations,
now moved outside the lock. All are fixed in the shipped code.

One toolchain note: GNAT 16.1 crashes (`exp_ch9.adb:8406`) on a
`pragma Warnings (GNATprove, ...)` placed inside a protected body. The
justifications for barrier-only entries are therefore placed around the whole
protected body instead.

## Rules for code built on this runtime

Six constraints are real, and two of them come from Jorvik rather than from
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

**Ask before assuming a listener can be shared.** `Iour.Net.Listen` takes a
`Reuseport` flag, and `Iour.Net.Port_Sharing_Available` says whether it will
do anything. It is True on Linux and False on Windows, and a server that
assumes the wrong one still runs — it just runs on one core. The echo server
shows both shapes.

**Use `Iour.Text.Put_Line`, not `Ada.Text_IO`, inside a fiber.**
`Ada.Text_IO` writes through C stdio and blocks the shard. `Iour.Text` builds
the line on the fiber's stack, hands it to the ring, and suspends only that
fiber. Off a fiber it falls back to a plain blocking write, so it is safe to
call from anywhere.

**Fiber bodies and shared state live at library level.** Jorvik's
`No_Local_Protected_Objects` puts protected objects at library level, and a
job registers itself when its `Iour.Fibers.Job` instance elaborates, so the
instance has to be at library level too -- one that came and went with a
stack frame would leave a dangling entry behind. Application code is
therefore written as library-level packages, with the main subprogram
reduced to starting the runtime and reporting. A main procedure's
declarative part is not library level, so a program that wants to spawn from
`main` puts the instance in a package body and exports a wrapper;
`Echo_Server_App.Start_Acceptor` is that shape.

**State shared between fibers on different shards must synchronize itself.**
This is the one obligation SPARK will not remind you of. Two fibers on the
*same* shard cannot preempt each other — they switch only where the code
says `Await`, `Yield` or an I/O call — so sharing within a shard is safe by
construction, and `Echo_Server_App.Next_Core` is a plain variable for
exactly that reason. Two fibers on *different* shards are two Ada tasks and
genuinely race. But gnatprove cannot see it either way: a fiber body is
reached through the assembly trampoline, so nothing connects it to a task in
SPARK's call graph, and the rules that would catch an unsynchronized shared
variable never fire on it. Use a protected object, or an `Atomic` scalar, or
a promise — the same three things the runtime uses. See *Deadlock and data
races* above.

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
package Worker_Job is new Iour.Fibers.Job (Work => Worker);
...
Done : Future_Ref;
Iour.Promises.Create (Done);
Worker_Job.Spawn (Fiber_Argument (Done), Handle);
Iour.Promises.Await (Done, Result);           --  this fiber sleeps alone

--  in Worker, when finished:
Iour.Promises.Fulfil (Future_Id (Arg), 0);    --  the awaiter resumes
```

`Fulfil` works from any fiber on any shard, and from the environment task. A
wake sent from a shard reaches its target immediately, as a completion put
straight into its stream. The
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

Portable above the line, platform-specific below it. Only `src/os` and
`src/arch` vary with the host, and the project file picks one directory from
each.

```
src/iour.ads                 core types, handles, tunables
src/ffi/                     the portable half of the system interface
  iour-ffi-sys.ads           processes, processors, pages, standard streams
  iour-ffi-net.ads           the synchronous half of sockets
  iour-ffi-inet.ads/.adb     sockaddr_in, byte order, dotted-quad parsing
  iour-ffi-identity.ads/.adb which shard this thread is: SPARK spec, Off body
  iour-ffi-memory.ads/.adb   address-of for the kernel: SPARK spec, Off body
  iour-ffi-fiber.ads         the context-switch spec
  iour-ffi-fiber-target.ads/.adb
                             the exchange theorem and the text walk: the
                             interface an assembly target implements
  iour-ffi-fiber-frames.ads  the abstract machine, over a location set
  iour-ffi-fiber-text.ads/.adb    the assembler-text scanner
  iour-ffi-fiber-layout.ads/.adb  where a fiber's first frame goes
src/runtime/
  iour-reactor.ads           the whole surface onto asynchronous I/O
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
                             -------- picked by host --------
src/os/linux/
  iour-ffi-posix.ads         raw libc: mmap, errno, rlimit, sockets, signals
  iour-ffi-uring.ads         io_uring's kernel ABI, expressed in Ada
  iour-ffi-uring-memory.adb  the mapped rings: SPARK spec, Off body
  iour-reactor.adb           the io_uring submission/completion protocol
  iour-ffi-sys.adb, iour-ffi-net.adb
src/os/windows/
  iour-ffi-win32.ads/.adb    Kernel32, Winsock, the thread pool:
                             SPARK spec, Off body
  iour-reactor.adb           one completion port per shard
  iour-ffi-sys.adb, iour-ffi-net.adb
src/arch/x86_64-sysv/
  iour-ffi-fiber.adb         the context switch: inline Asm, SPARK_Mode Off
  iour-ffi-fiber-machine.ads/.adb
                             one machine described: locations, offsets, the
                             instruction sequence, the text; instantiates
                             Iour.Ffi.Fiber.Target
src/arch/x86_64-win64/
  iour-ffi-fiber.adb         the same, for the Win64 ABI
  iour-ffi-fiber-machine.ads/.adb
examples/                    echo server and client
tests/smoke.adb              runtime self-test
tests/abi_check.c            kernel-ABI conformance, checked at compile time
```

## Building

A GNAT toolchain with SPARK, from Alire; `alr exec` puts it on `PATH`. On
Linux, `liburing` (2.5 here) as well. On Windows, nothing beyond the
toolchain: everything the backend calls is in Kernel32 or Winsock and is old
enough to link against directly, so no Windows SDK is needed to build.

The same commands on either system. The project file reads the `OS`
environment variable, which Windows sets for every process and no Unix does;
`-XIOUR_OS=linux` or `-XIOUR_OS=Windows_NT` overrides it.

```
make examples     # library, server, client
make smoke        # runtime self-test
make demo         # server and client, 2000 connections
make abi-check    # kernel-ABI mirrors vs. this system's headers (Linux)
make bench        # against the Tokio and Go echo servers (Linux)
make check-linux  # compile the Linux backend from anywhere, without running it
make prove        # SPARK proof of everything analysable (expected clean)
```

`make check-linux` is worth knowing about when working on Windows: it
compiles the other backend without generating code, so a change to shared
code that would only break over there is caught before it is pushed. There is
no cross toolchain involved.

The three project files carry `-Wframe-larger-than=16384`, a compile-time
bound on any single stack frame. Fiber stacks are 64 KiB with a guard page
below and nothing is heap-allocated, so an oversized local array is the one
realistic way to overrun one; 16 KiB is a quarter of a fiber stack and fires
on nothing today, the largest frame in the runtime being `Scheduler.Run` at
8432 bytes, on a shard's thread stack rather than a fiber's. It is
deliberately not `-Wstack-usage`, which also warns on dynamically sized
frames and so fires on every subprogram that builds a message out of `&`
and `'Image`.

Run the demo by hand (`.exe` on Windows):

```
./bin/echo_server 9099 2000 &
./bin/echo_client 127.0.0.1 9099 2000 10
```

Windows notes, both about the client rather than the runtime: a run of two
thousand connections consumes two thousand ephemeral ports, and Windows holds
each in `TIME_WAIT` for two minutes, so repeated back-to-back runs at that
size will eventually start failing to connect with `WSAEADDRINUSE`. And the
environment task's `CPU => 1` is ignored there, so start-up and reporting
share a core with a shard.

## Tuning

Everything is in `src/iour.ads` except `Shard_Count`, which the build sets.

| Constant | Default | What it costs |
|---|---|---|
| `Shard_Count` | 4 | One pinned thread and one ring each; set with `-XIOUR_SHARDS=<n>` |
| `Max_Shards` | 8 | Task declarations in `Iour.Shards` |
| `First_Shard_Cpu` | 1 | Ada CPU of shard 0, shared with the environment task |
| `Max_Futures` | 16384 | Concurrent unresolved futures |
| `Max_Fibers` | 4096 | Ceiling on concurrent tasks |
| `Fiber_Stack_Bytes` | 64 KiB | Memory per *live* fiber; stacks are mapped lazily and recycled |
| `Ring_Entries` | 4096 | Submission queue depth per shard |
| `Idle_Poll_Nanos` | 1 ms | Base of the idle backoff, which doubles to 128 ms |

Raising `Shard_Count` above `Max_Shards` is a compile-time error. Adding shards
past 8 means adding task declarations to `Iour.Shards`, because Jorvik requires
each CPU to be static.

`Shard_Count` is chosen by the build rather than by editing a source file,
because it must reach Ada as a *static* constant — the CPU aspects, and the
`Active_Shard` subtype, both need it at compile time — and a GPR external is a
string the project file can see and Ada cannot. So the project selects one of
the `src/config/shards-<n>` directories, each holding one declaration of
`Iour_Config` with a different value.

### Shards past `Shard_Count`

`Iour.Shards` declares `Max_Shards` tasks however many shards are actually
wanted, because the profile gives no way to declare a variable number of them.
The surplus ones **disable themselves**: `Scheduler.Run` returns immediately
for any index `>= Shard_Count`, and `Serve` then parks the task forever on a
barrier that never opens. Such a shard burns no CPU, owns no ring, and reaps
no completions. The park is deliberate rather than a fall-through — Jorvik's
`No_Task_Termination` makes running off the end of a task body a bounded
error.

There is one thing a surplus shard cannot opt out of, and it used to bite. A
task's CPU aspect is elaborated when the task is created, which happens before
any of this runtime's own code runs — before `Scheduler.Run` is reached and so
before anything can decide the shard is surplus. Asking for a core the machine
does not have raises `TASKING_ERROR` there, and the whole process dies at
start-up. With eight declarations that meant **a four-shard build demanded
eight cores merely to elaborate**.

So the index is folded back into the range that is actually in use:

```ada
task Shard_5
  with CPU => First_Shard_Cpu + (5 mod Shard_Count),
       Priority => Shard_Priority;
```

A surplus shard is pinned to a core an active shard already owns, which it
will never contend for because it parks immediately, and `mod` keeps the
expression static as the aspect requires. The runtime therefore needs exactly
`First_Shard_Cpu + Shard_Count - 1` cores to exist — with `First_Shard_Cpu` at
1, exactly `Shard_Count` of them.

This cannot show up on a machine with more cores than `Max_Shards`, which is
why it went unnoticed: it was found on an emulated aarch64 guest, where the
core count is whatever qemu was told to provide.

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
