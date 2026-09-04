------------------------------------------------------------------------------
--  Iour.Ffi.Fiber -- the context-switch primitive.
--
--  A "context" is eight bytes holding a saved stack pointer.  Switching
--  pushes the callee-saved registers onto the outgoing stack, swaps the
--  stack pointer, and pops them back: no signal mask is touched, so a
--  switch costs tens of cycles rather than the microsecond that
--  swapcontext(3) spends in rt_sigprocmask.
--
--  Contexts are addressed by System.Address rather than by an access value.
--  The Ada side never dereferences one; only the assembly does.
------------------------------------------------------------------------------

with System;

package Iour.Ffi.Fiber with SPARK_Mode => On is

   --  Mirror of the C `iour_ctx_t`.  Checked against the C side at startup.
   type Context is limited record
      Stack_Pointer : System.Address;
   end record
     with Convention => C;

   --  Save the running context into From and resume the one saved in To.
   --  Returns on the From side only once something switches back to it.
   procedure Switch (From : System.Address; To : System.Address)
     with Import, Convention => C, External_Name => "iour_ctx_switch",
          Global => null;

   --  Map a stack with a guard page below it.  Null address on failure.
   function Stack_Alloc (Size : C_Size) return System.Address
     with Import, Convention => C, External_Name => "iour_stack_alloc",
          Global => null;

   procedure Stack_Free (Base : System.Address; Size : C_Size)
     with Import, Convention => C, External_Name => "iour_stack_free",
          Global => null;

   --  Arrange for the next switch into Ctx to begin a fresh call of the
   --  exported Ada entry point with Arg.  Stacks outlive fibers, so a
   --  recycled fiber slot primes an existing stack instead of mapping a new
   --  one: starting a fiber costs no system call.
   procedure Prime
     (Ctx  : System.Address;
      Base : System.Address;
      Size : C_Size;
      Arg  : C_Long)
     with Import, Convention => C, External_Name => "iour_ctx_prime",
          Global => null;

   function Context_Size return C_Size
     with Import, Convention => C, External_Name => "iour_ctx_size",
          Global => null;

   function Guard_Size return C_Size
     with Import, Convention => C, External_Name => "iour_ctx_guard_size",
          Global => null;

end Iour.Ffi.Fiber;
