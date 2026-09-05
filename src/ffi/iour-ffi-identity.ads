------------------------------------------------------------------------------
--  Iour.Ffi.Identity -- which shard the calling thread is.
--
--  Every shard asks this on every pass and on every suspension, so it has
--  to be cheap; and everything else in the runtime is decided from the
--  answer, so it has to be exact.
--
--  It used to be neither quite.  A shard was whichever core it was running
--  on -- sched_getcpu, minus a base -- which is exact only for as long as
--  every thread that matters is pinned to a core of its own.  Ada says so
--  with the CPU aspect, and GNAT for Linux implements it, so on Linux the
--  trick held.  GNAT for Windows accepts the same aspect and does nothing
--  with it: the tasks float across every core in the machine, two shards
--  land on one processor, and the environment task can find itself
--  answering to a shard's number.
--
--  So identity is recorded rather than inferred.  A shard says who it is
--  once, into thread-local storage, and every later question is one load
--  from it.  That is faster than sched_getcpu was, exact on both systems,
--  and independent of whether anything is pinned -- which leaves pinning
--  to be what it should have been all along, a performance measure rather
--  than the thing correctness rests on.
--
--  The slot is modelled the same way as the saved register file in
--  Iour.Ffi.Fiber: state the runtime owns, in a body SPARK does not look
--  inside.  Current has Global => null for the same reason sched_getcpu
--  did -- it is a pure question about the calling thread, and no answer it
--  gives can be changed by anything a caller does.
--
--  Fibers do not affect it.  A context switch moves the stack and the
--  registers; thread-local storage belongs to the thread, so every fiber
--  running on a shard sees that shard.  Which is what makes it the right
--  place to put this.
------------------------------------------------------------------------------

package Iour.Ffi.Identity with SPARK_Mode => On is

   --  Claim the calling thread as shard Index.  Called once, by the shard
   --  itself, before it does anything else.
   procedure Claim (Index : Shard_Id)
     with Global => (In_Out => Kernel), Always_Terminates;

   --  Which shard the calling thread claimed to be, or No_Shard on a
   --  thread that never claimed one: the environment task, a thread-pool
   --  callback, anything the runtime did not start.
   function Current return Shard_Ref
     with Global => null;

end Iour.Ffi.Identity;
