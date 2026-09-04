------------------------------------------------------------------------------
--  Iour.Ffi.Fiber -- the context-switch primitive.
--
--  A context is a saved stack pointer.  Switching pushes the callee-saved
--  registers onto the outgoing stack, swaps the stack pointer, and pops
--  them back: no signal mask is touched, so a switch costs tens of cycles
--  rather than the microsecond that swapcontext(3) spends in
--  rt_sigprocmask.
--
--  Contexts are named by slot index, and the slot table itself lives on the
--  C side.  That split is deliberate.  A saved stack pointer is machine
--  state whose only accessor is the assembly, and an Ada array that has to
--  hand out addresses into itself can be neither a protected object nor
--  anything SPARK will let an access type designate -- so keeping the table
--  in Ada bought nothing and cost the analysability of the whole scheduler.
--  Naming slots by integer, the Ada side has no addresses to hand out and
--  no shared array to race over.
------------------------------------------------------------------------------

with System;

package Iour.Ffi.Fiber with SPARK_Mode => On is

   --  Reserve the slot table.  Idempotent, and succeeds if a table large
   --  enough already exists.  Returns 0 on success.
   --
   --  Not thread safe on its own: callers must serialise it, and must call
   --  it before any fiber exists.  Iour.Fibers does both by calling it from
   --  inside a protected action at shard start-up.
   function Reserve (Slots : C_Long) return C_Int
     with Import, Convention => C, External_Name => "iour_ctx_reserve",
          Global => null;

   function Slot_Count return C_Long
     with Import, Convention => C, External_Name => "iour_ctx_slots",
          Global => null;

   --  Save the running context into slot From and resume slot To.  Returns
   --  on the From side only once something switches back to it.  An
   --  out-of-range or self-directed slot returns without switching.
   --  Always_Terminates is a contract worth reading twice.  Every switch
   --  a fiber makes to suspend does return, once something switches back.
   --  The one exception is a finished fiber's last switch, which never
   --  returns because the slot is recycled underneath it; Iour.Fibers
   --  makes that safe by following it with a loop that cannot be left.
   procedure Switch (From : C_Long; To : C_Long)
     with Import, Convention => C, External_Name => "iour_ctx_switch",
          Global => (In_Out => Kernel), Always_Terminates;

   --  Map a stack with a guard page below it.  Null address on failure.
   function Stack_Alloc (Size : C_Size) return System.Address
     with Import, Convention => C, External_Name => "iour_stack_alloc",
          Global => null;

   procedure Stack_Free (Base : System.Address; Size : C_Size)
     with Import, Convention => C, External_Name => "iour_stack_free",
          Global => (In_Out => Kernel), Always_Terminates;

   --  Arrange for the next switch into Slot to begin a fresh call of the
   --  exported Ada entry point with Arg.  Stacks outlive fibers, so a
   --  recycled fiber slot primes an existing stack instead of mapping a new
   --  one: starting a fiber costs no system call.
   procedure Prime
     (Slot : C_Long;
      Base : System.Address;
      Size : C_Size;
      Arg  : C_Long)
     with Import, Convention => C, External_Name => "iour_ctx_prime",
          Global => (In_Out => Kernel), Always_Terminates;

   function Guard_Size return C_Size
     with Import, Convention => C, External_Name => "iour_ctx_guard_size",
          Global => null;

end Iour.Ffi.Fiber;
