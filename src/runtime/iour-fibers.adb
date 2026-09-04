with Interfaces; use Interfaces;
with System;
with Iour.Ffi;
with Iour.Ffi.Fiber;
with Iour.Ffi.Sys;
with Iour.Futures;
with Iour.Per_Shard;
with Iour.Reactor;
with Iour.Run_Queue;
with Iour.Trace;

package body Iour.Fibers with
  SPARK_Mode    => On,
  Refined_State =>
    (Registry => (Pool, Shard_Cells,
                  Currents.Cells, Exits.Cells, Inbox_Flags.Cells))
is

   package Fib renames Iour.Ffi.Fiber;
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

   --  Linux CPU number of shard 0.  Ada counts CPUs from one.
   Linux_Base : constant Ffi.C_Int := Ffi.C_Int (First_Shard_Cpu) - 1;

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

   type Fiber_Table is array (Fiber_Id) of Fiber_Record;
   type Free_Stack is array (Natural range 0 .. Max_Fibers - 1) of Fiber_Id;

   Initial_Free : constant Free_Stack :=
     [for I in 0 .. Max_Fibers - 1 => Fiber_Id (Max_Fibers - 1 - I)];

   protected Pool
     with Priority => Runtime_Priority
   is
      procedure Allocate
        (Work : Fiber_Body; Arg : Fiber_Argument; Fiber : out Fiber_Ref);
      procedure Bind (Fiber : Fiber_Id; Shard : Shard_Id; Done : Future_Id);
      procedure Launch_Info
        (Fiber : Fiber_Id;
         Shard : out Shard_Ref;
         Work  : out Fiber_Body;
         Arg   : out Fiber_Argument;
         Done  : out Future_Ref);
      procedure Home_Of (Fiber : Fiber_Id; Shard : out Shard_Ref);
      procedure Stack_Of (Fiber : Fiber_Id; Base : out System.Address);
      procedure Set_Stack (Fiber : Fiber_Id; Base : System.Address);
      procedure Recycle (Fiber : Fiber_Id);
      procedure Stats (Live : out Natural; High_Water : out Natural);
      procedure Next_Stack (From : in out Natural; Base : out System.Address);
   private
      Slots     : Fiber_Table := [others => (others => <>)];
      Available : Free_Stack  := Initial_Free;

      --  Available (0 .. Top - 1) holds the free slots; the bounded
      --  subtypes make the arithmetic provable rather than just correct.
      Top  : Natural range 0 .. Max_Fibers := Max_Fibers;
      Peak : Natural range 0 .. Max_Fibers := 0;
   end Pool;

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

   --  Whether Post_Wake has left anything in the inbox since the shard last
   --  looked.  Set by the poster after its protected push; cleared by the
   --  shard before it drains.
   package Inbox_Flags is new Iour.Per_Shard (Boolean, False);

   type Ready_Index is mod Max_Fibers;
   type Ready_Array is array (Ready_Index) of Fiber_Id;

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
      procedure Pop (Fiber : out Fiber_Ref);
      procedure Depth (Count : out Natural);
      procedure Put_Idle (Idle : Boolean);
      procedure Take_Idle (Idle : out Boolean);
      --  The inbox: wakeups posted from threads that own no ring.
      procedure Post (Fiber : Fiber_Id);
      procedure Take_Post (Fiber : out Fiber_Ref);
   private
      Items   : Ready_Array := [others => 0];
      Head    : Ready_Index := 0;
      Tail    : Ready_Index := 0;
      Held    : Natural range 0 .. Max_Fibers := 0;
      Asleep  : Boolean := False;

      Inbox   : Ready_Array := [others => 0];
      In_Head : Ready_Index := 0;
      In_Tail : Ready_Index := 0;
      In_Held : Natural range 0 .. Max_Fibers := 0;
   end Shard_Cell;

   Shard_Cells : array (Shard_Id) of Shard_Cell;

   ---------------------------------------------------------------------------
   --  Pool body
   ---------------------------------------------------------------------------

   protected body Pool is

      procedure Allocate
        (Work : Fiber_Body; Arg : Fiber_Argument; Fiber : out Fiber_Ref)
      is
         Live : Natural;
      begin
         if Top = 0 then
            Fiber := No_Fiber;
            return;
         end if;
         Top := Top - 1;
         Fiber := Available (Top);

         --  Deliberately preserve Stack: a recycled slot keeps the mapping
         --  it already owns, so only the first use of a slot costs an mmap.
         Slots (Fiber).In_Use := True;
         Slots (Fiber).Home   := No_Shard;
         Slots (Fiber).Work  := Work;
         Slots (Fiber).Arg   := Arg;
         Slots (Fiber).Done  := No_Future;

         Live := Max_Fibers - Top;
         if Live > Peak then
            Peak := Live;
         end if;
      end Allocate;

      procedure Bind (Fiber : Fiber_Id; Shard : Shard_Id; Done : Future_Id) is
      begin
         Slots (Fiber).Home := Shard;
         Slots (Fiber).Done := Done;
      end Bind;

      procedure Launch_Info
        (Fiber : Fiber_Id;
         Shard : out Shard_Ref;
         Work  : out Fiber_Body;
         Arg   : out Fiber_Argument;
         Done  : out Future_Ref) is
      begin
         Shard := Slots (Fiber).Home;
         Work  := Slots (Fiber).Work;
         Arg   := Slots (Fiber).Arg;
         Done  := Slots (Fiber).Done;
      end Launch_Info;

      procedure Home_Of (Fiber : Fiber_Id; Shard : out Shard_Ref) is
      begin
         Shard := Slots (Fiber).Home;
      end Home_Of;

      procedure Stack_Of (Fiber : Fiber_Id; Base : out System.Address) is
      begin
         Base := Slots (Fiber).Stack;
      end Stack_Of;

      procedure Set_Stack (Fiber : Fiber_Id; Base : System.Address) is
      begin
         Slots (Fiber).Stack := Base;
      end Set_Stack;

      procedure Recycle (Fiber : Fiber_Id) is
      begin
         if not Slots (Fiber).In_Use then
            return;
         end if;
         Slots (Fiber).In_Use := False;
         Slots (Fiber).Home   := No_Shard;
         Slots (Fiber).Work  := null;
         Slots (Fiber).Arg   := 0;
         Slots (Fiber).Done  := No_Future;
         if Top < Max_Fibers then
            Available (Top) := Fiber;
            Top := Top + 1;
         end if;
      end Recycle;

      procedure Stats (Live : out Natural; High_Water : out Natural) is
      begin
         Live := Max_Fibers - Top;
         High_Water := Peak;
      end Stats;

      procedure Next_Stack (From : in out Natural; Base : out System.Address)
      is
      begin
         Base := System.Null_Address;
         while From < Max_Fibers loop
            if Slots (Fiber_Id (From)).Stack /= System.Null_Address then
               Base := Slots (Fiber_Id (From)).Stack;
               Slots (Fiber_Id (From)).Stack := System.Null_Address;
               From := From + 1;
               return;
            end if;
            From := From + 1;
         end loop;
      end Next_Stack;

   end Pool;

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
         Items (Tail) := Fiber;
         Tail := Tail + 1;
         Held := Held + 1;
         Accepted := True;
      end Push;

      procedure Enqueue (Fiber : Fiber_Id) is
      begin
         if Held = Max_Fibers then
            return;
         end if;
         Items (Tail) := Fiber;
         Tail := Tail + 1;
         Held := Held + 1;
      end Enqueue;

      procedure Pop (Fiber : out Fiber_Ref) is
      begin
         if Held = 0 then
            Fiber := No_Fiber;
            return;
         end if;
         Fiber := Items (Head);
         Head := Head + 1;
         Held := Held - 1;
      end Pop;

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
      Count := (if Slots <= 0 then 0
                elsif Slots > Ffi.C_Long (Natural'Last) then Natural'Last
                else Natural (Slots));
   end Context_Slots;

   function Self return Shard_Ref is
      Cpu : constant Ffi.C_Int := Ffi.Sys.Sched_Getcpu;
   begin
      if Cpu < Linux_Base
        or else Cpu >= Linux_Base + Ffi.C_Int (Shard_Count)
      then
         return No_Shard;
      end if;
      return Shard_Ref (Cpu - Linux_Base);
   end Self;

   procedure Verify_Cpu (Shard : Active_Shard; Ok : out Boolean) is
      Who : constant Shard_Ref := Self;
   begin
      Ok := Who = Shard;
   end Verify_Cpu;

   ---------------------------------------------------------------------------
   --  Thin forwarding layer
   ---------------------------------------------------------------------------

   procedure Reserve_Contexts (Ok : out Boolean) is
   begin
      Ok := Contexts_Ready;
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

   procedure Pop_Ready (Shard : Shard_Id; Fiber : out Fiber_Ref) is
   begin
      Shard_Cells (Shard).Pop (Fiber);
   end Pop_Ready;

   procedure Ready_Depth (Shard : Shard_Id; Count : out Natural) is
   begin
      Shard_Cells (Shard).Depth (Count);
   end Ready_Depth;

   procedure Home_Of (Fiber : Fiber_Id; Shard : out Shard_Ref) is
   begin
      Pool.Home_Of (Fiber, Shard);
   end Home_Of;

   procedure Live_Fibers (Count : out Natural; High_Water : out Natural) is
   begin
      Pool.Stats (Count, High_Water);
   end Live_Fibers;

   ---------------------------------------------------------------------------
   --  Wakeups
   ---------------------------------------------------------------------------

   --  Post a ring message from From's ring.  The submission queue can be
   --  momentarily full; a message dropped for that reason would be a lost
   --  wakeup, so flush and retry rather than give up.  The retry is bounded
   --  because a ring that fails to flush is not coming back, and the idle
   --  timer will surface the work eventually in any case.
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
      --  post a message on its ring: it arrives as an ordinary completion,
      --  so a sibling asleep in io_uring_enter wakes with no shared lock
      --  and no eventfd anywhere in the path.
      if Home in Active_Shard and then From in Active_Shard then
         declare
            Target_Fd : Descriptor;
         begin
            Reactor.Ring_Descriptor (Home, Target_Fd);
            Send_Message
              (From,
               Reactor.Op_Msg_Ring
                 (Target_Ring  => Target_Fd,
                  Target_Token =>
                    Reactor.Encode
                      (Reactor.Tag_Wake, Unsigned_32 (Fiber) + 1),
                  Token => Reactor.Encode (Reactor.Tag_Msg_Send, 0)));
         end;
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
               declare
                  Target_Fd : Descriptor;
               begin
                  Reactor.Ring_Descriptor (Target, Target_Fd);
                  Send_Message
                    (From,
                     Reactor.Op_Msg_Ring
                       (Target_Ring  => Target_Fd,
                        --  Payload zero: "look around", no particular fiber.
                        Target_Token =>
                          Reactor.Encode (Reactor.Tag_Wake, 0),
                        Token =>
                          Reactor.Encode (Reactor.Tag_Msg_Send, 0)));
               end;
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

      Pool.Allocate (Work, Arg, Fiber);
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
         Pool.Recycle (Fiber);
         return;
      end if;

      --  Publish on the one queue every shard pops from.  This is the
      --  whole of the load-balancing policy.
      Run_Queue.Push (Handle, Accepted);
      if not Accepted then
         Futures.Release (Handle);
         Pool.Recycle (Fiber);
         Handle := No_Future;
         return;
      end if;

      Nudge_Idle (Me);
   end Spawn;

   ---------------------------------------------------------------------------
   --  Adopt
   ---------------------------------------------------------------------------

   procedure Adopt
     (Shard   : Shard_Id;
      Handle  : Future_Id;
      Started : out Boolean)
   is
      Fiber  : Fiber_Ref;
      Base   : System.Address;
      Waiter : Fiber_Ref;
      Home   : Shard_Ref;
   begin
      Started := False;

      Futures.Adopt (Handle, Fiber);
      if Fiber = No_Fiber then
         return;  --  another shard claimed it first
      end if;

      Pool.Bind (Fiber, Shard, Handle);

      --  Give the fiber a stack, reusing the slot's previous one when it
      --  has been round before.
      Pool.Stack_Of (Fiber, Base);
      if Base = System.Null_Address then
         Base := Fib.Stack_Alloc (Ffi.C_Size (Fiber_Stack_Bytes));
         if Base = System.Null_Address then
            --  Out of address space.  Fail the future rather than drop the
            --  work silently, so whoever awaits it learns why.
            Futures.Resolve (Handle, -E_Again, Waiter, Home);
            if Waiter /= No_Fiber
              and then Home in Active_Shard
              and then Shard in Active_Shard
            then
               Wake (Shard, Waiter, Home);
            end if;
            Pool.Recycle (Fiber);
            return;
         end if;
         Pool.Set_Stack (Fiber, Base);
      end if;

      --  Point the context slot at a fresh call of Fiber_Main on that stack.
      Fib.Prime (Slot => Fiber_Slot (Fiber),
                 Base => Base,
                 Size => Ffi.C_Size (Fiber_Stack_Bytes),
                 Arg  => Ffi.C_Long (Fiber));

      Push_Ready (Shard, Fiber, Started);
      Trace.Event (Shard, "adopted fiber", Integer (Fiber));
   end Adopt;

   ---------------------------------------------------------------------------
   --  Resume / After_Resume
   ---------------------------------------------------------------------------

   procedure Resume (Shard : Shard_Id; Fiber : Fiber_Id) is
   begin
      Currents.Set (Shard, Fiber);

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
            Pool.Recycle (Fiber);
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

   procedure Await_Submitted
     (Shard  : Active_Shard;
      Me     : Fiber_Id;
      Handle : Future_Id;
      Result : out Io_Result)
   is
      Resolved : Boolean;
   begin
      loop
         --  Sleep first, ask afterwards.  The waiter was registered when
         --  the future was acquired, and the operation behind it sits in
         --  this shard's ring, whose completions only this shard's loop
         --  reaps -- so it cannot resolve before the switch below gives
         --  that loop the core.  The loop is defence: if the wakeup was
         --  not for a resolution, sleep again rather than return nothing.
         Exits.Set (Shard, Suspended);
         Switch_To_Scheduler (Me, Shard);

         Futures.Claim (Handle, Me, Shard, Resolved, Result);
         exit when Resolved;
      end loop;
   end Await_Submitted;

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
         Pool.Launch_Info (Me, Shard, Work, Param, Done);
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
      Cursor : Natural := 0;
      Base   : System.Address;
   begin
      loop
         Pool.Next_Stack (Cursor, Base);
         exit when Base = System.Null_Address;
         Fib.Stack_Free (Base, Ffi.C_Size (Fiber_Stack_Bytes));
      end loop;
   end Release_All_Stacks;

end Iour.Fibers;
