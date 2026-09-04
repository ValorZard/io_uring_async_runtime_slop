with Interfaces; use Interfaces;
with Iour.Fibers;
with Iour.Futures;
with Iour.Reactor;
with Iour.Scheduler;
with Iour.Promises;
with Iour.Text;

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
      procedure Set_Handshake (H : Future_Ref);
      procedure Get_Handshake (H : out Future_Ref);
   private
      Shake     : Future_Ref := No_Future;
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

      procedure Set_Handshake (H : Future_Ref) is
      begin
         Shake := H;
      end Set_Handshake;

      procedure Get_Handshake (H : out Future_Ref) is
      begin
         H := Shake;
      end Get_Handshake;

      procedure Read (Done : out Natural; Runs_Out : out Run_Counts) is
      begin
         Done := Completed;
         Runs_Out := Runs;
      end Read;

   end Tally;

   ---------------------------------------------------------------------------

   --  Arg is the promise the workers collectively fulfil when the last one
   --  finishes.
   procedure Worker (Arg : Fiber_Argument) is
      Handle  : Future_Ref;
      Queued  : Boolean;
      Outcome : Io_Result;
      Shard   : constant Shard_Ref := Fibers.Self;
      Done    : Natural;
      Runs    : Run_Counts;
   begin
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
      Tally.Read (Done, Runs);
      if Done = Worker_Count and then Arg >= 0 then
         --  Last one out wakes the root, wherever its shard is.
         Iour.Text.Put_Line ("  worker on shard" & Shard'Image
                             & " is last; fulfilling the promise");
         Iour.Promises.Fulfil (Future_Id (Arg), Io_Result (Done));
      end if;
   end Worker;

   ---------------------------------------------------------------------------

   procedure Root (Arg : Fiber_Argument) is
      Handle    : Future_Ref;
      All_Done  : Future_Ref;
      From_Main : Future_Ref;
      Value     : Io_Result;
   begin
      pragma Unreferenced (Arg);

      --  A promise the last worker fulfils.  Awaiting it suspends this
      --  fiber alone -- no polling, no protected entry, no parked shard.
      Iour.Promises.Create (All_Done);
      if All_Done = No_Future then
         Scheduler.Request_Shutdown;
         return;
      end if;

      for I in 1 .. Worker_Count loop
         Fibers.Spawn (Worker'Access, Fiber_Argument (All_Done), Handle);
      end loop;

      Iour.Promises.Await (All_Done, Value);
      Iour.Text.Put_Line ("  root woke: workers finished" & Value'Image);

      --  Now a promise the ENVIRONMENT TASK fulfils, which has no ring and
      --  so has to reach this shard through its inbox.
      Iour.Promises.Create (From_Main);
      if From_Main /= No_Future then
         Tally.Set_Handshake (From_Main);
         Iour.Promises.Await (From_Main, Value);
         Iour.Text.Put_Line ("  root woke again: main said" & Value'Image);
      end if;

      Scheduler.Request_Shutdown;
   end Root;

   procedure Handshake (Handle : out Future_Ref) is
   begin
      Tally.Get_Handshake (Handle);
   end Handshake;

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
