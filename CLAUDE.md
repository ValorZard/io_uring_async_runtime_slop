# Working on this repo

A thread-per-core async runtime in Ada 2022 / SPARK under the Jorvik profile,
over `io_uring` on Linux and **I/O completion ports** on Windows. Stackful
fibers, no heap, no access types, no C. Read `README.md` first for the design;
this file is what a session needs to *change* it without relearning things the
hard way.

Most of what follows was established by experiment on this machine, not read in
documentation. Where that is true it says so, because the documentation does not
say it and in a few places implies the opposite.

---

## Commands

```
make examples        # library + echo server/client        (both systems)
make smoke           # runtime self-test
make multi-await     # await/handover test
make demo            # traced walkthrough, then 2000 connections
make check-linux     # compile the Linux backend from anywhere, no codegen
make prove           # SPARK proof
make abi-check       # io_uring UAPI mirrors vs headers    (Linux only)
make bench           # vs tokio and Go                        (both systems)
```

The project file picks the backend from the `OS` environment variable, which
Windows sets for every process and no Unix does. Override with
`-XIOUR_OS=linux` or `-XIOUR_OS=Windows_NT`.

**Always run `make check-linux` before finishing a change to shared code.** It
compiles the *other* backend without generating code, needs no cross toolchain,
and catches everything that would only break over there. Use `--subdirs=` so it
does not clobber the real object directory:

```
alr exec -- gprbuild -P examples.gpr -XIOUR_OS=linux --subdirs=crosscheck \
  -j0 -c -f -cargs -gnatc
```

`gnatprove` also runs against the Linux backend from Windows — it generates no
code either:

```
alr gnatprove -P io_uring_async_runtime.gpr -XIOUR_OS=linux --mode=all --level=3 -j0
```

Current state: **962 checks proved, 0 unproved, 2 justified.** The two
justifications are `unused global "Ffi.Kernel"` on `Ffi.Net.Initialize` and
`Ffi.Sys.Bind_To_Cpu`, whose contracts are the union of what the two backends do
and whose Linux bodies do less. Do not "fix" them by narrowing the contract.

---

## The one seam

`Iour.Reactor` is the only platform-dependent package. Everything above it —
scheduler, fibers, futures, sockets, timers — compiles unchanged on both. Keep
it that way.

```
src/ffi/            portable system interface: Sys, Net, Inet, Identity,
                    Memory, and the Fiber spec
src/runtime/        scheduler, fibers, futures, run queue, promises, text, trace
src/net/            asynchronous sockets
src/os/linux/       io_uring reactor, raw libc (Ffi.Posix), the mapped rings
src/os/windows/     completion-port reactor, Win32/Winsock (Ffi.Win32)
src/arch/x86_64-sysv/    context switch, SysV ABI
src/arch/x86_64-win64/   context switch, Win64 ABI
```

`Op_Spec` is platform-neutral by design: a kind, a descriptor, a buffer, a
token. Adding an operation means adding an `Op_Kind` and handling it in **both**
reactor bodies. `Op_Timeout` takes the interval **by value** — io_uring wants a
`struct __kernel_timespec` that outlives submission, and the Linux backend
stages one itself, indexed by submission slot.

---

## Windows: a completion port, and the ring that used to be here

One completion port per shard. Everything the backend does either is an
overlapped Win32 call the kernel completes onto that port, or is finished
here and announced on it with `PostQueuedCompletionStatus`. One place to
look, one place to sleep, and `GetQueuedCompletionStatusEx` is the wait, the
batch collection and the cross-shard wakeup in a single system call.

| operation | how |
|---|---|
| recv / send | `WSARecv` / `WSASend` with an `OVERLAPPED` |
| accept | `AcceptEx`, which needs the listener on the port |
| connect | blocking `connect(2)` on a thread-pool thread |
| timeout | thread-pool timer, whose callback posts to the port |
| write to a standard stream | synchronous `WriteFile`, plus a posted completion |

**A socket is associated with a port by the shard that issues its first
operation**, not by the shard that accepted it. Where the port cannot be
shared there is one acceptor dealing connections round the cores, so those
two are usually different; associating at accept time sent three quarters of
a server's completions to a shard with no fiber waiting for them, and the
entry was then resolved against the wrong shard's slot table. A per-shard
direct-mapped cache keeps the association to one call per socket rather than
one per read; it is a cache, so a collision costs a redundant call and
nothing else, and `Kind_Close` clears the entry before Windows can hand the
same handle number out again.

### There was an IoRing here. Do not put it back without reading this.

Windows 11 has a real submission ring, and this backend used it for the data
plane until 2026-09-05. The removal was measured, not assumed, and the
measurement is the opposite of what the Linux side would suggest.

IoRing's opcodes are read, write, register-files, register-buffers, cancel
and flush. **That is the whole list**: no accept, no connect, no timeout,
nothing like `MSG_RING`. So the completion port had to exist anyway, the
ring's only real saving was one system call per *batch* of submissions, and
against that it cost a wakeup — a ring completion signals an event a shard
waits on, where a port completion is handed to a waiting thread by the I/O
manager directly.

Both paths built from one binary, run alternately rep by rep:

| | runs the port won | typical |
|---|---|---|
| 1 conn, sequential | 33 of 36 | 32.2k against 41.8k rt/s, 40% less CPU |
| 100 × 1000 | 3 of 5 | 243k against 266k rt/s |
| 500 × 200 | 6 of 12 | 141k against 139k rt/s |
| 2000 × 100 | 10 of 16 | 229k against 223k rt/s |

A tie under concurrency; a clear loss for the ring at one connection, where
there is no batch to amortise and only the wakeup is left.

Deleting it was not itself a speedup — the port path measures the same before
and after the deletion, 4 paired wins to 2 at 2000 connections and 4 to 4 at
one. What went with it is the point:

- **The rule.** A socket associated with a completion port cannot be read or
  written through an IoRing; the builders refuse it with `E_INVALIDARG`. That
  is documented nowhere, was established here by experiment, and shaped the
  entire backend around keeping data sockets off the port.
- **The bridge.** A shard had two things to sleep on, so the ring's
  completion event was bridged onto the port through
  `RegisterWaitForSingleObject` — two extra thread wakeups per completion —
  armed lazily and stickily, because the event is auto-reset and the bridge
  and a direct wait could not both have it.
- **The wake events.** Anything posting to a port also had to `SetEvent` the
  target, or a shard asleep on its ring would not hear it. With one place to
  sleep, the post *is* the wakeup.
- **`GetProcAddress`.** Seven entry points resolved by name, because the
  toolchain's Kernel32 import library predates them and because a binary that
  imported them would not start on Windows 10.

The facts below were established by experiment while the ring was here. They
are kept because they are the evidence for the removal, and because anyone
tempted to reinstate it will re-derive them otherwise.

1. **IoRing reads and writes Winsock sockets**, despite being documented as a
   file API. A `WSA_FLAG_OVERLAPPED` socket is a handle to `\Device\Afd` and
   `BuildIoRingReadFile` / `BuildIoRingWriteFile` work on it.
2. **A socket associated with a completion port cannot be read or written
   through an IoRing** — `E_INVALIDARG` (`0x80070057`). It is the port
   association, not `AcceptEx`, not `SO_UPDATE_ACCEPT_CONTEXT`.
3. **An `AcceptEx`'d socket works through the ring** provided the accepted
   socket is never itself bound to a port.
4. **A socket can be read through a different shard's ring** than the one
   whose port accepted it. Handle refs are raw handles; rings are not owners.
5. Reading a closed socket returns `E_HANDLE` (`0x80070006`).
6. On this machine: `MaxVersion` 400 (`IORING_VERSION_4`), `MaxSq` 65536,
   `MaxCq` 131072, features `0x2` = `SET_COMPLETION_EVENT`. Feature bit
   `0x1` (`UM_EMULATION`) is clear, so this was real kernel support and the
   measurements above are not of an emulation.
7. `IORING_OP_REGISTER_FILES` **replaces the whole table** on every update,
   with link semantics — useless for churning connections, and it is accept,
   which the ring has no opcode for, that would have to fill it.

`Has_Fixed_Files` is `False` on Windows and always was. Registered files are
an io_uring idea; nothing on a completion port takes an index in place of a
handle.

### Win32 ABI details that bite

- `OVERLAPPED_ENTRY` needs an explicit representation clause. It is 28 bytes of
  fields with 4 bytes of tail padding; without a rep clause the array stride is
  wrong and every entry after the first is misread.
- An `OVERLAPPED` must be the **first component** of the record the slot pool
  hands out, because the port gives back the address of that field and the
  slot is recovered by treating it as the address of the whole record. `Open`
  checks the two coincide rather than trusting the layout silently.
- The status of a completed overlapped operation is the NTSTATUS the I/O
  manager left in the `OVERLAPPED`'s `Internal` field, not anything the port
  reports; the port reports only the byte count.

These were also true, and are kept for anyone reinstating the ring:

- `IORING_CREATE_FLAGS` is an 8-byte struct of two `UINT32`s, passed **in one
  register**. Declare the Ada parameter as `Unsigned_64` (low word = required,
  high word = advisory). Two separate `Unsigned_32` parameters would use two
  registers and be wrong.
- `IORING_HANDLE_REF` and `IORING_BUFFER_REF` are 16 bytes, which Win64 passes
  **by address**. Declare those parameters as `System.Address` and pass
  `'Address` of an aliased local.
- IoRing entry points live in **`kernelbase.dll`** and have to be resolved
  with `GetProcAddress`; the GNAT toolchain's Kernel32 import library predates
  them.

---

## Windows platform facts

**GNAT for Windows accepts Ada's `CPU` aspect and ignores it.** Tasks float
across every core. Verified with a standalone two-task program. This is why
shard identity is a thread-local (`Iour.Ffi.Identity`) rather than
`sched_getcpu` arithmetic, and why `Iour.Fibers.Claim_Core` binds the thread
itself with `SetThreadAffinityMask`. Pinning is a performance measure; identity
does not depend on it. The environment task's `CPU => 1` is ignored too.

**`listen()` backlog: pass `SOMAXCONN` (`0x7FFFFFFF`), not a number.** Windows
clamps an explicit backlog to a system maximum that is **200 on client
editions**. Asking for 4096 and being given 200 refused 26–66% of a thousand
simultaneous connects. `SOMAXCONN` means "the largest this provider will give".
Measured: 735–1000 of 1000 succeeding before, 1000 of 1000 across five runs
after.

**`shutdown()` on a listening socket cancels nothing.** On Linux it is what
makes a pending `accept` give up, and `Iour.Ffi.Net.Shutdown`'s contract says
so. Windows has no directions to half-close on a listening socket and returns
`WSAENOTCONN` having done nothing, so acceptors sat in `AcceptEx` for ever
and the process took the scheduler's whole drain bound to exit — sixty-four
seconds with 32 acceptors pending. The Windows body now falls through to
`CancelIoEx` when `shutdown` refuses; the pending accepts complete with
`ERROR_OPERATION_ABORTED`, which is what the acceptors already read as
"stop". Shutdown went from 64s to under one.

**No `SO_REUSEPORT` equivalent.** Windows `SO_REUSEADDR` lets a second bind
*take over* the port rather than join it, so a server that assumed otherwise
would run on one core and look like it was running on all of them.
`Iour.Net.Port_Sharing_Available` returns `False` there and
`Echo_Server_App` puts one acceptor on one core and deals connections round the
others. Do not add `SO_REUSEADDR` to the Windows listener.

**No per-process handle limit worth raising.** The ceiling is 16,777,216, set by
the kernel; `Raise_Descriptor_Limit` reports it.

**No SIGPIPE**, so `Ignore_Broken_Pipe` is a null procedure and the guarantee
holds for free.

Windows handle values are small (a few hundred at most in practice), so they fit
in `Descriptor` well below `Fixed_File_Base` (2^30). `Ffi.Net.As_Descriptor`
checks rather than assumes.

---

## The Win64 context switch

`src/arch/x86_64-win64/iour-ffi-fiber.adb`, against the same spec as the SysV
one. Three differences, and the middle one is easy to miss:

- **More callee-saved registers.** `rdi` and `rsi` are scratch on Linux and
  preserved here, and `xmm6`–`xmm15` are preserved as well — 160 bytes.
  `mxcsr` and the x87 control word too. Dropping the vector registers corrupts
  any fiber in the middle of vectorised code, which on a modern compiler
  includes `memcpy`.
- **TEB stack bounds move with the registers**: `gs:0x08` `StackBase`,
  `gs:0x10` `StackLimit`, `gs:0x1478` `DeallocationStack`. Compiler stack probes
  and the unwinder read them. boost.context does the same on this platform.
- **No red zone, but a 32-byte shadow store.** `Prime` leaves that room where
  the SysV body leaves 128 bytes of red zone. First argument is `rcx`, not
  `rdi`.

The context record is 272 bytes with an explicit rep clause and a
`Compile_Time_Error` guarding it. `pragma Machine_Attribute (X, "naked")` works
on x86-64 with this GCC.

Fiber stacks: `VirtualAlloc` + `PAGE_NOACCESS` guard page. **Not
`PAGE_GUARD`** — that arms once and then becomes ordinary memory, letting the
second overrun through silently.

---

## SPARK_Mode is On unless it cannot be

**Everything that CAN be proven with `SPARK_Mode => On` SHOULD be set to
`SPARK_Mode => On`.** This is the rule the rest of this section serves.

`Off` is not a convenience, and it is not the default for "code that talks to
the kernel" — the Linux `Ffi.Sys`, `Ffi.Net` and `Iour.Reactor` are all `On`
and all talk to the kernel. `Off` is a claim that the *language* cannot
express what a body does, and each one enlarges the trusted base that the
other 961 checks rest on. A new body starts `On`. If it will not prove, the
thing to change is the body, not the aspect.

Before writing `Off` anywhere, establish that `On` is impossible, and do it by
experiment rather than by expectation:

```
alr gnatprove -P io_uring_async_runtime.gpr --mode=check_all -j0 -U
```

`--mode=check_all` is the cheap question: SPARK legality only, seconds rather
than the minutes `--mode=all` takes. If it passes, `Off` was not needed.

Two outcomes look similar in the log and mean opposite things:

- **A hard error** — `E0001`, `E0002` and friends — means the construct is
  outside SPARK. That is a real reason for `Off`.
- **`assumed-global-null` is not a pass.** It means gnatprove could not see
  what a subprogram touches and assumed it touches nothing. Flipping a spec to
  `On` and collecting these makes the proof claim *more* than it should:
  everything above is then verified against a kernel call modelled as pure. An
  import gets a truthful `Global` before its callers go `On`, the way all
  twenty of `Ffi.Posix`'s do.

`Off` goes on the **smallest unit that needs it**. A package body may be `On`
with `SPARK_Mode => Off` on the individual subprograms that need it, and that
is preferred whenever it leaves anything analysed. The four below are
whole-body only because in each case every subprogram in the body fails.

### Why the Linux trusted base is exactly these four

Rechecked by flipping each to `On` and recording what came back. Do not retry
them expecting a different answer:

* `Ffi.Fiber` (per ABI) — inline `Asm` in `naked` subprograms, which is not
  analysable code at all.
* `Ffi.Memory` — `E0002`, `'Address` outside an attribute definition clause,
  on three of its four subprograms.
* `Ffi.Uring.Memory` — `E0002` again, and `E0001` effectively volatile object
  not at library level for the atomic ring words.
* `Ffi.Identity` — legality passes, and the result is wrong. See below.

`Ffi.Memory.Advance` is the near miss, and it looks like a gap when it is not.
It takes no address — it is `Base + Storage_Offset (By)` — and it is legal
SPARK. Analysed, it yields exactly one *unprovable* check: its postcondition
`Advance'Result /= System.Null_Address`. SPARK does not axiomatise
`System.Address` arithmetic, so nothing constrains the result and nothing ever
will. `On` buys a permanently unproved check or a third justification, so it
stays with the other three, where that postcondition is a promise about memory
rather than a proof obligation.

`Ffi.Identity` is the one to be careful with, because `check_all` **passes**
it. The body is legal SPARK. It is simply not the same program: SPARK ignores
`pragma Thread_Local_Storage` (`ignored-pragma`) and models the one per-thread
slot as one shared variable, so `On` would prove a single-slot runtime this is
not. `Current` is declared `Global => null` because it is a question about the
*calling thread*, and per-thread state is something SPARK has no model for.
Legality is necessary and not sufficient; the question is always whether the
analysed program is the one that runs.

### Windows is not at this standard, and this is the gap

`Ffi.Win32` (spec **and** body), `Ffi.Sys`, `Ffi.Net` and `Iour.Reactor` are
all `Off` on Windows, where the Linux `Ffi.Sys` and `Ffi.Net` are `On`. Only
the reactor has a reason of the Linux kind. Both checks run against the
Windows configuration from Linux — neither generates code:

```
alr gnatprove -P io_uring_async_runtime.gpr -XIOUR_OS=Windows_NT \
  --mode=check_all -j0 -U
alr exec -- gprbuild -P examples.gpr -XIOUR_OS=Windows_NT \
  --subdirs=wincheck -j0 -c -f -cargs -gnatc
```

Measured that way: with the `Ffi.Win32` spec flipped to `On`, legality passes,
`Ffi.Net` is four errors from `On` (three `'Access`-with-ownership, one
`'Address`) and `Ffi.Sys` two, one of each. That is the tempting version of
this change and it is the unsound one — it also raises `assumed-global-null`
warnings, because not one of Win32's imports carries a `Global`.

Doing it properly is gated on a design change rather than an annotation pass:
the lazily-resolved entry points are mutable package-level
access-to-subprogram variables, and sound `On` needs them declared as an
`Abstract_State`, the loader declared to write it, every accessor to read it,
and a truthful `Global` on each import.

**Removing the IoRing shrank that job by most of its size, and nobody has
gone back to it.** It used to be nine such variables and five flags beside
them — `AcceptEx`, `ConnectEx` and seven IoRing entry points, with
`Ioring_Available` and the rest reading the flags back. It is now two
variables (`Accept_Ex_Ptr`, `Connect_Ex_Ptr`), one flag
(`Extensions_Missing`), and 34 imports rather than 38. That is a small enough
surface to be worth attempting; the four packages stay `Off` together until
someone does, because the spec is what everything above is verified against
and a half-done version claims more than it proves.

## Ada / GNAT / SPARK things hit in this codebase

- A `Side_Effects` function **may not be an expression function**.
- `Unsigned_32'Mod (X)` is valid; `Hresult'Mod (X)` is not — `'Mod` needs a
  modular *target*. Reinterpret to a signed type arithmetically.
- A record's `'Size` is **not static**, so it cannot appear in a named-number
  declaration. Use a typed constant plus a `Compile_Time_Error`.
- **Anonymous arrays are not allowed as record components.** Name the type.
- **`C_Long` is 32-bit on Windows** (LLP64) and 64-bit on Linux. Range guards
  that are live on one are provably dead on the other; keep them and silence the
  warning locally rather than deleting them.
- GNAT proves `X + 1` statically out of range when `X`'s subtype is `0 .. 0`,
  even on a branch that cannot run. Count in the base type and wrap:
  `(Integer (X) + 1) mod N`. This bit the acceptor's round-robin at
  `Shard_Count = 1`, which only the benchmark's variant builds exercise.
- For a portable spec whose two bodies have different effects, give the spec the
  **union** and justify the weaker body with
  `pragma Annotate (GNATprove, Intentional, "unused global ...", "...")`.
- `Convention => Stdcall` is the same as `C` on x64; it is used in `Ffi.Win32`
  for documentation value.
- Overload the same name across unrelated things and the prover's diagnostics
  become unreadable. `Fill_Sqe` is named apart from `Encode` for that reason.

---

## The benchmark

`scripts/bench.sh` runs on both systems. Everything platform-dependent is in one
"Platform" section near the top; the stages are the same code on both.
`make bench` invokes it on both systems. Windows lacks the Linux fairness
controls (`taskset`, `ip_local_port_range`, `ListenOverflows`), so read its
Windows caveats before comparing numbers across systems.

`bench/runwait` is a small Go program that replaces `/usr/bin/time -f '%U %S
%M'`. It exists because of two traps:

- **Bash's `time` builtin reports zero user time for native Windows children**
  under MSYS. A program that burns a core for 1.5s is recorded at `0.000`.
- **Prefixing a command with `env` makes `env` the measured process.** Windows
  has no `exec`, only spawn, so the real command is `env`'s child and its CPU is
  never counted. `runwait` takes `NAME=VALUE` prefixes itself for this reason.
  This produced a nonsensical 0.08 µs/round-trip reading before it was found.

`RUNWAIT_TIMEOUT_S` bounds the child. The timeout must live inside `runwait`
because only it holds a handle on the child; a `timeout` outside would kill the
wrapper on Windows and orphan a server still holding the port. Without it, a
server whose accept queue overflowed waits for connections that never arrive and
hangs the whole run.

### Measurement traps

- **A stale variant build is the worst of these, because it is silent.**
  `scripts/bench.sh` builds one copy of the runtime per `Shard_Count`, and
  per client pinning, under `bench/build/`. It used to reuse any directory
  that was already there. A run after a source change then measured the
  previous run's binaries for the entire scaling stage and for the Ada
  client the whole matrix uses, and reported them as current. Fixed by
  comparing mtimes, but check `bench/build/*/bin/*.exe` timestamps against
  the source before believing a variant row, and read the server banner in
  the saved log: it names the backend, and an old binary names an old one.
- **`RUNWAIT_TIMEOUT_S` must be in `runwait`'s own environment**, not in the
  `NAME=VALUE` prefixes it forwards to the child. Passed as a prefix it bounds
  nothing, and a server that never reaches its connection target then holds
  the port until something kills it by name.
- **A server with a connection target hangs when the client loses sessions**,
  because the target is a count of *completed* connections. That is a
  benchmark artifact, not a runtime fault; bound the server and treat the run
  as failed rather than reading its throughput.

- **Windows charges CPU on the 15.6 ms scheduler tick.** A process that blocks
  between short bursts is systematically under-charged, and short runs quantise
  badly. Use ≥ 50,000 round trips for CPU comparisons, not the harness default
  of 5,000.
- **Ephemeral ports.** Repeated 2000-connection runs exhaust them and produce
  spurious `WSAEADDRINUSE` connect failures that look like a runtime bug. On
  this machine `TIME_WAIT` drains in ~30 s (not the documented 120) and the
  dynamic range is 1024–65534. The harness's `drain` waits for it.
- **Never rebuild binaries while a benchmark is running.**
- Restarting a server needs the previous one gone *and* the new one's
  `listening on port` line seen. A fixed `sleep 1` is not enough and produces
  all-connections-failed runs that look like regressions.
- `netstat -an | grep -c TIME_WAIT` takes ~60–100 ms;
  `Get-NetTCPConnection` takes ~3 s. Use netstat.
- MSYS `taskkill` needs doubled slashes: `taskkill //F //IM foo.exe`.

### Start-up races: fixed, and what they were hiding (2026-09-05)

Two once-only initialisers in the Windows backend set their "done" flag on
entry rather than on completion, and every shard calls them the instant its
task activates — library-level tasks, so they are running before the
environment task's first statement. Whichever shard arrived second saw
"already loaded", found `Ioring_Available` still `False`, and quietly took
the Windows 10 fallback path while its siblings used the ring.

A **mixed configuration is worse than either path alone**. A shard on the
fallback associates the sockets it accepts with its own completion port, and
a socket that has been on a port can never afterwards be read through an
IoRing; with connections dealt round the cores, most of them then landed on a
shard that could not touch them. Measured at 2 start-ups in 12 before the
fix, 0 in 15 after.

**Every intermittent result in the run below is suspect for this reason** --
though not all of them were this, and the section after next says which. The
guards now test the *result* (`Available`, or both extension pointers
non-null) rather than whether anyone has started, so a racing caller does the
work again and both get the right answer. Never guard a once-only initialiser
on having begun.

Both of those loaders were IoRing-related, and one of them went with the
ring; `Load_Socket_Extensions` is the one left, and its guard is written out
at length in `Ffi.Win32` because it is the shape that is easy to get wrong.

### The 2026-09-04 run: both of its conclusions were wrong

`bench/results/20260904-232732` reported three things. They have different
fates and it is worth being precise about which.

**"More shards did not increase throughput" -- 81.7k on one core, 83.5k on
four, 78.8k on eight -- was measuring the load generator, not the server.**
The scaling stage drives every server with the same Tokio client, and on
2026-09-05 that client held all three runtimes to 78-89k round trips a second
at every core count:

```
             1 core   2 cores  4 cores  8 cores
ada           82.0k    84.5k    87.4k    83.7k
go            87.6k    84.5k    88.4k    88.8k
tokio         78.5k    84.0k    81.9k    84.2k
```

Go and Tokio do not scale on that stage either, which is the tell. The stage
is still worth running -- as a CPU-per-round-trip comparison at a fixed
offered load it is the most useful thing in the report, and it puts the Ada
server at 8.9 us of server CPU per round trip on one core against Go's 8.8
and Tokio's 11.9 -- but no scaling conclusion can be drawn from it. The Ada
server reaches 269k against the Ada client on the same machine, so it is not
sitting at 85k because it cannot go faster.

**"The two-core variant lost exactly 1,000 of 2,000 sessions" was the
start-up race, and is fixed** -- but it appeared to reproduce on 2026-09-05,
and how that happened is the more useful lesson. `build_variant` reused any
variant directory that already existed, so the scaling stage ran the
*previous day's* binaries. The row that looked like a live bug was the old
racy build, and it said so in its own banner: `Windows IoRing, NOT carrying
connections -- fallback path` -- a string the current code cannot print.
`build_variant` now compares mtimes and rebuilds; see *Measurement traps*.

**The intermittent failures elsewhere in that matrix were the same race**,
and are gone.

### Measured, 2026-09-05

All of these are paired: two builds alternating rep by rep against one
client, compared only within a batch. Absolute numbers on this machine drift
by a third between batches an hour apart, so a number from one table must not
be held against a number from another.

**The session's changes, against the commit they started from.** Ada client,
4 shards, server on CPUs 1-4 and client on 9-12:

| | before | after |
|---|---|---|
| 2000 conn × 100 | 165.5k rt/s, 5 of 6 runs valid | **225.1k**, 6 of 6 |
| 500 conn × 200 | 128.1k rt/s, 5 of 6 runs valid | **139.7k**, 6 of 6 |
| 1 conn × 20000, unbounded server | 33.0k rt/s | **49.0k**, 6 paired wins of 8 |

Two earlier batches put the throughput comparison at 161.5k against 225.5k
and 127.9k against 142.6k. The gain at 2000 connections has been 31-40% in
every batch, and at 500 connections 5-11% -- that workload is partly limited
by the Ada client rather than by the server.

The "runs valid" column matters as much as the throughput. A run that loses
sessions is not a slow run; it is not a result. Before the fixes one run in
five or six was one.

**The ring against the port**, one binary, `IOUR_WINDOWS_IO=iocp` selecting
between them:

| | ring | port | paired wins |
|---|---|---|---|
| 2000 × 100 | 228.7k rt/s, 2.54s CPU | 223.5k, 2.50s | ring 4, port 2 |
| 500 × 200 | 141.2k rt/s, 1.16s CPU | 138.6k, 1.07s | 3 - 3 |
| 1 × 20000 | 32.2k rt/s, 0.47s CPU | 41.8k, 0.27s | ring 1, **port 7** |

**Deleting the ring, against merely not using it** -- the port path before
and after the code came out:

| | ring code present | ring code gone | paired wins |
|---|---|---|---|
| 2000 × 100 | 239.9k rt/s | 235.6k | kept 4, gone 2 |
| 1 × 20000 | 41.5k rt/s | 41.5k | 4 - 4 |

So the removal is a simplification, not a speedup, and should be described
that way. The throughput came from the start-up race, the acceptors and the
shutdown path; the latency came from choosing the port over the ring.

### The full suite, 2026-09-05 (`bench/results/20260905-noring`)

`BENCH_REPS=2`, scales 500x200 and 2000x100, everything rebuilt. Medians;
a row that lost sessions is marked and is not a throughput figure.

Holding the client constant, which is what the cross pairings are for:

| load | client | Ada srv | Go srv | Tokio srv |
|---|---|---|---|---|
| 2000x100 | Ada | **274,495** | 142,667 | 136,848 |
| 2000x100 | Go | **245,611** | lost 1849 | lost 300 |
| 2000x100 | Tokio | **142,270** | 135,306 | 129,613 |
| 500x200 | Ada | **155,721** | 137,458 | 105,669 |
| 500x200 | Go | **281,411** | lost 65 | lost 59 |
| 500x200 | Tokio | **142,566** | 142,335 | 139,508 |

The Ada server leads every valid comparison, and under the Go client it is
the only one of the three that completes every session.

Server CPU per round trip is the number to watch rather than throughput:
Ada 11.2-12.5 us, Go 9.8-12.6, Tokio 13.7-15.5. Peak RSS is where this
runtime pays -- Ada 25-32 MB against Go's 11-30 and Tokio's 6-9, which is one
64 KiB fiber stack per live connection.

Latency, one connection and 5000 sequential round trips against an idle
server, all three driven by the Tokio client: **Ada 22.0 us**, Tokio 21.5,
Go 23.2. The 2026-09-04 report had Ada at 28.0 against 25.0 and 25.2.

### A benchmark artifact that looks exactly like a regression

Give the server a connection target and single-connection latency reads
41.7k before against 36.4k after -- a 13% regression that is not there.

With a target, the old single acceptor retires as soon as the target is met,
so the shard serving the connection has no kernel operation outstanding for
the rest of the run. With 32 acceptors, 31 stay pending and that shard keeps
whatever the pending accepts imply -- which, while the ring was here, meant
the bridge. A server that keeps serving never stops accepting, so the state
the bounded run measures is one no real server is ever in. Measured against
`echo_server <port> 0`, the same comparison is 33.0k against 49.0k the other
way.

Measure latency against an unbounded server. `scratchpad/lat_unb.sh` is the
shape.

## Open work

Ranked by expected payoff:

1. **Use `ConnectEx`.** Connect is still a blocking `connect(2)` on a
   thread-pool thread, and it is the last thing in this backend still shaped
   by a constraint that no longer exists: `ConnectEx` needs the socket on a
   completion port, which was disqualifying while an IoRing carried the data
   plane and is now what every data socket does anyway. It costs a thread hop
   per connect, which the client side of the benchmark pays 2000 times in a
   burst. The change is confined to `Iour.Reactor`'s `Kind_Connect` and
   `Absorb`.
2. **Stop copying every completion twice** (port → per-shard pending queue →
   scheduler batch). Linux copies once. `Harvest` also clears the whole
   `Completion_Batch` on every call including the one that returns nothing,
   which is free to fix.
3. **Run the harness on Linux.** Nothing has been measured there since the
   port, though it compiles and proves clean. The interesting comparison is
   now the same runtime over io_uring against itself over completion ports.
4. **Finish the Windows SPARK story.** See *Windows is not at this standard*:
   the removal cut the blocking work down to two access-to-subprogram
   variables and one flag.

Not open, and deliberately: **registering buffers, or anything else that
needs the IoRing back.** `REGISTER_BUFFERS` was the one registration Windows
offered that this runtime could have used, and it is not worth reinstating a
second data plane, an undocumented rule and a thread-pool bridge to reach
it. The measurement is in *There was an IoRing here*.

The Go *client* drops connections against every server, its own included:
measured on this machine at 500 simultaneous connections it completed 211–305
of 500 against the Go server in five runs out of five, against 500 of 500
for the Ada server in four runs out of five. It is not a usable control for
session loss at high connection counts, and a run of it that loses sessions
says nothing about the server under test. Use the Ada client for that, and
the Go client only for throughput on the runs where it completes.

---

## Conventions

Comments in this codebase explain **why**, at length, and are part of the
deliverable — match that register rather than adding `-- increment I`. Lines
stay within 79 columns. Handles are small integers into static tables; there are
no access types and no dynamic allocation, and changes should keep it that way.
**Everything that CAN be proven with `SPARK_Mode => On` SHOULD be set to
`SPARK_Mode => On`** — see *SPARK_Mode is On unless it cannot be*, which is
where the rule and the evidence for the current four `Off` bodies live.
`SPARK_Mode => Off` is confined to the trusted base listed in the README's
*SPARK status* table; adding a fifth one needs a reason of the same kind, and
needs `--mode=check_all` run to show that `On` was not possible.
