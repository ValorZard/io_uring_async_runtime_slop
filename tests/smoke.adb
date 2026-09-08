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
with Iour.Ffi.Fiber.Machine;
with Iour.Ffi.Sys;
with Iour.Fibers;
with Iour.Net;
with Iour.Scheduler;
with Iour.Shards;
with Smoke_Workload;
with Ada.Environment_Variables;
with Iour.Promises;
with Iour.Trace;

procedure Smoke with SPARK_Mode => On, CPU => 1 is

   --  Every path here ends in Exit_Process, which is No_Return, so
   --  gnatprove reports that this procedure never returns normally.  That
   --  is the design and not a defect: a Jorvik partition never ends on its
   --  own, because the environment task would block forever waiting on
   --  tasks that No_Task_Termination forbids to terminate.  Exiting the
   --  process is how such a program stops, and the README says so.
   pragma Annotate
     (GNATprove, Intentional,
      "all paths",
      "A Jorvik partition ends by calling Exit_Process; returning from the "
      & "main subprogram would hang on tasks that may not terminate.");

   Handle     : Future_Ref;
   Finished   : Natural;
   Spread     : String (1 .. 240);
   Spread_End : Natural;
   Live, Peak : Natural;
   Slots      : Natural;
   Ok         : Boolean;
   Asm_Ok     : Boolean;
   Asm_At     : Natural;
begin
   if Ada.Environment_Variables.Exists ("IOUR_TRACE") then
      Trace.Enable;
   end if;
   --  Before anything else: is the context switch in this binary the one
   --  Iour.Ffi.Fiber.Machine proved?  The shards ask the same question
   --  through Fibers.Reserve_Contexts and refuse to start if the answer is
   --  no, so this only reports it -- but it reports where, which is what a
   --  person editing the template needs.
   Ffi.Fiber.Machine.Check_Switch_Text
     (Ffi.Fiber.Machine.Switch_Template, Asm_Ok, Asm_At);
   if not Asm_Ok then
      Put_Line ("smoke: FAIL -- the assembled context switch is not the"
                & " proved instruction sequence, from character"
                & Asm_At'Image);
      Ffi.Sys.Exit_Process (1);
   end if;
   Ffi.Fiber.Machine.Check_Trampoline_Text
     (Ffi.Fiber.Machine.Trampoline_Template, Asm_Ok, Asm_At);
   if not Asm_Ok then
      Put_Line ("smoke: FAIL -- the assembled trampoline is not the proved"
                & " instruction sequence, from character" & Asm_At'Image);
      Ffi.Sys.Exit_Process (1);
   end if;
   Put_Line ("smoke: context switch matches its proved instruction sequence");

   Shards.Activate;
   Net.Ignore_Broken_Pipes;

   Put_Line ("smoke: starting" & Shard_Count'Image & " shards");
   Scheduler.Wait_Until_Ready;
   Fibers.Context_Slots (Slots);
   Put_Line ("smoke: rings up," & Slots'Image & " machine-context slots");

   Smoke_Workload.Start_Root (Handle);
   if Handle = No_Future then
      Put_Line ("smoke: FAIL -- could not spawn the root fiber");
      Ffi.Sys.Exit_Process (1);
   end if;

   --  Fulfil the root's second promise from here, the environment task.
   --  It has to be created first, so wait for the root to publish it.
   declare
      Shake : Future_Ref := No_Future;
   begin
      for Attempt in 1 .. 2_000 loop
         Smoke_Workload.Handshake (Shake);
         exit when Shake /= No_Future;
         delay 0.001;
      end loop;
      if Shake /= No_Future then
         Put_Line ("smoke: main fulfilling the root's promise");
         Promises.Fulfil (Shake, 42);
      else
         Put_Line ("smoke: FAIL -- root never published its promise");
      end if;
   end;

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
