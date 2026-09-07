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
  thread-to-core map checkable at compile time.

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

The package holds the machine locations the switch owns as a type, their
offsets, the instruction sequence as data, an abstract machine, and the exact
assembler text. Two ideas, from two papers:

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

  A dropped register, a duplicated offset, a load from the wrong slot and a
  save that never happens all make it false. Dropping `xmm11` from the Win64
  switch's fifty-nine instructions is an easy mistake and a nearly
  undebuggable one — it corrupts only fibers suspended inside vectorised code,
  which on a modern compiler means inside `memcpy`.

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
Success: all checks proved (1161 checks).

SPARK Analysis results     Total       Flow    Provers   Justified   Unproved
Data Dependencies            131        129          .           2          .
Flow Dependencies             23         23          .           .          .
Initialization               346        346          .           .          .
Run-time Checks              392          .        392           .          .
Assertions                    50          .         50           .          .
Functional Contracts         125          .        125           .          .
Termination                   94         90          4           .          .
```

The same command with `-XIOUR_OS=Windows_NT` proves the other backend, from
either system — it generates no code. Delete `obj/gnatprove` first: the two
configurations share it, and a run that inherits the other one's session
reports a check count several higher than a clean run does.

```
Success: all checks proved (974 checks).

SPARK Analysis results     Total       Flow    Provers   Justified   Unproved
Data Dependencies             78         77          .           1          .
Flow Dependencies              9          9          .           .          .
Initialization               230        230          .           .          .
Run-time Checks              435          .        435           .          .
Assertions                    47          .         47           .          .
Functional Contracts         106          .        106           .          .
Termination                   69         66          3           .          .
```

Zero unproved, zero warnings, zero data races, zero C.

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
                             what that assembly is supposed to be, in
                             SPARK: locations, offsets, the instruction
                             sequence, the exchange theorem, the text
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

Everything is in `src/iour.ads`.

| Constant | Default | What it costs |
|---|---|---|
| `Shard_Count` | 4 | One pinned thread and one ring each |
| `Max_Shards` | 8 | Task declarations in `Iour.Shards` |
| `First_Shard_Cpu` | 2 | Ada CPU of shard 0; CPU 1 is left to the environment task |
| `Max_Futures` | 16384 | Concurrent unresolved futures |
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
