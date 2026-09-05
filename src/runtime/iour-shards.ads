------------------------------------------------------------------------------
--  Iour.Shards -- the pinned worker threads.
--
--  Jorvik requires each task's CPU to be a static expression and forbids
--  task hierarchies, so these are written out as Max_Shards separate
--  library-level task declarations rather than an array of task objects.
--  That is not boilerplate for its own sake: it is what makes the
--  thread-to-core assignment checkable at compile time instead of at run
--  time.
--
--  Shard N asks for Ada CPU First_Shard_Cpu + N.  Ada numbers CPUs from one,
--  so with First_Shard_Cpu = 2 the shards occupy the system's CPUs 1 upward
--  and leave CPU 0 to the environment task, which does start-up, reporting
--  and teardown.
--
--  Asks, rather than gets.  GNAT for Linux implements the CPU aspect with
--  sched_setaffinity before the task body runs; GNAT for Windows accepts the
--  aspect and does nothing with it, so a shard there binds itself in
--  Iour.Fibers.Claim_Core.  Either way the binding is a performance measure:
--  a shard knows which shard it is from Iour.Ffi.Identity, not from the core
--  it happens to be on.
--
--  Tasks beyond Shard_Count park forever instead of terminating: under
--  Jorvik a task that ends is a bounded error.
------------------------------------------------------------------------------

package Iour.Shards with SPARK_Mode => On is

   --  Referencing this makes the partition include the shard tasks; with
   --  sequential elaboration they activate once every library unit is
   --  elaborated, so the runtime is fully built before any shard runs.
   procedure Activate;

end Iour.Shards;
