with Interfaces; use Interfaces;
with Iour.Fibers;
with Iour.Futures;
with Iour.Reactor;
with Iour.Scheduler;
with Iour.Time;

package body Smoke_Workload with SPARK_Mode => On is

   package Fibers renames Iour.Fibers;
   package Futures renames Iour.Futures;
   package Reactor renames Iour.Reactor;
   package Scheduler renames Iour.Scheduler;

   type Run_Counts is array (Shard_Id) of Natural;

   protected Tally is
      procedure Record_Run (Shard : Shard_Ref);
      procedure Finished;
      procedure Read (Done : out Natural; Runs_Out : out Run_Counts);
      function All_Done return Boolean;
   private
      Runs      : Run_Counts := [others => 0];
      Completed : Natural := 0;
   end Tally;

   protected body Tally is

      procedure Record_Run (Shard : Shard_Ref) is
      begin
         if Shard in Shard_Id then
            Runs (Shard) := Runs (Shard) + 1;
         end if;
      end Record_Run;

      procedure Finished is
      begin
         Completed := Completed + 1;
      end Finished;

      function All_Done return Boolean is (Completed = Worker_Count);

      procedure Read (Done : out Natural; Runs_Out : out Run_Counts) is
      begin
         Done := Completed;
         Runs_Out := Runs;
      end Read;

   end Tally;

   ---------------------------------------------------------------------------

   procedure Worker (Arg : Fiber_Argument) is
      Handle : Future_Ref;
      Queued : Boolean;
      Outcome : Io_Result;
      Shard  : constant Shard_Ref := Fibers.Self;
   begin
      pragma Unreferenced (Arg);
      Tally.Record_Run (Shard);

      if Shard in Active_Shard then
         --  A NOP is trivial as an operation but drives the entire path:
         --  submission slot, io_uring_enter, completion harvest, future
         --  resolution, and the switch back into this fiber.
         Futures.Acquire (No_Fiber, Futures.Pending, Handle);
         if Handle /= No_Future then
            Reactor.Push
              (Active_Shard (Shard),
               Reactor.Op_Nop
                 (Reactor.Encode (Reactor.Tag_Future, Unsigned_32 (Handle))),
               Queued);
            if Queued then
               Fibers.Await (Handle, Outcome);
            else
               Futures.Release (Handle);
            end if;
         end if;

         --  Cover the voluntary-yield path as well.
         Fibers.Yield;
      end if;

      Tally.Finished;
   end Worker;

   ---------------------------------------------------------------------------

   procedure Root (Arg : Fiber_Argument) is
      Handle : Future_Ref;
   begin
      pragma Unreferenced (Arg);

      for I in 1 .. Worker_Count loop
         Fibers.Spawn (Worker'Access, Fiber_Argument (I), Handle);
      end loop;

      --  Wait by sleeping, not by queueing on a protected entry.  An entry
      --  call from a fiber blocks the underlying task, and the task is the
      --  whole shard: every other fiber on that core would stop with it.
      --  Iour.Time.Sleep suspends this fiber alone.
      while not Tally.All_Done loop
         Iour.Time.Sleep_Milliseconds (1);
      end loop;

      Scheduler.Request_Shutdown;
   end Root;

   ---------------------------------------------------------------------------

   procedure Result
     (Finished : out Natural;
      Spread   : out String;
      Last     : out Natural)
   is
      Runs   : Run_Counts;
      Cursor : Natural := Spread'First;
   begin
      Spread := [others => ' '];
      Tally.Read (Finished, Runs);
      Last := Spread'First - 1;

      for S in Active_Shard loop
         declare
            Piece : constant String :=
              " shard" & S'Image & ":" & Runs (S)'Image;
         begin
            exit when Cursor + Piece'Length - 1 > Spread'Last;
            Spread (Cursor .. Cursor + Piece'Length - 1) := Piece;
            Cursor := Cursor + Piece'Length;
            Last := Cursor - 1;
         end;
      end loop;
   end Result;

end Smoke_Workload;
