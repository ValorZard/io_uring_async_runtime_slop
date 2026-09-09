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
make check-aarch64   # compile the AArch64 backend from anywhere, no codegen
make prove           # SPARK proof of the library
make prove-consumers # SPARK proof of the examples and tests, with -U
make abi-check       # io_uring UAPI mirrors vs headers    (Linux only)
make bench           # vs tokio and Go                        (both systems)
```

The project file picks the backend from the `OS` environment variable, which
Windows sets for every process and no Unix does. Override with
`-XIOUR_OS=linux` or `-XIOUR_OS=Windows_NT`.

Two more scenario variables, neither of which any environment variable can
supply:

* `-XIOUR_ARCH=x86_64|aarch64` -- which context switch. Nothing portable
  exports the machine type, so it defaults to `x86_64` and an AArch64 build
  asks for itself. Getting it wrong builds nothing subtly wrong: the
  assembler rejects the other target's instructions.
* `-XIOUR_SHARDS=1..8` -- how many shards. See *Shards, cores and the
  build*.

**Always run `make check-linux` before finishing a change to shared code.** It
compiles the *other* backend without generating code, needs no cross toolchain,
and catches everything that would only break over there. Use `--subdirs=` so it
does not clobber the real object directory:

```
alr exec -- gprbuild -P examples.gpr -XIOUR_OS=linux --subdirs=crosscheck \
  -j0 -c -f -cargs -gnatc
```

The same trick checks the AArch64 backend, and it is the cheap answer to
"does this compile over there": `-gnatc` is semantic analysis only, so the
host compiler does it and no cross toolchain is involved. It catches
everything the language catches, the static-string rule an `Asm` template
has to meet included. **Run it before finishing any change to shared code,
the same as `check-linux`.**

```
alr exec -- gprbuild -P examples.gpr -XIOUR_OS=linux \
  -XIOUR_ARCH=aarch64 --subdirs=aarch64check -j0 -c -f -cargs -gnatc
```

What it cannot catch is whether the instruction text *assembles* -- that
needs a real aarch64 `as`, and so needs the VM. See *Running on AArch64
under qemu*.

`gnatprove` also runs against the Linux backend from Windows — it generates no
code either:

```
alr gnatprove -P io_uring_async_runtime.gpr -XIOUR_OS=linux --mode=all --level=3 -j0
```

Current state, all measured after deleting `obj/gnatprove`:
**Linux x86_64 1217 checks proved, 2 justified; Linux AArch64 1252 proved,
2 justified; Windows 1037 proved, 1 justified. Nothing unproved anywhere.**

And, separately, the *consumers*: **`make prove-consumers` proves 1721
checks**, covering the echo server, the echo client, `smoke` and
`multi_await` against the library, with their fiber bodies race-checked
through the witness every `Iour.Fibers.Job` instance carries. It was 1586
while that witness was one per program rather than one per job. See *Fiber
bodies are numbers, not pointers* for why that target exists, and
*Race-checking fibers* for what makes the fiber bodies visible to the
data-race rule at all.

Every justification is `unused global
"Ffi.Kernel"` on a portable spec whose two bodies do different amounts:
`Ffi.Net.Initialize` and `Ffi.Sys.Bind_To_Cpu` on Linux, which do less than
Windows, and `Ffi.Sys.Ignore_Broken_Pipe` on Windows, which does less than
Linux. The contract is the union in each case. Do not "fix" them by narrowing
it.

**Delete `obj/gnatprove` before quoting a number.** The three configurations
share it, and a run that inherits another one's session reports a total
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
src/arch/aarch64-aapcs64/ context switch, AAPCS64, and its proved model
src/config/shards-<n>/   one declaration of Iour_Config per shard count
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

* `Ffi.Fiber` (per ABI) — the `Asm` call itself. Not "inline assembly is
  unanalysable" as a matter of taste: `System.Machine_Code` is declared
  `SPARK_Mode => Off` in the runtime, so `On` gives `"Asm" is not allowed in
  SPARK (due to entity declared with SPARK_Mode Off)`, and the same for
  `Asm_Input_Operand`, `Asm_Output_Operand` and their `No_*` companions.
  The AArch64 body adds `E0002` for `'Address` on top.
  This is the one whose *content* has largely
  escaped anyway: `Iour.Ffi.Fiber.Machine` is `On` and proved, and what is
  left in the `Off` body is the `Asm` calls, two slot addresses and one
  write through a computed address.  See the section below.
* `Ffi.Memory` — `E0002`, `'Address` outside an attribute definition clause,
  on three of its four subprograms.
* `Ffi.Uring.Memory` — `E0002` again, and `E0001` effectively volatile object
  not at library level for the atomic ring words.
* `Ffi.Identity` — a `Global` that cannot be told the truth. See below.

`Ffi.Memory.Advance` is the near miss, and it looks like a gap when it is not.
It takes no address — it is `Base + Storage_Offset (By)` — and it is legal
SPARK. Analysed, it yields exactly one *unprovable* check: its postcondition
`Advance'Result /= System.Null_Address`. SPARK does not axiomatise
`System.Address` arithmetic, so nothing constrains the result and nothing ever
will. `On` buys a permanently unproved check or a third justification, so it
stays with the other three, where that postcondition is a promise about memory
rather than a proof obligation.

`Ffi.Identity` is the one to be careful with, and the symptom has changed
since this was first written -- so do not go looking for the old one. It used
to pass `check_all` outright, which made it the subtle case. On GNAT 15.2 it
fails instead, with

```
error: "Slot" is referenced in expression function but missing from the Global
```

because `Current` is declared `Global => null` while reading `Slot`. **The
reason for `Off` is unchanged and the new error does not weaken it.** The
error is trivially "fixable" -- put `Slot` in the `Global` -- and fixing it
is the mistake: SPARK ignores `pragma Thread_Local_Storage`
(`ignored-pragma`) and models the one per-thread slot as one shared
variable, so `On` would prove a single-slot runtime this is
not. `Current` is declared `Global => null` because it is a question about the
*calling thread*, and per-thread state is something SPARK has no model for.
Legality is necessary and not sufficient; the question is always whether the
analysed program is the one that runs.

### Windows: what closed the gap, and what is left

`Ffi.Win32`'s **spec**, `Ffi.Sys` and `Ffi.Net` are `On` on Windows, as they
are on Linux. What is still `Off` there is `Ffi.Win32`'s **body** and
`Iour.Reactor`, and the two are *not* off for the same kind of reason --
which this section used to claim and which is worth being precise about,
because one of them is a live lead and the other is not.

`Ffi.Win32`'s body has **three** independent hard errors, not just the
`Unchecked_Conversion` from `System.Address` to access-to-subprogram that
`Load_Socket_Extensions` is made of. Flipping it to `On` also gives `E0004`,
a volatile object in an interfering context, and `E0002`, `'Address` outside
an attribute definition clause. So solving the entry-point resolution would
not by itself buy `On`; all three would have to go.

`Iour.Reactor` is the one whose `Off` is **not established**. See *The
Windows reactor is the one unestablished `Off`* below. Both checks run
against the Windows configuration from Linux; neither generates code:

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

### The Windows reactor is the one unestablished `Off`

Re-audited 2026-09-08 by flipping every `Off` body to `On` and running
`--mode=check_all -j0 -U` in its own configuration -- the cheap question,
seconds rather than minutes. Six of the seven answered with a language wall.
This one did not, and the distinction is the point of the audit:

| body | what `On` says |
|---|---|
| `Ffi.Fiber` x3 | `"Asm" is not allowed in SPARK` (`System.Machine_Code` is `Off`) |
| `Ffi.Memory` | `E0002` `'Address` |
| `Ffi.Uring.Memory` | `E0002` `'Address` |
| `Ffi.Win32` body | unchecked conversion to access-to-subprogram, `E0004`, `E0002` |
| `Ffi.Identity` | a `Global` that cannot be told the truth |
| **`Iour.Reactor`** | **`state "Engines" requires refinement`** |

That last is not an `E000x`. It is a missing `Refined_State`, which is
ordinary contract work -- and the Linux reactor, which is `SPARK_Mode => On`,
already has one. "A reason of the Linux kind" was exactly backwards as a
description: the Linux reactor is the *worked example*, not the precedent for
giving up.

Two layers were cleared before this was stopped:

1. **The refinement is writable.** The body's package-level state is only
   `Engines_Data` and `Wake_Flags`; everything else at that level is a
   constant. `Refined_State => (Engines => (Engines_Data, Wake_Flags))` gets
   past the first error.
2. **Then: `constituent of synchronized state "Engines" must be
   synchronized`.** The shared spec declares `Abstract_State => (Engines with
   External, Synchronous)`, so the constituents have to be synchronized
   objects. Also contract shape, and also something the Linux side solved --
   its constituents are the `Cells` of packages that declare them
   appropriately.

**What is not known** is what lies behind those two, because the run that
would have said was killed before it finished. Full legality checking with
the reactor `On` takes far longer than the Global-generation phase that
reports the first two errors, which is itself a signal that it gets a good
way in. At least one plausible wall is visible by inspection: the body
instantiates `System.Address_To_Access_Conversions`, which is access-type
machinery, and there are `'Address` uses in the slot-pool arithmetic of the
kind that give `E0002` elsewhere.

### Running the probe

Before anything else, because the probe has now been killed part-way three
times across two sessions and each time it looked like a hang:

* **Never wrap it in `timeout`.** `timeout` kills `alr`, and `alr`'s death
  does not take `gnatprove`'s `gnat2why` children with it. They keep running,
  orphaned, with their output going to a pipe nobody reads -- so the log
  stays empty and the process list stays busy, which is indistinguishable
  from a hang until you check the parent.
* **Redirect to a file; do not pipe to `tail` or `grep`.** A pipeline shows
  nothing until the writer exits, and if the writer is killed you lose
  everything it had produced.
* **Run it in a scratch copy of the tree**, not in the repository. It takes
  long enough that you will want to keep working, and the mutation it needs
  -- the reactor flipped to `On`, and `Synchronous` dropped from the shared
  spec to get past the second wall -- must not be committed by accident.
* **Budget properly, and expect more than an hour.** The longest clean
  attempt so far ran 55 minutes in phase 2 alone, on a single `gnat2why`
  process, and was stopped there rather than finishing -- so the wall
  behind the two contract errors is *still* unseen, and nobody has yet
  paid the whole cost of looking. Compare `--mode=check_all` on the
  unmutated tree, which is seconds. That gap is itself the most
  interesting datum anyone has collected about this question: the body is
  large and Global generation over it is not cheap.

So the honest state is: **`Off` here has never been shown to be necessary**,
where for the other six it has. Anyone picking this up should start by
re-running the probe and letting it finish:

```
--  in the body
package body Iour.Reactor with SPARK_Mode => On,
  Refined_State => (Engines => (Engines_Data, Wake_Flags))
is
```

then `--mode=check_all` against `-XIOUR_OS=Windows_NT`, and read what comes
after the synchronization error. If it is `E0002`/`E0004` all the way down,
write that here and close the question. If it is more contract work, the
Linux reactor is the model. Either way the next person should not have to
re-derive the first two layers.

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

### What a missing register actually does

Worth knowing before hunting one, because it is almost never the
segmentation fault people expect. A register the switch fails to preserve
comes back holding the *other* fiber's value, and what that costs depends
entirely on which register it was:

* **`rsp`** is the one that faults immediately and unmistakably.
* **`rbx`, `rbp`, `r12`-`r15`, `rdi`, `rsi`** corrupt silently. A crash
  needs the value to have been a pointer that something then dereferences,
  and it then lands far from the switch with an innocent-looking stack
  trace. A loop counter or an index gives wrong answers and no crash at
  all.
* **`xmm6`-`xmm15`** corrupt vectorised code, which on a modern compiler
  includes `memcpy`. Wrong *data*, essentially never a fault.
* **`mxcsr` and the x87 control word** leak rounding modes and exception
  masks between fibers. Completely silent: arithmetic that is subtly
  wrong, or a spurious FP exception thousands of switches later.
* **The three TEB fields** are the likeliest to fault, because
  `___chkstk_ms` reads `StackLimit` and the unwinder reads `StackBase`. A
  fiber running on another fiber's bounds either faults inside the probe
  or breaks exception propagation, in both cases somewhere
  unrecognisable.

So the dominant mode is silent wrongness rather than a crash, which is the
argument for checking the set mechanically instead of waiting to be told.

### Asking GCC what the callee-saved set is

GCC emits `.seh_pushreg` and `.seh_savexmm` only for registers it is
*obliged* to preserve, so the compiler will state the ABI's callee-saved
set if you apply enough register pressure. Two throwaway C functions --
one holding a dozen live doubles across calls, one holding ten live longs
-- produced exactly this on this machine:

```
rbx rbp rdi rsi r12 r13 r14 r15
xmm6 xmm7 xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14 xmm15
```

which is `Location`'s general set minus `L_Rip` and `L_Rsp`, plus its
whole xmm range. Eighteen of the twenty-five locations, agreed by an
oracle nobody typed. That is the property worth having: every other
artefact here derives from `Location`, so they cannot disagree with it,
and this one does not.

Measured on Win64. The SysV analogue is `.cfi_offset` and has not been
tried here.

What it does not reach: `L_Mxcsr`, `L_Fpu_Cw` and the three TEB fields are
not prologue-saved registers and never appear in the directives, and
`L_Rip`/`L_Rsp` are structural rather than preserved. Those seven still
rest on a human reading the ABI -- though they are also the ones hardest
to omit unnoticed, being conspicuous rather than one of a numbered series,
which is where an omission is actually plausible.

Not wired into `make`; it was run by hand, and it is two `gcc -O2 -S` runs
and a `grep -oE "seh_pushreg|seh_savexmm"` over the output.

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
  consistent and wrong together. This is the one of the three that does
  not have to stay that way: eighteen of the twenty-five locations can be
  cross-checked against the compiler rather than reasoned about. See
  *Asking GCC what the callee-saved set is*.
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

There are three targets now -- x86-64 SysV, x86-64 Win64 and AArch64
AAPCS64 -- and the AArch64 one is the worked example of a target whose
*mechanism* differs, not just its register file: see *AArch64, the third
target* before assuming a fourth can be a naked subprogram with an `Asm` in
it.

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
`io_uring_async_runtime.gpr` -- under `Host_Arch`, which is what
`-XIOUR_ARCH` selects -- and write the `Asm` body against the same spec the
other three use.

Two more things the AArch64 target had to establish that a fourth should
check before assuming either way:

6. **Does this target have naked subprograms?** x86-64 does; AArch64 does
   not, and GCC says so only as an ignored-attribute *warning*. If it does
   not, assemble the function whole inside `.pushsection`/`.popsection` and
   bind it with `Import`, which keeps the template an Ada constant and so
   keeps the render check.
7. **Does the ABI want the entry frame at 8 or 0 modulo 16?** Both x86
   targets want 8, because a `call` has pushed a return address.  A
   link-register ABI wants 0 and has no return slot to leave room for;
   `Layout.Entry_Sp_Offset` is the sibling of `Return_Slot_Offset` for
   that case.

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

**Re-run against the AArch64 target (2026-09-08).** Its templates share no
text with either x86 one, so the character positions are its own. Swapping
x21's and x22's save displacements gives `switch: MISMATCH at 99` and
`Emitted_Matches_Model = FALSE`. That was done in the scratch project from
*The Windows model can be exercised from Linux*, which works in this
direction too: the AArch64 model depends on nothing AArch64-specific, so it
can be rendered and checked on Windows without a cross toolchain.

**Re-run against the Win64 target, on Windows (2026-09-07)**, because the
table above was built on the SysV one and the two templates share no text:

| mutation | caught by | message |
|---|---|---|
| swap `r13`'s and `r14`'s save displacements | start-up text walk | `smoke` FAIL, character 131 |
| break `Save_One`'s body *and* its `Post` together | `Target.Save_Obligation` | `assertion might fail`, in `iour-ffi-fiber-target.adb:30`, reported at the instantiation `iour-ffi-fiber-machine.ads:335` |

The first of those also exercises the gate that matters, which `smoke`
only reports on. Built with the swapped displacements, `echo_server`
starts, every shard reports zero completions, zero resumes and zero kernel
sleeps, and the process exits without serving a connection:
`Reserve_Contexts` refused all four. **It exits 0 and prints an ordinary
banner**, so outside `smoke` a broken switch is silent -- the per-shard
counters are the tell.

**The one link the start-up check cannot see** was closed by hand at the
same time. That check compares the template constant against the model,
and `Asm` consumes that same constant, but nothing in the program looks at
what the assembler actually produced. `objdump -d obj/iour-ffi-fiber.o` on
Windows is the template instruction for instruction: ascending saves from
0x00 to 0x100, descending restores, the TEB fields through `rax`,
`jmp *(%rdx)`, and `lea 0x13f(%rip),%rax` resolving to the `1:` label at
0x146. The context stride is 0x110, which is `Context_Bytes`. Worth
redoing after any change to the template, and it is one command.

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

## AArch64, the third target

`src/arch/aarch64-aapcs64/`, against the same `Iour.Ffi.Fiber` spec as the
two x86 ones and instantiating the same `Iour.Ffi.Fiber.Target`. Everything
in *The context switch is proved* applies unchanged; what follows is only
what is different, and the first item is different enough to have shaped the
whole file.

### GCC has no naked subprograms here

Both x86 bodies rely on `pragma Machine_Attribute (Swap, "naked")` to make
the `Asm` template the entire function. **That attribute does not exist on
AArch64.** GCC accepts it and ignores it:

```
warning: 'naked' attribute directive ignored [-Wattributes]
```

Measured on the target with GCC 12.2 and again with 14.2, not read off a
document. A context switch with a compiler prologue around it is not a
context switch: the prologue would save x29 and x30 onto the *outgoing*
fiber's stack and the epilogue restore them from the *incoming* one.

So the two functions are assembled whole, out of one `Asm` block bracketed
by `.pushsection .text` / `.popsection`, and reached through `Import`:

```ada
procedure Emit_Switch_Code
  with Convention => C, Export,
       External_Name => "iour_aarch64_emit_switch_code";
```

The bracketing is what makes it safe: everything between the directives goes
into `.text` as its own symbol and the enclosing subprogram's instruction
stream is untouched, so it does not matter what GCC emits around it. It is
`Export`ed and never called -- an exported subprogram cannot be dropped as
unreferenced, where a local one could, and calling it would buy nothing.

**The point is what survives.** The template is still an Ada constant of
`Machine`, so `Emitted_Matches_Model` still walks the proved instruction
sequence and compares it with the string handed to `Asm`, character for
character. The verification argument is not weakened by the change of
mechanism; only the wrapper directives are outside the check, and they
contain no instructions.

Verified on the target before the real file was written: a function defined
this way out of `add x0, x0, #7` and `ret` returns its argument plus seven --
which a prologue would have disturbed -- and the next symbol begins exactly
eight bytes later, so those two instructions are the whole function.

### Two escaping and staticness rules, both of which bite

* **`%` in an Asm template.** GCC reads it as introducing an operand number,
  so the `%function` a `.type` directive needs is written `%%`. Getting it
  wrong is a compile error -- "operand number missing after %-letter" -- not
  silent damage. This is the same doubling `Fiber.Text.Sigil` provides for
  the x86 register names, needed here for an unrelated reason: AArch64
  register names carry no sigil, so `Switch_Template` contains no `%` at all.

* **A function call is never static** -- RM 4.9(6,18) -- and GNAT requires an
  `Asm` template to be static. Building the wrapper with
  `Head (Swap_Symbol) & ...` is the obvious way to avoid writing it out twice
  per symbol, and it fails with "asm template argument is not static". The
  four wrappers are written out as `constant String`s instead. Concatenation
  of literals and of constants *is* static and folds, which is also what lets
  `Machine.Switch_Template` live in another package.

### The location set, and why it is 23 locations in 184 bytes

```
L_Pc  L_Sp  L_X19..L_X28  L_X29  L_X30  L_Fpcr  L_D8..L_D15
```

All eight bytes wide, so the model is uniform like the SysV one rather than
four-width like the Win64 one. Four things differ from x86 and each forces
something:

* **The link register is a location.** x86 pushes a return address and `ret`
  pops it; AArch64 keeps it in x30 and `ret` branches to it. So x30
  round-trips like any other callee-saved register, and a resumed fiber
  returns to *its* caller because its own x30 came back with it. `L_Pc` is
  still separate and still `Location'First`: the resume label's address,
  saved and never restored, and the incoming context's copy is the branch
  that ends the sequence.
* **The stack pointer is not addressable.** `str sp, [x0, #8]` does not
  encode -- register 31 reads as the zero register in that position -- so
  `L_Sp` goes through the scratch register both ways, exactly as the Win64
  target's TEB fields do. `L_Fpcr` is the same shape because `mrs`/`msr`
  name a system register, not memory.
* **Only the low half of v8-v15 is callee-saved.** AAPCS64 obliges a callee
  to preserve d8-d15, that is bits 0-63, and nothing above. So these are
  eight-byte slots written with `str d8`, and the context is *smaller* than
  the Win64 one despite covering more registers.
* **The tail is four instructions, not three.** AArch64 has no branch
  through memory, so the jump loads the target first: `ldr x16, [x1, #0]`
  then `br x16`. `Max_Ops` is 4 here against 3 on both x86 targets.

x16 is the scratch (IP0, which AAPCS64 lets a linker veneer destroy, so no
caller can expect it to survive). `Fr.State`'s scratch field is named `Rax`
for the target that was written first; here it stands for x16.

### The one change to the portable half

`Layout.Return_Slot_Offset` promises `mod 16 = 8`, which is an artefact of
x86: a `call` has pushed a return address and the ABI's 16-byte guarantee is
measured before that push. AAPCS64 keeps the return address in x30 and wants
the stack pointer 16-byte aligned whenever it addresses memory -- the
hardware faults otherwise with `SCTLR_EL1.SA` set -- so this target uses a
sibling, `Layout.Entry_Sp_Offset`, whose postcondition is `mod 16 = 0` and
which subtracts no return slot. It is additive; both x86 targets are
untouched and `Layout` proves at 34 checks under either arch.

`Entry_Reserve` is 0: AAPCS64 defines no red zone, where SysV reserves 128
bytes and Win64 a 32-byte shadow store. And `Prime` writes nothing to the
stack at all -- the "nothing ever returns here" sentinel goes in the
context's x30 slot, which is where AAPCS64 returns through.

### What is proved, and what was checked from Windows

* **210 checks** for `iour-ffi-fiber-machine.adb` alone; **1240 for the whole
  AArch64 configuration**, 0 unproved. (Linux x86_64 is 1205.) All of it from
  Windows: the model is ordinary Ada and gnatprove generates no code.
* **The template matches the model**, also checked from Windows, with the
  scratch-project technique the Win64 section describes -- copy the portable
  half plus this target's `Machine` into a throwaway project with a stub
  `Iour.Ffi.Fiber` body and call `Check_Switch_Text`. It reports
  `Context_Bytes = 184`, `template length = 964`, `switch: MATCHES`,
  `trampoline: MATCHES`.
* **The render check is load-bearing here too**: swapping x21's and x22's
  save displacements in that scratch copy gives `switch: MISMATCH at 99` and
  `Emitted_Matches_Model = FALSE`, which is what `Reserve_Contexts` gates a
  shard's start on.

None of that assembles the text. That took the VM, and it worked first
time: the library built, `smoke` linked, and the start-up check passed on
the target.

---

## Fiber bodies are numbers, not pointers

The one change a consumer sees, and the reason for it is a SPARK rule that
makes the obvious API impossible.

`Iour.Fibers.Spawn` used to take a `Fiber_Body`, which was
`access procedure (Arg : Fiber_Argument)`, and every caller wrote
`Spawn (Handler'Access, Arg, H)`. **SPARK rejects that outright:**

```
error: access to subprogram with global effects is not allowed in SPARK
--> echo_client.adb:80:18
   80 |    Fibers.Spawn (Echo_Client_App.Driver'Access, 0, Handle);
```

An access-to-subprogram type in SPARK carries an implicit `Global => null`,
and `'Access` is legal only on a subprogram that meets it. A fiber body that
does any I/O has global effects by definition, so **no SPARK program could
spawn a fiber at all** -- the runtime was unusable from SPARK for the one
thing it exists to do.

Two things kept that invisible for as long as it was true:

* **`make prove` never looked at a consumer.** It runs against
  `io_uring_async_runtime.gpr`, which holds only the library. The echo
  server, the echo client, `smoke` and `multi_await` are all
  `SPARK_Mode => On` and none of them had ever been through gnatprove. The
  first run found three illegal spawns and five other legality errors.
  `make prove-consumers` is that run, and it exists so this cannot recur.

* **The library's own proof was reading the fiber body as a no-op.** SPARK
  models a call *through* an access-to-subprogram as touching nothing, and
  `Fiber_Main` called `Work.all (Param)` inline in a `SPARK_Mode => On`
  body. So every check above it was discharged against a fiber body that
  does nothing -- an assumption that was not merely unstated but
  unsatisfiable, since nothing could legally construct such a pointer.

### What it looks like now

A job is registered once, by instantiating a generic with an ordinary
procedure, and spawned through the instance:

```ada
   procedure Serve (Arg : Fiber_Argument);
   package Serve_Job is new Iour.Fibers.Job (Work => Serve);
   ...
   Serve_Job.Spawn_Here (Fiber_Argument (Incoming), Started);
```

No access value appears in consumer code, so the rule never applies to it.
`Iour.Fibers.Spawn`, `Spawn_Here` and `Spawn_On` now take a `Job_Id`, a
small integer into a table -- the same shape as every other handle here, and
the shape `Iour`'s header always claimed all of them had. `Fiber_Body` still
exists but has moved to `Iour.Fibers`'s **private part**, where no consumer
can name it.

The instance is the handle. `Number` is there for code that wants the job
number itself; most callers never see one.

### The three Ada rules that shape the generic, each of which names its own fix

Do not re-derive these. Every one of them was hit, and every one gives an
error message that says what to do.

1. **`'Access` of a generic formal subprogram is not subtype conformant**
   (RM 6.3.1(17/3)). So the generic cannot take `Work'Access` directly;
   `Trampoline` is an ordinary procedure that calls the formal, and it is
   `Trampoline'Access` that gets registered. One extra call per fiber start,
   which is once per connection and not on any I/O path.

2. **`'Access` in a generic *body* is illegal when the access type is
   declared outside the generic** (RM 3.10.2(32)), and `Fiber_Body` is --
   it lives in `Iour.Fibers`'s private part. GNAT's own diagnostic says
   "move 'Access to private part, or use an anonymous access type instead".
   The anonymous route is a dead end: an anonymous access-to-subprogram
   parameter cannot be *stored* -- RM 3.10.2(13), "value has deeper
   accessibility than any master". So the constant lives in the private part
   of the generic's **spec**.

3. **The private part is where the `SPARK_Mode => Off` goes.** With it On,
   every instantiation fails with `"Ref" is not allowed in SPARK (due to
   access to subprogram with global effects)`, reported at the consumer's
   instantiation rather than in the library. `pragma SPARK_Mode (Off);`
   immediately after `private` confines it to those two declarations.

There is no fourth option. A `Global` aspect on the access-to-subprogram
type is what SPARK ought to want here, and GNAT 15.2 does not accept it:
`error: incorrect placement of aspect "Global"`, from the compiler rather
than from gnatprove, with `-gnat2022` on, for both `Global => null` and a
real one. Checked in both directions; do not spend the afternoon on it
again.

### The generic's body cannot be `On`, and the reason is a chain of Ada rules

Worth writing down, because "the private part is `Off`, so move the
`'Access` into the body and keep the body `On`" is the obvious next idea
and it does not work. Every step below was tried:

* **An `Off` private part forces an `Off` body.** `error: incorrect use of
  SPARK_Mode ... value Off was set for SPARK_Mode on "Job"`. So the two
  cannot be separated the way `Invoke`'s declaration and body are.
* **Declaring the access type inside the generic body** does escape RM
  3.10.2(32) -- `'Access` becomes legal -- but then the value cannot be
  handed to `Register`: `error: target type must be declared in same
  generic body as operand type`. Converting an access type declared inside
  a generic body to one declared outside is illegal, whatever the
  accessibility levels work out to.
* **Declaring it inside `Enrol`** rather than at the instance's level fails
  earlier still: `operand type has deeper accessibility level than target`.

So the whole of `Iour.Fibers.Job` is a trusted body, not just its private
part. It is thirty lines of wrappers and one registration, all of it
visible on one screen, and its spec carries the `Global`s everything above
is checked against -- which is the same arrangement as `Ffi.Win32`, for the
same reason: the language has no way to express what it does.

### The registry, and why it is a protected object

`Iour.Fibers` holds one table from job number to `Fiber_Body`. Registration
happens when an instance elaborates, which under this partition's
`Partition_Elaboration_Policy (Sequential)` is before any shard task exists,
so the table is complete and unchanging by the time anything reads it.

That is exactly what SPARK's `Constant_After_Elaboration` describes, and it
would have cost nothing -- but **SPARK RM 6.1.4(22) forbids such a variable
from being an output of any subprogram at all**, and registration
necessarily is one. Measured, not guessed: `high: constant after
elaboration "Jobs" ... must not be an output of subprogram "Install"`. Only
the declaring package's own elaboration may write such a variable, and the
writes come from the consumer's instantiations.

So it is a protected object, like every other shared table here. The lock is
taken once per fiber start, on a path that already takes
`Fiber_Bank.Allocate`, and never on the I/O path.

### `Invoke`, and the assumption that is now written down

The indirect call is confined to one subprogram in `Iour.Fibers`, whose
declaration is `On` with a `Global` and whose body is `Off`:

```ada
   procedure Invoke (Work : Fiber_Body; Arg : Fiber_Argument)
     with Pre    => Work /= null,
          Global => (In_Out => (Banks, Shard_Cells, Jobs, ...,
                                Futures.Table, Run_Queue.Queue,
                                Reactor.Engines, Trace.Switch, Ffi.Kernel));
```

This does not make SPARK's model of the call true. It makes it **one named
place with the assumption written on it**, and it replaces `Global => null`
with the union of every state a fiber body can reach inside this library,
which is a great deal closer to the truth. What it still cannot name is the
consumer's own state; see *What SPARK proves about deadlock and data races*.

Note the shape: `Off` on the **body only**. An `Off` *declaration* cannot be
called from SPARK code at all -- `"Invoke" is not allowed in SPARK (due to
entity declared with SPARK_Mode Off)` -- which is the same trap
`Ffi.Posix`'s imports avoid by declaring their `Global`s.

### Adding a fiber body

* The actual has to be **declared before the instantiation**, and the
  instance has to be **at library level** -- it registers from its own
  elaboration, and a job that came and went with a stack frame would leave a
  dangling entry. A procedure already declared in the package's spec needs
  no forward declaration and the instance can stand at the top of the body;
  one private to the body needs a forward declaration ahead of it.
* `Max_Jobs` is 64 and bounds *kinds* of fiber, not live fibers. Overflow
  yields `No_Job`, which the generic's `Spawn` wrappers report as "did not
  start" rather than raising: it is a fact about the program, not a runtime
  condition.
* Instantiating inside a main procedure does not work -- a main procedure's
  declarative part is not library level. Put the instance in a package body
  and export a wrapper, which is what `Echo_Server_App.Start_Acceptor` and
  `Echo_Client_App.Start_Driver` are for.

---

## Proving a consumer: what the examples had to change

`make prove-consumers` went green only after the four programs stopped doing
things SPARK forbids. None of those changes were about the runtime; all of
them are things any SPARK program using it will meet, so they are worth
knowing before writing the next one.

**A volatile object may appear only as the whole right-hand side of an
assignment** (SPARK RM 7.1.3(9)) -- not as an actual parameter, not as an
operand, not as a condition. `Atomic` implies volatile, and a protected
function is a volatile function, so

```ada
   if Distribute then                       --  E0004
   exit when Stats.Accept_Limit_Reached;    --  E0004
   Net.Connect (Sock, Host_String, Server_Port, Status);   --  E0004
```

all become a read into a local first, then the test. Two lines apiece, and
nothing at run time.

**A function may not read a volatile object at all** (E0005). `Goal` in the
server and `Session_Count` in the client were `Atomic` variables read by
protected functions; both moved *into* the protected object that reads them,
which is simpler than what it replaced and says something truer -- they are
read under the same lock as the counters they are compared with.
`Host_String` stopped being a function returning `String` and became a
procedure with an out parameter.

**Spell an `Atomic` variable's external properties out.** Defaulted,
`Atomic` means `External` with all four True, and `Effective_Reads => True`
says reading is itself an act that changes the thing read -- true of a
hardware FIFO and of nothing in an application. All four False is *illegal*,
SPARK RM 7.1.2(6): at least one of `Async_Readers` and `Async_Writers` must
be True. The shape that works for "written by one thread, read by others" is
`Async_Writers` alone, which is how `Iour.Trace`'s `Enabled` flag has always
been declared.

**No conversion between fixed-point and floating-point.** The client's
throughput line was `Long_Float (Frames) / Long_Float (Elapsed)`. It is now
integer arithmetic over `Ada.Real_Time`'s division of one `Time_Span` by
another, which yields an `Integer` count directly and needs no `Duration` at
all -- and so also sidesteps proving that `To_Duration`'s result fits in
`Duration`, which SPARK cannot.

**Saturate statistics counters.** Unbounded `Natural` increments are
unprovable overflow checks, and a server runs for as long as the process
does, so they are not spurious. Both apps now use the `Bump` idiom
`Iour.Scheduler` already had.

---

## Running gnatprove without lying to yourself

Four ways a proof run in this repository reports something other than what
you asked it. Every one of them was hit in a single session, and three of
them produce a *plausible* answer rather than an error, which is what makes
them worth a section.

**Never build in the repository while a proof is running there.** `gprbuild`
and `gnatprove` share `obj/`, and a build started underneath a proof kills
it part-way: the run ends with `gnatprove: error during flow analysis and
proof` and no failing check named. That looks exactly like a real
regression in whichever configuration happened to be running. It cost an
afternoon's confusion over an AArch64 "failure" that re-ran clean at 1252
the moment nothing else was touching the directory. Either wait, or work in
a copy -- `tar cf - --exclude=obj --exclude=lib --exclude=bin` into the
scratchpad takes seconds and has its own object directory.

**Never wrap a long run in `timeout`.** `timeout` kills `alr`, and `alr`'s
death does not take `gnatprove`'s `gnat2why` children with it. They keep
running, orphaned, writing to a pipe nobody reads -- so the log stays empty
and the process list stays busy, which is indistinguishable from a hang
until you check the parent's start time. Redirect to a file rather than
piping to `tail` or `grep`, too: a pipeline shows nothing until the writer
exits, and if the writer is killed you lose everything it produced. Both
halves of this were learned on the Windows reactor probe, which was killed
three times across two sessions before anyone noticed why.

**`-U`, or you are proving less than you think.** Without it gnatprove
analyses only the units reachable from `for Main use`, and
`examples.gpr`'s list does not include `multi_await.adb`. `make
prove-consumers` reported "all checks proved" for a long time while
silently skipping a quarter of what it claims to cover; the moment `-U` was
added, `multi_await_workload` produced a dozen ordinary obligations that
had never been looked at. Any new main added to `tests/` or `examples/`
inherits the same trap unless it goes in `for Main use` as well.

**A single-unit run used to do no race analysis at all**, and no longer
does nothing: the two witness tasks now come with the `Iour.Fibers.Job`
instance, so a `gnatprove -u <workload>.adb` run has both halves of the
pair inside the unit it is looking at. The trap as it stood -- the main
subprogram's call to `Races.Never_Runs` being half the pair, and a
single-unit run therefore silently checking nothing -- died with the
consumer's witness. `-U` is still what `make prove-consumers` passes, for
the unrelated reason above. See *Race-checking fibers*.

**Editing sources with a script can rewrite every line ending.** The tree is
LF; Python's text mode writes `os.linesep`, which on Windows is CRLF, so a
scripted edit turns a three-line change into a whole-file diff and hides
what actually changed. Read and write in binary, or normalise afterwards
(`open(p,'rb').read().replace(b'
', b'
')`) before looking at
`git diff`.

And one that is not a trap so much as a dead end worth recording: **the
`.spark` files do not carry the globals.** They hold entity names with
slocs, plus the flow and proof results, which is enough to see *which*
subprograms were analysed and how they fared and not enough to build a
linter over "what does each fiber body touch". That was the zero-runtime
alternative to the race witness, and this is why it was not taken.

## Running a SPARK concurrency experiment

Most of what is written about SPARK's concurrency rules here was settled by
a throwaway project rather than by reading, and the setup is worth keeping
because every one of these questions is faster to answer than to argue
about. Four files:

```
alire.toml     name/description/version/authors/maintainers/licenses,
               plus [[depends-on]] gnatprove = "^16.1.0"
gnat.adc       pragma SPARK_Mode (On);
               pragma Profile (Jorvik);
               pragma Partition_Elaboration_Policy (Sequential);
<name>.gpr     Source_Dirs "src", Object_Dir "obj",
               Builder.Global_Configuration_Pragmas "gnat.adc",
               Compiler switches "-gnat2022"
src/*.ad?      the question
```

`alr` refuses to run without the manifest -- `Could not detect an alire.toml
manifest` -- which is the only reason the first file is there. The `gnat.adc`
is not optional either: without the profile every tasking construct fails
with `tasking in SPARK requires Ravenscar profile (SPARK RM 9(2))`, and
without `-gnat2022` some of what this codebase does will not parse.

Then `alr gnatprove -P <name>.gpr --mode=all --level=1 -j2` answers in
seconds. The baseline worth building first, because everything else is a
variation on it: two tasks, one unsynchronized library-level variable, one
procedure that touches it, called from both. That reports `high: possible
data race when accessing variable "..."`, and once you have seen it you can
tell a rule that did not fire from a rule that fired and found nothing --
which is the distinction most of these experiments turn on.

---

## Two justification idioms, and where each one has to go

**`pragma Annotate (GNATprove, Intentional, ...)` goes where the check is
reported, and for a check on the subprogram itself that means the first
thing in its declarative part** -- not after the body, which is the obvious
guess and silently does nothing. The four main subprograms all end in
`Ffi.Sys.Exit_Process`, which is `No_Return`, so gnatprove says `high: all
paths in "Echo_Server" raise exceptions or do not terminate normally`. That
is the design -- a Jorvik partition never ends on its own, because the
environment task would block forever on tasks that `No_Task_Termination`
forbids to terminate -- so it is justified rather than fixed, with the
message prefix `"all paths"`.

**`Ada.Real_Time`'s subtraction of two `Time` values cannot be bounded, and
no guard fixes it.** Nothing in the language relates two arbitrary `Time`
values, so `To - From` carries a range check that cannot be discharged --
and a guard written in terms of that same difference carries the same
check, so there is no way to write around it. `pragma Assume` does not help
either: the assumption's own expression contains the subtraction. The
answer is one subprogram with a SPARK declaration and an `Off` body, which
is the shape the runtime uses everywhere else the language cannot express
what a body means; `Echo_Client.Elapsed_Milliseconds` is the only one in
the examples.

Where the arithmetic *can* be avoided, avoid it instead: the client's
throughput line divides one `Time_Span` by another, which `Ada.Real_Time`
defines as an `Integer` count, and so needs no `Duration` and no
fixed-to-floating conversion -- SPARK supports neither that conversion nor
a proof that `To_Duration`'s result fits in `Duration`.

---

## Race-checking fibers: the witness

SPARK's data-race rule fires when an unsynchronized object is reachable
from two tasks. Fiber bodies are reachable from none, so until there was a
witness they were checked for nothing at all.

The break is the trampoline. A fiber is entered through the context
switch's assembly, so gnatprove analyses `Iour.Fibers.Fiber_Main` as a
subprogram nobody calls, and nothing connects a fiber body to a shard task.
(The indirect call through `Iour.Fibers.Invoke` is a second break, but it is
downstream of the first and never gets reached.)

`Iour.Fibers.Race_Witness` closes it, and **nothing instantiates it by
hand**. `Iour.Fibers.Job` does, on the same actual, from its visible part:

```ada
   --  in iour-fibers-job.ads, once, for every job there will ever be
   package Witness is new Iour.Fibers.Race_Witness (Work);
```

So registering a fiber body is what puts it under the rule. A consumer
writes what it always wrote --

```ada
   procedure Serve (Arg : Fiber_Argument);
   package Serve_Job is new Iour.Fibers.Job (Work => Serve);
```

-- and there is no list, no call from the main subprogram, and nothing to
forget. Nothing runs: both witness tasks read an atomic flag nothing ever
sets and take a branch never taken.

**This is not what this section used to say.** The trade it used to
describe was measured correctly and decided wrongly: the witness now costs
a second parked thread per job kind, and buys the removal of every part of
the mechanism that a consumer could get silently wrong.

### Why it is in `Job`'s visible part and not in `Job`

`Job` is where it belongs -- that is the only place in the runtime that
reaches a fiber body directly, everywhere else holds it as a `Fiber_Body`
access value and SPARK sees nothing through an access-to-subprogram. But it
cannot be *in* `Job`, and the reason is a chain already documented here:

`Job`'s private part is `SPARK_Mode => Off` for the one `'Access` the
runtime contains, an **`Off` private part forces an `Off` body**, and a task
body declared in an `Off` package body is analysed for nothing at all. A
witness task written directly into `Job` would compile, park two threads,
and report nothing -- the worst possible failure, because it looks exactly
like a clean run.

So the witness is a sibling generic with a body of its own, which is `On`,
instantiated from `Job`'s **visible** part, which is also `On`. gnatprove
analyses instances, so each job's instance is analysed against that job's
actual, concretely.

The thing to check if this is ever restructured: that the instantiation is
above the `private` keyword in `iour-fibers-job.ads`. Below it, it inherits
the `Off` and the whole mechanism goes quiet.

### Two tasks per job, and the arrangement that came before

The rule needs **two callers of the same body**. One task per job would
catch state shared between *different* jobs and miss state one job shares
with itself across shards -- which is the commoner case and exactly the
`Next_Core` case, so it is not an acceptable weakening. Hence `Witness_A`
and `Witness_B`, both calling `Work`.

What came before got its second caller from the environment task: one
witness per *program*, instantiated on a procedure the application wrote
listing every fiber body, plus one call to `Races.Never_Runs` from `main`.
That cost one thread per program rather than two per job kind. It was the
right answer on thread count and the wrong one overall, because three of
its failure modes were silent and every one of them was the consumer's to
get wrong -- a body left off the list, a missing call from `main`, and a
single-unit `gnatprove -u` run in which the main's unit was half the pair.
None of the three exists now.

**The elaboration trick still does not work**, and it is the thing that
would have got this to one task per job. Making the instance's own
elaboration the second caller is rejected outright: `high: cannot write
"Shared_Counter" during elaboration of "Handler_Job" [E0008]`. The atomic
guard does not help, because E0008 is a flow rule over the call graph
rather than anything gnatprove folds.

So the cost is **two parked threads per kind of fiber**: four for the echo
server and for `smoke`, six for `multi_await`, against one per program
before. Not per fiber -- a server with two thousand live connections still
has four.

### They never run, and neither reason is the obvious one

Two independent things stop a witness task from ever calling a fiber body,
and **the order of the statements in the task body is what buys the first**:

```ada
   task body Witness_A is
   begin
      Never_Opens.Park;   --  an entry whose barrier is False.  Blocks here
      Never_Runs;         --  for ever, so this is never reached
      loop
         Never_Opens.Park;
      end loop;
   end Witness_A;
```

1. **The task blocks before the call.** `Never_Opens.Park`'s barrier is
   `False` and nothing opens it, so the call does not return. This is the
   same mechanism `Iour.Shards` already uses to park a surplus shard.
2. **`Run` is `False`**, and nothing anywhere assigns it -- it is declared
   in this body and nothing outside can name it.

gnatprove folds neither, which is why the arrangement is free: it cannot
fold an entry call, and `Async_Writers => True` says an outside agent might
write `Run`. `Work` stays in the call graph either way, and the race check
is unchanged -- verified by mutating `Next_Core` back to a plain variable
with the wait first, which still reports the race naming both of that job's
tasks.

**Measured, not reasoned about.** An `Exit_Process (99)` at the top of
`Never_Runs`, in a scratch build: with the call *before* the wait -- which
is how this was first written -- `smoke` exits 99 every time, so those tasks
really were reaching it. With the wait first, five runs of `smoke` and one
of `multi_await` all exit 0. The old shape was safe, because `Run` was
`False`; it was one mechanism deep rather than two, and it was executing
code nobody wanted executed.

### Ghost is not available, and neither is a bare task type

The threads cannot be compiled out. Both attempts were made and both are
walls, so do not re-derive them:

* **`Ghost` cannot apply to a task.** GNAT rejects it twice at once:
  `aspect "Ghost" cannot apply to a task type` and `ghost object
  "Witness_A" cannot be synchronized`. Behind the message is a rule no
  arrangement gets around -- ghost code may not write non-ghost state, and
  reaching a fiber body that writes real state is the entire purpose. A
  ghost witness would be a witness to nothing.
* **A task type with no objects is silent**, and so is **a task type with
  one object**. Both were run against a plain unsynchronized `Next_Core`
  and reported nothing: gnatprove counts task *objects*, not potential
  instances of a type. So there is no way to declare the shape without
  paying for the threads.

Two real task objects per job kind is the floor. What the ordering above
buys is that they cost a thread each and nothing else -- no code of the
program's ever runs on them.

### Mutation tests

Redo these after any change to the witness or to how fiber bodies are
registered. Run them with `--mode=flow -j0 -U` on `examples.gpr`, which is
seconds rather than the minutes `--mode=all` takes; the data-race rule is a
flow rule and the flow phase reports it in full.

| mutation | result |
|---|---|
| `Next_Core` back to a plain variable | `high: possible data race ... next_core`, naming `acceptor_job.witness.witness_a` and `..._b` |
| delete `Witness_B` from the witness body | **silent** for `Next_Core` -- one task, and the rule needs two |
| move `package Witness` below `private` in `iour-fibers-job.ads` | **silent** -- it inherits the `Off` |
| delete the `Witness` instantiation from `Job` | **silent** -- nothing is in any task's call graph again |
| move `Never_Runs` *before* `Never_Opens.Park` in a task body | race still reported -- but the task then really executes the call site, which an `Exit_Process` at the top of `Never_Runs` proves |

The first was re-run when the witness moved into `Job`, and the message
names both of that one job's own tasks -- which is the confirmation that
the self-race case is covered, and that case is the one a single task per
job would have missed.

Three mutations that used to be on this list are gone with the consumer's
list: a body dropped from `All_Fiber_Bodies`, a missing `Races.Never_Runs`
call, and `gnatprove -u <app>.adb` without the main's unit. The last is
still worth knowing about -- `make prove-consumers` passes `-U` for the
unrelated reason in *Running gnatprove without lying to yourself* -- but a
single-unit run over a workload package now does race-check its fibers,
because both witness tasks are inside that unit's own closure.

### Four more things about the shape, each established by experiment

* **The guard must be one gnatprove cannot fold.** A statically `False`
  guard is pruned -- `warning: this statement is never reached` -- and the
  race check stays silent. `Run` is `Atomic` and nothing ever sets it.

* **The witness has to be in the partition's closure.** Put in a unit
  nothing `with`s -- a child package in its own source directory, selected
  by a scenario variable the way `IOUR_SHARDS` is -- it is not analysed and
  reports nothing, even under `-U`. That is what settles the design: the
  witness is compiled into the program rather than being a proof-only
  artefact, which also keeps the proved program and the shipped program the
  same program. Reaching it through `Job` makes this automatic, since a
  program that spawns a fiber at all withs `Job`.

* **It must run at `Runtime_Priority`.** At any other priority every
  protected object it reaches reports a possible ceiling violation instead
  of the thing you are looking for.

* **It must park, not spin.** Jorvik forbids a task body from running off
  its end, so the obvious `loop null; end loop;` is a task burning a core
  for the life of the process. The witness tasks wait on a barrier that
  never opens, exactly as `Iour.Shards` does for shards past `Shard_Count`
  -- and they wait *first*, which is what makes the call unreachable at run
  time as well as unexecuted. See *They never run* above.

### What it costs, and what it found

Two threads per kind of fiber: each starts, blocks on its first statement,
and never runs again. No code of the program's runs on them.

It also gets fiber bodies analysed *standalone* rather than only in their
calling contexts, which surfaces obligations the caller had been
discharging. `Serve`'s and `Session`'s frame counters were the two here,
and they were real: nothing bounds how many frames a connection exchanges.

Three genuine data races, found the first time the witnesses ran -- two in
the server, one in the client:

| variable | what it was | why it was wrong |
|---|---|---|
| `Echo_Server_App.Next_Core` | plain variable shared by acceptor fibers | safe only under a configuration invariant nothing checks |
| `Echo_Server_App.Listeners` | array with `Atomic_Components` | an array of atomic components is not a synchronized object |
| `Echo_Client_App.Host_Chars` | array with `Atomic_Components` | the same |

The `Atomic_Components` pair is the one worth remembering, because the
mistake is so natural. **`Atomic` on an object makes it synchronized;
`Atomic_Components` on an array does not.** `Iour.Per_Shard`'s header has
said so all along -- it is why that package holds `Max_Shards` separate
atomic scalars instead of one array -- and both examples had made exactly
the mistake it warns about. Both are protected objects now; neither is on a
hot path.

`Next_Core` is now `Atomic`. The argument it used to rest on was true --
acceptors all live on one shard when `Distribute` is set, and fibers on one
shard cannot preempt each other -- but it was a configuration invariant
that nothing enforced and SPARK cannot express. One atomic scalar,
incremented once per accepted connection, and the argument is gone.

### What it still does not cover

The witness models "these bodies run on two shards", which is what the
data-race rule needs. It does not model the *scheduling*: SPARK still has
no notion that fibers on one shard cannot preempt each other, so it treats
two fibers on the same shard exactly like two on different ones. That
direction is conservative -- it reports races that shard confinement would
rule out -- which is the right way round for a check to be wrong, and it is
why `Next_Core` had to become `Atomic` rather than be justified.

---

## What SPARK proves about deadlock and data races, and what it does not

Worth stating exactly, because "SPARK proves it is concurrency-safe" is both
roughly right and wrong in the places that matter.

### Deadlock freedom: structural, resting on four things

Not a proof obligation gnatprove discharges -- SPARK proves no liveness
property at all -- but a consequence of the shape of the code, and every
premise is cheap to re-check:

1. **No protected body in this runtime calls anything outside itself.**
   Checked over all nine in the library -- `Fibers.Fiber_Bank`,
   `Fibers.Shard_Cell`, `Fibers.Job_Registry`, `Futures.Bank`,
   `Run_Queue.Shared`, `Scheduler.Control`, `Shards.Parking`,
   `Fibers.Race_Witness.Never_Opens` and the Linux reactor's `Ring_Cell` --
   and over the six in the examples and tests, which is where it was broken
   and repaired in the same session: a saturating `Bump` helper added
   beside `Echo_Server_App`'s statistics was being called from inside its
   protected body, and had to move in.

   It is worth re-checking mechanically rather than by eye, because the way
   it breaks is by someone adding a helper *next to* a protected object
   instead of inside it, which looks completely ordinary. Extract each
   `protected body X is ... end X;` and list every capitalised name in it
   that is followed by `(` or `'`: every one should be an operation of that
   object, one of its private components, a local subprogram, a type name,
   or a pragma. Anything else is a call out. Fifteen bodies, one screen of
   output. Every statement in every one of them touches only that
   object's own components. So there is no nested protected call anywhere,
   hence no lock-acquisition cycle and no mutual-exclusion deadlock -- and
   hence also no potentially blocking operation inside a protected action,
   trivially rather than by inspection. **This is the property to
   preserve.** One call out of a protected body is what would put it at
   risk, and nothing in the language will warn about it.

2. **One priority in the partition.** Every task runs at `Runtime_Priority`
   and every protected object declares it as its ceiling. Jorvik mandates
   ceiling locking, so equal ceilings mean no ceiling violation is possible
   and there is no priority inversion to invert. (This is also a speed
   measure -- see `Iour`'s header for what unequal ceilings cost.)

3. **Three entries, all pure barriers, two of them monotone.**
   `Control.Await_Ready` opens at `Rings_Up = Shard_Count` and
   `Control.Await_All_Stopped` at `Stopped = Shard_Count`; both counters
   only increase and both saturate at `Shard_Count`. Every active shard
   calls `Ring_Up` exactly once on **every** path out of start-up, including
   the failure path where its ring did not open, and `Shard_Finished`
   exactly once on every path out of `Run`. That is what makes the barriers
   open, and it is why the failure path calls both rather than simply
   returning.

4. **`Shards.Parking.Wait_Forever` never opens, deliberately.** A surplus or
   finished shard blocks there for good, because Jorvik's
   `No_Task_Termination` makes running off the end of a task body a bounded
   error. It is a task meant never to run again, not a deadlock.

### Data-race freedom: this one gnatprove does check

SPARK's rules here are legality rules rather than proof obligations, so they
are reported by `--mode=check_all` and by the flow phase, not as unproved
checks. What they establish is that no unsynchronized object is reachable
from two tasks. Every shared thing in the runtime is one of:

* a **protected object** -- the fiber banks, the ready queues, the future
  banks, the run queue, the job registry, the scheduler's tallies;
* an **`Atomic` scalar**, one per shard, through `Iour.Per_Shard`. Not an
  array with `Atomic_Components`: an array is not itself a synchronized
  object, which is why that package holds `Max_Shards` separate scalars and
  dispatches on the index;
* a **`Synchronous` state abstraction** whose constituents are one of the
  above.

### What the proof does not cover

Four things, and the first is the one a consumer has to act on.

* **Fiber bodies reach the rule through a witness.** SPARK's rule is about
  tasks, and the assembly trampoline means a fiber body is in no task's
  call graph -- so by default state shared between fibers would be checked
  for nothing at all. `Iour.Fibers.Job` instantiates a **race witness** on
  every job, so registering a fiber body is what puts it under the rule and
  a consumer neither opts in nor can forget to; see *Race-checking fibers*
  above. What the witness still does not model is the scheduling: SPARK
  cannot tell two fibers on one shard (which cannot preempt each other)
  from two on different shards (which race), so it treats both as racing.
  That is conservative, which is the right way round. A body that is never
  registered as a job -- reached some other way -- is still checked for
  nothing.

* **`Ffi.Identity` is analysed as a different program.** SPARK ignores
  `pragma Thread_Local_Storage` and would model the one per-thread slot as
  one shared variable, so the body is `Off`. Shard identity -- the single
  fact the shared-nothing design rests on -- is therefore asserted, not
  verified. See *Why the Linux trusted base is exactly these four*.

* **The trusted bodies.** Everything in the README's *SPARK status* table,
  plus `Iour.Fibers.Invoke` and the whole of `Iour.Fibers.Job`. Each is
  verified against its spec rather than through it.

* **`Await_Direct`'s handover.** The fastest path in the runtime -- a fiber
  sleeping on its own submission, with the result handed over through a
  per-shard atomic cell and no protected object anywhere -- rests on an
  ownership argument rather than on synchronization: only this shard reaps
  this shard's ring, it does so only after the fiber has switched out, and a
  fiber has at most one such operation outstanding. All true, none checked.
  SPARK sees an atomic cell written and read by one thread, which is what it
  is, and would not notice the ownership rule being broken. If that path is
  ever changed, the argument has to be re-made by hand; there is nothing to
  re-run.

* **`Switch`'s `Always_Terminates` is false in one case**, which its own
  comment admits. See *Open work*.

---

## Shards, cores and the build

### Setting the shard count at build time

`-XIOUR_SHARDS=<n>`, 1 to 8. It cannot be a plain GPR external passed
through to Ada: `Shard_Count` has to arrive as a **static** constant --
Jorvik requires each shard task's CPU aspect to be static, `Active_Shard` is
a subtype bounded by it, and `Compile_Time_Error` checks it against
`Max_Shards` -- and a GPR external is a string only the project file can
see. So the project selects a *source directory* instead,
`src/config/shards-<n>/`, each holding one declaration of `Iour_Config` with
a different value, and `Iour.Shard_Count` takes it from there. Eight tiny
files, no preprocessing, no generated source, and the same mechanism that
already picks the OS and the arch.

### Shards past Shard_Count, and the elaboration trap

`Iour.Shards` declares `Max_Shards` tasks whatever `Shard_Count` is, because
the profile gives no way to declare a variable number of them. The surplus
ones disable themselves: `Scheduler.Run` returns immediately for any index
`>= Shard_Count` and `Serve` then parks the task forever on a barrier that
never opens. No CPU, no ring, no completions.

**What they cannot opt out of is elaboration.** A task's CPU aspect is
evaluated when the task is created, which is before any of this runtime's
own code runs -- before `Scheduler.Run` is reached, so before anything can
decide the shard is surplus. Asking for a core the machine does not have
raises `TASKING_ERROR` there and the process dies at start-up. With eight
declarations that meant **a four-shard build demanded eight cores merely to
elaborate.**

The fix is to fold the index back into the range actually in use, which
keeps the expression static as the aspect requires:

```ada
task Shard_5
  with CPU => First_Shard_Cpu + (5 mod Shard_Count),
       Priority => Shard_Priority;
```

A surplus shard is pinned to a core an active shard already owns and never
contends for it, because it parks immediately. With `First_Shard_Cpu` now 1
-- shard 0 shares CPU 1 with the environment task, deliberately -- the
runtime needs exactly `Shard_Count` cores and no more. It was 2 before, so
an eight-shard build wanted nine.

**This cannot reproduce on a machine with more cores than `Max_Shards`,**
which is why it went unnoticed. It was found on an emulated aarch64 guest,
where the core count is whatever qemu was told to provide. Test a
shard-count change on a VM sized to `Shard_Count`, not on the workstation.

### An array of shard tasks is rejected, not merely unidiomatic

Worth knowing because it is the obvious way to delete the eight
declarations, and the comments only said "Jorvik forbids dynamic CPU
assignment" without saying what happens. Measured:

```ada
task type Shard_Task (Id : Shard_Id; Core : CPU) with CPU => Core;
type Shard_Array is array (Shard_Id) of Shard_Task;
```

```
error: violation of restriction "No_Dynamic_Cpu_Assignment"
       from profile "Jorvik"
error: unconstrained element type in array declaration
```

A task type carries **one** CPU aspect for every object of it, and threading
the core through a discriminant is dynamic assignment by definition. An
array of tasks that all share one core is legal and is not thread-per-core.
The second error is incidental -- a discriminated task type without defaults
cannot be an array element -- and defaults would fix it; the first is fatal.

So the eight declarations are the price of static CPU pinning under the
profile. Deleting them would need conditional compilation or eight copies of
the task bodies, both worse than four parked tasks.

---

## Running on AArch64 under qemu

Only needed to *run*; `make check-aarch64` and `gnatprove` answer everything
else from Windows, in seconds. Reach for this when the question is "does the
assembly assemble" or "does the switch actually switch".

qemu is a scoop install and is **not on PATH** in the Bash tool:
`C:\Users\sraya\scoop\apps\qemu\current\`. TCG only -- no KVM or WHPX for
aarch64 on an x86 host -- so builds are slow, but a whole-library build is
minutes rather than hours.

The harness lives in the session scratchpad, not the repo: a Python driver
that boots the guest, drives its serial console over a TCP socket, and runs
a script of shell commands. Source goes in through a **vvfat** drive --
`-drive file=fat:<dir>,format=raw,if=virtio,readonly=on` exposes a host
directory as a FAT disk, mounted in the guest at `/dev/vdb1` -- which needs
no tools on either side. Remember to mount it in *every* script: it does not
survive a reboot.

**Use Debian 13, not 12.** Debian 12 ships GNAT 12.2, which is older than
this codebase: `Side_Effects` (GNAT 14) is unknown, so `Stack_Alloc`'s
`In_Out` global is rejected outright; `Always_Terminates` (GNAT 13) is not a
valid aspect; and `Ghost` on a generic formal subprogram is rejected in
`Fiber.Target`. Backports has no newer one -- bookworm carries gnat-11 and
gnat-12 and nothing else. Debian 13 has gnat-14, which is enough. The host
is on GNAT 15.2.

**Debian 13's nocloud image cannot be logged into as shipped.** Root has no
password and its PAM no longer accepts an empty one, where Debian 12's did,
so the console answers `Login incorrect` for ever. GRUB is reachable on the
serial console with a five-second timeout: send `c` for its command line,
then

```
set root=(hd0,gpt1)
linux /boot/vmlinuz-<version> root=/dev/vda1 rw init=/bin/bash console=ttyAMA0
initrd /boot/initrd.img-<version>
boot
```

and `chpasswd` at the root shell it drops into. Debian 13 has **no
`/vmlinuz` symlink**, so the version has to be named; `ls (hd0,gpt1)/boot/`
at the GRUB prompt gives it. Root is partition 1, the ESP is 15.

**Size the guest to the shard count.** `-smp` must be at least
`First_Shard_Cpu + Shard_Count - 1`; below that every run dies in
elaboration with `TASKING_ERROR: CPU not in range` before printing anything
of its own. That is the whole reason the fold above exists, and a 4-shard
build now runs on `-smp 4`.

### Harness traps, one run each

* **A readiness marker matches the terminal's echo of the command that
  produced it.** Sending `echo MARK` and waiting for `MARK` succeeds at a
  *login prompt*, because the console echoes what you type. The driver then
  types shell commands at `login:` for a whole run and every exit status
  reads back as the literal `$?`. Split the marker so the typed text does
  not contain it: `echo "@@IOUR-""READY@@"`.
* **GRUB has an `echo` of its own,** so even a split marker cannot tell a
  GRUB prompt from a Linux shell -- the first version of the password script
  cheerfully typed `chpasswd` at GRUB and reported success. Probe with
  `uname -s` and require `Linux` in the answer.
* **Two qemu processes on one qcow2 corrupt it,** and the second one's
  failure reads as a console bug -- "could not attach to the serial port" --
  rather than a collision. Refuse to start if the serial port is bound.
* **`hostfwd=tcp::2222-:22` fails on Windows** with "could not set up host
  forwarding rule". Give the host address:
  `hostfwd=tcp:127.0.0.1:2222-:22`.
* **`packages.debian.org` returns HTTP 200 for packages that do not exist,**
  so checking the status code "confirmed" gnat-14 in bookworm-backports,
  which is not there. Ask the guest's own `apt-cache policy` instead.
* **`-serial mon:stdio` with piped stdin fails on Windows** with `OSError:
  [Errno 22]`. Use `-serial tcp:127.0.0.1:<port>,server=on,wait=off` and a
  socket.

---

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
- **An access-to-subprogram type carries an implicit `Global => null`**, and
  `'Access` is then legal only on a subprogram with no global effects at all
  -- `access to subprogram with global effects is not allowed in SPARK`. The
  `Global` aspect that ought to fix this is **rejected by GNAT 15.2 on the
  type declaration**, `error: incorrect placement of aspect "Global"`, from
  the compiler rather than gnatprove and with `-gnat2022` on, for both
  `Global => null` and a real one. Calling *through* such a value is
  allowed, and is modelled as touching nothing -- which is worse than a
  rejection, because it is silent. See *Fiber bodies are numbers, not
  pointers*.
- **`Atomic` on an object makes it synchronized; `Atomic_Components` on an
  array does not.** An array of atomic components is an ordinary variable as
  far as SPARK's data-race rule is concerned. This is why `Iour.Per_Shard`
  holds `Max_Shards` separate scalars rather than one array, and both echo
  applications had made the mistake anyway.
- **Spell an `Atomic` variable's external properties out.** Defaulted,
  `Atomic` means `External` with all four True, and `Effective_Reads => True`
  says reading is itself an act that changes the thing read -- true of a
  hardware FIFO and of nothing in an application. It forbids reading the
  variable inside a larger expression (`E0004`) and, with `Async_Readers`,
  makes it an *output* of any function that reads it (`E0005`). All four
  False is illegal, **SPARK RM 7.1.2(6)**: at least one of `Async_Readers`
  and `Async_Writers` must be True. The shape for "written by one thread,
  read by others" is `Async_Writers` alone.
- **A volatile object may appear only as the whole right-hand side of an
  assignment**, SPARK RM 7.1.3(9) -- not as an actual parameter, not as an
  operand, not as a condition. A **protected function is a volatile
  function** and obeys the same rule, so `exit when Stats.Limit_Reached` and
  `while not Stats.All_Finished loop` both have to become a read into a
  local followed by the test.
- **`Constant_After_Elaboration` cannot be written by a subprogram at all**,
  SPARK RM 6.1.4(22) -- only by the declaring package's own elaboration. It
  is therefore useless for anything another package's elaboration registers
  into, which is why `Iour.Fibers`'s job table is a protected object.
- **A package cannot write another package's state during elaboration**:
  `high: cannot write "X" during elaboration of "Y" [E0008]`.
- **A generic formal subprogram cannot have `'Access` taken** (RM
  6.3.1(17/3), not subtype conformant), and **`'Access` in a generic body is
  illegal when the access type is declared outside the generic** (RM
  3.10.2(32)). The private part of the generic's spec is where it is
  allowed. Declaring the access type *inside* the generic body escapes the
  second rule and then fails on the way out: `target type must be declared
  in same generic body as operand type`.
- **An `Off` private part forces an `Off` body.** `error: incorrect use of
  SPARK_Mode ... value Off was set for SPARK_Mode on "X"`. So a package
  needing one `Off` declaration in its private part cannot keep an analysed
  body, which is why `Iour.Fibers.Job` is trusted whole.
- **An `Off` *declaration* cannot be called from SPARK code**, `"X" is not
  allowed in SPARK (due to entity declared with SPARK_Mode Off)`. Put the
  `Off` on the **body** and give the declaration a truthful `Global`; that
  is what `Iour.Fibers.Invoke` and `Ffi.Posix`'s imports both do.
- **gnatprove prunes statically dead calls.** A call under `if False` is
  reported as `this statement is never reached` and drops out of the call
  graph entirely -- so it cannot be used to make anything visible to flow
  analysis. A guard gnatprove cannot fold, such as a read of an `Atomic`
  flag, keeps the call in the graph. See *Race-checking fibers*.
- **A unit nothing `with`s is not analysed**, even under `-U`, so nothing
  declared in it participates in whole-program checks like the data-race
  rule.

---

## Stack budgets, and the flag that guards them

Fiber stacks are `Fiber_Stack_Bytes` -- 64 KiB, with one `PAGE_NOACCESS`
guard page below on Windows and an `mmap` guard on Linux. Nothing is
heap-allocated anywhere, so the only way to overrun one is a stack frame,
and in a runtime with no heap every buffer is a static local.

All three project files therefore carry **`-Wframe-larger-than=16384`**: a
compile-time bound on any single frame, a quarter of a fiber stack, and it
fires on nothing today.

Measured on Windows with `-fstack-usage`, largest first:

| subprogram | frame | which stack |
|---|---|---|
| `Scheduler.Run` | 8432 | shard thread |
| `Reactor.Drain` | 4240 | shard thread |
| `Reactor.Harvest` | 4176 | shard thread |
| `Fibers.Pop_Many` | 2112 | shard thread |
| everything reached from a fiber | <= 320 | fiber |

The last column is the point. The large frames are on the shard's own
thread stack -- `Iour.Shards` calls `Scheduler.Run` there -- and are
nowhere near a 64 KiB fiber stack. The fiber budget has enormous headroom;
the flag exists to keep it that way, not because it is tight.

**Not `-Wstack-usage`, which is the obvious choice and is unusable here.**
It bounds the same thing and *also* warns when a frame is dynamically
sized -- and `"n =" & X'Image` builds a temporary whose size is computed,
so every subprogram that formats a message reports "stack usage might be
unbounded". Six of them across the examples and tests, not one a defect.
Permanent noise teaches people to ignore warnings, which is worse than no
check at all. The price of the narrower flag is that a runaway *dynamic*
frame is not caught; the guard page is what catches that one.

**Whole-call-graph analysis is what would actually answer the question,
and it is not available.** It needs GNATstack over
`-fcallgraph-info=su,da`: the flag is in this GCC, GNATstack is an AdaCore
Pro tool the Alire FSF toolchain does not ship. The `.ci` files are plain
text and this call graph is small and static, so a homegrown consumer is
realistic if it ever matters. It could never be complete regardless --
fiber bodies arrive as `'Access` values, so the runtime cannot know a user
fiber's depth, and the guard page stays the backstop.

**The guard page is sound against a large frame**, because GCC emits
`___chkstk_ms` for frames over a page and probes downward. Verified in
`Scheduler.Run`'s prologue: `mov $0x20a8,%eax; call ___chkstk_ms; sub
%rax,%rsp`. Unprobed, an 8 KiB frame could step clean over a 4 KiB guard
page and land in whatever is below it. In the object file the call is an
unresolved relocation, so `objdump -d | grep chkstk` finds nothing and
`objdump -r | grep chkstk` finds it.

**Checking that the flag still fires** is a one-line mutation: a
`pragma Volatile` array of 40,000 bytes in a fiber-reachable subprogram
gives `the frame size of 40096 bytes is larger than 16384 bytes`. Without
`Volatile` it is optimised away at `-O2` and nothing is reported -- which
looks exactly like a flag that was never wired up.

The Linux frames are **unmeasured**: `make check-linux` compiles with
`-gnatc` and generates no code, so it produces no `.su` files. If a Linux
frame exceeds 16 KiB the flag will warn there first. Warnings are not
errors here, so it cannot break that build.

---

## The benchmark

`scripts/bench_tcp.sh` runs on both systems. Everything platform-dependent is in one
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

### The HTTP benchmark is separate

`scripts/bench_http.sh` is a separate HTTP-only harness. Do not add HTTP
stages to `scripts/bench_tcp.sh`: their process contracts overlap, but their
workloads and future protocol controls do not. `make bench-http` invokes the
HTTP harness; `make bench-tcp` and the compatibility `make bench` invoke TCP.
Both scripts are Git mode `100755`. On Windows, Make invokes Git Bash by its
installed path, not the WSL `/bin/bash`, because Alire's Windows executable is
not visible in WSL; the HTTP script also resolves the standard Windows Alire
path when Git Bash's PATH exposes only a bare `alr` name.

The implemented fixture is deliberately one request per TCP connection:
`Connection: close`, `Content-Length: 32`, status 200 and body
`0123456789abcdef0123456789abcdef`. Its common benchmark CLI is:

```
http_server [port] [request-goal]
http_client [host] [port] [connections] [rounds]
```

The goal is requests, so the harness starts each server with
`connections * rounds`. The Ada client creates one fiber per connection and
opens a fresh socket for each round; this is intentional while the server has
no keep-alive. The client prints `elapsed`, `round trips per second`, `frames
exchanged` and `failed`; those labels are a machine contract with the harness.
Its elapsed unit may be milliseconds (Ada) or seconds (Go/Rust), and the
harness reads the unit rather than assuming one.

`bench/go_http/` is a safe standard-library Go `net/http` server/client pair.
`bench/axum_http/` is an Axum server and Reqwest client pair; `Cargo.lock` is
part of the source, `target/` is generated output. The repository's old
unanchored `bin` ignore rule also matches `bench/axum_http/src/bin`; use `/bin`
for a root-only binary-output rule or Rust sources there will be silently
ignored and never staged.

`bench_http.sh` runs all nine Ada/Go/Axum server-client pairings for every
`BENCH_HTTP_SCALES` cell and repetition. Its CSV is
`pairing,connections,rounds,rep,elapsed_s,rt_per_s,frames,failed_sessions,ok`.
Keep its numeric handling the same as TCP: normalize duration to seconds with
nine decimal places, normalize rate to an integer before writing CSV, and use
`group` and `fixed3` for human-readable log lines. Rust and Go deliberately
emit scientific notation, while Ada emits an integer; formatting belongs in the
harness, never in a client just to make a log attractive.

`.github/workflows/http-bench.yml` owns the independent HTTP CI run and
uploads `bench/results/http-ci`. Its environment selects the workload; do the
arithmetic before increasing it: one scale with $C$ connections and $R$ rounds
means $9 \times REPS \times C \times R$ requests. This is a full cross-pairing
matrix, not a single server run, and large values quickly turn a completion gate
into a long performance job. `bench_http.sh` randomizes its nine pairings per
repetition and uses `bench/runwait` to record server user CPU, system CPU and
peak RSS in its CSV; the console also prints server CPU microseconds per
completed request and RSS in MiB. Windows accounts CPU on a 15.6 ms scheduler
tick, so use at least 50,000 requests before comparing CPU cost. The HTTP
harness still has no TCP-style TIME_WAIT drain, port retry, summary, scaling
sweep or tail histogram. Do not interpret wall-clock throughput as a fair
CPU-cost comparison until those are deliberately designed for HTTP.

Validated after introducing the common CLI: a compact full nine-pairing
Ada/Go/Axum loopback matrix, `make demo-http`, `make check-linux`, and
`make check-aarch64` all passed. The HTTP parser's standalone test passes and
its focused SPARK proof reported 1,145 checks. HTTP remains a bounded first
slice: no persistent connections, request-body or response-body API, header
dispatch, status/header control, chunked decoder, DNS, or WebSocket support.

### Measurement traps

- **The three clients do not print elapsed time in the same unit, and the
  matrix's `elapsed_s` column used to believe them all.** The Ada client
  prints milliseconds: SPARK supports neither a fixed-to-floating
  conversion nor a proof that `To_Duration`'s result fits in `Duration`,
  so `Echo_Client` divides one `Time_Span` by another and gets an
  `Integer` count of milliseconds. Go and Tokio print seconds. Read as
  seconds that is a thousandfold, so every Ada row in the log showed a
  number three orders of magnitude worse than its neighbours and the
  fastest server in the matrix read as by far the slowest. `rt_per_s` was
  never affected -- the client computes it -- so no conclusion in any
  saved result is wrong, but the raw per-rep log lines from 1f1a43b
  onwards are unreadable. `run_pair` now reads the unit off the line
  rather than assuming it. **A new client, or a change to an existing
  one's output, has to keep the unit in the text.**

  The same three clients disagree about *rendering* as well as unit, and
  that half is harmless -- but it reached the log for a long time and made
  a column unreadable. Given the same `%.8E`, Rust writes `2.23628137E5`
  and Go writes `1.89083387E+05`, because the exponent's sign and padding
  are not standardised; the Ada client prints an integer, for the SPARK
  reason above. All three parse back correctly, so nothing downstream was
  ever wrong, which is exactly why nobody noticed. `run_pair` now
  normalises `rt_per_s` to a plain integer on the way into the CSV, and
  the per-rep log line goes through `group` and `fixed3` so it is in the
  summary tables' own format. **Format numbers in the harness, not in the
  clients** -- the Ada one cannot be made to match the other two.

- **The three clients have to measure the same window, and the Ada one did
  not.** It took `Clock` either side of `Iour.Scheduler.Wait_For_Shutdown`,
  so every shard draining its ring and stopping was inside the figure it
  called elapsed. The Go and Tokio clients stop their clock when the last
  session task joins and shut nothing down before reading it. Measured
  paired -- one server, the two Ada clients alternating rep by rep, 100
  connections by 1000 rounds -- the reported window fell from a median of
  897 ms to 769 ms and was shorter in 8 reps of 8, so a seventh of what it
  reported was teardown and its throughput was understated by about a
  sixth. `Echo_Client_App.Session_Window` is the fix: `Driver` stamps
  `Clock` just before it spawns, each session stamps as it finishes, and
  the protected object keeps the last finisher's stamp. **Every ada-cli row
  recorded before 2026-09-09 is low by an unknown amount**, including the
  whole of the first Linux run.
  What is left in the window at one connection is still tens of
  milliseconds for microseconds of work, and that part is not a bug: it is
  the connect, which on Windows is a blocking `connect(2)` on a thread-pool
  thread and costs a scheduler tick whenever it misses one. Go and Tokio
  connect inside their windows too.

- **A stale variant build is the worst of these, because it is silent.**
  `scripts/bench_tcp.sh` builds one copy of the runtime per `Shard_Count`, and
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

### The first Linux run, 2026-09-09 (`.github/workflows/bench.yml`)

Open work item 3 was "nothing has been measured on Linux". This is that
measurement, and it is worth reading for what it does and does not settle.
It ran on a GitHub Actions runner: two vCPUs of an AMD EPYC 7763 on an
oversubscribed Azure host, kernel 6.17, two repetitions. The Ada server is
one shard on Linux CPU 0, the Ada client one shard on CPU 1, and Go and
Tokio unconfigured across both. **Absolute numbers from a shared runner
mean nothing** -- the workflow's own header says so at length -- but the
within-run comparisons are the first evidence about this runtime over
io_uring that anyone has.

**Read the client column first, because a third of the matrix is
client-bound.** Every pairing driven by the Ada client lands between 43k
and 48k round trips a second *whatever server is on the other end*, and
each of those servers reaches 70-92k under a different client:

| server | under ada-cli | under tokio-cli | under go-cli |
|---|---|---|---|
| ada | 48,146 | 92,053 | 79,774 |
| tokio | 46,882 | 90,216 | 80,935 |
| go | 43,150 | 79,607 | 70,912 |

The Ada client is pinned to one core because it is this runtime and this
runtime pins; the other two help themselves to both. So six of the
eighteen matrix rows measure the load generator, exactly as the whole
scaling stage did on 2026-09-04. The tell is the same one: the *other*
runtimes do not scale on those rows either.

**Those six rows are also low by about a sixth**, on top of being
client-bound, because this run predates the timing-window fix in
*Measurement traps*: the Ada client was still counting the runtime's own
shutdown as elapsed time. Correcting for it moves the ada-cli column from
43-48k to roughly 50-56k, which does not change the reading -- 56k is
still a long way under the 92k the same servers reach under the Tokio
client -- but the numbers in this table will not reproduce.

Holding the client constant, which is what the cross pairings are for --
median of two repetitions, round trips per second:

| load | client | Ada | Go | Tokio |
|---|---|---|---|---|
| 100x1000 | tokio | **92,053** | 79,607 | 90,216 |
| 100x1000 | go | 79,774 | 70,912 | **80,935** |
| 500x200 | tokio | **91,103** | 77,302 | 88,166 |
| 500x200 | go | 76,655 | 70,477 | **82,530** |

And the column that survives the asymmetry -- server CPU microseconds per
round trip:

| load | client | Ada | Go | Tokio |
|---|---|---|---|---|
| 100x1000 | tokio | **10.84** | 13.23 | 11.07 |
| 100x1000 | go | 11.71 | 14.02 | **11.28** |
| 500x200 | tokio | **10.78** | 13.04 | 11.23 |
| 500x200 | go | **10.88** | 13.78 | 11.40 |

**Ada and Tokio are within a few percent of each other and Go is 20-25%
dearer**, which is a different picture from Windows in both directions:
there, unpinned, Go and Tokio cost two to four times what this runtime
does, and pinned to the same cores Go was as cheap as it is. Two contended
cores is closer to the pinned arrangement than to the unpinned one, and
the numbers agree.

The scaling stage is a single Ada row here -- one shard is the only count
that fits -- so it is a three-way comparison at a fixed offered load
rather than a sweep, and it is the cleanest cell in the run because the
load generator is the same for all three:

```
ada/1-cores    90,316 rt/s   10.88 us/rt   7.1 MB
tokio/default  87,482 rt/s   11.31         3.6
go/default     80,243 rt/s   13.12         7.7
```

**Latency is where this runtime loses, and it is the one result worth
chasing.** One connection, 5000 sequential round trips against an idle
server, driven by the Tokio client:

| server | us per round trip |
|---|---|
| go | 47.2 |
| tokio | 55.0 |
| ada | 61.4 |

All three are inflated -- the same measurement on Windows puts every
runtime at 13-14 us -- so the shared host is most of the absolute figure.
The *ordering* is what is new: on Windows this runtime is at or ahead of
both, and here it is 30% behind Go. There is an obvious suspect and it has
not been tested. The Ada server is pinned to Linux CPU 0, which is also
where its own environment task, the runner's own threads and everything
else on a two-vCPU VM sit, while Go and Tokio can move to CPU 1; at one
connection there is no throughput to hide a scheduling delay behind. That
is a hypothesis about the arrangement, not a finding about io_uring, and
distinguishing the two needs a machine with cores to spare.

**Resident memory is a genuine difference from Windows.** 5.5-7.1 MB at
500 connections here against 25-32 MB there, for the same 64 KiB fiber
stack per live connection. `mmap` gives a stack that costs nothing until
it is touched and a fiber touches one page of it; `VirtualAlloc` plus the
guard page does not behave the same way. Tokio is 3.6 MB throughout, which
is what having no per-connection stack at all looks like.

What this run does **not** settle: anything about more than one shard,
because one is all that fits beside the client on two cores. Thread-per-core
is the thing this runtime is, and the CI configuration cannot exercise it.
That still needs a machine.

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
3. **Run the harness on Linux somewhere with cores to spare.** The
   workflow in `.github/workflows/bench.yml` has now run it -- see *The
   first Linux run* -- so this is no longer "nothing has been measured".
   What it measured is a **one-shard** runtime on two shared vCPUs, which
   settles the cheap questions (it works, it completes every session, its
   CPU per round trip is Tokio's) and cannot touch the expensive one:
   thread-per-core is what this runtime is, and one shard is not it. The
   two things that run wants answered are whether the shard count buys
   anything over io_uring the way it does over completion ports, and why
   single-connection latency there is 30% behind Go's when on Windows it
   is ahead of it.

   Nothing has been *benchmarked* on AArch64 either. `smoke` passes there
   under emulation, which says the switch is correct and says nothing at all
   about its cost -- TCG timings are meaningless, and there is no aarch64
   hardware here.
4. **`Iour.Reactor` on Windows, which is the only `Off` body whose
   necessity is unestablished.** Its first two obstacles are contract shape,
   not language walls -- see *The Windows reactor is the one unestablished
   `Off`*. Worth an attempt; the Linux reactor is `On` and is the worked
   example of what the contracts look like.

   **Read that section's *Running the probe* note before starting.** The
   probe is a very long run -- well over an hour in phase 2 alone on this
   machine -- and it has now been killed part-way three times across two
   sessions. Never wrap it in `timeout`: `timeout` kills `alr` and orphans
   the `gnat2why` children, which keep running with their output going
   nowhere, so the run looks hung when it is merely detached. Redirect to a
   file rather than piping to `tail`, and leave it alone.

   `Ffi.Win32`'s body is *not* worth attempting on the same evidence: it has
   three independent hard errors and needs all three solved. `Ffi.Win32`'s
   spec, `Ffi.Sys` and `Ffi.Net` are already `On`. `Iour.Fibers.Job`'s body
   is settled and is not worth attempting either -- see *The generic's body
   cannot be `On`*.
5. **STAL's other half, if it is ever worth it.**
   `Iour.Ffi.Fiber.Machine` proves the register file is exchanged and proves
   the *initial* frame's placement; it says nothing about what is on a
   suspended fiber's stack, because `L_Rsp` is modelled as one more location
   that round-trips. Typing the stack the way stack-based TAL does would
   need frame layouts the compiler owns and this runtime never sees, so it
   is not a small change and may not be a possible one against GCC-generated
   frames. Listed so that "the context switch is proved" is not read as more
   than it is. See *The context switch is proved*.

6. **`Switch`'s `Always_Terminates` is not true, and the comment beside it
   says so.** `Iour.Ffi.Fiber.Switch` carries
   `Global => (In_Out => Kernel), Always_Terminates`, and its own comment
   admits the exception: a finished fiber's last switch never returns,
   because the slot is recycled underneath it. `Iour.Fibers` makes that safe
   with a loop that cannot be left -- safe by construction, not by proof,
   and meanwhile every caller above is verified against a claim that is
   false in that one case.

   Whether this is fixable is genuinely open. Dropping `Always_Terminates`
   costs the termination proofs of everything that calls it, which is most
   of the scheduler. Splitting it into a terminating `Suspend` and a
   `No_Return` `Finish` is the obvious shape and has not been tried; the two
   differ only in what the *caller* intends, which is not something the
   callee's contract can see. Start by measuring what breaks: drop the
   aspect, run `--mode=all`, and count.

7. **Fiber *scheduling* is still outside SPARK's model, though fiber races
   are no longer.** This item used to say fibers were outside the model
   entirely. That is now half wrong, and the half that changed is the
   useful half.

   Races between fibers **are** checked, for every body registered with
   `Iour.Fibers.Job`, which instantiates the witness on it -- see
   *Race-checking fibers*. It found three real ones the day it was
   written.

   What is still not modelled is that fibers on one shard cannot preempt
   each other. SPARK treats two fibers on the same shard exactly like two
   on different ones, so it reports races that shard confinement would rule
   out. That direction is conservative and therefore safe, and the cost is
   real: `Echo_Server_App.Next_Core` had to become `Atomic` rather than
   keep the confinement argument it carried, because there is no way to
   state the argument in a form SPARK will accept. A program that genuinely
   needs shard-confined shared state has no option but to synchronize it or
   justify it by hand.

   Whether the confinement *can* be expressed is the open question. It
   needs a way to say "this subprogram only ever runs on shard N", which is
   a property of the scheduler rather than of the code, and SPARK has no
   vocabulary for it. Nothing has been tried. It is also worth asking
   whether it is worth having: the conservative answer costs one atomic
   increment per accepted connection here, and the argument it replaced was
   three sentences long and rested on a build-time configuration.

   The remaining weakness is smaller than it was. The three silent ways to
   get the witness wrong were all consumer-side -- a body left out of the
   list, a missing call from the main subprogram, a single-unit `gnatprove
   -u` run -- and all three went when the witness moved into
   `Iour.Fibers.Job`, which is the one place in the runtime that can name a
   fiber body. What is left is that a body reached some way other than
   through a `Job` instance is still witnessed by nothing, and that a
   change to the generic could break the mechanism without breaking a
   build. The mutation table in *Race-checking fibers* exists for the
   second, because a witness that has stopped working looks exactly like a
   clean run.

8. **`Ffi.Identity` is analysed as a different program, and shard identity
   is what the shared-nothing argument rests on.** SPARK ignores
   `pragma Thread_Local_Storage` and would model the one per-thread slot as
   one shared variable, which is why the body is `Off` -- see *Why the Linux
   trusted base is exactly these four*. That is the right call, but it means
   the single fact the whole design depends on ("a shard knows which shard
   it is, and no two agree") is asserted, not verified. No fix is known.
   Listed so it is not mistaken for something the proof covers.

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

Two obligations belong to anything that adds a fiber body or a protected
object, because neither is enforced by the language and both fail quietly:

* **A new fiber body is race-checked because it is registered**, and for
  no other reason. `Iour.Fibers.Job` attaches the witness; a body reached
  some way other than through a `Job` instance is checked for races against
  nothing at all, and nothing says so. See *Race-checking fibers*.
* **A helper called from inside a protected body goes inside it.** "No
  protected body calls anything outside itself" is the premise the whole
  deadlock-freedom argument rests on, and the way it breaks is somebody
  putting a two-line `Bump` next to a protected object rather than in it --
  which looks entirely ordinary. See *What SPARK proves about deadlock and
  data races* for the mechanical re-check.
