with Interfaces; use Interfaces;
with Iour.Fibers;
with Iour.Futures;
with Iour.Reactor;
with Iour.Scheduler;
with Iour.Promises;
with Iour.Text;

package body Multi_Await_Workload with SPARK_Mode => On is

   package Fibers renames Iour.Fibers;
   package Futures renames Iour.Futures;
   package Reactor renames Iour.Reactor;

   Max_Events : constant := Weavers * Steps;

   subtype Weaver_Index is Natural range 0 .. Weavers - 1;
   subtype Step_Index is Natural range 1 .. Steps;

   type Event is record
      Who   : Natural   := 0;
      Step  : Natural   := 0;
      Shard : Shard_Ref := No_Shard;
   end record;

   type Event_Log is array (1 .. Max_Events) of Event;

   ---------------------------------------------------------------------------
   --  Shared state.  Everything the fibers write and the environment task
   --  reads afterwards, in one protected object at library level.
   ---------------------------------------------------------------------------

   protected Book with Priority => Runtime_Priority is
      procedure Take_Index (Who : out Natural);
      procedure Append (Who : Natural; Step : Natural; Shard : Shard_Ref);
      procedure Finished_Weaver (Count : out Natural);
      procedure Read_Log (Out_Log : out Event_Log; Count : out Natural);

      procedure Set_Batch (Submitted, Resolved, Peak : Natural);
      procedure Get_Batch (Submitted, Resolved, Peak : out Natural);

      procedure Kid_Ran;
      procedure Set_Joined (Count : Natural);
      procedure Get_Join (Joined_Out, Ran_Out : out Natural);

      procedure Set_Home (Shard : Shard_Ref);
      procedure Get_Home (Shard : out Shard_Ref);
   private
      Next_Index  : Natural := 0;
      Log         : Event_Log;
      Used        : Natural := 0;
      Done_Weaver : Natural := 0;

      B_Submitted : Natural := 0;
      B_Resolved  : Natural := 0;
      B_Peak      : Natural := 0;

      Kids_Ran    : Natural := 0;
      Joined      : Natural := 0;
      Home        : Shard_Ref := No_Shard;
   end Book;

   protected body Book is

      procedure Take_Index (Who : out Natural) is
      begin
         Who := Next_Index;
         if Next_Index < Natural'Last then
            Next_Index := Next_Index + 1;
         end if;
      end Take_Index;

      procedure Append (Who : Natural; Step : Natural; Shard : Shard_Ref) is
      begin
         if Used < Max_Events then
            Used := Used + 1;
            Log (Used) := (Who => Who, Step => Step, Shard => Shard);
         end if;
      end Append;

      procedure Finished_Weaver (Count : out Natural) is
      begin
         Done_Weaver := Done_Weaver + 1;
         Count := Done_Weaver;
      end Finished_Weaver;

      procedure Read_Log (Out_Log : out Event_Log; Count : out Natural) is
      begin
         Out_Log := Log;
         Count := Used;
      end Read_Log;

      procedure Set_Batch (Submitted, Resolved, Peak : Natural) is
      begin
         B_Submitted := Submitted;
         B_Resolved := Resolved;
         B_Peak := Peak;
      end Set_Batch;

      procedure Get_Batch (Submitted, Resolved, Peak : out Natural) is
      begin
         Submitted := B_Submitted;
         Resolved := B_Resolved;
         Peak := B_Peak;
      end Get_Batch;

      procedure Kid_Ran is
      begin
         Kids_Ran := Kids_Ran + 1;
      end Kid_Ran;

      procedure Set_Joined (Count : Natural) is
      begin
         Joined := Count;
      end Set_Joined;

      procedure Get_Join (Joined_Out, Ran_Out : out Natural) is
      begin
         Joined_Out := Joined;
         Ran_Out := Kids_Ran;
      end Get_Join;

      procedure Set_Home (Shard : Shard_Ref) is
      begin
         Home := Shard;
      end Set_Home;

      procedure Get_Home (Shard : out Shard_Ref) is
      begin
         Shard := Home;
      end Get_Home;

   end Book;

   ---------------------------------------------------------------------------
   --  One await, built the long way round so the future is visible: take a
   --  slot, put a NOP in this shard's ring against it, suspend on it.
   --  Trivial as an operation, but it drives the whole path -- submission,
   --  io_uring_enter, harvest, resolution, and the switch back into here.
   ---------------------------------------------------------------------------

   procedure Nop_Await (Ok : out Boolean) is
      Shard   : constant Shard_Ref := Fibers.Self;
      Handle  : Future_Ref;
      Queued  : Boolean;
      Outcome : Io_Result;
   begin
      Ok := False;
      if Shard not in Active_Shard then
         return;
      end if;

      Futures.Acquire
        (Near   => Shard,
         Worker => No_Fiber,
         State  => Futures.Pending,
         Waiter => No_Fiber,
         Home   => No_Shard,
         Handle => Handle);
      if Handle = No_Future then
         return;
      end if;

      Reactor.Push
        (Active_Shard (Shard),
         Reactor.Op_Nop (Reactor.Encode (Reactor.Tag_Future,
                                         Unsigned_32 (Handle))),
         Queued);
      if not Queued then
         Futures.Release (Handle);
         return;
      end if;

      Fibers.Await (Handle, Outcome);
      Ok := Outcome >= 0;
   end Nop_Await;

   ---------------------------------------------------------------------------
   --  Weaver: Steps awaits in one straight-line procedure, logging where it
   --  is each time it comes back.  Arg is the promise the last one fulfils.
   ---------------------------------------------------------------------------

   procedure Weaver (Arg : Fiber_Argument) is
      Me    : Natural;
      Ok    : Boolean;
      Done  : Natural;
      Shard : Shard_Ref;
   begin
      Book.Take_Index (Me);

      for Step in Step_Index loop
         Nop_Await (Ok);
         exit when not Ok;
         Shard := Fibers.Self;
         Book.Append (Me, Step, Shard);
      end loop;

      Book.Finished_Weaver (Done);
      if Done = Weavers and then Arg >= 0 then
         Iour.Promises.Fulfil (Future_Id (Arg), Io_Result (Done));
      end if;
   end Weaver;

   ---------------------------------------------------------------------------
   --  Kid: a spawned fiber with two suspension points of its own, so a join
   --  is joining something that really did give the core up.
   ---------------------------------------------------------------------------

   procedure Kid (Arg : Fiber_Argument) is
      Ok : Boolean;
   begin
      pragma Unreferenced (Arg);
      Nop_Await (Ok);
      Fibers.Yield;
      Book.Kid_Ran;
   end Kid;

   ---------------------------------------------------------------------------
   --  Root: runs the three experiments in turn.
   ---------------------------------------------------------------------------

   procedure Root (Arg : Fiber_Argument) is
      Home      : constant Shard_Ref := Fibers.Self;
      Woven     : Future_Ref;
      Value     : Io_Result;
      Started   : Boolean;

      --  Batch: Batch futures alive at once inside this one procedure.
      Handles   : array (1 .. Batch) of Future_Ref := [others => No_Future];
      Submitted : Natural := 0;
      Resolved  : Natural := 0;
      Live      : Natural := 0;
      Peak      : Natural := 0;
      Queued    : Boolean;

      --  Join: Kids spawned futures, all held here at once.
      Kid_Handles : array (1 .. Kids) of Future_Ref := [others => No_Future];
      Joined      : Natural := 0;
   begin
      pragma Unreferenced (Arg);

      if Home not in Active_Shard then
         Iour.Scheduler.Request_Shutdown;
         return;
      end if;

      ------------------------------------------------------------------
      --  1.  Many awaits in one procedure, several fibers, one core.
      ------------------------------------------------------------------

      Book.Set_Home (Home);

      Iour.Promises.Create (Woven);
      if Woven = No_Future then
         Iour.Scheduler.Request_Shutdown;
         return;
      end if;

      --  Spawn_Here, so every weaver lands on this core and nothing else
      --  can be running when they interleave.
      for I in 1 .. Weavers loop
         Fibers.Spawn_Here (Weaver'Access, Fiber_Argument (Woven), Started);
         exit when not Started;
      end loop;

      Iour.Promises.Await (Woven, Value);

      ------------------------------------------------------------------
      --  2.  Batch futures live at once, awaited one after another.
      ------------------------------------------------------------------

      for I in Handles'Range loop
         Futures.Acquire
           (Near   => Home,
            Worker => No_Fiber,
            State  => Futures.Pending,
            Waiter => No_Fiber,
            Home   => No_Shard,
            Handle => Handles (I));
         exit when Handles (I) = No_Future;

         Reactor.Push
           (Active_Shard (Home),
            Reactor.Op_Nop
              (Reactor.Encode (Reactor.Tag_Future,
                               Unsigned_32 (Handles (I)))),
            Queued);
         if not Queued then
            Futures.Release (Handles (I));
            Handles (I) := No_Future;
            exit;
         end if;
         Submitted := Submitted + 1;
      end loop;

      --  Every one of them is outstanding at this instant.
      Futures.Stats (Live, Peak);

      for I in Handles'Range loop
         if Handles (I) /= No_Future then
            Fibers.Await (Future_Id (Handles (I)), Value);
            if Value >= 0 then
               Resolved := Resolved + 1;
            end if;
         end if;
      end loop;

      Book.Set_Batch (Submitted, Resolved, Live);

      ------------------------------------------------------------------
      --  3.  Kids spawned, all their futures held here, joined in turn.
      ------------------------------------------------------------------

      for I in Kid_Handles'Range loop
         Fibers.Spawn (Kid'Access, Fiber_Argument (I), Kid_Handles (I));
      end loop;

      for I in Kid_Handles'Range loop
         if Kid_Handles (I) /= No_Future then
            Fibers.Await (Future_Id (Kid_Handles (I)), Value);
            Joined := Joined + 1;
         end if;
      end loop;

      Book.Set_Joined (Joined);

      Iour.Text.Put_Line ("  root: weave, batch and join all returned");
      Iour.Scheduler.Request_Shutdown;
   end Root;

   ---------------------------------------------------------------------------
   --  Reporting
   ---------------------------------------------------------------------------

   procedure Weave_Result
     (Recorded    : out Natural;
      One_Shard   : out Boolean;
      Round_Robin : out Boolean;
      Interleaved : out Boolean)
   is
      Log   : Event_Log;
      Count : Natural;
      First : Shard_Ref;

      --  Step each weaver has reached, walking the log in order.
      Reached : array (Weaver_Index) of Natural := [others => 0];
   begin
      Book.Read_Log (Log, Count);
      Recorded := Count;
      One_Shard := Count > 0;
      Round_Robin := Count = Max_Events;
      Interleaved := Count > 0;

      if Count = 0 then
         return;
      end if;

      First := Log (1).Shard;
      for I in 1 .. Count loop
         if Log (I).Shard /= First then
            One_Shard := False;
         end if;
      end loop;

      --  Round robin: the log is Weavers-sized blocks, each block holding
      --  every weaver exactly once, at the same step.  That is what a
      --  handover at every await point produces when the awaits cost the
      --  same.
      for I in 1 .. Count loop
         declare
            Expected_Step : constant Natural := (I - 1) / Weavers + 1;
         begin
            if Log (I).Step /= Expected_Step then
               Round_Robin := False;
            end if;
         end;
      end loop;

      --  Interleaved, the weaker claim: no weaver ever got more than one
      --  step ahead of another that had not finished.  Fails outright if
      --  any weaver ran its whole line before another began.
      for I in 1 .. Count loop
         if Log (I).Who in Weaver_Index then
            Reached (Log (I).Who) := Log (I).Step;
            for W in Weaver_Index loop
               if Reached (W) + 1 < Log (I).Step then
                  Interleaved := False;
               end if;
            end loop;
         end if;
      end loop;
   end Weave_Result;

   procedure Weave_Trace (Text : out String; Last : out Natural) is
      Log    : Event_Log;
      Count  : Natural;
      Cursor : Natural := Text'First;
      Names  : constant String := "ABCDEFGH";
   begin
      Text := [others => ' '];
      Last := Text'First - 1;
      Book.Read_Log (Log, Count);

      for I in 1 .. Count loop
         declare
            Who   : constant Natural := Log (I).Who;
            Tag   : constant Character :=
              (if Who < Names'Length then Names (Names'First + Who) else '?');
            Digit : constant String := Log (I).Step'Image;
            Piece : constant String :=
              Tag & Digit (Digit'First + 1 .. Digit'Last) & " ";
         begin
            exit when Cursor + Piece'Length - 1 > Text'Last;
            Text (Cursor .. Cursor + Piece'Length - 1) := Piece;
            Cursor := Cursor + Piece'Length;
            Last := Cursor - 1;
         end;
      end loop;
   end Weave_Trace;

   procedure Weave_Shard (Shard : out Shard_Ref) is
   begin
      Book.Get_Home (Shard);
   end Weave_Shard;

   procedure Batch_Result
     (Submitted : out Natural;
      Resolved  : out Natural;
      Peak_Live : out Natural) is
   begin
      Book.Get_Batch (Submitted, Resolved, Peak_Live);
   end Batch_Result;

   procedure Join_Result (Joined : out Natural; Ran : out Natural) is
   begin
      Book.Get_Join (Joined, Ran);
   end Join_Result;

end Multi_Await_Workload;
