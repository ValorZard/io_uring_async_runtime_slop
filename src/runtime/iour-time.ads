------------------------------------------------------------------------------
--  Iour.Time -- waiting without blocking a core.
--
--  Sleep suspends the calling fiber only.  Its shard carries on running
--  other fibers and reaping completions; the wait itself is whatever the
--  backend has for a timer -- an IORING_OP_TIMEOUT on Linux, a thread-pool
--  timer on Windows -- so nothing spins and no shard is parked.
--
--  This is the reason a fiber should never call an Ada protected entry to
--  wait for something.  A protected entry blocks the task, and the task is
--  the whole shard: every other fiber on that core stops too.  Wait with
--  Sleep, or with Await on a future, and the core stays busy.
------------------------------------------------------------------------------

with Iour.Ffi;
with Iour.Fibers;
with Iour.Reactor;

package Iour.Time with SPARK_Mode => On is

   --  Suspend the calling fiber for at least this long.  Must be called
   --  from a fiber.
   procedure Sleep (Nanoseconds : Natural)
     with Global => (In_Out => (Reactor.Engines, Fibers.Registry, Ffi.Kernel));

   procedure Sleep_Milliseconds (Milliseconds : Natural)
     with Global => (In_Out => (Reactor.Engines, Fibers.Registry, Ffi.Kernel));

end Iour.Time;
