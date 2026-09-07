with Interfaces; use Interfaces;
with System;
with Iour.Ffi.Fiber;
with Iour.Ffi.Fiber.Machine;
with Iour.Ffi.Identity;
with Iour.Ffi.Sys;
with Iour.Futures;
with Iour.Per_Shard;
with Iour.Reactor;
with Iour.Run_Queue;
with Iour.Trace;

package body Iour.Fibers with
  SPARK_Mode    => On,
  Refined_State =>
    (Registry => (Banks, Shard_Cells,
                  Currents.Cells, Exits.Cells, Results.Cells,
                  Inbox_Flags.Cells))
is

   package Fib renames Iour.Ffi.Fiber;
   package Mach renames Iour.Ffi.Fiber.Machine;
   use type System.Address;
   use type Ffi.C_Int;
   use type Ffi.C_Long;

   ---------------------------------------------------------------------------
   --  Machine context slots
   ---------------------------------------------------------------------------

   --  Contexts live in Iour.Ffi.Fiber; this package only names them.  Slots
   --  0 .. Max_Fibers - 1 belong to fibers, the rest to the shard schedulers
   --  they switch back to.
   Total_Slots : constant := Max_Fibers + Max_Shards;

   --  Reserved once, during elaboration of this package body.
   --  Partition_Elaboration_Policy (Sequential) guarantees every library
   --  unit is elaborated before any task is activated, so the table exists
   --  before a shard could possibly want it.  Making it a constant is what
   --  keeps it out of the protected objects entirely: there is no lock to
   --  take, no allocation inside a protected action, and nothing for two
   --  shards to race over.
   Contexts_Ready : constant Boolean :=
     Fib.Reserve (Ffi.C_Long (Total_Slots)) = 0;

   ---------------------------------------------------------------------------
   --  Shard identity
   ---------------------------------------------------------------------------

   --  The system's own number for the core shard 0 sits on.  Ada counts
   --  CPUs from one and both Linux and Windows count them from zero, so
   --  the offset is the same on either.
   Cpu_Base : constant Integer := First_Shard_Cpu - 1;

   ---------------------------------------------------------------------------
   --  Fiber table
   ---------------------------------------------------------------------------

   type Fiber_Record is record
      In_Use : Boolean        := False;
      Home   : Shard_Ref      := No_Shard;
      Work   : Fiber_Body     := null;
      Arg    : Fiber_Argument := 0;
      Done   : Future_Ref     := No_Future;
      Stack  : System.Address := System.Null_Address;
   end record;

   ---------------------------------------------------------------------------
   --  The fiber table, banked per shard
   ---------------------------------------------------------------------------

   --  One bank per shard, each a contiguous stripe of the slot space, the
   --  same shape Iour.Futures uses.  A slot number names its own bank, so
   --  a fiber allocated on one core is still bound, recycled and asked
   --  about from any other -- what changes is that the common case does
   --  not have to.  Accepting a connection allocates a slot, binds it and
   --  recycles it on one core, and that used to be three trips through a
   --  lock every other core wanted.
   Fiber_Bank_Size : constant := Max_Fibers / Shard_Count;

   pragma Compile_Time_Error
     (Fiber_Bank_Size < 8,
      "Max_Fibers is too small to divide across Shard_Count banks");

   --  Exact division, so Bank_Of is total over the whole slot space and
   --  needs no clamp.  If you pick a Shard_Count that does not divide
   --  Max_Fibers, round Max_Fibers up in Iour rather than working around
   --  it here.
   pragma Compile_Time_Error
     (Fiber_Bank_Size * Shard_Count /= Max_Fibers,
      "Shard_Count must divide Max_Fibers exactly");

   subtype Bank_Index  is Active_Shard;
   subtype Fiber_Local is Natural range 0 .. Fiber_Bank_Size - 1;

   type Bank_Table is array (Fiber_Local) of Fiber_Record;
   type Free_Stack is array (Fiber_Local) of Fiber_Local;

   Initial_Free : constant Free_Stack :=
     [for I in Fiber_Local => Fiber_Bank_Size - 1 - I];

   function Bank_Of (Fiber : Fiber_Id) return Bank_Index is
     (Bank_Index (Natural (Fiber) / Fiber_Bank_Size));

   function Local_Of (Fiber : Fiber_Id) return Fiber_Local is
     (Natural (Fiber) mod Fiber_Bank_Size);

   function Fiber_Of (Bank : Bank_Index; Local : Fiber_Local) return Fiber_Id
   is (Fiber_Id (Natural (Bank) * Fiber_Bank_Size + Local));

   --  Every operation takes a bank-local index; composing and decomposing
   --  slot numbers is the wrapper's job, which keeps the discriminant off
   --  the protected type and so lets the banks live in a plain array.
   protected type Fiber_Bank
     with Priority => Runtime_Priority
   is
      procedure Allocate
        (Work  : Fiber_Body;
         Arg   : Fiber_Argument;
         Local : out Fiber_Local;
         Got   : out Boolean);
      procedure Bind (Local : Fiber_Local; Shard : Shard_Id; Done : Future_Ref);
      procedure Launch_Info
        (Local : Fiber_Local;
         Shard : out Shard_Ref;
         Work  : out Fiber_Body;
         Arg   : out Fiber_Argument;
         Done  : out Future_Ref);
      procedure Home_Of (Local : Fiber_Local; Shard : out Shard_Ref);
      procedure Stack_Of (Local : Fiber_Local; Base : out System.Address);
      procedure Set_Stack (Local : Fiber_Local; Base : System.Address);
      procedure Recycle (Local : Fiber_Local);
      procedure Stats (Live : out Natural; High_Water : out Natural)
        with Post => Live <= Fiber_Bank_Size
                     and then High_Water <= Fiber_Bank_Size;
      procedure Next_Stack (From : in out Natural; Base : out System.Address)
        with Pre  => From <= Fiber_Bank_Size,
             Post => From <= Fiber_Bank_Size;
   private
      Slots     : Bank_Table := [others => (others => <>)];
      Available : Free_Stack := Initial_Free;

      --  Available (0 .. Top - 1) holds the free slots; the bounded
      --  subtypes make the arithmetic provable rather than just correct.
      Top  : Natural range 0 .. Fiber_Bank_Size := Fiber_Bank_Size;
      Peak : Natural range 0 .. Fiber_Bank_Size := 0;
   end Fiber_Bank;

   Banks : array (Bank_Index) of Fiber_Bank;

   ---------------------------------------------------------------------------
   --  Per-shard scheduling state
   ---------------------------------------------------------------------------

   --  Two layers.  Below, one protected object per shard holds what a
   --  sibling may reach into: the ready queue a wakeup lands on, the inbox,
   --  the idle flag.  Here, three atomic cells per shard hold what nobody
   --  but the shard's own thread ever touches, and which therefore need no
   --  lock: it is the same thread that writes and reads them, and an atomic
   --  store is how SPARK lets that be said without one.

   --  Which fiber is on the core.  No_Fiber while the scheduler itself is.
   package Currents is new Iour.Per_Shard (Fiber_Ref, No_Fiber);

   --  Why the fiber that last held the core gave it back.  The fiber writes
   --  it just before switching out; After_Resume reads it just after.
   type Exit_Reason is
     (Suspended,   --  waiting on a future; whoever resolves it will Wake
      Yielded,     --  voluntarily; goes to the back of the ready queue
      Completed);  --  body returned; the slot is recycled

   package Exits is new Iour.Per_Shard (Exit_Reason, Suspended);

   --  What the resumption in progress carries.  Resume writes it from the
   --  ready-queue entry just before switching in; a fiber asleep in
   --  Await_Direct reads it just after the switch returns.  Same thread
   --  both sides, which is why a cell is enough.
   package Results is new Iour.Per_Shard (Io_Result, No_Result);

   --  Whether Post_Wake has left anything in the inbox since the shard last
   --  looked.  Set by the poster after its protected push; cleared by the
   --  shard before it drains.
   package Inbox_Flags is new Iour.Per_Shard (Boolean, False);

   type Ready_Index is mod Max_Fibers;
   type Ready_Array is array (Ready_Index) of Wake_Entry;
   type Inbox_Array is array (Ready_Index) of Fiber_Id;

   protected type Shard_Cell
     with Priority => Runtime_Priority
   is
      procedure Push (Fiber : Fiber_Id; Accepted : out Boolean);
      --  Push for the paths where a full queue is impossible: the queue
      --  holds Max_Fibers entries, a fiber sits in at most one queue at a
      --  time, and there are never more than Max_Fibers fibers.  The guard
      --  stays because SPARK proves the arithmetic from it; the branch it
      --  guards is unreachable.
      procedure Enqueue (Fiber : Fiber_Id);
      procedure Enqueue_Many (Batch : Wake_Batch; Count : Wake_Count);
      procedure Pop_Many (Batch : out Wake_Batch; Count : out Wake_Count);
      procedure Depth (Count : out Natural);
      procedure Put_Idle (Idle : Boolean);
      procedure Take_Idle (Idle : out Boolean);
      --  The inbox: wakeups posted from threads that own no ring.
      procedure Post (Fiber : Fiber_Id);
      procedure Take_Post (Fiber : out Fiber_Ref);
   private
      Items   : Ready_Array := [others => (others => <>)];
      Head    : Ready_Index := 0;
      Tail    : Ready_Index := 0;
      Held    : Natural range 0 .. Max_Fibers := 0;
      Asleep  : Boolean := False;

      Inbox   : Inbox_Array := [others => 0];
      In_Head : Ready_Index := 0;
      In_Tail : Ready_Index := 0;
      In_Held : Natural range 0 .. Max_Fibers := 0;
   end Shard_Cell;

   Shard_Cells : array (Shard_Id) of Shard_Cell;

   ---------------------------------------------------------------------------
   --  Pool body
   ---------------------------------------------------------------------------

   protected body Fiber_Bank is

      procedure Allocate
        (Work  : Fiber_Body;
         Arg   : Fiber_Argument;
         Local : out Fiber_Local;
         Got   : out Boolean)
      is
         Live : Natural;
      begin
         if Top = 0 then
            --  This bank is exhausted.  The caller tries its siblings
            --  before giving up.
            Local := 0;
            Got   := False;
            return;
         end if;
         Top := Top - 1;
         Local := Available (Top);
         Got   := True;

         --  Deliberately preserve Stack: a recycled slot keeps the mapping
         --  it already owns, so only the first use of a slot costs an mmap.
         Slots (Local).In_Use := True;
         Slots (Local).Home   := No_Shard;
         Slots (Local).Work   := Work;
         Slots (Local).Arg    := Arg;
         Slots (Local).Done   := No_Future;

         Live := Fiber_Bank_Size - Top;
         if Live > Peak then
            Peak := Live;
         end if;
      end Allocate;

      procedure Bind
        (Local : Fiber_Local; Shard : Shard_Id; Done : Future_Ref) is
      begin
         Slots (Local).Home := Shard;
         Slots (Local).Done := Done;
      end Bind;

      procedure Launch_Info
        (Local : Fiber_Local;
         Shard : out Shard_Ref;
         Work  : out Fiber_Body;
         Arg   : out Fiber_Argument;
         Done  : out Future_Ref) is
      begin
         Shard := Slots (Local).Home;
         Work  := Slots (Local).Work;
         Arg   := Slots (Local).Arg;
         Done  := Slots (Local).Done;
      end Launch_Info;

      procedure Home_Of (Local : Fiber_Local; Shard : out Shard_Ref) is
      begin
         Shard := Slots (Local).Home;
      end Home_Of;

      procedure Stack_Of (Local : Fiber_Local; Base : out System.Address) is
      begin
         Base := Slots (Local).Stack;
      end Stack_Of;

      procedure Set_Stack (Local : Fiber_Local; Base : System.Address) is
      begin
         Slots (Local).Stack := Base;
      end Set_Stack;

      procedure Recycle (Local : Fiber_Local) is
      begin
         if not Slots (Local).In_Use then
            return;
         end if;
         Slots (Local).In_Use := False;
         Slots (Local).Home   := No_Shard;
         Slots (Local).Work   := null;
         Slots (Local).Arg    := 0;
         Slots (Local).Done   := No_Future;
         if Top < Fiber_Bank_Size then
            Available (Top) := Local;
            Top := Top + 1;
         end if;
      end Recycle;

      procedure Stats (Live : out Natural; High_Water : out Natural) is
      begin
         Live := Fiber_Bank_Size - Top;
         High_Water := Peak;
      end Stats;

      procedure Next_Stack (From : in out Natural; Base : out System.Address)
      is
      begin
         Base := System.Null_Address;
         while From < Fiber_Bank_Size loop
            if Slots (From).Stack /= System.Null_Address then
               Base := Slots (From).Stack;
               Slots (From).Stack := System.Null_Address;
               From := From + 1;
               return;
            end if;
            From := From + 1;
         end loop;
      end Next_Stack;

   end Fiber_Bank;

   ---------------------------------------------------------------------------
   --  Slot operations -- take the bank apart, then go straight to it
   ---------------------------------------------------------------------------

   --  Allocate prefers Near's bank and falls through to the others, so a
   --  workload that accepts everything on one core still gets the whole
   --  table rather than its share of it.  A slot's bank has nothing to do
   --  with the shard that ends up running the fiber: that is Home, set by
   --  Bind.
   procedure Slot_Allocate
     (Near  : Shard_Ref;
      Work  : Fiber_Body;
      Arg   : Fiber_Argument;
      Fiber : out Fiber_Ref)
   is
      First : constant Natural :=
        (if Near in Active_Shard then Natural (Near) else 0);
      Bank_No : Bank_Index;
      Local   : Fiber_Local;
      Got     : Boolean;
   begin
      Fiber := No_Fiber;
      for Step in 0 .. Shard_Count - 1 loop
         Bank_No := Bank_Index ((First + Step) mod Shard_Count);
         Banks (Bank_No).Allocate (Work, Arg, Local, Got);
         if Got then
            Fiber := Fiber_Of (Bank_No, Local);
            return;
         end if;
      end loop;
   end Slot_Allocate;

   procedure Slot_Bind
     (Fiber : Fiber_Id; Shard : Shard_Id; Done : Future_Ref) is
   begin
      Banks (Bank_Of (Fiber)).Bind (Local_Of (Fiber), Shard, Done);
   end Slot_Bind;

   procedure Slot_Launch_Info
     (Fiber : Fiber_Id;
      Shard : out Shard_Ref;
      Work  : out Fiber_Body;
      Arg   : out Fiber_Argument;
      Done  : out Future_Ref) is
   begin
      Banks (Bank_Of (Fiber)).Launch_Info
        (Local_Of (Fiber), Shard, Work, Arg, Done);
   end Slot_Launch_Info;

   procedure Slot_Home_Of (Fiber : Fiber_Id; Shard : out Shard_Ref) is
   begin
      Banks (Bank_Of (Fiber)).Home_Of (Local_Of (Fiber), Shard);
   end Slot_Home_Of;

   procedure Slot_Stack_Of (Fiber : Fiber_Id; Base : out System.Address) is
   begin
      Banks (Bank_Of (Fiber)).Stack_Of (Local_Of (Fiber), Base);
   end Slot_Stack_Of;

   procedure Slot_Set_Stack (Fiber : Fiber_Id; Base : System.Address) is
   begin
      Banks (Bank_Of (Fiber)).Set_Stack (Local_Of (Fiber), Base);
   end Slot_Set_Stack;

   procedure Slot_Recycle (Fiber : Fiber_Id) is
   begin
      Banks (Bank_Of (Fiber)).Recycle (Local_Of (Fiber));
   end Slot_Recycle;

   --  Summed across the banks, one at a time, so this never holds two
   --  locks.  Live is exact; High_Water is the sum of the banks' own
   --  marks, so it bounds the number ever live at one instant rather than
   --  reading it.
   procedure Slot_Stats (Live : out Natural; High_Water : out Natural) is
      Bank_Live : Natural;
      Bank_Peak : Natural;
   begin
      Live := 0;
      High_Water := 0;
      for B in Bank_Index loop
         pragma Loop_Invariant
           (Live <= Fiber_Bank_Size * Natural (B)
            and then High_Water <= Fiber_Bank_Size * Natural (B));

         Banks (B).Stats (Bank_Live, Bank_Peak);
         Live := Live + Bank_Live;
         High_Water := High_Water + Bank_Peak;
      end loop;
   end Slot_Stats;


   ---------------------------------------------------------------------------
   --  Shard_Cell body
   ---------------------------------------------------------------------------

   protected body Shard_Cell is

      procedure Push (Fiber : Fiber_Id; Accepted : out Boolean) is
      begin
         if Held = Max_Fibers then
            Accepted := False;
            return;
         end if;
         Items (Tail) := (Fiber => Fiber, Result => No_Result);
         Tail := Tail + 1;
         Held := Held + 1;
         Accepted := True;
      end Push;

      procedure Enqueue (Fiber : Fiber_Id) is
      begin
         if Held = Max_Fibers then
            return;
         end if;
         Items (Tail) := (Fiber => Fiber, Result => No_Result);
         Tail := Tail + 1;
         Held := Held + 1;
      end Enqueue;

      procedure Enqueue_Many (Batch : Wake_Batch; Count : Wake_Count) is
      begin
         for I in 0 .. Count - 1 loop
            pragma Loop_Invariant (Held <= Max_Fibers);
            exit when Held = Max_Fibers;   --  unreachable, see Enqueue
            Items (Tail) := Batch (I);
            Tail := Tail + 1;
            Held := Held + 1;
         end loop;
      end Enqueue_Many;

      procedure Pop_Many (Batch : out Wake_Batch; Count : out Wake_Count) is
      begin
         Batch := [others => (others => <>)];
         Count := 0;
         while Count < Wake_Batch_Size and then Held > 0 loop
            --  Restating the loop test, for the prover rather than the
            --  compiler: it is what carries the bound on Count into the
            --  indexing below.
            pragma Warnings (Off, "condition is always True");
            pragma Loop_Invariant (Count < Wake_Batch_Size);
            pragma Warnings (On, "condition is always True");
            Batch (Count) := Items (Head);
            Head := Head + 1;
            Held := Held - 1;
            Count := Count + 1;
         end loop;
      end Pop_Many;

      procedure Depth (Count : out Natural) is
      begin
         Count := Held;
      end Depth;

      procedure Put_Idle (Idle : Boolean) is
      begin
         Asleep := Idle;
      end Put_Idle;

      procedure Take_Idle (Idle : out Boolean) is
      begin
         Idle := Asleep;
      end Take_Idle;

      procedure Post (Fiber : Fiber_Id) is
      begin
         if In_Held = Max_Fibers then
            return;  --  unreachable: a fiber is posted at most once
         end if;
         Inbox (In_Tail) := Fiber;
         In_Tail := In_Tail + 1;
         In_Held := In_Held + 1;
      end Post;

      procedure Take_Post (Fiber : out Fiber_Ref) is
      begin
         if In_Held = 0 then
            Fiber := No_Fiber;
            return;
         end if;
         Fiber := Inbox (In_Head);
         In_Head := In_Head + 1;
         In_Held := In_Held - 1;
      end Take_Post;

   end Shard_Cell;

   ---------------------------------------------------------------------------
   --  Context slots and shard identity
   ---------------------------------------------------------------------------

   function Fiber_Slot (Fiber : Fiber_Id) return Ffi.C_Long is
     (Ffi.C_Long (Fiber));

   function Shard_Slot (Shard : Shard_Id) return Ffi.C_Long is
     (Ffi.C_Long (Max_Fibers) + Ffi.C_Long (Shard));

   procedure Context_Slots (Count : out Natural) is
      Slots : constant Ffi.C_Long := Fib.Slot_Count;
   begin
      --  C's long is sixty-four bits on Linux and thirty-two on Windows,
      --  so the upper guard is real on one and provably dead on the other.
      --  It stays either way: the point is that this cannot overflow
      --  wherever it is compiled.
      pragma Warnings (Off, "condition is always False");
      pragma Warnings (Off, "condition can only be True if invalid values*");
      Count := (if Slots <= 0 then 0
                elsif Slots > Ffi.C_Long (Natural'Last) then Natural'Last
                else Natural (Slots));
      pragma Warnings (On, "condition can only be True if invalid values*");
      pragma Warnings (On, "condition is always False");
   end Context_Slots;

   function Self return Shard_Ref is (Ffi.Identity.Current);

   procedure Claim_Core (Shard : Active_Shard; Pinned : out Boolean) is
   begin
      --  Identity first: from here on this thread is this shard, whatever
      --  the scheduler underneath decides to do with it.
      Ffi.Identity.Claim (Shard);

      --  Then the core.  Side_Effects functions may only be called as the
      --  right-hand side of an assignment.
      Pinned := Ffi.Sys.Bind_To_Cpu (Natural (Cpu_Base + Integer (Shard)));
   end Claim_Core;

   ---------------------------------------------------------------------------
   --  Thin forwarding layer
   ---------------------------------------------------------------------------

   procedure Reserve_Contexts (Ok : out Boolean) is
   begin
      --  Two questions, and a shard needs both answered yes.  The table is
      --  the easy one.  The other is whether the assembly this binary was
      --  built with is the assembly the context switch was proved about:
      --  Iour.Ffi.Fiber.Machine renders its proved instruction sequence and
      --  compares it, character for character, with the template GCC
      --  actually assembled.
      --
      --  It has to be asked here rather than proved once and forgotten
      --  because GNAT requires an Asm template to be a static string, so
      --  the emitted text cannot itself be the rendered one.  Asking costs
      --  a few hundred character comparisons per shard, once, and buys the
      --  guarantee that a binary whose assembly and whose proof had drifted
      --  apart refuses to start rather than switching contexts wrongly.
      Ok := Contexts_Ready and then Mach.Emitted_Matches_Model;
   end Reserve_Contexts;

   procedure Running_Fiber (Shard : Shard_Id; Fiber : out Fiber_Ref) is
   begin
      Currents.Get (Shard, Fiber);
   end Running_Fiber;

   procedure Set_Idle (Shard : Shard_Id; Idle : Boolean) is
   begin
      Shard_Cells (Shard).Put_Idle (Idle);
   end Set_Idle;

   procedure Post_Wake (Fiber : Fiber_Id; Home : Shard_Id) is
   begin
      --  Flag after the push, never before: the protected action orders
      --  the push ahead of the store, so a shard that sees the flag will
      --  find the fiber.
      Shard_Cells (Home).Post (Fiber);
      Inbox_Flags.Set (Home, True);
   end Post_Wake;

   procedure Inbox_Pending (Shard : Shard_Id; Pending : out Boolean) is
   begin
      Inbox_Flags.Get (Shard, Pending);
      if Pending then
         Inbox_Flags.Set (Shard, False);
      end if;
   end Inbox_Pending;

   procedure Take_Posted (Shard : Shard_Id; Fiber : out Fiber_Ref) is
   begin
      Shard_Cells (Shard).Take_Post (Fiber);
   end Take_Posted;

   procedure Push_Ready
     (Shard : Shard_Id; Fiber : Fiber_Id; Accepted : out Boolean) is
   begin
      Shard_Cells (Shard).Push (Fiber, Accepted);
   end Push_Ready;

   procedure Enqueue_Batch
     (Shard : Shard_Id; Batch : Wake_Batch; Count : Wake_Count) is
   begin
      if Count > 0 then
         Shard_Cells (Shard).Enqueue_Many (Batch, Count);
      end if;
   end Enqueue_Batch;

   procedure Pop_Batch
     (Shard : Shard_Id; Batch : out Wake_Batch; Count : out Wake_Count) is
   begin
      Shard_Cells (Shard).Pop_Many (Batch, Count);
   end Pop_Batch;

   procedure Ready_Depth (Shard : Shard_Id; Count : out Natural) is
   begin
      Shard_Cells (Shard).Depth (Count);
   end Ready_Depth;

   procedure Home_Of (Fiber : Fiber_Id; Shard : out Shard_Ref) is
   begin
      Slot_Home_Of (Fiber, Shard);
   end Home_Of;

   procedure Live_Fibers (Count : out Natural; High_Water : out Natural) is
   begin
      Slot_Stats (Count, High_Water);
   end Live_Fibers;

   ---------------------------------------------------------------------------
   --  Wakeups
   ---------------------------------------------------------------------------

   --  Put a wakeup into another shard's completion stream.  The submission
   --  queue can be momentarily full; a message dropped for that reason
   --  would be a lost wakeup, so flush and retry rather than give up.  The
   --  retry is bounded because an engine that fails to flush is not coming
   --  back, and the idle timer will surface the work eventually in any
   --  case.
   procedure Send_Message (From : Shard_Id; Message : Reactor.Op_Spec) is
      Accepted : Boolean;
      Status   : Io_Result;
   begin
      for Attempt in 1 .. 4 loop
         Reactor.Push (From, Message, Accepted);
         exit when Accepted;
         Reactor.Flush (From, 0, Status);
         exit when Failed (Status);
      end loop;
   end Send_Message;

   procedure Wake (From : Shard_Id; Fiber : Fiber_Id; Home : Shard_Id) is
   begin
      if Home = From then
         Shard_Cells (From).Enqueue (Fiber);
         return;
      end if;

      --  Another core owns this fiber.  Rather than reach into its queue,
      --  put a completion into its stream: it arrives as an ordinary one,
      --  so a sibling asleep in the kernel wakes with no shared lock and
      --  nothing to poll.  IORING_OP_MSG_RING on Linux and a posted
      --  completion-port entry on Windows, and neither is named here.
      if Home in Active_Shard and then From in Active_Shard then
         Send_Message
           (From,
            Reactor.Op_Wake
              (Target       => Home,
               Target_Token =>
                 Reactor.Encode (Reactor.Tag_Wake, Unsigned_32 (Fiber) + 1),
               Token => Reactor.Encode (Reactor.Tag_Msg_Send, 0)));
      end if;
   end Wake;

   --  Nudge one sleeping shard so it notices new work on the global queue.
   procedure Nudge_Idle (From : Shard_Ref) is
      Sleeping : Boolean;
   begin
      --  Only a shard can send: the message has to come from a ring, and
      --  the environment task owns none.  Work published from there is
      --  picked up by the idle timer instead.
      if From not in Active_Shard then
         return;
      end if;

      for Target in Active_Shard loop
         if Target /= From then
            Shard_Cells (Target).Take_Idle (Sleeping);
            if Sleeping then
               Send_Message
                 (From,
                  Reactor.Op_Wake
                    (Target => Target,
                     --  Payload zero: "look around", no particular fiber.
                     Target_Token => Reactor.Encode (Reactor.Tag_Wake, 0),
                     Token => Reactor.Encode (Reactor.Tag_Msg_Send, 0)));
               exit;  --  one woken core is enough to drain the queue
            end if;
         end if;
      end loop;
   end Nudge_Idle;

   ---------------------------------------------------------------------------
   --  Spawn
   ---------------------------------------------------------------------------

   procedure Spawn
     (Work   : Fiber_Body;
      Arg    : Fiber_Argument;
      Handle : out Future_Ref)
   is
      --  Read once: Self is a sched_getcpu, and both the bank choice below
      --  and the wakeup at the end want the same answer anyway.
      Me       : constant Shard_Ref := Self;
      Fiber    : Fiber_Ref;
      Accepted : Boolean;
   begin
      Handle := No_Future;

      Slot_Allocate (Me, Work, Arg, Fiber);
      if Fiber = No_Fiber then
         return;  --  fiber table full
      end if;

      --  Banked on the spawning core.  Which core ends up *running* the
      --  fiber is still decided by the run queue; this only says where the
      --  handle lives, and the spawner is the one that resolves it if the
      --  push below fails.
      Futures.Acquire (Near   => Me,
                       Worker => Fiber,
                       State  => Futures.Queued,
                       Waiter => No_Fiber,
                       Home   => No_Shard,
                       Handle => Handle);
      if Handle = No_Future then
         Slot_Recycle (Fiber);
         return;
      end if;

      --  Publish on the one queue every shard pops from.  This is the
      --  whole of the load-balancing policy.
      Run_Queue.Push (Handle, Accepted);
      if not Accepted then
         Futures.Release (Handle);
         Slot_Recycle (Fiber);
         Handle := No_Future;
         return;
      end if;

      Nudge_Idle (Me);
   end Spawn;

   ---------------------------------------------------------------------------
   --  Adopt
   ---------------------------------------------------------------------------

   --  Everything a fiber needs between having a slot and being runnable:
   --  bind it to the core that will run it, give it a stack, and point its
   --  context at a fresh call of Fiber_Main.  The same whether the work
   --  came off the global queue or was spawned straight onto a core.
   --
   --  Ok is False only when the stack could not be mapped.  Giving the
   --  slot back is the caller's job, because only the caller knows whether
   --  there is also a future to fail.
   procedure Prepare
     (Shard  : Shard_Id;
      Fiber  : Fiber_Id;
      Handle : Future_Ref;
      Ok     : out Boolean)
   is
      Base : System.Address;
   begin
      Ok := False;
      Slot_Bind (Fiber, Shard, Handle);

      --  Give the fiber a stack, reusing the slot's previous one when it
      --  has been round before.
      Slot_Stack_Of (Fiber, Base);
      if Base = System.Null_Address then
         Base := Fib.Stack_Alloc (Ffi.C_Size (Fiber_Stack_Bytes));
         if Base = System.Null_Address then
            return;  --  out of address space
         end if;
         Slot_Set_Stack (Fiber, Base);
      end if;

      Fib.Prime (Slot => Fiber_Slot (Fiber),
                 Base => Base,
                 Size => Ffi.C_Size (Fiber_Stack_Bytes),
                 Arg  => Ffi.C_Long (Fiber));
      Ok := True;
   end Prepare;

   procedure Adopt
     (Shard   : Shard_Id;
      Handle  : Future_Id;
      Started : out Boolean)
   is
      Fiber  : Fiber_Ref;
      Waiter : Fiber_Ref;
      Home   : Shard_Ref;
      Ok     : Boolean;
   begin
      Started := False;

      Futures.Adopt (Handle, Fiber);
      if Fiber = No_Fiber then
         return;  --  another shard claimed it first
      end if;

      Prepare (Shard, Fiber, Handle, Ok);
      if not Ok then
         --  Fail the future rather than drop the work silently, so
         --  whoever awaits it learns why.
         Futures.Resolve (Handle, -E_Again, Waiter, Home);
         if Waiter /= No_Fiber and then Home in Active_Shard then
            Wake (Shard, Waiter, Home);
         end if;
         Slot_Recycle (Fiber);
         return;
      end if;

      Push_Ready (Shard, Fiber, Started);
      Trace.Event (Shard, "adopted fiber", Integer (Fiber));
   end Adopt;

   ---------------------------------------------------------------------------
   --  Spawning onto a particular core
   ---------------------------------------------------------------------------

   --  Both of these are detached: no future, so nothing to await and
   --  nothing to release.  That is what work like a connection handler
   --  actually wants, and it takes a whole future -- acquire, resolve,
   --  release -- off the path.

   procedure Spawn_Here
     (Work    : Fiber_Body;
      Arg     : Fiber_Argument;
      Started : out Boolean)
   is
      Me    : constant Shard_Ref := Self;
      Fiber : Fiber_Ref;
      Ok    : Boolean;
   begin
      Started := False;
      if Me not in Active_Shard then
         return;  --  not on a shard: there is no "here"
      end if;

      Slot_Allocate (Me, Work, Arg, Fiber);
      if Fiber = No_Fiber then
         return;  --  fiber table full
      end if;

      Prepare (Me, Fiber, No_Future, Ok);
      if not Ok then
         Slot_Recycle (Fiber);
         return;
      end if;

      Push_Ready (Me, Fiber, Started);
      if not Started then
         Slot_Recycle (Fiber);
      end if;
   end Spawn_Here;

   procedure Spawn_On
     (Shard   : Active_Shard;
      Work    : Fiber_Body;
      Arg     : Fiber_Argument;
      Started : out Boolean)
   is
      Me    : constant Shard_Ref := Self;
      Fiber : Fiber_Ref;
      Ok    : Boolean;
   begin
      Started := False;

      --  Allocate out of the target's bank, since that is the core that
      --  will bind, run and recycle the slot.
      Slot_Allocate (Shard, Work, Arg, Fiber);
      if Fiber = No_Fiber then
         return;
      end if;

      Prepare (Shard, Fiber, No_Future, Ok);
      if not Ok then
         Slot_Recycle (Fiber);
         return;
      end if;

      if Me = Shard then
         Push_Ready (Shard, Fiber, Started);
         if not Started then
            Slot_Recycle (Fiber);
         end if;
      else
         --  Only a shard may enqueue onto its own ready queue, so hand the
         --  fiber over through the inbox and let it do the enqueue on its
         --  next pass.  This is the path the environment task takes, which
         --  is where the acceptors come from.
         Post_Wake (Fiber, Shard);
         Started := True;
      end if;
   end Spawn_On;

   ---------------------------------------------------------------------------
   --  Resume / After_Resume
   ---------------------------------------------------------------------------

   procedure Resume (Shard : Shard_Id; Fiber : Fiber_Id; Result : Io_Result)
   is
   begin
      Currents.Set (Shard, Fiber);
      Results.Set (Shard, Result);

      --  The conservative default, in case a path out of the fiber ever
      --  fails to say why it left: a fiber nobody wakes is a leak, and a
      --  fiber resumed twice is a corruption.
      Exits.Set (Shard, Suspended);

      --  Hand the core to the fiber.  This returns once the fiber suspends,
      --  yields or finishes -- on this same stack, with the scheduler's
      --  registers restored exactly as they were.
      Fib.Switch (From => Shard_Slot (Shard), To => Fiber_Slot (Fiber));

      Currents.Set (Shard, No_Fiber);
   end Resume;

   procedure After_Resume (Shard : Shard_Id; Fiber : Fiber_Id) is
      Why : Exit_Reason;
   begin
      Exits.Get (Shard, Why);
      case Why is
         when Completed =>
            --  The slot goes back to the pool but keeps its stack.
            Slot_Recycle (Fiber);
         when Yielded =>
            --  Back of the queue.
            Shard_Cells (Shard).Enqueue (Fiber);
         when Suspended =>
            --  Whoever resolves the future will call Wake.
            null;
      end case;
   end After_Resume;

   ---------------------------------------------------------------------------
   --  Suspension
   ---------------------------------------------------------------------------

   procedure Switch_To_Scheduler (Fiber : Fiber_Id; Shard : Shard_Id) is
   begin
      Fib.Switch (From => Fiber_Slot (Fiber), To => Shard_Slot (Shard));
   end Switch_To_Scheduler;

   procedure Await (Handle : Future_Id; Result : out Io_Result) is
      Shard    : constant Shard_Ref := Self;
      Me       : Fiber_Ref;
      Resolved : Boolean;
   begin
      Result := -E_Again;

      if Shard not in Active_Shard then
         return;  --  not on a shard: nothing to suspend
      end if;

      Running_Fiber (Shard, Me);
      if Me = No_Fiber then
         return;  --  not in a fiber: nothing to suspend
      end if;

      loop
         --  Registering as the waiter, testing for a result and, if there
         --  is one, freeing the slot all happen in one protected action, so
         --  a resolution racing in from another core cannot slip between
         --  the test and the sleep.  When it returns Resolved the handle
         --  is already dead.
         Futures.Claim (Handle, Me, Shard, Resolved, Result);
         exit when Resolved;

         Exits.Set (Shard, Suspended);

         --  Give the core back.  Other fibers run, completions are reaped,
         --  and control returns here once this future has been resolved.
         Switch_To_Scheduler (Me, Shard);
      end loop;
   end Await;

   procedure Await_Direct
     (Shard  : Active_Shard;
      Me     : Fiber_Id;
      Result : out Io_Result)
   is
   begin
      loop
         --  Sleep first, ask afterwards.  The operation sits in this
         --  shard's ring, whose completions only this shard's loop reaps
         --  -- so it cannot complete before the switch below gives that
         --  loop the core, and when the loop resumes this fiber it has
         --  already put the result in the cell.  The loop is defence: a
         --  resumption that carries no result was not the completion.
         Exits.Set (Shard, Suspended);
         Switch_To_Scheduler (Me, Shard);

         Results.Get (Shard, Result);
         exit when Result /= No_Result;
      end loop;
   end Await_Direct;

   procedure Yield is
      Shard : constant Shard_Ref := Self;
      Me    : Fiber_Ref;
   begin
      if Shard not in Active_Shard then
         return;
      end if;
      Running_Fiber (Shard, Me);
      if Me = No_Fiber then
         return;
      end if;

      --  Yielded, not Suspended: After_Resume puts it straight back on the
      --  ready queue.
      Exits.Set (Shard, Yielded);
      Switch_To_Scheduler (Me, Shard);
   end Yield;

   ---------------------------------------------------------------------------
   --  Fiber entry point
   ---------------------------------------------------------------------------

   --  The precondition is a contract with the C trampoline, not a check on
   --  an Ada caller: Adopt primes every slot with a valid Fiber_Id, and the
   --  trampoline passes that value back unchanged.  Stating it lets SPARK
   --  prove the conversion below instead of assuming it.
   procedure Fiber_Main (Arg : Ffi.C_Long)
     with Export, Convention => C, External_Name => "iour_fiber_main",
          Pre => Arg >= 0 and then Arg <= Ffi.C_Long (Fiber_Id'Last);

   procedure Fiber_Main (Arg : Ffi.C_Long) is
      Me     : constant Fiber_Id := Fiber_Id (Arg);
      Shard  : Shard_Ref;
      Work   : Fiber_Body;
      Param  : Fiber_Argument;
      Done   : Future_Ref;
      Waiter : Fiber_Ref;
      Home   : Shard_Ref;
      Status : Io_Result;
   begin
      loop
         Slot_Launch_Info (Me, Shard, Work, Param, Done);
         Status := 0;
         Trace.Event (Shard, "fiber starts", Integer (Me));

         if Work /= null then
            pragma Warnings
              (GNATprove, Off, "this statement is never reached",
               Reason => "Defence in depth: SPARK proves fiber bodies raise"
                         & " nothing, and the handler exists for the case"
                         & " where that proof no longer holds.");
            begin
               Work.all (Param);
            exception
               --  SPARK proves fiber bodies raise nothing, so this is
               --  unreachable by construction.  It is here because the
               --  alternative, if that ever stopped holding, is an
               --  exception unwinding off a fiber stack into the trampoline
               --  and its dummy return address, which would take the process
               --  down with no diagnosis at all.
               when others =>
                  Status := -E_Canceled;
            end;
            pragma Warnings
              (GNATprove, On, "this statement is never reached");
         end if;

         --  Publish the result and hand the awaiting fiber, if any, back to
         --  whichever core owns it.
         if Done /= No_Future then
            Futures.Resolve (Done, Status, Waiter, Home);
            if Waiter /= No_Fiber
              and then Home in Active_Shard
              and then Shard in Active_Shard
            then
               Wake (Shard, Waiter, Home);
            end if;
         end if;

         Trace.Event (Shard, "fiber finished", Integer (Me));

         if Shard in Active_Shard then
            Exits.Set (Shard, Completed);
            Switch_To_Scheduler (Me, Shard);
         end if;

         --  Unreachable: the scheduler recycles this slot and re-primes the
         --  stack before anything runs on it again, so control restarts at
         --  the trampoline rather than returning here.  The loop is what
         --  guarantees the procedure cannot fall through into the dummy
         --  return address Prime planted above it.
      end loop;
   end Fiber_Main;

   ---------------------------------------------------------------------------
   --  Teardown
   ---------------------------------------------------------------------------

   procedure Release_All_Stacks is
      --  Bounded rather than plain Natural, so Next_Stack's precondition
      --  is discharged by the subtype instead of by a proof about the
      --  loop.
      Cursor : Natural range 0 .. Fiber_Bank_Size;
      Base   : System.Address;
   begin
      for B in Bank_Index loop
         Cursor := 0;
         loop
            Banks (B).Next_Stack (Cursor, Base);
            exit when Base = System.Null_Address;
            Fib.Stack_Free (Base, Ffi.C_Size (Fiber_Stack_Bytes));
         end loop;
      end loop;
   end Release_All_Stacks;

end Iour.Fibers;
