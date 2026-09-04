------------------------------------------------------------------------------
--  Iour.Scheduler -- the event loop each shard runs.
--
--  One pass of the loop, in order:
--
--    1. Harvest everything the kernel has finished and resolve the futures
--       it belongs to, waking whichever fiber was waiting.
--    2. Take new work off the global run queue and give it a stack.
--    3. Run every fiber that is ready, one after another, until none is.
--    4. Push submissions to the kernel; if there is genuinely nothing left
--       to do, sleep inside io_uring_enter until something arrives.
--
--  Step 4 is the only place a shard blocks, and it blocks in the kernel on
--  its own ring rather than on a lock or a condition variable.  A sibling
--  with work to hand over wakes it with a ring message; nothing else can.
------------------------------------------------------------------------------

package Iour.Scheduler with SPARK_Mode => On is

   --  Run this shard's loop.  Returns once shutdown has been requested and
   --  the shard has drained -- or immediately, if this shard is beyond
   --  Shard_Count and so takes no part.
   procedure Run (Shard : Shard_Id);

   --  Ask every shard to finish its outstanding work and stop.  Callable
   --  from a fiber or from the environment task.
   procedure Request_Shutdown;

   --  Block until all shards have stopped.  Called by the environment task,
   --  which then tears the runtime down and ends the process: a Jorvik
   --  partition has no other way to terminate.
   procedure Wait_For_Shutdown;

   --  Per-shard tallies, for reporting.
   procedure Report
     (Shard        : Shard_Id;
      Completions  : out Natural;
      Fibers_Run   : out Natural;
      Adopted      : out Natural;
      Sleeps       : out Natural;
      Abandoned    : out Natural;
      Flush_Errors : out Natural);

   --  True once every shard's ring is up, so the environment task knows the
   --  runtime is ready to accept work.
   procedure Wait_Until_Ready;

end Iour.Scheduler;
