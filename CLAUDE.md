# Working on this repo

A thread-per-core async runtime in Ada 2022 / SPARK under the Jorvik profile,
over `io_uring` on Linux and **Windows IoRing** on Windows. Stackful fibers, no
heap, no access types, no C. Read `README.md` first for the design; this file is
what a session needs to *change* it without relearning things the hard way.

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
make bench           # vs tokio and Go             (Linux only, see below)
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

Current state: **961 checks proved, 0 unproved, 2 justified.** The two
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
src/os/windows/     IoRing reactor, Win32/Winsock/IoRing (Ffi.Win32)
src/arch/x86_64-sysv/    context switch, SysV ABI
src/arch/x86_64-win64/   context switch, Win64 ABI
```

`Op_Spec` is platform-neutral by design: a kind, a descriptor, a buffer, a
token. Adding an operation means adding an `Op_Kind` and handling it in **both**
reactor bodies. `Op_Timeout` takes the interval **by value** — io_uring wants a
`struct __kernel_timespec` that outlives submission, and the Linux backend
stages one itself, indexed by submission slot.

---

## Windows IoRing — what is actually true

IoRing has opcodes for read, write, register-files, register-buffers, cancel and
flush. **That is the whole list.** No accept, no connect, no timeout, nothing
like `MSG_RING`. Everything else in the Windows backend follows from that.

Facts established by experiment (`bench/`-adjacent probes, since deleted; rerun
them if you doubt any of this):

1. **IoRing reads and writes Winsock sockets**, despite being documented as a
   file API. A `WSA_FLAG_OVERLAPPED` socket is a handle to `\Device\Afd` and
   `BuildIoRingReadFile` / `BuildIoRingWriteFile` work on it.

2. **A socket associated with an I/O completion port cannot be read or written
   through an IoRing.** The builders refuse it with `E_INVALIDARG`
   (`0x80070057`). This is the single constraint that shapes the whole backend
   and it is documented nowhere. Isolated: it is the port association, not
   `AcceptEx`, not `SO_UPDATE_ACCEPT_CONTEXT`.

3. **An `AcceptEx`'d socket works through the ring** provided the *accepted*
   socket is never itself bound to a port. Only the listener goes on the port.

4. **A socket can be read through a different shard's ring** than the one whose
   port accepted it. Handle refs are raw handles; rings are not owners.

5. Reading a closed socket returns `E_HANDLE` (`0x80070006`).

6. On this machine: `MaxVersion` 400 (`IORING_VERSION_4`), `MaxSq` 65536,
   `MaxCq` 131072, features `0x2` = `SET_COMPLETION_EVENT`. Feature bit `0x1`
   (`UM_EMULATION`) is clear, so this is real kernel support.

7. `IORING_OP_REGISTER_FILES` **replaces the whole table** on every update, with
   link semantics. That makes it useless for churning connections, and it is
   accept — which the ring has no opcode for — that would have to fill it.
   `Has_Fixed_Files` is therefore `False` on Windows. `REGISTER_BUFFERS` is the
   registration that could actually be used here; see *Open work*.

Consequences baked into the design:

- **Listener on the port** (for `AcceptEx`); it carries no data.
- **Accepted sockets never on the port**; their whole data plane is the ring.
- **Connect is a blocking `connect(2)` on a thread pool**, not `ConnectEx`.
  `ConnectEx` needs the socket on the port, which would cost that connection the
  ring for the rest of its life for the sake of one call at the start of it.
- **`Op_Write` is a synchronous `WriteFile`** plus a posted completion. IoRing
  takes only handles opened for asynchronous access and a console handle has no
  overlapped mode; every caller of `Op_Write` is `Iour.Text` writing to a
  standard stream.
- **No `CreateIoRing` at all** (Windows 10) falls back to overlapped `WSARecv` /
  `WSASend` on the port, and *then* data sockets are associated with it.
  `Reactor.Ring_Carries_Sockets` reports which path a shard got.

### Sleeping, and the thread-pool bridge

The completion port is where a shard sleeps. Getting a *ring* completion to a
sleeping shard needs a bridge: the ring signals an event, a registered wait
(`RegisterWaitForSingleObject`) fires on a thread-pool thread, that thread
`PostQueuedCompletionStatus`es, and the shard's `GetQueuedCompletionStatusEx`
returns. Two extra thread wakeups per completion.

So the backend avoids it: a shard with nothing the *kernel* will deliver to the
port (`Kernel_Live = 0`) sleeps on `WaitForMultipleObjects` over the ring's
completion event and its own wake event. The bridge is armed **lazily and
stickily**, only on a shard that has to sleep on the port — in the echo
server, the one that accepts.

**The event is auto-reset, so the bridge and a direct wait cannot both have
it.** Whichever waiter arrives first consumes it and the other sleeps through
the completion. That is why `Bridged` is sticky. Do not make it dynamic.

Anything of ours that posts to the port (`Post_Done`, `Op_Wake`) must also
`SetEvent` the target's wake event, or a shard asleep on the ring will not hear
it. Cross-shard wakeups additionally set `Wake_Flags (Target)` — **post first,
then set the flag**; the reader clears the flag before draining. Same ordering
as `Iour.Fibers`' inbox, and for the same reason.

### Win32 ABI details that bite

- `IORING_CREATE_FLAGS` is an 8-byte struct of two `UINT32`s, passed **in one
  register**. Declare the Ada parameter as `Unsigned_64` (low word = required,
  high word = advisory). Two separate `Unsigned_32` parameters would use two
  registers and be wrong.
- `IORING_HANDLE_REF` and `IORING_BUFFER_REF` are 16 bytes, which Win64 passes
  **by address**. Declare those parameters as `System.Address` and pass
  `'Address` of an aliased local.
- `OVERLAPPED_ENTRY` needs an explicit representation clause. It is 28 bytes of
  fields with 4 bytes of tail padding; without a rep clause the array stride is
  wrong and every entry after the first is misread.
- IoRing entry points live in **`kernelbase.dll`** and are resolved with
  `GetProcAddress`, not linked. The GNAT toolchain's Kernel32 import library
  predates them, and dynamic resolution is also what lets the binary start on
  Windows 10 and fall back.

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
this change and it is the unsound one — it also raises eight
`assumed-global-null` warnings, because not one of Win32's thirty-eight
imports carries a `Global`.

Doing it properly is gated on a design change rather than an annotation pass.
`Ffi.Win32`'s body holds nine mutable package-level access-to-subprogram
variables — the `AcceptEx`/`ConnectEx` and IoRing entry points, resolved
lazily through `GetProcAddress` — and five flags beside them recording what
was resolved, read back through `Ioring_Available`, `Accept_Ex` and the rest.
Sound `On` needs those declared as `Abstract_State`,
`Load_Ioring` and `Load_Socket_Extensions` declared to write it, every
accessor to read it, and a truthful `Global` on each import. Until that
exists the four stay `Off` together, because the spec is what everything above
would be verified against and a half-done version claims more than it proves.

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
`make bench` still refuses to run on Windows because its *fairness controls* —
`taskset`, `ip_local_port_range`, `ListenOverflows` — have no Windows
equivalent; run `./scripts/bench.sh` directly there and read the caveats.

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

### Results so far (Windows, 4 cores, loopback, 500 conn × 200 rounds)

Ada 128k rt/s vs Go 122k vs tokio 108k under the Ada client; CPU per round trip
17–20 µs for all three; peak RSS 26 MB (Ada) / 11 MB (Go) / 6 MB (tokio) —
the fiber stacks. Full report and raw CSVs in `bench/results/win-before` and
`win-after`.

---

## Open work

Ranked by expected payoff, from the benchmark report:

1. **Keep several `AcceptEx` in flight.** One acceptor with one accept
   outstanding still drops 50–90 sessions in a 1000–2000 connection burst
   even after the `SOMAXCONN` fix. Several acceptor fibers on the accepting
   shard; the change is confined to `examples/echo_server_app.adb`.
2. **Register the fiber stacks as IoRing buffers.** `REGISTER_BUFFERS` is the
   one registration Windows offers that this runtime can use; stacks are
   allocated once and recycled, so the region could be registered at start-up
   and every read/write could reference it by index and offset.
3. **Stop copying every completion twice** (ring → per-shard pending queue →
   scheduler batch). Linux copies once.
4. **Isolate the four Windows optimisations and re-measure.** They went in as
   one batch worth −17% CPU on the uncontended path; which one did it is
   currently an argument, not a result.
5. **Run the harness on Linux.** Nothing has been measured there since the port,
   though it compiles and proves clean. The interesting comparison is the same
   runtime over io_uring against itself over IoRing.

Known unexplained: the Go-server/Go-client benchmark pairing drops 174–200 of
500 sessions, in that combination only.

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
