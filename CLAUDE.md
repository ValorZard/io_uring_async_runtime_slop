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
make smoke           # runtime self-test, and the context-switch model check
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

Current state: **Linux 1196 checks proved, 0 unproved, 2 justified; Windows
1017 proved, 0 unproved, 1 justified.** Every justification is `unused global
"Ffi.Kernel"` on a portable spec whose two bodies do different amounts:
`Ffi.Net.Initialize` and `Ffi.Sys.Bind_To_Cpu` on Linux, which do less than
Windows, and `Ffi.Sys.Ignore_Broken_Pipe` on Windows, which does less than
Linux. The contract is the union in each case. Do not "fix" them by narrowing
it.

**Delete `obj/gnatprove` before quoting a number.** The two configurations
share it, and a run that inherits the other one's session reports a total
several checks higher than a clean run does.

On this machine a whole-configuration `--mode=all --level=3 -j0` run takes
roughly five minutes for Linux and eleven for Windows, so budget a quarter of
an hour for the pair and use `-u <unit>.adb` while iterating.

**A clean `gnatprove` is not a clean build.** gnatprove's frontend accepts at
least one construct the compiler rejects -- a library-level `pragma Assert`
calling a spec-declared function, under SPARK RM 7.7(3) -- so a proof-only
change still needs a real `gprbuild` before it is finished. See *The context
switch is proved*.

---

## The one seam

`Iour.Reactor` is the only platform-dependent package. Everything above it —
scheduler, fibers, futures, sockets, timers — compiles unchanged on both. Keep
it that way.

```
src/ffi/            portable system interface: Sys, Net, Inet, Identity,
                    Memory, the Fiber spec, and the portable half of the
                    context switch -- Fiber.Frames, .Target, .Text, .Layout
src/runtime/        scheduler, fibers, futures, run queue, promises, text, trace
src/net/            asynchronous sockets
src/os/linux/       io_uring reactor, raw libc (Ffi.Posix), the mapped rings
src/os/windows/     completion-port reactor, Win32/Winsock (Ffi.Win32)
src/arch/x86_64-sysv/    context switch, SysV ABI, and its proved model
src/arch/x86_64-win64/   context switch, Win64 ABI, and its proved model
```

`Iour.Ffi.Fiber.Machine` is the second per-ABI unit, beside the switch it
describes -- but only the target-specific half of it. What every switch has
in common is portable and lives in `src/ffi/`, and a target implements it by
instantiating `Iour.Ffi.Fiber.Target`. See *The context switch is proved; the
assembly is checked against the proof*.

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
`Compile_Time_Error` guarding it. Its offsets are `Iour.Ffi.Fiber.Machine`'s
named numbers, not literals, and so are the displacements in the emitted
instructions; the `Asm` template is that package's `Switch_Template`.
`pragma Machine_Attribute (X, "naked")` works on x86-64 with this GCC.

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
other 1160 checks rest on. A new body starts `On`. If it will not prove, the
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

When even that is not available -- the whole body is genuinely outside the
language -- the next move is not to give up but to **lift what the body
*means* into a proved companion beside it**, and reduce the `Off` body to the
part the language cannot express.  `Iour.Ffi.Fiber.Machine` is the worked
example: the switch's assembly is still `Off` and always will be, but the
locations it owns, their layout, the instruction sequence, the register-file
exchange and the stack arithmetic are all `On` and proved, and what is left
in the `Off` body is two `Asm` calls, two slot addresses and one write
through a computed address.  That pattern is available to
`Ffi.Memory`, `Ffi.Uring.Memory` and the Windows reactor too, and has not
been tried on any of them.

### Why the Linux trusted base is exactly these four

Rechecked by flipping each to `On` and recording what came back. Do not retry
them expecting a different answer:

* `Ffi.Fiber` (per ABI) — inline `Asm` in `naked` subprograms, which is not
  analysable code at all.  This is the one whose *content* has largely
  escaped anyway: `Iour.Ffi.Fiber.Machine` is `On` and proved, and what is
  left in the `Off` body is the `Asm` calls, two slot addresses and one
  write through a computed address.  See the section below.
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

### Windows: what closed the gap, and what is left

`Ffi.Win32`'s **spec**, `Ffi.Sys` and `Ffi.Net` are `On` on Windows, as they
are on Linux. What is still `Off` there is `Ffi.Win32`'s **body** — the
`Unchecked_Conversion` from `System.Address` to access-to-subprogram that
`Load_Socket_Extensions` is made of — and `Iour.Reactor`, which has a reason
of the Linux kind. Both checks run against the Windows configuration from
Linux; neither generates code:

```
alr gnatprove -P io_uring_async_runtime.gpr -XIOUR_OS=Windows_NT \
  --mode=all --level=3 -j0
alr exec -- gprbuild -P examples.gpr -XIOUR_OS=Windows_NT \
  --subdirs=wincheck -j0 -c -f -cargs -gnatc
```

**Windows: 685 checks proved, 0 unproved, 1 justified** at the time. Before
this it was 3, because everything Windows-specific was `Off` and nothing was
analysed. It is 974 now; the context switch's model is the difference.

Four things were needed, and three of them were contract work rather than the
annotation pass this section used to predict:

1. **A `Global` on every import.** Function imports get `Global => null`,
   procedure imports `Global => (In_Out => Kernel), Always_Terminates` — the
   convention `Ffi.Posix` already follows. Getting one wrong is not cosmetic:
   `Get_System_Info` declared as writing `Kernel` made `Ffi.Sys.Page_Size` a
   function with an output global, which is `E0005` and not allowed in SPARK
   at all. `GetSystemInfo` is Windows' `getpagesize` and takes `Global =>
   null` for the same reason Linux's does.

2. **`Kernel`'s external properties, spelled out.** Defaulted, `External`
   means all four, and `Effective_Reads => True` says reading the state is
   itself an act that changes it — which is why SPARK refuses to let any
   function read it. Nothing here is a FIFO, so `Iour.Ffi` declares
   `Effective_Reads => False` and `Accept_Ex`/`Connect_Ex` can be read back
   by `Volatile_Function`s. This is the one change that touches the shared
   spec, and the Linux proof was unchanged by it: **962 checks at the time,
   the same two justifications, nothing unproved.**

3. **The resolved entry points are part of `Kernel`,** not a state
   abstraction of their own. A separate `Abstract_State` is what this section
   used to prescribe and it does not work: `Ffi.Net`'s spec is portable and
   cannot name a Windows-only abstraction, so `Tcp_Socket` could never list
   it in a `Global`, and gnatprove says exactly that, twice. They belong to
   `Kernel` on the same grounds `Ffi.Fiber`'s slot table does — machine state
   the runtime owns.

4. **Two idioms borrowed from the Linux bodies.** `'Access` on a local
   aliased object is bound to a scoped `constant access` first, the way the
   Linux body already wraps `getrlimit`. `'Address` is avoided by importing
   the same entry point a second time with a typed profile — `WriteFile`
   taking a `Byte_Array`, `setsockopt` taking `access constant C_Int` — which
   is how `Ffi.Posix` already imports `write` and `close` twice each.

Three things fell out of it. `closesocket`, `shutdown`, `WSAStartup` and
`CancelIoEx` are now `Side_Effects` functions over `Kernel`, as their Linux
counterparts are; a `Side_Effects` function may only appear as the right-hand
side of an assignment, so `Adapt (Win.C_Closesocket (...))` had to become two
statements. `Ffi.Sys.Failure_Code` and `Ffi.Net.Shutdown` both converted
`WSAGetLastError` to `Dword` without excluding a negative, which is a real
latent bug and was the last unproved check. And `Bind_To_Cpu` computed
`Shift_Left (1, Cpu)` *before* checking `Cpu >= 64`.

What would close the rest is a way to resolve an entry point without
`Unchecked_Conversion` to an access-to-subprogram, and there is not one — so
`Ffi.Win32`'s body is a trusted base of the same kind as the context switch,
and its spec is what everything above is verified against.

## The context switch is proved; the assembly is checked against the proof

`Iour.Ffi.Fiber`'s body will always be `SPARK_Mode => Off` -- inline `Asm` in
a `naked` subprogram is not analysable code. What used to follow from that,
and no longer does, is that the switch itself was unverified. Everything the
assembly is *supposed to be* is ordinary Ada, and it is split in two: what
every context switch has in common, portable, and what describes one
machine, per target.

```
src/ffi/iour-ffi-fiber-frames.ads     the abstract machine, over a location
                                      set -- generic
src/ffi/iour-ffi-fiber-target.ads     the exchange theorem and the text
        /.adb                         walk: THE INTERFACE -- generic
src/ffi/iour-ffi-fiber-text.ads/.adb  the assembler-text scanner
src/ffi/iour-ffi-fiber-layout.ads     where a fiber's first frame goes
        /.adb

src/arch/x86_64-sysv/iour-ffi-fiber-machine.ads/.adb   8 locations, 19 insns
src/arch/x86_64-win64/iour-ffi-fiber-machine.ads/.adb 25 locations, 59 insns
```

The Win64 template is 1332 characters. The SysV one is 19 lines.

**A target implements the interface by instantiating
`Iour.Ffi.Fiber.Target`**, and that instantiation is where its obligations
are discharged. Be precise about how much of that Ada enforces, because it
is less than it looks: the formal subprograms carry no contracts -- they
cannot, see *SPARK and generics* -- so **instantiation alone checks only
profiles**.

What makes it an interface rather than a shared body of code is that
`Target` states the obligation itself, as `Save_Obligation` and
`Load_Obligation`, and `Model_Switch`'s body asserts them after every call
and is proved *from* them rather than from whatever the actual happened to
promise. So the obligation is written once where a new target's author
reads it; every target is held to the same one rather than merely to a
sufficient one; and a target that misses it fails at its instantiation,
naming the predicate it broke.

That last is checked, not asserted. A stand-in target whose `Save_One`
treats the instruction pointer like any other register -- and whose own
postcondition says so, so that it is internally consistent -- fails with
`assertion might fail ... Save_Obligation`, at the instantiation. Without
the asserted predicate it would have proved, because its instance's
`Model_Switch` would have been proved from its own weaker contract.

What a target supplies is five subprograms -- `Save_One`, `Load_One`,
`Emit_Save`, `Emit_Load`, `Emit_Tail` -- plus its location set, offsets,
opcodes, snippets and templates. Nothing else. Before the split, 313 of the
SysV body's 427 lines had an identical twin in the Win64 body; it is 151 of
277 now, and what is left is the same *shape* rather than the same text.

**The generated code did not change.** `objdump` of `iour-ffi-fiber.o` before
and after is byte for byte identical, on both `Swap` and `Trampoline`. This
was a change to what is *known* about the switch, not to the switch.

**Measured anyway, paired against the commit before it** (Linux, WSL2, 32
CPUs, Shard_Count 4; one constant Ada client built at `First_Shard_Cpu` 10
driving the two servers alternately, rep by rep, order swapped each rep):

| | before | after | paired |
|---|---|---|---|
| 2000 x 100, srv us/rt | 3.75 | 3.72 | -0.7% |
| 2000 x 100, rt/s | 131.3k | 136.5k | new 4, base 1, tie 1 |
| 2000 x 5 (spawn-dominated), srv us/rt | 11.00 | 11.00 | 0.0% |
| 2000 x 5, rt/s | 8,395 | 8,361 | base 3, new 1, tie 2 |
| 1 x 20000, unbounded server | 104.04 us/rt | 104.20 us/rt | base 3, new 3, tie 2 |

Every run completed 2000 of 2000 sessions, so none of them is disqualified.
**Read the `srv us/rt` column, not the throughput one**: within a single
build the throughput at 2000 x 100 ranged over 23.7% (base, 115.8k to 143.3k)
and 14.1% (new), so the +3.9% median gap is inside one build's own spread and
is not a result. Single-connection latency on this machine is bimodal at
~98 or ~104 us and both builds land in both modes across the eight reps,
which is the same story told more obviously.

The latency row is the second measurement, not the first. The first one
leaked: `kill` on a `/usr/bin/time` wrapper does not kill its child, so every
rep left an idle unbounded server pinned to the same four cores as the next
rep's server under test, fourteen of them by the end. It happened to give
almost exactly the same answer -- 98.09 against 98.02, a 3-2-3 split -- which
is the point worth remembering: a contaminated paired comparison can look
perfectly healthy, because the contamination lands on both arms. It was
caught by `pgrep`, not by the numbers. See *Measurement traps*.

The one genuinely new cost is `Emitted_Matches_Model`, and it was measured
directly rather than inferred: **0.66 us per call**, once per shard in
`Reserve_Contexts`, so about 2.6 us per process at `Shard_Count` 4. The
2000 x 5 row exists because it is spawn-dominated -- 2000 `Prime` calls for
10,000 round trips -- and it is where the extra arithmetic in `Prime` would
show if it were going to.

### The two papers, and which idea came from which

**Rutter, *Using a high level language as a cross assembler* (SIGPLAN Notices
16(2), 1981).** The instruction sequence is *data*, not characters. A save is
`(Op_Store_Reg, L_R14)`, and both its displacement and its register name are
derived from `L_R14` by `Offset_Of` and `Reg_Name`. So `movq %r14, 40(%rdi)`
-- the register written at its neighbour's offset -- is not a thing anyone
can type. That whole class of bug is gone by construction rather than by
review.

**Crary, *Toward a Foundational Typed Assembly Language* (POPL 2003)**, and
closer still Morrisett, Crary and Glew's **stack-based TAL** (JFP 13(5),
2003; TIC '98 before that). TAL states the callee-saved convention as a type
the callee holds abstract and must hand back unchanged. A context switch is
that obligation and nothing else, so it is stated as one predicate and
proved:

```ada
   procedure Model_Switch (S : in out State)
     with Ghost, Global => null, Always_Terminates,
       Post =>
         (for all L in Location =>
            S.Out_Ctx (L) =
              (if L = L_Rip then Resume_Address else S.Live'Old (L)))
         and then (for all L in Restorable => S.Live (L) = S.In_Ctx'Old (L))
         and then S.In_Ctx = S.In_Ctx'Old;
```

STAL types *both* halves of a switch and this model takes one. The other half
is the stack type variable: a function polymorphic in the shape of the stack
it was called on, obliged to restore that shape before jumping to its return
address, which is exactly two fibers' stacks exchanged. Here `L_Rsp` is one
more location that round-trips, so what is proved is that the stack
*pointer* is exchanged intact, and nothing about what is on either stack.
`Return_Slot_Offset` covers the one frame this runtime builds itself, the
initial one; every frame after that is GCC's. Do not describe the switch as
"proved" without that qualification -- the README states it at length and the
sentence is load-bearing.

### How coverage is guaranteed, and why not the obvious way

`Location` is the ABI's callee-saved set as an enumeration **in ascending
offset order**. `Restorable` is all of it except `L_Rip`, which is saved (as
the resume label's address) and never restored, because the incoming
context's copy is the jump that ends the sequence.

The save phase is `for L in Location` and the restore phase
`for L in reverse Restorable`, in *both* consumers. So coverage is by
construction and **never a proof obligation** -- there is no "did we remember
`xmm11`" to discharge. What is left to prove is non-interference, which is
`Save_One`'s and `Load_One`'s postcondition, and which is where a duplicated
offset dies.

That the real assembly already had exactly this shape -- ascending saves,
descending restores, on both ABIs -- is why the model is a description of the
existing switch rather than a rewrite of it. Check that before changing the
order of anything.

Four designs were considered first and rejected. Do not re-derive them:

* **A flat program array plus an interpreter, with the permutation property
  proved.** The theorem then needs loop invariants quantified over the prefix
  of an arbitrary well-formed program, or thirty unrollings. Looping over the
  type instead makes coverage free and the invariants trivial.
* **Build-time codegen** -- an Ada program that emits the template into a
  checked-in source file, with `make` diffing it. Faithful to Rutter, and
  strictly worse here: it adds a generated source and a build step to buy
  what the start-up check already buys.
* **`"i"` immediate `Asm` operands**, so `%0` in the template picks up
  `Off_Rbp` as an Ada expression and the offsets exist only once. It removes
  offset duplication and adds operand-index duplication, and it makes the
  text check impossible because the template would then hold `%0`, not `16`.
* **A `Compile_Time_Error` per offset**, comparing the named number and a
  textual twin against the same literal, so editing one without the other
  fires at compile time. It works -- GNAT folds the string comparison -- but
  it is three copies of every offset to catch a subset of what one render
  check catches totally.

### What the model does not catch

Measured, not reasoned about, and worth knowing before trusting any of this
further than it goes.

**A register deleted from `Location` was not caught, until the tiling lemma.**
Deleting `L_R14`, `Off_R14`, its two template lines and its field of the
context record left a model that compiled, proved clean at 168 checks, and
passed the start-up text check -- while the switch silently stopped
preserving r14. Everything agreed with everything else; there was simply one
fewer register in the story. `Context'Size` does not catch it because
removing a *middle* field leaves a hole and the record's size is unchanged.
`Layout_Tiles_Context` now does catch it, on the successor of the hole.

What is still trusted input, and cannot be checked from inside:

* **That `Location` is the ABI's callee-saved set.** The lemmas tie
  `Location` to the context record and to the emitted text; nothing ties any
  of them to what the System V or Win64 ABI actually requires. If a target's
  author never knew xmm11 was callee-saved, every artefact here is
  consistent and wrong together.
* **That `Apply` means what the instruction means.** `Op_Store_Reg` is
  *defined* as `Out_Ctx (L) := Live (L)`. That it corresponds to what
  `movq %reg, off(%base)` does on the machine is a claim in a comment.
* **That `Emit` renders the instruction it names.** Same shape of claim, in
  the other direction.

So the honest summary is that the model proves the *internal* consistency of
a description of the switch -- layout, coverage, composition, and text -- and
that the assembled text is that description. It does not and cannot prove
that the description is the right one for the machine. Two of the three
trusted claims above are one line each and reviewable by eye, which is the
argument for the arrangement, not a proof of it.

### What is proved and what is checked

The distinction matters and is worth reading before changing anything here.

**Proved by gnatprove**, statically. `gnatprove -u iour-ffi-fiber-machine.adb`
is the quick way to work on one target: 175 checks for the SysV model, 273
for the Win64 one, seconds rather than the minutes a whole configuration
takes.

* `Layout_Is_Disjoint`: the offsets do not overlap, each is naturally aligned
  for its width, and each fits `Context_Bytes`. Over 25 locations in four
  widths on Windows this is the check that would notice a vector slot laid on
  top of the control words.
* `Layout_Tiles_Context`: the offsets are a *chain* -- first at zero, each
  starting where its predecessor ended (plus the two padding bytes, on
  Windows, at the one place there are any), last ending exactly at
  `Context_Bytes`. **This is the one that catches a dropped register**, and
  it exists because disjointness alone does not. See the measurement below.
* `Model_Switch`'s postcondition above.
* `Return_Slot_Offset`: a fiber's first frame is 8 modulo 16 -- the alignment
  a `call` leaves -- is above the guard page, and has the red zone (SysV, 128)
  or shadow store (Win64, 32) above it inside the mapping.
* `Round_Up_Pages` cannot overflow. The arithmetic it replaced could, for a
  large enough request; nothing asked for one, so it was latent.
* Nothing in the renderer can go out of bounds.

**Checked at start-up**: that the text GCC actually assembled is the
rendering of that instruction sequence. It has to be a run-time check because
**GNAT requires an `Asm` template to be a static string**, so the template
cannot be built by the loops that render it -- it is written out once, in the
same package the proof is about, and `Emitted_Matches_Model` walks the
sequence and compares character for character.
`Iour.Fibers.Reserve_Contexts` asks before any shard starts, and a shard that
gets `False` refuses to run; `Iour.Scheduler` already treats that as "this
shard takes no part". It costs a few hundred character comparisons per shard,
once. `make smoke` reports it separately and names the character where a
divergence begins.

Both failure classes were tested by introducing them into the SysV template:
a displacement swapped between `r13` and `r14` is caught at character 153, a
dropped `movq 40(%rsi), %r13` at 241.

### The structure that ties the two together

One `Snippet` per location, consumed twice:

```
Save_Snippet (L) / Load_Snippet (L) / Tail_Snippet
        |                                   |
        v                                   v
   Apply  (semantics, Ghost, proved)   Emit (text, checked at start-up)
```

Both walk the same snippets in the same order, so a location the meaning
covers is a location the text covers. That is the whole argument, and it is
why `Instruction` and `Snippet` are **not** `Ghost` while `State`, `Frame`,
`Apply` and `Model_Switch` are: the machine model costs nothing at run time,
the instruction sequence has to exist because the checker reads it.

`Op_Array` is fixed length -- no heap here either -- and `N` says how many of
its entries are the snippet. `Pad_Op` fills the rest and is never read by
either consumer. Two instructions is the maximum on SysV (`L_Rip`'s save
needs the `leaq`); on Win64 the TEB fields also take two each way, because
gs-relative to memory is not a move the machine has and they go through
`rax`, which Win64 makes caller-saved. The tail is three.

### Where it hooks into the rest of the runtime

Two places outside `src/arch` know about the model, and both are small:

* `Iour.Fibers` is portable and now `with`s `Iour.Ffi.Fiber.Machine`, which
  is per-ABI. That is legal and safe because both arches provide the unit and
  `Reserve_Contexts` only calls `Emitted_Matches_Model`, which is a
  `Boolean` function with `Global => null` on both. It is the second
  portable-to-arch dependency after `Iour.Ffi.Fiber` itself; keep any further
  use to subprograms that exist identically on both sides, because `Location`
  and everything indexed by it do not.
* `tests/smoke.adb` runs `Check_Switch_Text` and `Check_Trampoline_Text`
  before `Shards.Activate` and exits 1 on failure, naming the character. The
  shards would refuse to start anyway; smoke exists to say *where*.

### Traps found while building it

* **A precondition on a SPARK unit called from an `Off` body is neither
  proved nor checked.** Assertions are `Ignore` by default in this project,
  so `Machine.Round_Up_Pages`'s precondition buys the `Off` caller nothing.
  `Iour.Ffi.Fiber`'s body therefore enforces the bounds itself, in
  `Usable_Size`: at least four pages, at most `Max_Stack` (2**27), page size
  clamped into `Page_Bytes`. Any future call from an `Off` body into a proved
  one needs the same treatment.
* **The model works in offsets from the mapping base; the old code worked in
  addresses.** `Return_Slot_Offset` does its own 16-alignment on the offset,
  which is the same answer as aligning the address only if the base is itself
  16-aligned. `mmap` and `VirtualAlloc` always return that, so `Prime` now
  refuses -- `To_Integer (Base) mod 16 /= 0` -- rather than build a
  misaligned frame if it ever stops being true.
* **`Align_Down_16` models the mask rather than deriving 16-alignment from
  the page size.** Deriving it needs divisibility transitivity (`X mod P = 0`
  and `P mod 16 = 0` implies `X mod 16 = 0`), which provers do not reliably
  do. Modelling `and $-16` directly keeps the whole thing in linear
  arithmetic *and* keeps the model the same shape as the code.
* **A null `String` may have `'Last = 'First - 1`.** `Text'Last <=
  Max_Template` is not enough; SPARK produced a counterexample with
  `Text'Last = -1`. Every such precondition is `Text'Last in 0 ..
  Max_Template`.
* **Newlines terminate instructions, they do not separate them**, so both
  templates end with one. The separating version needed a `First : in out
  Boolean` threaded through the renderer, and gnatprove's flow analysis then
  warned that the last call sets it and nobody reads it.
* The bounds guard at the top of `Emitted_Matches_Model` is provably dead --
  the templates are static and GCC says so -- and is wrapped in
  `pragma Warnings (Off, "range test optimized away")`. It stays because it
  is what discharges `Check_Switch_Text`'s precondition.
* `Reg_Name` and `Teb_Offset` on Windows have `when others =>` branches that
  their preconditions exclude. They are there because a `case` on `Location`
  must be complete, not because anything reaches them.

### SPARK and generics, which is how the interface is expressed

Four things established by experiment while splitting the model in two.
Every one of them is the opposite of the obvious guess, so do not re-derive
them:

* **gnatprove analyses instances, not templates.** That is why the interface
  works at all: `Iour.Ffi.Fiber.Target`'s `Model_Switch` is re-proved at each
  instantiation against that target's actual `Save_One` and `Load_One`, so
  the obligation lands on the target. It also means the split does not
  halve proof time -- it halves *source*.
* **Do not put contracts on generic formal subprograms.** Stating the
  obligation as `with procedure Save_One (...) with Post => ...` is the
  obvious way to do it, compiles under `gprbuild`, and is then rejected by
  gnatprove's frontend at every instantiation with a type mismatch between
  the formal `Location` and the actual. This is the mirror image of the
  SPARK RM 7.7(3) trap: there the compiler rejects what gnatprove accepts,
  here the reverse.
  **State the obligation as a ghost predicate in the generic's visible part
  and `pragma Assert` it after each call instead.** That is expressible --
  the visible part can name the formal package's types, and the assertion
  is checked in the instance where the types are concrete -- and it is
  strictly better than a formal contract would have been, because the
  shared code is then proved *from* the stated obligation rather than from
  whatever each actual happens to promise.
* **A ghost type may not appear in a generic formal subprogram's profile,
  and a ghost actual may not be passed to a non-ghost formal.** So
  `Fiber.Frames`'s `Frame` and `State` are not `Ghost` and neither is
  `Resume_Address`; the formal *subprograms* carry `with Ghost` instead.
  Nothing is emitted for a type or a constant, so the run-time cost is
  still nil.
* **A generic instance's operators are not directly visible, and a generic
  formal part cannot carry a use clause.** The equalities the contracts
  need are imported as formals with defaults --
  `with function "=" (L, R : F.Frame) return Boolean is <>;` -- and the
  instantiating package needs `use type Fr.Frame; use type Fr.Word; use
  type Fr.State;` before its own contracts and before the instantiation.

### Static string expressions: more than the RM promises

Established here by experiment, because GNAT is more generous than Ada is and
the difference is what makes the whole arrangement possible:

* **Concatenation of string literals, and of `constant String`s declared in
  another unit, is static** and works as an `Asm` template. Verified by
  compiling a two-unit test and reading `gcc -S`: the text comes out verbatim.
  This is what lets the template live in the model package rather than beside
  the `Asm` call.
* **An array aggregate is never static.** `Nl` is `"" & ASCII.LF`, not
  `[1 => ASCII.LF]`; the latter compiles fine everywhere except as part of an
  `Asm` template, where it fails with "asm template argument is not static".
* **GNAT folds static string comparison inside `pragma Compile_Time_Error`.**
  Not used here -- the render check subsumes it -- but it is real, and it is
  a way to tie a textual constant to a literal at compile time.

### Adding a target

The five things a new `Iour.Ffi.Fiber.Machine` must get right, none of which
are obvious from the interface's profiles:

1. **The instruction pointer must be `Location'First`.** The portable half
   derives `Restorable` as `Location'Succ (Location'First) .. Location'Last`
   and `Save_Obligation` special-cases `Location'First` as the one that
   receives the resume address. Both existing targets put `L_Rip` first for
   this reason; a target that put it elsewhere would fail the obligation
   without any message saying why.
2. **`Location` in ascending offset order.** The save phase is
   `for L in Location` and the restore phase `for L in reverse Restorable`,
   so the enumeration order *is* the instruction order, and the template has
   to match it.
3. **`Load_One` and `Emit_Load` take `Location`, not `Restorable`.** A
   generic actual's profile must match the formal's exactly, and the formal
   says `Location`. Constrain them with `Pre => L in Restorable` instead;
   the generic only ever calls them from a loop over its own `Restorable`,
   so the precondition discharges.
4. **Give `Save_One` and `Load_One` postconditions that imply the
   obligations.** They are written out in full in both targets rather than
   deferred to `Save_Obligation`, because that is also where the target's
   body is checked against them, and a target reads better with its
   obligation in front of it.
5. **`Resume_Address` and the frame types are not `Ghost`.** A ghost entity
   cannot be a non-ghost generic formal's actual, and a ghost type cannot
   appear in a formal subprogram's profile. The formal *subprograms* carry
   `with Ghost`; nothing is emitted for a type or a constant either way.

Then instantiate `Iour.Ffi.Fiber.Target`, add the arch directory to
`io_uring_async_runtime.gpr`, and write the `Asm` body against the same spec
the other two use.

### Testing that the interface actually binds

Worth doing after any change to the portable half, and easy to do wrongly:

* **Breaking only the target's body proves nothing about the interface.**
  The target's own postcondition catches it first, and the failure is
  reported on the target's file. That is a test of the target, not of
  `Target`.
* **Break the body *and* its postcondition together**, so the target is
  internally consistent but does not meet the obligation. Then the failure
  is `assertion might fail ... Save_Obligation` inside
  `iour-ffi-fiber-target.adb`, reported at the instantiation. That is the
  test that the interface is load-bearing, and without the asserted
  predicate that target would have proved.
**Every mutation that has been tried, and what reports it.** Redo these
after any change to the portable half; each one should still fail, in the
place named.

| mutation | caught by | message |
|---|---|---|
| swap two displacements in the template (`r14` at `r13`'s offset) | start-up text walk | `smoke` FAIL, character 153 |
| delete one restore line from the template | start-up text walk | `smoke` FAIL, character 241 |
| break `Save_One`'s body only | the target's own `Post` | `postcondition might fail`, in the target's file |
| break `Save_One`'s body *and* its `Post` together | `Target.Save_Obligation` | `assertion might fail`, in `iour-ffi-fiber-target.adb`, reported at the instantiation |
| delete a location, its offset, its template lines and its record field | `Layout_Tiles_Context` | `postcondition might fail ... Offset_Of (L) = Offset_Of (Pred) + Size_Of (Pred)` |
| delete a location but leave the record field | the parent body's rep clause | `"Off_R14" not declared in "Machine"` |

The fourth row is the one that has to be done properly: breaking only the
body is a test of the *target*, not of the interface, because the target's
own postcondition catches it first and the interface never gets a chance to.

* **Back the file up before mutating it, and restore from the backup, not
  from git.** `git checkout <file>` restores from HEAD, which after a
  mid-session commit is the *committed* version and not the working one; it
  will silently discard uncommitted work on that file. This cost a
  reconstruction of the SysV spec in the session that wrote this.

### Changing it

* Adding a register means adding a `Location` and an `Off_*`. Coverage
  follows; the template does not, so the start-up check fails until it is
  updated. That is the intended workflow, not a nuisance.
* Offsets are named numbers in the model spec, and the context record's
  representation clause in the parent body uses them. Do not write a literal
  offset in either place. `Compile_Time_Error` on `Context'Size` against
  `Machine.Context_Bytes` catches the record and the model disagreeing about
  the total.
* **`gnatprove` accepting a unit does not mean it compiles.** A library-level
  `pragma Assert` calling a function declared in the same package's spec is
  rejected by the *compiler* under SPARK RM 7.7(3), "early call region",
  while gnatprove is happy with it. That is why the layout theorem is a ghost
  procedure with a postcondition and an empty body rather than an assertion.
  Always run a real `gprbuild` after a proof-only change.
* Do not use `pragma Assert` at library level to state a fact about
  constants, for the same reason. A `Ghost` procedure with `Post` and a null
  body is the idiom.
* An obligation stated for a generic to assert takes `Before, After : State`
  rather than using `'Old`, because `'Old` is only available in a
  postcondition. `Model_Switch` keeps a ghost `Before` and copies into it
  before each call; ghost, so it costs nothing.
* A subprogram of a generic instance can be re-exported by renaming --
  `procedure Check_Switch_Text (...) renames Switch.Check_Switch_Text;` --
  and the contract comes with it. That is what keeps `Machine`'s callers
  from having to name the instance.
* `Consumed_All` compares against `Text'Last + 1`, so it needs
  `Text'Last in 0 .. Max_Template` in its precondition or the addition is an
  unprovable overflow check on a 32-bit `Integer`.
* `Layout.Reserve_Bytes` carries a `Predicate` of `mod 16 = 0`, because the
  frame below the reserve could not be 8 modulo 16 otherwise. Both ABIs
  oblige: 128 and 32.
* **The Windows model can be exercised from Linux** -- it depends on nothing
  Windows-specific, only on `Iour.Ffi.Fiber`'s spec and the portable half.
  Copy into a scratch project with its own trivial `.gpr`:

  ```
  src/iour.ads
  src/ffi/iour-ffi.ads  iour-ffi.adb  iour-ffi-fiber.ads
  src/ffi/iour-ffi-fiber-frames.ads   iour-ffi-fiber-target.ads/.adb
  src/ffi/iour-ffi-fiber-text.ads/.adb
  src/arch/x86_64-win64/iour-ffi-fiber-machine.ads/.adb
  ```

  plus a stub body for `Iour.Ffi.Fiber` -- and do not use `gnat.adc`, the
  stub has no tasking. Then call `Check_Switch_Text` on `Switch_Template`.
  The stub needs `use type Interfaces.C.long` and explicit `C_Int`
  conversions, and `Stack_Alloc` cannot be an expression function because it
  is `Side_Effects`. `iour-ffi-fiber-layout` is not needed unless the scratch
  main touches the stack arithmetic.

  That is how the 59-instruction Win64 template was confirmed against its
  model without a Windows machine, and it is worth redoing after any change
  to the Windows switch or to the portable half -- the answer to look for is
  `switch: MATCHES`.

## Ada / GNAT / SPARK things hit in this codebase

- A `Side_Effects` function **may not be an expression function**.
- **A static string expression is more than the RM promises.** GNAT folds
  concatenation of string literals and of `constant String`s declared in
  another unit, which is what lets an `Asm` template live in a different
  package from the `Asm` call. An **array aggregate is never static**, so a
  one-character string for a template is `"" & ASCII.LF`, not
  `[1 => ASCII.LF]`. GNAT also folds static string comparison inside
  `pragma Compile_Time_Error`.
- A library-level `pragma Assert` that calls a function declared in the same
  package's spec is rejected under **SPARK RM 7.7(3), "early call region"** --
  by the compiler, not by gnatprove, so it only appears in a real build.
  State the fact as a ghost procedure with a postcondition and an empty body.
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

**Read the "What is and is not held equal" block at the top of the script
before quoting any figure from it.** The Ada server is pinned to
`Shard_Count` cores and Go and Tokio are not pinned at all, which is
deliberate and which makes round trips per second an asymmetric measure. The
`srv us/rt` column is the one that survives it.

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
- **Killing a `/usr/bin/time` wrapper does not kill the process it is
  timing.** A harness that starts `time server ...` in the background and
  kills `$!` kills the wrapper; the server keeps running, keeps its port,
  and keeps its shard pinning. Doing that once per rep against an unbounded
  server accumulates one competitor per rep on exactly the cores under test.
  Start the server directly and kill its own pid, take its CPU from
  `/proc/<pid>/stat` before killing it, and have every rep refuse to start
  while any `echo_server` is alive, with
  `ps -eo args | grep -c "[b]in/echo_server"`.
  The tell is not in the numbers, which stay plausible because both arms are
  contaminated equally; check for strays directly.
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

### Go and Tokio run unconfigured now, and that changed the question

Until 2026-09-05 the two comparison programs pinned their worker threads to
the Ada shards' cores, raised `RLIMIT_NOFILE`, and asked for a 4096 listen
backlog through hand-written `syscall` and `kernel32` bindings. None of that
is anything a Go or Rust program would ordinarily contain; all of it was
there so the three servers met on the Ada server's terms.

It is gone. `bench/go_echo` and `bench/tokio_echo` are now plain safe Go and
Rust -- no libc, no kernel32, no build tags, no `unsafe` -- doing what
`net.Listen`, `#[tokio::main]` and `TcpListener::bind` do by default. 438
lines came out.

**So the comparison is no longer "the same cores each."** On this 32-CPU
machine it is the Ada server on 4 pinned cores against Go and Tokio on all
32. The Ada side keeps its pinning because thread-per-core with a static CPU
per shard is what that runtime *is* -- it is the thing under test, not a
benchmark setting.

That makes **`srv us/rt` the honest column**, not round trips per second: it
is the one figure that does not depend on how many cores a runtime helped
itself to.

Two things that were expected to bite and did not: Rust's `TcpListener::bind`
asks for a backlog of 128 where Go passes `SOMAXCONN`, and nothing raises
`RLIMIT_NOFILE` for the Rust binaries any more. Neither produced a failed
session on Windows at 2000 connections. Every failure row in the run below is
the Go *client* bursting connects, which it does against every server
including its own.

**Do not compare that run's numbers with the pinned one's.** The load
generator changed too -- the Tokio client is now unpinned, and in the latency
stage it used to be pinned to a single CPU -- which is why every latency
figure roughly halved. Within-run comparisons only.

### The full suite, 2026-09-05 unpinned (`bench/results/20260905-unpinned`)

Holding the client constant, median of two repetitions:

| load | client | Ada srv | Go srv | Tokio srv |
|---|---|---|---|---|
| 500x200 | Ada | 143,378 | **146,490** | 130,857 |
| 500x200 | Go | **293,989** | lost 353 | lost 523 |
| 500x200 | Tokio | **157,791** | 93,721 | 89,500 |
| 2000x100 | Ada | **243,673** | 207,365 | 115,772 |
| 2000x100 | Go | lost 2389 | lost 3497 | lost 3505 |
| 2000x100 | Tokio | **122,652** | 102,649 | 93,303 |

And the column that survives the asymmetry -- server CPU microseconds per
round trip:

| load | client | Ada | Go | Tokio |
|---|---|---|---|---|
| 500x200 | Ada | **10.2** | 32.7 | 20.6 |
| 500x200 | Tokio | **10.3** | 25.9 | 28.1 |
| 2000x100 | Ada | **11.4** | 47.0 | 41.9 |
| 2000x100 | Tokio | **14.0** | 38.1 | 51.2 |

**Unpinned Go and Tokio burn two to four times the CPU per round trip.**
That is the cost of letting a work-stealing scheduler spread a latency-bound
loopback workload across 32 cores: every wakeup becomes a cross-core IPI onto
a cold cache. It is also the argument for thread-per-core stated as a
measurement rather than as a preference.

The scaling stage now sweeps only the Ada shard count, with the other two
appearing once each as the reference line:

```
ada/1-cores  110,631 rt/s   8.71 us/rt
ada/2-cores  134,014 rt/s   9.42
ada/4-cores  133,398 rt/s  12.31
ada/8-cores  133,132 rt/s  17.31
go/default   111,188 rt/s  33.67
tokio/default 100,927 rt/s 39.06
```

Two shards is where the Ada server stops gaining throughput on this load and
starts only spending more CPU. Latency, one connection and 5000 sequential
round trips: **Ada 12.8 us**, Go 13.0, Tokio 14.0.

### Kept for contrast: the same suite with everything pinned (`bench/results/20260905-noring`)

The last run before the scaffolding came out, with Go and Tokio pinned to
the Ada shards' four cores. It is not superseded so much as answering a
different question -- "same cores each" rather than "as deployed" -- and the
pair is more useful than either alone. Read it against the unpinned tables
above and the CPU column is the story: pinned, all three sit between 9.8 and
15.5 us per round trip; unpinned, Ada stays at 10-14 and the other two go to
21-51.

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

Server CPU per round trip, all three on the same four cores: Ada 11.2-12.5
us, Go 9.8-12.6, Tokio 13.7-15.5 -- which is the point of keeping this run.
Given the same cores, Go is as cheap per round trip as this runtime is;
given the whole machine it is three times dearer. Peak RSS is where this
runtime pays either way -- Ada 25-32 MB against Go's 11-30 and Tokio's 6-9,
one 64 KiB fiber stack per live connection.

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
4. **The last two Windows `Off` bodies.** See *Windows: what closed the gap,
   and what is left*. `Ffi.Win32`'s spec, `Ffi.Sys` and `Ffi.Net` are `On`;
   what remains is `Ffi.Win32`'s body, which needs a way to resolve an entry
   point without `Unchecked_Conversion` to an access-to-subprogram and has
   none, and `Iour.Reactor`.
5. **STAL's other half, if it is ever worth it.**
   `Iour.Ffi.Fiber.Machine` proves the register file is exchanged and proves
   the *initial* frame's placement; it says nothing about what is on a
   suspended fiber's stack, because `L_Rsp` is modelled as one more location
   that round-trips. Typing the stack the way stack-based TAL does would
   need frame layouts the compiler owns and this runtime never sees, so it
   is not a small change and may not be a possible one against GCC-generated
   frames. Listed so that "the context switch is proved" is not read as more
   than it is. See *The context switch is proved*.

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
where the rule and the evidence for the current `Off` bodies live — four on
Linux, plus `Ffi.Win32`'s body and the reactor on Windows. Where a body has
to stay `Off`, the next move is to lift what it *means* into a proved
companion beside it and reduce the `Off` body to the part the language
genuinely cannot express; `Iour.Ffi.Fiber.Machine` is the worked example.
`SPARK_Mode => Off` is confined to the trusted base listed in the README's
*SPARK status* table;
adding another needs a reason of the same kind, and needs `--mode=check_all`
run to show that `On` was not possible.
