package body Iour.Run_Queue with
  SPARK_Mode    => On,
  Refined_State => (Queue => Shared)
is

   --  One more slot than the maximum number of fibers, so a full queue is
   --  distinguishable from an empty one without a separate count.
   Capacity : constant := Max_Fibers;

   type Slot_Index is mod Capacity;
   type Slot_Array is array (Slot_Index) of Future_Id;

   protected Shared
     with Priority => Runtime_Priority
   is
      procedure Push (Handle : Future_Id; Accepted : out Boolean);
      procedure Pop (Handle : out Future_Ref);
      procedure Depth (Count : out Natural);
      procedure Total_Pushed (Count : out Natural);
   private
      Items : Slot_Array := [others => 0];
      Head  : Slot_Index := 0;   --  next to pop
      Tail  : Slot_Index := 0;   --  next to fill

      --  Bounding Held in its own subtype is what lets the arithmetic below
      --  be proved rather than assumed.
      Held : Natural range 0 .. Capacity := 0;

      --  Saturating, so a long-running server cannot overflow a statistic.
      Lifetime : Natural := 0;
   end Shared;

   protected body Shared is

      procedure Push (Handle : Future_Id; Accepted : out Boolean) is
      begin
         if Held = Capacity then
            Accepted := False;
            return;
         end if;
         Items (Tail) := Handle;
         Tail := Tail + 1;          --  modular: wraps on its own
         Held := Held + 1;
         if Lifetime < Natural'Last then
            Lifetime := Lifetime + 1;
         end if;
         Accepted := True;
      end Push;

      procedure Pop (Handle : out Future_Ref) is
      begin
         if Held = 0 then
            Handle := No_Future;
            return;
         end if;
         Handle := Items (Head);
         Head := Head + 1;
         Held := Held - 1;
      end Pop;

      procedure Depth (Count : out Natural) is
      begin
         Count := Held;
      end Depth;

      procedure Total_Pushed (Count : out Natural) is
      begin
         Count := Lifetime;
      end Total_Pushed;

   end Shared;

   procedure Push (Handle : Future_Id; Accepted : out Boolean) is
   begin
      Shared.Push (Handle, Accepted);
   end Push;

   procedure Pop (Handle : out Future_Ref) is
   begin
      Shared.Pop (Handle);
   end Pop;

   procedure Depth (Count : out Natural) is
   begin
      Shared.Depth (Count);
   end Depth;

   procedure Total_Pushed (Count : out Natural) is
   begin
      Shared.Total_Pushed (Count);
   end Total_Pushed;

end Iour.Run_Queue;
