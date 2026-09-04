package body Iour.Futures with
  SPARK_Mode    => On,
  Refined_State => (Table => Banks)
is

   type Future_Record is record
      State  : Future_State := Free;
      Result : Io_Result    := 0;
      Waiter : Fiber_Ref    := No_Fiber;
      Home   : Shard_Ref    := No_Shard;
      Worker : Fiber_Ref    := No_Fiber;
   end record;

   ---------------------------------------------------------------------------
   --  Banking
   ---------------------------------------------------------------------------

   --  One bank per shard, each holding a contiguous stripe of the handle
   --  space.  A handle names its own bank, so nothing has to be remembered
   --  about where a future was created: Bank_Of and Local_Of take any handle
   --  apart, and every operation below goes straight to the one protected
   --  object that owns that slot.
   Bank_Size : constant := Max_Futures / Shard_Count;

   pragma Compile_Time_Error
     (Bank_Size < 8,
      "Max_Futures is too small to divide across Shard_Count banks");

   --  Exact division is what keeps Bank_Of total without a clamp, and so
   --  keeps the handle space free of slots that belong to no bank.  If you
   --  pick a Shard_Count that does not divide Max_Futures, round Max_Futures
   --  up in Iour rather than working around it here.
   pragma Compile_Time_Error
     (Bank_Size * Shard_Count /= Max_Futures,
      "Shard_Count must divide Max_Futures exactly");

   subtype Bank_Index  is Active_Shard;
   subtype Local_Index is Natural range 0 .. Bank_Size - 1;

   type Local_Records is array (Local_Index) of Future_Record;
   type Local_Stack   is array (Local_Index) of Local_Index;

   --  Free slots are kept on a stack rather than found by scanning, so
   --  Acquire is constant time however full a bank is.  Every bank starts
   --  with the same contents, because the stack holds bank-local indices;
   --  the Ada 2022 iterated component association needs no elaboration code.
   Initial_Free : constant Local_Stack :=
     [for I in Local_Index => Bank_Size - 1 - I];

   --  Total over the whole handle space, given the exact division above:
   --  the largest handle is Shard_Count * Bank_Size - 1, so the quotient
   --  never leaves Bank_Index.  That totality is what lets every operation
   --  below take a bare Future_Id, with no precondition for callers to
   --  carry and no range check for SPARK to leave unproved.
   function Bank_Of (Handle : Future_Id) return Bank_Index is
     (Bank_Index (Natural (Handle) / Bank_Size));

   function Local_Of (Handle : Future_Id) return Local_Index is
     (Natural (Handle) mod Bank_Size);

   function Handle_Of (Bank : Bank_Index; Local : Local_Index) return Future_Id
   is (Future_Id (Natural (Bank) * Bank_Size + Local));

   ---------------------------------------------------------------------------
   --  One bank
   ---------------------------------------------------------------------------

   --  Every operation takes a bank-local index; composing and decomposing
   --  handles is the wrapper's job, which keeps the discriminant off the
   --  protected type and so lets the banks live in a plain array.
   protected type Bank
     with Priority => Runtime_Priority
   is

      procedure Acquire
        (Worker : Fiber_Ref;
         State  : Future_State;
         Local  : out Local_Index;
         Got    : out Boolean);
      procedure Release (Local : Local_Index);
      procedure Resolve
        (Local  : Local_Index;
         Result : Io_Result;
         Waiter : out Fiber_Ref;
         Home   : out Shard_Ref);
      procedure Subscribe
        (Local    : Local_Index;
         Waiter   : Fiber_Id;
         Home     : Shard_Id;
         Resolved : out Boolean;
         Result   : out Io_Result);
      procedure Take (Local : Local_Index; Result : out Io_Result);
      procedure Worker_Of (Local : Local_Index; Worker : out Fiber_Ref);
      procedure Adopt (Local : Local_Index; Worker : out Fiber_Ref);
      procedure Stats (Live : out Natural; High_Water : out Natural)
        with Post => Live <= Bank_Size and then High_Water <= Bank_Size;

   private
      Slots     : Local_Records := [others => (others => <>)];
      Available : Local_Stack   := Initial_Free;

      --  Available (0 .. Top - 1) holds the free slots.  Giving Top its own
      --  bounded subtype is what makes the index arithmetic below provable
      --  instead of merely correct.
      Top  : Natural range 0 .. Bank_Size := Bank_Size;
      Peak : Natural range 0 .. Bank_Size := 0;
   end Bank;

   Banks : array (Bank_Index) of Bank;

   ---------------------------------------------------------------------------

   protected body Bank is

      procedure Acquire
        (Worker : Fiber_Ref;
         State  : Future_State;
         Local  : out Local_Index;
         Got    : out Boolean)
      is
         Live : Natural;
      begin
         if Top = 0 then
            --  This bank is exhausted.  The caller tries its siblings before
            --  giving up, and surfaces the eventual failure as a rejected
            --  connection or a refused spawn; silently blocking here would
            --  deadlock the very shard that could free a slot.
            Local := 0;
            Got   := False;
            return;
         end if;

         Top := Top - 1;
         Local := Available (Top);
         Got   := True;

         Slots (Local) := (State  => State,
                           Result => 0,
                           Waiter => No_Fiber,
                           Home   => No_Shard,
                           Worker => Worker);

         Live := Bank_Size - Top;
         if Live > Peak then
            Peak := Live;
         end if;
      end Acquire;

      procedure Release (Local : Local_Index) is
      begin
         if Slots (Local).State = Free then
            return;  --  idempotent: error paths need not track ownership
         end if;
         Slots (Local) := (others => <>);
         if Top < Bank_Size then
            Available (Top) := Local;
            Top := Top + 1;
         end if;
      end Release;

      procedure Resolve
        (Local  : Local_Index;
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
         if Slots (Local).State not in Queued | Pending then
            return;
         end if;

         Slots (Local).Result := Result;
         Slots (Local).State  := Ready;

         --  Hand the waiter back exactly once; a second resolution of the
         --  same future must not wake anybody twice.
         Waiter := Slots (Local).Waiter;
         Home   := Slots (Local).Home;
         Slots (Local).Waiter := No_Fiber;
      end Resolve;

      procedure Subscribe
        (Local    : Local_Index;
         Waiter   : Fiber_Id;
         Home     : Shard_Id;
         Resolved : out Boolean;
         Result   : out Io_Result)
      is
      begin
         if Slots (Local).State = Ready then
            --  Resolved before the caller got here: no need to sleep.
            Resolved := True;
            Result := Slots (Local).Result;
            return;
         end if;

         Resolved := False;
         Result := 0;
         Slots (Local).Waiter := Waiter;
         Slots (Local).Home   := Home;
      end Subscribe;

      procedure Take (Local : Local_Index; Result : out Io_Result) is
      begin
         Result := Slots (Local).Result;
         Release (Local);
      end Take;

      procedure Worker_Of (Local : Local_Index; Worker : out Fiber_Ref) is
      begin
         Worker := Slots (Local).Worker;
      end Worker_Of;

      procedure Adopt (Local : Local_Index; Worker : out Fiber_Ref) is
      begin
         Worker := No_Fiber;
         if Slots (Local).State /= Queued then
            return;  --  another shard got there first
         end if;
         Slots (Local).State := Pending;
         Worker := Slots (Local).Worker;
      end Adopt;

      procedure Stats (Live : out Natural; High_Water : out Natural) is
      begin
         Live := Bank_Size - Top;
         High_Water := Peak;
      end Stats;

   end Bank;

   ---------------------------------------------------------------------------
   --  Thin forwarding layer
   ---------------------------------------------------------------------------

   procedure Acquire
     (Near   : Shard_Ref;
      Worker : Fiber_Ref;
      State  : Future_State;
      Handle : out Future_Ref)
   is
      --  A thread with no shard of its own -- the environment task during
      --  startup, say -- lands on bank zero and moves on from there.  It is
      --  not on the hot path by definition: it owns no ring.
      First : constant Natural :=
        (if Near in Active_Shard then Natural (Near) else 0);

      Bank_No : Bank_Index;
      Local   : Local_Index;
      Got     : Boolean;
   begin
      Handle := No_Future;

      --  Own bank first, which is the whole point.  Walking the rest keeps
      --  a workload that spawns everything from one core from failing while
      --  the other banks sit empty.
      for Step in 0 .. Shard_Count - 1 loop
         Bank_No := Bank_Index ((First + Step) mod Shard_Count);
         Banks (Bank_No).Acquire (Worker, State, Local, Got);
         if Got then
            Handle := Handle_Of (Bank_No, Local);
            return;
         end if;
      end loop;
   end Acquire;

   procedure Release (Handle : Future_Id) is
   begin
      Banks (Bank_Of (Handle)).Release (Local_Of (Handle));
   end Release;

   procedure Resolve
     (Handle : Future_Id;
      Result : Io_Result;
      Waiter : out Fiber_Ref;
      Home   : out Shard_Ref) is
   begin
      Banks (Bank_Of (Handle)).Resolve
        (Local_Of (Handle), Result, Waiter, Home);
   end Resolve;

   procedure Subscribe
     (Handle : Future_Id;
      Waiter : Fiber_Id;
      Home   : Shard_Id;
      Resolved : out Boolean;
      Result : out Io_Result) is
   begin
      Banks (Bank_Of (Handle)).Subscribe
        (Local_Of (Handle), Waiter, Home, Resolved, Result);
   end Subscribe;

   procedure Take (Handle : Future_Id; Result : out Io_Result) is
   begin
      Banks (Bank_Of (Handle)).Take (Local_Of (Handle), Result);
   end Take;

   procedure Worker_Of (Handle : Future_Id; Worker : out Fiber_Ref) is
   begin
      Banks (Bank_Of (Handle)).Worker_Of (Local_Of (Handle), Worker);
   end Worker_Of;

   procedure Adopt (Handle : Future_Id; Worker : out Fiber_Ref) is
   begin
      Banks (Bank_Of (Handle)).Adopt (Local_Of (Handle), Worker);
   end Adopt;

   procedure Stats (Live : out Natural; High_Water : out Natural) is
      Bank_Live : Natural;
      Bank_Peak : Natural;
   begin
      Live := 0;
      High_Water := 0;

      --  Read one bank at a time, so this never holds two locks and never
      --  stops the other cores.  The price is that the answer is a sum of
      --  readings taken at slightly different instants, which is the right
      --  trade for a counter nothing steers on.
      for B in Bank_Index loop
         pragma Loop_Invariant
           (Live <= Bank_Size * Natural (B)
            and then High_Water <= Bank_Size * Natural (B));

         Banks (B).Stats (Bank_Live, Bank_Peak);
         Live := Live + Bank_Live;
         High_Water := High_Water + Bank_Peak;
      end loop;
   end Stats;

end Iour.Futures;
