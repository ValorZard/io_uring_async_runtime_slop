------------------------------------------------------------------------------
--  Iour.Ffi.Fiber -- the context-switch primitive, in Ada.
--
--  A context is the eight callee-saved registers of the SysV x86-64 ABI,
--  saved into a 64-byte buffer.  Switching stores the outgoing registers,
--  loads the incoming ones, and jumps.  No signal mask is touched, so a
--  switch costs tens of cycles rather than the microsecond swapcontext(3)
--  spends in rt_sigprocmask.
--
--  The design follows minicoro (github.com/edubart/minicoro): registers go
--  in a context buffer rather than on the stack, a two-instruction
--  trampoline receives the entry point in r12 and its argument in r13, and
--  the initial stack carries a dummy return address so the entry sees the
--  alignment a call would have left.  The assembly is GNAT's own inline
--  Asm inside naked subprograms; there is no C anywhere in this runtime.
--
--  Contexts are named by slot index.  The slot table lives in the body of
--  this package, which is SPARK_Mode => Off: it has to take addresses of
--  objects and write through computed ones, and SPARK forbids both.  This
--  spec stays in SPARK, and its contracts are what every client is verified
--  against.  The saved-register table is modelled as part of Ffi.Kernel:
--  machine state the runtime owns.
--
--  What the assembly in that body is supposed to do is not left to the
--  comments around it.  The child package Iour.Ffi.Fiber.Machine, one per
--  ABI and beside the body it describes, is SPARK_Mode => On and holds the
--  machine locations the switch owns, their offsets, the instruction
--  sequence as data, the register-file exchange it performs -- proved --
--  and the assembler text, which it checks against that sequence before
--  any shard is allowed to start.  Read its header first.
--
--  x86-64 only.  The body lives under src/arch/x86_64; another target gets
--  its own directory, its own model and its own body against this same
--  spec.
------------------------------------------------------------------------------

with System;

package Iour.Ffi.Fiber with SPARK_Mode => On is

   --  Confirm the slot table can hold Slots contexts.  The table is static,
   --  sized from Iour.Max_Fibers and Iour.Max_Shards, so this only checks;
   --  it allocates nothing and touches no state.  Returns 0 on success.
   function Reserve (Slots : C_Long) return C_Int
     with Global => null;

   --  Slots the table holds.
   function Slot_Count return C_Long
     with Global => null;

   --  Save the running context into slot From and resume slot To.  Returns
   --  on the From side only once something switches back to it.  An
   --  out-of-range or self-directed slot returns without switching.
   --
   --  Always_Terminates is a contract worth reading twice.  Every switch a
   --  fiber makes to suspend does return, once something switches back.
   --  The one exception is a finished fiber's last switch, which never
   --  returns because the slot is recycled underneath it; Iour.Fibers makes
   --  that safe by following it with a loop that cannot be left.
   procedure Switch (From : C_Long; To : C_Long)
     with Global => (In_Out => Kernel), Always_Terminates;

   --  Map a stack of Size usable bytes with a guard page below it, so an
   --  overrun faults instead of corrupting a neighbour.  Returns the mapping
   --  base, or Null_Address on failure.
   function Stack_Alloc (Size : C_Size) return System.Address
     with Side_Effects, Global => (In_Out => Kernel);

   procedure Stack_Free (Base : System.Address; Size : C_Size)
     with Global => (In_Out => Kernel), Always_Terminates;

   --  Arrange for the next switch into Slot to begin a fresh call of the
   --  exported Ada entry point "iour_fiber_main" with Arg, on the stack at
   --  Base/Size.  Stacks outlive fibers, so a recycled fiber slot primes an
   --  existing stack instead of mapping a new one: starting a fiber costs
   --  no system call.
   procedure Prime
     (Slot : C_Long;
      Base : System.Address;
      Size : C_Size;
      Arg  : C_Long)
     with Global => (In_Out => Kernel), Always_Terminates;

   --  Bytes of guard page placed below every fiber stack.
   function Guard_Size return C_Size
     with Global => null;

end Iour.Ffi.Fiber;
