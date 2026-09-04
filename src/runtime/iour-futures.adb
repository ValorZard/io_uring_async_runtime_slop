package body Iour.Futures with
  SPARK_Mode    => On,
  Refined_State => (Table => Pool)
is

   type Future_Record is record
      State  : Future_State := Free;
      Result : Io_Result    := 0;
      Waiter : Fiber_Ref    := No_Fiber;
      Home   : Shard_Ref    := No_Shard;
      Worker : Fiber_Ref    := No_Fiber;
   end record;

   type Record_Array is array (Future_Id) of Future_Record;
   type Free_Stack is array (Natural range 0 .. Max_Futures - 1) of Future_Id;

   --  Free slots are kept on a stack rather than found by scanning, so
   --  Acquire is constant time however full the table is.  The initial
   --  contents are built with an Ada 2022 iterated component association,
   --  which needs no elaboration code at all.
   Initial_Free : constant Free_Stack :=
     [for I in 0 .. Max_Futures - 1 => Future_Id (Max_Futures - 1 - I)];

   protected Pool is

      procedure Acquire
        (Worker : Fiber_Ref; State : Future_State; Handle : out Future_Ref);
      procedure Release (Handle : Future_Id);
      procedure Resolve
        (Handle : Future_Id;
         Result : Io_Result;
         Waiter : out Fiber_Ref;
         Home   : out Shard_Ref);
      procedure Subscribe
        (Handle : Future_Id;
         Waiter : Fiber_Id;
         Home   : Shard_Id;
         Resolved : out Boolean;
         Result : out Io_Result);
      procedure Take (Handle : Future_Id; Result : out Io_Result);
      procedure Worker_Of (Handle : Future_Id; Worker : out Fiber_Ref);
      procedure Adopt (Handle : Future_Id; Worker : out Fiber_Ref);
      procedure Stats (Live : out Natural; High_Water : out Natural);

   private
      Slots     : Record_Array := [others => (others => <>)];
      Available : Free_Stack   := Initial_Free;

      --  Available (0 .. Top - 1) holds the free slots.  Giving Top its own
      --  bounded subtype is what makes the index arithmetic below provable
      --  instead of merely correct.
      Top  : Natural range 0 .. Max_Futures := Max_Futures;
      Peak : Natural range 0 .. Max_Futures := 0;
   end Pool;

   ---------------------------------------------------------------------------

   protected body Pool is

      procedure Acquire
        (Worker : Fiber_Ref; State : Future_State; Handle : out Future_Ref)
      is
         Live : Natural;
      begin
         if Top = 0 then
            --  Exhausted.  Callers surface this as a rejected connection or
            --  a refused spawn; silently blocking here would deadlock the
            --  very shard that could free a slot.
            Handle := No_Future;
            return;
         end if;

         Top := Top - 1;
         Handle := Available (Top);

         Slots (Handle) := (State  => State,
                            Result => 0,
                            Waiter => No_Fiber,
                            Home   => No_Shard,
                            Worker => Worker);

         Live := Max_Futures - Top;
         if Live > Peak then
            Peak := Live;
         end if;
      end Acquire;

      procedure Release (Handle : Future_Id) is
      begin
         if Slots (Handle).State = Free then
            return;  --  idempotent: error paths need not track ownership
         end if;
         Slots (Handle) := (others => <>);
         if Top < Max_Futures then
            Available (Top) := Handle;
            Top := Top + 1;
         end if;
      end Release;

      procedure Resolve
        (Handle : Future_Id;
         Result : Io_Result;
         Waiter : out Fiber_Ref;
         Home   : out Shard_Ref)
      is
      begin
         Waiter := No_Fiber;
         Home   := No_Shard;

         --  A completion for a slot that has already been freed is not an
         --  error: a cancelled or timed-out operation can still land after
         --  its future was abandoned.  Drop it.
         if Slots (Handle).State not in Queued | Pending then
            return;
         end if;

         Slots (Handle).Result := Result;
         Slots (Handle).State  := Ready;

         --  Hand the waiter back exactly once; a second resolution of the
         --  same future must not wake anybody twice.
         Waiter := Slots (Handle).Waiter;
         Home   := Slots (Handle).Home;
         Slots (Handle).Waiter := No_Fiber;
      end Resolve;

      procedure Subscribe
        (Handle : Future_Id;
         Waiter : Fiber_Id;
         Home   : Shard_Id;
         Resolved : out Boolean;
         Result : out Io_Result)
      is
      begin
         if Slots (Handle).State = Ready then
            --  Resolved before the caller got here: no need to sleep.
            Resolved := True;
            Result := Slots (Handle).Result;
            return;
         end if;

         Resolved := False;
         Result := 0;
         Slots (Handle).Waiter := Waiter;
         Slots (Handle).Home   := Home;
      end Subscribe;

      procedure Take (Handle : Future_Id; Result : out Io_Result) is
      begin
         Result := Slots (Handle).Result;
         Release (Handle);
      end Take;

      procedure Worker_Of (Handle : Future_Id; Worker : out Fiber_Ref) is
      begin
         Worker := Slots (Handle).Worker;
      end Worker_Of;

      procedure Adopt (Handle : Future_Id; Worker : out Fiber_Ref) is
      begin
         Worker := No_Fiber;
         if Slots (Handle).State /= Queued then
            return;  --  another shard got there first
         end if;
         Slots (Handle).State := Pending;
         Worker := Slots (Handle).Worker;
      end Adopt;

      procedure Stats (Live : out Natural; High_Water : out Natural) is
      begin
         Live := Max_Futures - Top;
         High_Water := Peak;
      end Stats;

   end Pool;

   ---------------------------------------------------------------------------
   --  Thin forwarding layer
   ---------------------------------------------------------------------------

   procedure Acquire
     (Worker : Fiber_Ref; State : Future_State; Handle : out Future_Ref) is
   begin
      Pool.Acquire (Worker, State, Handle);
   end Acquire;

   procedure Release (Handle : Future_Id) is
   begin
      Pool.Release (Handle);
   end Release;

   procedure Resolve
     (Handle : Future_Id;
      Result : Io_Result;
      Waiter : out Fiber_Ref;
      Home   : out Shard_Ref) is
   begin
      Pool.Resolve (Handle, Result, Waiter, Home);
   end Resolve;

   procedure Subscribe
     (Handle : Future_Id;
      Waiter : Fiber_Id;
      Home   : Shard_Id;
      Resolved : out Boolean;
      Result : out Io_Result) is
   begin
      Pool.Subscribe (Handle, Waiter, Home, Resolved, Result);
   end Subscribe;

   procedure Take (Handle : Future_Id; Result : out Io_Result) is
   begin
      Pool.Take (Handle, Result);
   end Take;

   procedure Worker_Of (Handle : Future_Id; Worker : out Fiber_Ref) is
   begin
      Pool.Worker_Of (Handle, Worker);
   end Worker_Of;

   procedure Adopt (Handle : Future_Id; Worker : out Fiber_Ref) is
   begin
      Pool.Adopt (Handle, Worker);
   end Adopt;

   procedure Stats (Live : out Natural; High_Water : out Natural) is
   begin
      Pool.Stats (Live, High_Water);
   end Stats;

end Iour.Futures;
