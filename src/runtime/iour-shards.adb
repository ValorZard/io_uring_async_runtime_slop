with System;
with System.Multiprocessors;
with Iour.Scheduler;

package body Iour.Shards with SPARK_Mode => On is

   use type System.Multiprocessors.CPU_Range;

   procedure Activate is null;

   ---------------------------------------------------------------------------
   --  Parking
   ---------------------------------------------------------------------------

   --  A barrier that never opens.  Jorvik's No_Task_Termination means a
   --  task must not run off the end of its body, so a shard that is surplus
   --  to Shard_Count, or that has finished draining, waits here instead.
   --  It costs no CPU: the task is blocked in the runtime, not spinning.
   protected Parking is
      entry Wait_Forever;
   private
      Released : Boolean := False;
   end Parking;

   --  Barrier-only entries: the body is "null" because the wait is the
   --  point, and SPARK reports a null statement as having no effect.
   pragma Warnings
     (GNATprove, Off, "statement has no effect",
      Reason => "Barrier-only entry: the wait is the point.");
   protected body Parking is
      entry Wait_Forever when Released is
      begin
         null;
      end Wait_Forever;
   end Parking;
   pragma Warnings (GNATprove, On, "statement has no effect");

   ---------------------------------------------------------------------------
   --  Shared body
   ---------------------------------------------------------------------------

   --  Every declared shard calls Run with its own index; Run itself decides
   --  whether that index is one of the Shard_Count that take part.  Keeping
   --  the decision there means nothing here narrows a value, so a task
   --  beyond Shard_Count cannot trip a range check on its way to parking.
   procedure Serve (Index : Shard_Id) is
   begin
      Scheduler.Run (Index);

      --  Park for good.  The loop is what makes "never returns" visible:
      --  the barrier below is permanently closed, but nothing in the
      --  language says so, and under Jorvik a task that runs off the end of
      --  its body is a bounded error.
      loop
         Parking.Wait_Forever;
      end loop;
   end Serve;

   ---------------------------------------------------------------------------
   --  The tasks
   ---------------------------------------------------------------------------

   --  One declaration per shard, each with its own static CPU.  To change
   --  how many cores the runtime uses, adjust Shard_Count in Iour; to raise
   --  the ceiling, add a declaration here and bump Max_Shards.

   Shard_Priority : constant System.Priority := System.Default_Priority;

   task Shard_0 with CPU => First_Shard_Cpu + 0, Priority => Shard_Priority;
   task Shard_1 with CPU => First_Shard_Cpu + 1, Priority => Shard_Priority;
   task Shard_2 with CPU => First_Shard_Cpu + 2, Priority => Shard_Priority;
   task Shard_3 with CPU => First_Shard_Cpu + 3, Priority => Shard_Priority;
   task Shard_4 with CPU => First_Shard_Cpu + 4, Priority => Shard_Priority;
   task Shard_5 with CPU => First_Shard_Cpu + 5, Priority => Shard_Priority;
   task Shard_6 with CPU => First_Shard_Cpu + 6, Priority => Shard_Priority;
   task Shard_7 with CPU => First_Shard_Cpu + 7, Priority => Shard_Priority;

   task body Shard_0 is begin Serve (0); end Shard_0;
   task body Shard_1 is begin Serve (1); end Shard_1;
   task body Shard_2 is begin Serve (2); end Shard_2;
   task body Shard_3 is begin Serve (3); end Shard_3;
   task body Shard_4 is begin Serve (4); end Shard_4;
   task body Shard_5 is begin Serve (5); end Shard_5;
   task body Shard_6 is begin Serve (6); end Shard_6;
   task body Shard_7 is begin Serve (7); end Shard_7;

   pragma Compile_Time_Error
     (Shard_Count > Max_Shards,
      "Shard_Count exceeds the number of shard task declarations");

end Iour.Shards;
