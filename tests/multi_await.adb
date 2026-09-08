------------------------------------------------------------------------------
--  multi_await -- can one fiber body hold many futures and await many
--  times, and does the core change hands at every one of those points?
--
--  Same shape as smoke: the environment task, pinned to Ada CPU 1 and clear
--  of the shards, starts the runtime, spawns the root fiber and reports.
------------------------------------------------------------------------------

with Ada.Text_IO; use Ada.Text_IO;
with Iour;        use Iour;
with Iour.Ffi.Sys;
with Iour.Fibers;
with Iour.Scheduler;
with Iour.Shards;
with Iour.Trace;
with Ada.Environment_Variables;
with Multi_Await_Workload;

procedure Multi_Await with SPARK_Mode => On, CPU => 1 is

   Handle : Future_Ref;
   Failed : Boolean := False;

   Recorded                   : Natural;
   One_Shard, Round_Robin     : Boolean;
   Interleaved                : Boolean;
   Weave_Shard                : Shard_Ref;
   Comps, Resumes, Adopted    : Natural;
   Slept, Aband, Flush_Bad    : Natural;
   Trace_Text                 : String (1 .. 512);
   Trace_Last                 : Natural;
   Submitted, Resolved, Peak  : Natural;
   Joined, Ran                : Natural;

   Expected_Steps : constant Natural :=
     Multi_Await_Workload.Weavers * Multi_Await_Workload.Steps;

   procedure Check (Ok : Boolean; What : String) is
   begin
      Put_Line ((if Ok then "  ok   " else "  FAIL ") & What);
      if not Ok then
         Failed := True;
      end if;
   end Check;

begin
   if Ada.Environment_Variables.Exists ("IOUR_TRACE") then
      Trace.Enable;
   end if;
   Shards.Activate;

   Put_Line ("multi_await: starting" & Shard_Count'Image & " shards");
   Scheduler.Wait_Until_Ready;

   Multi_Await_Workload.Start_Root (Handle);
   if Handle = No_Future then
      Put_Line ("multi_await: FAIL -- could not spawn the root fiber");
      Ffi.Sys.Exit_Process (1);
   end if;

   Scheduler.Wait_For_Shutdown;
   Fibers.Release_All_Stacks;

   Multi_Await_Workload.Weave_Result
     (Recorded, One_Shard, Round_Robin, Interleaved);
   Multi_Await_Workload.Weave_Shard (Weave_Shard);

   --  A shard publishes its tallies when it stops, so this is read after
   --  Wait_For_Shutdown.  Fibers_Run counts resumptions: every await point
   --  that suspended costs one.
   Resumes := 0;
   if Weave_Shard in Shard_Id then
      Scheduler.Report
        (Shard_Id (Weave_Shard), Comps, Resumes, Adopted, Slept, Aband,
         Flush_Bad);
   end if;
   Multi_Await_Workload.Weave_Trace (Trace_Text, Trace_Last);
   Multi_Await_Workload.Batch_Result (Submitted, Resolved, Peak);
   Multi_Await_Workload.Join_Result (Joined, Ran);

   New_Line;
   Put_Line ("1. many awaits in one procedure, several fibers, one core");
   Put_Line ("   " & Multi_Await_Workload.Weavers'Image & " weavers x"
             & Multi_Await_Workload.Steps'Image & " awaits each");
   Put_Line ("   trace: " & Trace_Text (Trace_Text'First .. Trace_Last));
   Check (Recorded = Expected_Steps,
          "every await returned:" & Recorded'Image & " of"
          & Expected_Steps'Image);
   Check (One_Shard, "all of them on one shard, so the interleaving is a"
          & " context switch and not another core");
   Check (Interleaved,
          "the weavers interleave -- no fiber ran its line to the end"
          & " before another started");
   Check (Round_Robin,
          "and strictly round robin: each await point hands the core on");
   Check (Resumes > Expected_Steps,
          "scheduler resumed fibers" & Resumes'Image
          & " times on that shard, more than the" & Expected_Steps'Image
          & " await points it had to cover");

   New_Line;
   Put_Line ("2. many futures live at once inside one procedure");
   Check (Submitted = Multi_Await_Workload.Batch,
          "submitted" & Submitted'Image & " operations before awaiting any");
   Check (Peak >= Submitted,
          "futures live at that instant:" & Peak'Image);
   Check (Resolved = Submitted,
          "awaited them one after another:" & Resolved'Image & " resolved");

   New_Line;
   Put_Line ("3. spawned futures held in one array and joined in turn");
   Check (Joined = Multi_Await_Workload.Kids,
          "joined" & Joined'Image & " of" & Multi_Await_Workload.Kids'Image);
   Check (Ran = Multi_Await_Workload.Kids,
          "and each kid really ran and suspended:" & Ran'Image);

   New_Line;
   if Failed then
      Put_Line ("multi_await: FAIL");
      Ffi.Sys.Exit_Process (1);
   end if;
   Put_Line ("multi_await: PASS");
   Ffi.Sys.Exit_Process (0);
end Multi_Await;
