package body Iour.Fibers.Job with SPARK_Mode => Off is

   --  Set once, when this instance elaborates.  No_Job if the table was
   --  already full.
   Me : Job_Ref := No_Job;

   procedure Trampoline (Arg : Fiber_Argument) is
   begin
      Work (Arg);
   end Trampoline;

   procedure Number (Id : out Job_Ref) is
   begin
      Id := Me;
   end Number;

   procedure Spawn (Arg : Fiber_Argument; Handle : out Future_Ref) is
   begin
      if Me = No_Job then
         Handle := No_Future;
      else
         Iour.Fibers.Spawn (Job_Id (Me), Arg, Handle);
      end if;
   end Spawn;

   procedure Spawn_Here (Arg : Fiber_Argument; Started : out Boolean) is
   begin
      if Me = No_Job then
         Started := False;
      else
         Iour.Fibers.Spawn_Here (Job_Id (Me), Arg, Started);
      end if;
   end Spawn_Here;

   procedure Spawn_On
     (Shard : Active_Shard; Arg : Fiber_Argument; Started : out Boolean) is
   begin
      if Me = No_Job then
         Started := False;
      else
         Iour.Fibers.Spawn_On (Shard, Job_Id (Me), Arg, Started);
      end if;
   end Spawn_On;

begin
   Register (Ref, Me);
end Iour.Fibers.Job;
