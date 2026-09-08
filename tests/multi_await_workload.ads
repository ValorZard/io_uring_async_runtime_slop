with Iour.Fibers.Race_Witness;
------------------------------------------------------------------------------
--  Multi_Await_Workload -- does one fiber body get to hold many futures and
--  await many times, and does the core really change hands at every one of
--  those await points?
--
--  Three questions, three fiber bodies:
--
--    * Weaver.  Several fibers pinned to ONE shard, each running a straight
--      line of Steps awaits in a single procedure.  Every resumption appends
--      to a shared log, so the log itself is the evidence: if the core is
--      handed over at each await, the weavers' steps interleave; if an await
--      ran to completion without switching, one weaver's whole line would
--      appear before the next one started.
--
--    * Root's batch.  One procedure holding Batch futures live at the same
--      time -- submitted together, awaited one after another.  This is the
--      shape a scatter/gather takes here: a fiber awaits one thing at a
--      time, but nothing stops it owning many outstanding operations.
--
--    * Kid, joined from Root.  Kids spawned futures, all held in one local
--      array, awaited in turn.
--
--  Library-level, for the same two Jorvik reasons as Smoke_Workload: no
--  local protected objects, and a fiber body must be at library level for
--  its 'Access to be legal.
------------------------------------------------------------------------------

with Iour; use Iour;

package Multi_Await_Workload with SPARK_Mode => On is

   --  Fibers sharing one core, and awaits each performs in one procedure.
   Weavers : constant := 4;
   Steps   : constant := 8;

   --  Futures live simultaneously inside one procedure.
   Batch : constant := 64;

   --  Fibers spawned and then joined from one procedure.
   Kids : constant := 32;

   procedure Weaver (Arg : Fiber_Argument);
   procedure Kid (Arg : Fiber_Argument);
   procedure Root (Arg : Fiber_Argument);

   --  Every fiber body this program registers.  Never executed: it is
   --  reached only through Races.Never_Runs, which the main subprogram
   --  calls once and which is guarded by a flag nothing ever sets.
   --
   --  A body missing from here is a body checked for nothing, and nothing
   --  will say so.  Keep it in step with the Iour.Fibers.Job instances.
   procedure All_Fiber_Bodies;

   package Races is new Iour.Fibers.Race_Witness (All_Fiber_Bodies);


   --  Start Root as a fiber; the Iour.Fibers.Job instance is in the body,
   --  which is where library-level instantiation is available.
   procedure Start_Root (Handle : out Future_Ref);

   ---------------------------------------------------------------------------
   --  Results, read by the environment task after shutdown
   ---------------------------------------------------------------------------

   --  Awaits the weavers completed, whether they all ran on one shard, and
   --  whether the trace is round-robin (every weaver advances one step
   --  before any advances twice) or at least interleaved (no weaver
   --  finished before another started).
   procedure Weave_Result
     (Recorded    : out Natural;
      One_Shard   : out Boolean;
      Round_Robin : out Boolean;
      Interleaved : out Boolean);

   --  The shard the weave ran on.  Its scheduler tally is only published
   --  when the shard stops, so the resume count is read after shutdown.
   procedure Weave_Shard (Shard : out Shard_Ref);

   --  The first Limit entries of the log, as "A1 B1 C1 D1 A2 ...".
   --  Text'First = 1, and non-empty: the cursor arithmetic in the body
   --  walks it from 1, and a String whose 'First is Natural'First makes
   --  that unprovable rather than merely awkward.
   procedure Weave_Trace (Text : out String; Last : out Natural)
     with Pre  => Text'First = 1
                  and then Text'Last in 1 .. Natural'Last - 1,
          Post => Last <= Text'Last;

   procedure Batch_Result
     (Submitted : out Natural;
      Resolved  : out Natural;
      Peak_Live : out Natural);

   procedure Join_Result (Joined : out Natural; Ran : out Natural);

end Multi_Await_Workload;
