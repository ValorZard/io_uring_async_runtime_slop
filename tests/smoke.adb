------------------------------------------------------------------------------
--  smoke -- does the runtime start, spread work across cores, suspend a
--  fiber on a real io_uring operation, and shut down cleanly?
--
--  The main subprogram only starts the runtime and reports; the work itself
--  lives in Smoke_Workload, because Jorvik requires fiber bodies and shared
--  state at library level.
--
--  The environment task is pinned to Ada CPU 1 (Linux CPU 0), clear of the
--  shards, which start at First_Shard_Cpu.  That separation matters: shard
--  identity is derived from the running CPU, so the environment task must
--  never share a core with a shard or it would be mistaken for one.
------------------------------------------------------------------------------

with Ada.Text_IO;  use Ada.Text_IO;
with Iour;         use Iour;
with Iour.Ffi.Sys;
with Iour.Fibers;
with Iour.Net;
with Iour.Scheduler;
with Iour.Shards;
with Smoke_Workload;

procedure Smoke with SPARK_Mode => On, CPU => 1 is

   Handle     : Future_Ref;
   Finished   : Natural;
   Spread     : String (1 .. 240);
   Spread_End : Natural;
   Live, Peak : Natural;
   Slots      : Natural;
   Ok         : Boolean;
begin
   Shards.Activate;
   Net.Ignore_Broken_Pipes;

   Put_Line ("smoke: starting" & Shard_Count'Image & " shards");
   Scheduler.Wait_Until_Ready;
   Fibers.Context_Slots (Slots);
   Put_Line ("smoke: rings up," & Slots'Image & " machine-context slots");

   Fibers.Spawn (Smoke_Workload.Root'Access, 0, Handle);
   if Handle = No_Future then
      Put_Line ("smoke: FAIL -- could not spawn the root fiber");
      Ffi.Sys.Exit_Process (1);
   end if;

   Scheduler.Wait_For_Shutdown;

   Smoke_Workload.Result (Finished, Spread, Spread_End);
   Fibers.Live_Fibers (Live, Peak);

   Put_Line ("smoke: workers finished" & Finished'Image
             & " of" & Smoke_Workload.Worker_Count'Image);
   Put_Line ("smoke: ran on" & Spread (Spread'First .. Spread_End));
   Put_Line ("smoke: fibers live" & Live'Image & ", peak" & Peak'Image);

   for S in Active_Shard loop
      declare
         Completions, Resumes, Adopted, Sleeps, Left, Bad : Natural;
      begin
         Scheduler.Report
           (S, Completions, Resumes, Adopted, Sleeps, Left, Bad);
         Put_Line ("  shard" & S'Image
                   & ": completions" & Completions'Image
                   & ", resumes" & Resumes'Image
                   & ", adopted" & Adopted'Image
                   & ", sleeps" & Sleeps'Image
                   & (if Bad > 0 then ", FLUSH ERRORS" & Bad'Image else ""));
      end;
   end loop;

   Fibers.Release_All_Stacks;

   Ok := Finished = Smoke_Workload.Worker_Count and then Live = 0;
   Put_Line (if Ok then "smoke: PASS" else "smoke: FAIL");

   --  A Jorvik partition never ends on its own: the environment task would
   --  block forever waiting on tasks that are not allowed to terminate.
   Ffi.Sys.Exit_Process (if Ok then 0 else 1);
end Smoke;
