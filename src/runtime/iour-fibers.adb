with Interfaces; use Interfaces;
with System;
with Iour.Ffi;
with Iour.Ffi.Fiber;
with Iour.Ffi.Sys;
with Iour.Futures;
with Iour.Reactor;
with Iour.Run_Queue;

package body Iour.Fibers with
  SPARK_Mode    => On,
  Refined_State =>
    (Registry   => (Pool, Ready_Cells),
     Scheduling => (Contexts, Cpu_Owner, Current, Asleep))
is

   package Fib renames Iour.Ffi.Fiber;
   use type System.Address;
   use type Ffi.C_Int;
   use type Ffi.C_Size;

   ---------------------------------------------------------------------------
   --  Machine contexts
   ---------------------------------------------------------------------------

   --  One context slot per fiber, plus one per shard for the scheduler it
   --  switches back to.  The values are written only by the assembly in
   --  iour_fiber.c; Ada never reads them, it only hands over their
   --  addresses.  Atomic components make the array a synchronised object,
   --  which is what lets several shard tasks share it.
   subtype Context_Slot is Natural range 0 .. Max_Fibers + Max_Shards - 1;

   type Context_Store is array (Context_Slot) of System.Address
     with Atomic_Components;

   Contexts : Context_Store := [others => System.Null_Address]
     with Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;

   ---------------------------------------------------------------------------
   --  Shard identity
   ---------------------------------------------------------------------------

   --  A shard is pinned to one core for its whole life, so the CPU the
   --  kernel reports identifies it outright.  That makes Self a vDSO read
   --  and an array index -- no thread-local storage, which SPARK does not
   --  model, and no registry lookup on the hot path.
   Max_Cpus : constant := 4096;
   subtype Cpu_Index is Natural range 0 .. Max_Cpus - 1;

   type Cpu_Map is array (Cpu_Index) of Shard_Ref with Atomic_Components;
   Cpu_Owner : Cpu_Map := [others => No_Shard]
     with Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;

   type Current_Map is array (Shard_Id) of Fiber_Ref with Atomic_Components;
   Current : Current_Map := [others => No_Fiber]
     with Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;

   type Idle_Map is array (Shard_Id) of Boolean with Atomic_Components;
   Asleep : Idle_Map := [others => False]
     with Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;

   ---------------------------------------------------------------------------

   ---------------------------------------------------------------------------
   --  Fiber table
   ---------------------------------------------------------------------------

   type Fiber_Record is record
      State : Fiber_State    := Slot_Free;
      Home  : Shard_Ref      := No_Shard;
      Work  : Fiber_Body     := null;
      Arg   : Fiber_Argument := 0;
      Done  : Future_Ref     := No_Future;
      Stack : System.Address := System.Null_Address;
   end record;

   type Fiber_Table is array (Fiber_Id) of Fiber_Record;
   type Free_Stack is array (Natural range 0 .. Max_Fibers - 1) of Fiber_Id;

   Initial_Free : constant Free_Stack :=
     [for I in 0 .. Max_Fibers - 1 => Fiber_Id (Max_Fibers - 1 - I)];

   protected Pool is
      procedure Allocate
        (Work : Fiber_Body; Arg : Fiber_Argument; Fiber : out Fiber_Ref);
      procedure Bind (Fiber : Fiber_Id; Shard : Shard_Id;
                      Done : Future_Id);
      procedure Launch_Info
        (Fiber : Fiber_Id;
         Shard : out Shard_Ref;
         Work  : out Fiber_Body;
         Arg   : out Fiber_Argument;
         Done  : out Future_Ref);
      procedure Mark (Fiber : Fiber_Id; State : Fiber_State);
      procedure State_Of (Fiber : Fiber_Id; State : out Fiber_State);
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
   --  Per-shard ready queues
   ---------------------------------------------------------------------------

   --  One lock per shard rather than one for the runtime.  In practice each
   --  is touched only by its owning shard, so it is always uncontended; it
   --  exists because SPARK requires state reachable from several tasks to
   --  be synchronised, and it makes the cross-shard handoff path safe by
   --  construction rather than by argument.
   type Ready_Index is mod Max_Fibers;
   type Ready_Array is array (Ready_Index) of Fiber_Id;

   protected type Ready_Cell is
      procedure Push (Fiber : Fiber_Id; Accepted : out Boolean);
      procedure Pop (Fiber : out Fiber_Ref);
      procedure Depth (Count : out Natural);
   private
      Items : Ready_Array := [others => 0];
      Head  : Ready_Index := 0;
      Tail  : Ready_Index := 0;
      Held  : Natural range 0 .. Max_Fibers := 0;
   end Ready_Cell;

   Ready_Cells : array (Shard_Id) of Ready_Cell;


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
         Slots (Fiber).State := Runnable;
         Slots (Fiber).Home  := No_Shard;
         Slots (Fiber).Work  := Work;
         Slots (Fiber).Arg   := Arg;
         Slots (Fiber).Done  := No_Future;

         Live := Max_Fibers - Top;
         if Live > Peak then
            Peak := Live;
         end if;
      end Allocate;

      procedure Bind (Fiber : Fiber_Id; Shard : Shard_Id;
                      Done : Future_Id) is
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

      procedure Mark (Fiber : Fiber_Id; State : Fiber_State) is
      begin
         Slots (Fiber).State := State;
      end Mark;

      procedure State_Of (Fiber : Fiber_Id; State : out Fiber_State) is
      begin
         State := Slots (Fiber).State;
      end State_Of;

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
         if Slots (Fiber).State = Slot_Free then
            return;
         end if;
         Slots (Fiber).State := Slot_Free;
         Slots (Fiber).Home  := No_Shard;
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

   protected body Ready_Cell is

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

   end Ready_Cell;

   function Fiber_Slot (Fiber : Fiber_Id) return Context_Slot is
     (Natural (Fiber));

   function Shard_Slot (Shard : Shard_Id) return Context_Slot is
     (Max_Fibers + Natural (Shard));

   function Context_Address (Slot : Context_Slot) return System.Address is
     (Contexts (Slot)'Address);

   function Context_Layout_Matches return Boolean is
     (Fib.Context_Size = Ffi.C_Size (System.Address'Size / 8));

   function Self return Shard_Ref is
      Cpu : constant Ffi.C_Int := Ffi.Sys.Sched_Getcpu;
   begin
      if Cpu < 0 or else Cpu > Ffi.C_Int (Cpu_Index'Last) then
         return No_Shard;
      end if;
      declare
         Owner : constant Shard_Ref := Cpu_Owner (Cpu_Index (Cpu));
      begin
         return Owner;
      end;
   end Self;

   function Running_Fiber (Shard : Shard_Id) return Fiber_Ref is
      Value : constant Fiber_Ref := Current (Shard);
   begin
      return Value;
   end Running_Fiber;

   procedure Set_Running (Shard : Shard_Id; Fiber : Fiber_Ref) is
   begin
      Current (Shard) := Fiber;
   end Set_Running;

   procedure Claim_Cpu (Shard : Shard_Id; Ok : out Boolean) is
      Cpu : constant Ffi.C_Int := Ffi.Sys.Sched_Getcpu;
   begin
      if Cpu < 0 or else Cpu > Ffi.C_Int (Cpu_Index'Last) then
         Ok := False;
         return;
      end if;
      Cpu_Owner (Cpu_Index (Cpu)) := Shard;
      Ok := True;
   end Claim_Cpu;

   procedure Set_Idle (Shard : Shard_Id; Idle : Boolean) is
   begin
      Asleep (Shard) := Idle;
   end Set_Idle;

   --  Volatile_Function: Asleep is written by every shard, so reading it is
   --  a volatile read and SPARK requires the function to say so.
   function Is_Idle (Shard : Shard_Id) return Boolean
     with Volatile_Function;

   function Is_Idle (Shard : Shard_Id) return Boolean is
      Value : constant Boolean := Asleep (Shard);
   begin
      return Value;
   end Is_Idle;

   procedure Push_Ready
     (Shard : Shard_Id; Fiber : Fiber_Id; Accepted : out Boolean) is
   begin
      Ready_Cells (Shard).Push (Fiber, Accepted);
   end Push_Ready;

   procedure Pop_Ready (Shard : Shard_Id; Fiber : out Fiber_Ref) is
   begin
      Ready_Cells (Shard).Pop (Fiber);
   end Pop_Ready;

   procedure Ready_Depth (Shard : Shard_Id; Count : out Natural) is
   begin
      Ready_Cells (Shard).Depth (Count);
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

   procedure Wake
     (From : Shard_Id; Fiber : Fiber_Id; Home : Shard_Id)
   is
      Accepted : Boolean;
   begin
      Pool.Mark (Fiber, Runnable);

      if Home = From then
         Push_Ready (From, Fiber, Accepted);
         return;
      end if;

      --  Another core owns this fiber.  Rather than reach into its queue,
      --  post a message on its ring: it arrives as an ordinary completion,
      --  so a sibling asleep in io_uring_enter wakes with no shared lock
      --  and no eventfd anywhere in the path.
      if Home in Active_Shard then
         declare
            Target_Fd : Descriptor;
         begin
            Reactor.Ring_Descriptor (Home, Target_Fd);
            Reactor.Push
              (From,
               Reactor.Op_Msg_Ring
                 (Target_Ring  => Target_Fd,
                  Target_Token =>
                    Reactor.Encode
                      (Reactor.Tag_Wake, Unsigned_32 (Fiber) + 1),
                  Token => Reactor.Encode (Reactor.Tag_Msg_Send, 0)),
               Accepted);
         end;
      end if;
   end Wake;

   --  Nudge one sleeping shard so it notices new work on the global queue.
   procedure Nudge_Idle (From : Shard_Ref) is
      Accepted : Boolean;
   begin
      --  Only a shard can send: the message has to come from a ring, and
      --  the environment task owns none.  Work published from there is
      --  picked up by the idle timer instead.
      if From not in Active_Shard then
         return;
      end if;

      for Target in Active_Shard loop
         declare
            Sleeping : constant Boolean := Is_Idle (Target);
         begin
            if Target /= From and then Sleeping then
               declare
                  Target_Fd : Descriptor;
               begin
                  Reactor.Ring_Descriptor (Target, Target_Fd);
                  Reactor.Push
                    (From,
                     Reactor.Op_Msg_Ring
                       (Target_Ring  => Target_Fd,
                        --  Payload zero: "look around", no particular fiber.
                        Target_Token =>
                          Reactor.Encode (Reactor.Tag_Wake, 0),
                        Token =>
                          Reactor.Encode (Reactor.Tag_Msg_Send, 0)),
                     Accepted);
               end;
               exit;  --  one woken core is enough to drain the queue
            end if;
         end;
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
      Fiber    : Fiber_Ref;
      Accepted : Boolean;
   begin
      Handle := No_Future;

      Pool.Allocate (Work, Arg, Fiber);
      if Fiber = No_Fiber then
         return;  --  fiber table full
      end if;

      Futures.Acquire (Worker => Fiber,
                       State  => Futures.Queued,
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

      Nudge_Idle (Self);
   end Spawn;

   ---------------------------------------------------------------------------
   --  Adopt
   ---------------------------------------------------------------------------

   procedure Adopt
     (Shard   : Active_Shard;
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
            if Waiter /= No_Fiber and then Home in Active_Shard then
               Wake (Shard, Waiter, Home);
            end if;
            Pool.Recycle (Fiber);
            return;
         end if;
         Pool.Set_Stack (Fiber, Base);
      end if;

      --  Point the context at a fresh call of Fiber_Main on that stack.
      Fib.Prime (Ctx  => Context_Address (Fiber_Slot (Fiber)),
                 Base => Base,
                 Size => Ffi.C_Size (Fiber_Stack_Bytes),
                 Arg  => Ffi.C_Long (Fiber));

      Pool.Mark (Fiber, Runnable);
      Push_Ready (Shard, Fiber, Started);
   end Adopt;

   ---------------------------------------------------------------------------
   --  Resume / After_Resume
   ---------------------------------------------------------------------------

   procedure Resume (Shard : Shard_Id; Fiber : Fiber_Id) is
   begin
      Pool.Mark (Fiber, Running);
      Set_Running (Shard, Fiber);

      --  Hand the core to the fiber.  This returns once the fiber suspends,
      --  yields or finishes -- on this same stack, with the scheduler's
      --  registers restored exactly as they were.
      Fib.Switch (From => Context_Address (Shard_Slot (Shard)),
                  To   => Context_Address (Fiber_Slot (Fiber)));

      Set_Running (Shard, No_Fiber);
   end Resume;

   procedure After_Resume (Shard : Shard_Id; Fiber : Fiber_Id) is
      State    : Fiber_State;
      Accepted : Boolean;
   begin
      Pool.State_Of (Fiber, State);
      case State is
         when Completed =>
            --  The slot goes back to the pool but keeps its stack.
            Pool.Recycle (Fiber);
         when Runnable =>
            --  Yielded voluntarily: back of the queue.
            Push_Ready (Shard, Fiber, Accepted);
         when others =>
            --  Suspended on a future; whoever resolves it will call Wake.
            null;
      end case;
   end After_Resume;

   ---------------------------------------------------------------------------
   --  Suspension
   ---------------------------------------------------------------------------

   procedure Switch_To_Scheduler (Fiber : Fiber_Id; Shard : Shard_Id) is
   begin
      Fib.Switch (From => Context_Address (Fiber_Slot (Fiber)),
                  To   => Context_Address (Shard_Slot (Shard)));
   end Switch_To_Scheduler;

   function In_Fiber return Boolean is
      Shard : constant Shard_Ref := Self;
   begin
      if Shard not in Active_Shard then
         return False;
      end if;
      --  A volatile read has to stand alone as the whole right-hand side,
      --  so it cannot be folded into the expression above.
      declare
         Fiber : constant Fiber_Ref := Running_Fiber (Shard);
      begin
         return Fiber /= No_Fiber;
      end;
   end In_Fiber;

   procedure Await (Handle : Future_Id; Result : out Io_Result) is
      Shard    : constant Shard_Ref := Self;
      Me       : Fiber_Ref;
      Resolved : Boolean;
   begin
      Result := -E_Again;

      if Shard not in Active_Shard then
         return;  --  not on a shard: nothing to suspend
      end if;

      Me := Running_Fiber (Shard);
      if Me = No_Fiber then
         return;  --  not in a fiber: nothing to suspend
      end if;

      loop
         --  Registering as the waiter and testing for a result happen in
         --  one protected action, so a resolution racing in from another
         --  core cannot slip between the test and the sleep.
         Futures.Subscribe (Handle, Me, Shard, Resolved, Result);
         exit when Resolved;

         Pool.Mark (Me, Suspended);

         --  Give the core back.  Other fibers run, completions are reaped,
         --  and control returns here once this future has been resolved.
         Switch_To_Scheduler (Me, Shard);
      end loop;

      Futures.Release (Handle);
   end Await;

   procedure Yield is
      Shard : constant Shard_Ref := Self;
      Me    : Fiber_Ref;
   begin
      if Shard not in Active_Shard then
         return;
      end if;
      Me := Running_Fiber (Shard);
      if Me = No_Fiber then
         return;
      end if;

      --  Runnable, not Suspended: After_Resume puts it straight back on
      --  the ready queue.
      Pool.Mark (Me, Runnable);
      Switch_To_Scheduler (Me, Shard);
   end Yield;

   ---------------------------------------------------------------------------
   --  Fiber entry point
   ---------------------------------------------------------------------------

   procedure Fiber_Main (Arg : Ffi.C_Long)
     with Export, Convention => C, External_Name => "iour_fiber_main";

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

         if Work /= null then
            begin
               Work.all (Param);
            exception
               --  SPARK proves fiber bodies raise nothing, so this is
               --  unreachable by construction.  It is here because the
               --  alternative, if that ever stopped holding, is an
               --  exception unwinding off a fiber stack into the assembly
               --  trampoline, which would take the process down with no
               --  diagnosis at all.
               when others =>
                  Status := -E_Canceled;
            end;
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

         Pool.Mark (Me, Completed);

         if Shard in Active_Shard then
            Switch_To_Scheduler (Me, Shard);
         end if;

         --  Unreachable: the scheduler recycles this slot and re-primes the
         --  stack before anything runs on it again, so control restarts at
         --  the trampoline rather than returning here.  The loop is what
         --  guarantees the procedure cannot fall through into the assembly.
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
