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
--  Shard N is pinned to Ada CPU First_Shard_Cpu + N.  Ada numbers CPUs from
--  one, so with First_Shard_Cpu = 2 the shards occupy Linux CPUs 1 upward
--  and leave CPU 0 to the environment task, which does startup, reporting
--  and teardown.
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
