------------------------------------------------------------------------------
--  Iour.Reactor body -- Windows, on IoRing with a completion port beside it.
--
--  Windows has a ring, and it is a real one: CreateIoRing gives a
--  submission queue the process fills without a system call per operation,
--  and SubmitIoRing hands the batch over in one.  What it does not have is
--  an opcode for anything but read, write, flush and cancel.  There is no
--  IORING_OP_ACCEPT, no connect, no timeout, and nothing like MSG_RING.
--
--  So each shard runs two things that behave as one.
--
--    The IoRing carries the data plane.  Every byte a connection sends or
--    receives is a BuildIoRingReadFile or BuildIoRingWriteFile on the
--    socket handle, submitted in batches exactly as on Linux.
--
--    A completion port carries what the ring has no opcode for -- accept,
--    connect, timeouts -- and is also the single place the shard sleeps.
--    The ring's completion event is bridged onto it with one registered
--    wait, so a shard waits in GetQueuedCompletionStatusEx and is woken
--    equally by a ring completion, a port completion or a sibling's
--    PostQueuedCompletionStatus.  One loop, one wait, one wakeup path.
--
--  The rule that makes it work, and the one thing to remember when
--  changing any of this: A SOCKET THAT HAS BEEN ASSOCIATED WITH A
--  COMPLETION PORT CANNOT BE READ OR WRITTEN THROUGH AN IORING.  The
--  builders refuse it with E_INVALIDARG.  So the listener -- which carries
--  no data -- goes on the port for AcceptEx, and no other socket ever does.
--  That is also why connect is a blocking connect(2) handed to a thread
--  pool rather than ConnectEx: ConnectEx would need the port, and the
--  socket would spend the rest of its life off the ring for the sake of
--  one call at the start of it.
--
--  Where CreateIoRing is not available at all -- Windows 10, which has the
--  completion port but not the ring -- Use_Ring is False and the data
--  plane falls back to overlapped WSARecv and WSASend on the port.  Then
--  and only then are data sockets associated with it.
--
--  SPARK_Mode is Off throughout.  This body hands addresses to the kernel,
--  overlays records on completion-port pointers and is re-entered from
--  thread-pool threads, all of which are outside the analysable subset.
--  Iour.Reactor's spec is what every client above is verified against, and
--  this body's job is to keep that promise.
------------------------------------------------------------------------------

with Interfaces.C;
with System.Address_To_Access_Conversions;
with System.Storage_Elements; use System.Storage_Elements;
with Iour.Ffi.Inet;
with Iour.Ffi.Net;
with Iour.Ffi.Sys;
with Iour.Ffi.Win32;

package body Iour.Reactor with SPARK_Mode => Off is

   package Win renames Iour.Ffi.Win32;
   package Inet renames Iour.Ffi.Inet;

   use type System.Address;
   use type Win.Handle;
   use type Win.Accept_Ex_Fn;
   use type Win.Set_Completion_Event_Fn;
   use type Win.Close_Io_Ring_Fn;
   use type Win.Submit_Io_Ring_Fn;
   use type Win.Pop_Completion_Fn;
   use type Interfaces.C.int;

   ---------------------------------------------------------------------------
   --  Completion-port keys
   ---------------------------------------------------------------------------

   --  What the completion key says about an entry the port hands back.
   Key_Socket : constant Unsigned_64 := 0;  --  overlapped op finished
   Key_Done   : constant Unsigned_64 := 1;  --  result already in the slot
   Key_Wake   : constant Unsigned_64 := 2;  --  the pointer IS the token
   Key_Ring    : constant Unsigned_64 := 3;  --  the IoRing has completions

   ---------------------------------------------------------------------------
   --  Operation slots
   ---------------------------------------------------------------------------

   --  Every operation the port carries needs an OVERLAPPED that stays put
   --  from submission until completion, plus what the completion handler
   --  has to know to make sense of it.  One pool per shard, a free list
   --  through it, and no allocation anywhere: the same shape as every
   --  other table in this runtime.
   --
   --  Sized so a slot is always there for a fiber that wants one: a fiber
   --  has at most one operation in flight, and the spare covers the
   --  acceptors and timers that are not fibers' own.
   Slot_Capacity : constant := Max_Fibers + 64;

   type Slot_Ref is range -1 .. Slot_Capacity - 1;
   subtype Slot_Index is Slot_Ref range 0 .. Slot_Capacity - 1;
   No_Slot : constant Slot_Ref := -1;

   type Op_Slot is record
      --  MUST be the first component.  The port hands back the address of
      --  this field, and the slot is recovered by treating that address as
      --  the address of the whole record.  Open checks the two coincide
      --  rather than trusting the compiler's layout silently.
      Ov : aliased Win.Overlapped;

      Kind   : Op_Kind       := Kind_Nop;
      Token  : Unsigned_64   := 0;
      Sock   : Win.Handle    := Win.Invalid_Socket;

      --  Kind_Accept: the socket AcceptEx will fill in, and the listener it
      --  came from, which SO_UPDATE_ACCEPT_CONTEXT needs afterwards.
      Accepted : Win.Handle  := Win.Invalid_Socket;
      Listener : Win.Handle  := Win.Invalid_Socket;

      Buffer : System.Address := System.Null_Address;
      Length : Natural        := 0;

      --  What a Key_Done entry reports, filled in before it is posted.
      Result : Io_Result     := 0;

      Shard  : Shard_Ref     := No_Shard;
      Me     : Slot_Ref      := No_Slot;

      --  The shard's port, kept here so a thread-pool callback never has
      --  to reach into another shard's engine record to find it.
      Port   : Win.Handle    := Win.Null_Handle;

      --  Kind_Timeout: created on first use and reused for the life of the
      --  slot, so a sleeping fiber costs no object churn.
      Timer  : System.Address := System.Null_Address;

      --  The shard's wake event, kept here for the same reason as Port:
      --  a thread-pool callback must be able to announce a completion
      --  without reaching into another shard's engine record.
      Waker  : Win.Handle := Win.Null_Handle;

      --  Whether the kernel is the one that will deliver this operation's
      --  completion to the port.  True for AcceptEx and for overlapped
      --  Winsock; false for everything this runtime finishes itself and
      --  announces with Post_Done, which sets the wake event as it goes.
      --  It is the difference between a shard that must sleep on the port
      --  and one that can sleep on the ring.
      From_Kernel : Boolean := False;

      --  Scratch the overlapped Winsock calls write through.
      Wsa    : aliased Win.Wsabuf;
      Bytes  : aliased Win.Dword := 0;
      Flags  : aliased Win.Dword := 0;

      --  AcceptEx insists on somewhere to put the two addresses, whether
      --  or not the caller wants them.  Nothing here reads it.
      Addrs  : Win.Accept_Buffer := [others => 0];

      Next   : Slot_Ref := No_Slot;
      Busy   : Boolean  := False;
   end record;

   type Slot_Array is array (Slot_Index) of aliased Op_Slot;

   package Slot_Pointers is new System.Address_To_Access_Conversions (Op_Slot);

   use type Slot_Pointers.Object_Pointer;

   ---------------------------------------------------------------------------
   --  Pending completions
   ---------------------------------------------------------------------------

   --  What a drain has taken off the port and out of the ring but the
   --  scheduler has not yet asked for.  A plain ring buffer, touched only
   --  by the owning shard.
   Pending_Capacity : constant := 1024;
   type Pending_Ring is array (0 .. Pending_Capacity - 1) of Completion;

   --  Entries pulled from the port in one call.  Bounded so a drain can
   --  never take more than the pending ring has room for.
   Drain_Batch : constant := 128;

   ---------------------------------------------------------------------------
   --  One shard's engine
   ---------------------------------------------------------------------------

   type Engine is record
      Ring      : Win.Handle := Win.Null_Handle;
      Port      : Win.Handle := Win.Null_Handle;
      Ring_Evt  : Win.Handle := Win.Null_Handle;
      Ring_Wait : Win.Handle := Win.Null_Handle;

      --  Set by anything of ours that puts an entry on the port, so that a
      --  shard asleep on the ring's event still hears about it.
      Wake_Evt  : Win.Handle := Win.Null_Handle;

      Started   : Boolean := False;

      --  Whether the data plane is on the IoRing.  False on a system with
      --  no CreateIoRing, and then socket reads and writes are overlapped
      --  Winsock calls on the port instead.
      Use_Ring  : Boolean := False;

      --  Whether the ring can tell us it has completions.  Without
      --  IORING_FEATURE_SET_COMPLETION_EVENT there is nothing to bridge
      --  onto the port, and a shard with ring operations in flight has to
      --  bound how long it sleeps.
      Ring_Signals : Boolean := False;

      --  Built into the submission queue, not yet handed over.
      Unsent    : Natural := 0;

      --  Submitted, completion not yet seen; and how those split between
      --  the ring and the port.  Ring_Live decides whether a sleep has to
      --  be bounded; Port_Live decides whether the port is worth asking.
      Live      : Natural := 0;
      Ring_Live : Natural := 0;
      Port_Live : Natural := 0;

      --  Of those port operations, the ones the kernel will complete on
      --  its own.  A shard with none of these never has to sleep on the
      --  port, and so never has to pay for the bridge.
      Kernel_Live : Natural := 0;

      --  Whether the ring's completion event has been bridged onto the
      --  port for this shard.  Sticky once set: the bridge and a direct
      --  wait cannot both have the event, because it is auto-reset and
      --  whichever waiter arrives first consumes it.
      Bridged   : Boolean := False;

      --  How long the next blocking wait may last, in milliseconds.  Set
      --  by Arm_Idle_Timer and consumed by the wait that follows it.
      Idle_Ms   : Win.Dword := 0;
      Armed     : Boolean := False;

      Free      : Slot_Ref := No_Slot;
      Slots     : Slot_Array;

      Pend      : Pending_Ring := [others => (others => <>)];
      Pend_Head : Natural := 0;
      Pend_Tail : Natural := 0;
      Pend_Count : Natural := 0;
   end record;

   type Engine_Array is array (Shard_Id) of Engine;

   --  Each shard touches its own row and no other's, except for the one
   --  cross-shard read a wakeup needs: the target's port, which is written
   --  once at Open and never again.
   Engines_Data : Engine_Array;

   --  Set by a shard that has just posted a wakeup to another, cleared by
   --  that other shard before it drains.  It exists so that a shard whose
   --  own work is all in the ring can tell, without a system call, whether
   --  the completion port has anything for it.
   --
   --  The order is what makes it sound, and it is the same order
   --  Iour.Fibers uses for its inbox: post first, then set the flag; read
   --  the flag, clear it, then drain.  A wakeup posted after the drain
   --  leaves the flag set for the next pass, and one posted before it is
   --  found by that drain whether or not the flag survived.  Nothing is
   --  lost either way, and the worst a race costs is one needless look at
   --  the port.
   Wake_Flags : array (Shard_Id) of Boolean := [others => False]
     with Atomic_Components;

   ---------------------------------------------------------------------------
   --  Token encoding
   ---------------------------------------------------------------------------

   --  Tag in the top eight bits, payload in the low thirty-two.  The gap in
   --  between is left empty so a token is easy to read in a trace.  Same
   --  encoding as the Linux backend, because the tokens mean the same
   --  things and the scheduler above reads both.
   Tag_Shift : constant := 56;

   function Encode (Tag : Token_Tag; Payload : Unsigned_32) return Unsigned_64
   is (Shift_Left (Unsigned_64 (Token_Tag'Pos (Tag) + 1), Tag_Shift)
       or Unsigned_64 (Payload));

   procedure Decode
     (Token   : Unsigned_64;
      Tag     : out Token_Tag;
      Payload : out Unsigned_32)
   is
      Code : constant Unsigned_64 := Shift_Right (Token, Tag_Shift);
   begin
      Payload := Unsigned_32 (Token and 16#FFFF_FFFF#);
      if Code >= 1
        and then Code <= Unsigned_64 (Token_Tag'Pos (Token_Tag'Last))
      then
         Tag := Token_Tag'Val (Natural (Code) - 1);
      else
         Tag := Tag_Unknown;
      end if;
   end Decode;

   ---------------------------------------------------------------------------
   --  Operation constructors
   ---------------------------------------------------------------------------

   --  Windows registers no file table, so no descriptor here is ever a
   --  fixed file and every operation belongs to whichever shard submits
   --  it.  Ring is left at No_Shard throughout, which is what tells
   --  Iour.Async it has nothing to check.

   function Op_Nop (Token : Unsigned_64) return Op_Spec is
     (Kind => Kind_Nop, Token => Token, others => <>);

   function Op_Accept
     (Fd     : Descriptor;
      Token  : Unsigned_64;
      Direct : Boolean := False) return Op_Spec
   is (Kind   => Kind_Accept,
       Fd     => Fd,
       Token  => Token,
       Direct => Direct,
       others => <>);

   function Op_Connect
     (Fd      : Descriptor;
      Address : System.Address;
      Length  : Natural;
      Token   : Unsigned_64) return Op_Spec
   is (Kind   => Kind_Connect,
       Fd     => Fd,
       Buffer => Address,
       Length => Length,
       Token  => Token,
       others => <>);

   function Op_Recv
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
   is (Kind   => Kind_Recv,
       Fd     => Fd,
       Buffer => Buffer,
       Length => Length,
       Token  => Token,
       others => <>);

   function Op_Send
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
   is (Kind   => Kind_Send,
       Fd     => Fd,
       Buffer => Buffer,
       Length => Length,
       Token  => Token,
       others => <>);

   function Op_Write
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
   is (Kind   => Kind_Write,
       Fd     => Fd,
       Buffer => Buffer,
       Length => Length,
       Token  => Token,
       others => <>);

   function Op_Close (Fd : Descriptor; Token : Unsigned_64) return Op_Spec is
     (Kind => Kind_Close, Fd => Fd, Token => Token, others => <>);

   function Op_Timeout
     (Nanoseconds : Unsigned_64; Token : Unsigned_64) return Op_Spec
   is (Kind        => Kind_Timeout,
       Nanoseconds => Nanoseconds,
       Token       => Token,
       others      => <>);

   function Op_Wake
     (Target       : Shard_Id;
      Target_Token : Unsigned_64;
      Token        : Unsigned_64) return Op_Spec
   is (Kind         => Kind_Wake,
       Target       => Target,
       Target_Token => Target_Token,
       Token        => Token,
       others       => <>);

   ---------------------------------------------------------------------------
   --  Small helpers
   ---------------------------------------------------------------------------

   function As_Handle (Fd : Descriptor) return Win.Handle is
     (if Fd < 0 then Win.Invalid_Socket else Win.Handle (Fd));

   --  Natural is 31 bits and Dword is 32, so every Natural fits; the
   --  conversion is here to say so once rather than at each call.
   function Capped (N : Natural) return Win.Dword is (Win.Dword (N));

   ---------------------------------------------------------------------------
   --  Pending queue
   ---------------------------------------------------------------------------

   procedure Post_Pending
     (E : in out Engine; Token : Unsigned_64; Res : Io_Result) is
   begin
      if E.Pend_Count >= Pending_Capacity then
         return;   --  cannot happen: every drain leaves room for its batch
      end if;
      E.Pend (E.Pend_Tail) := (Token => Token, Res => Res, Flags => 0);
      E.Pend_Tail := (E.Pend_Tail + 1) mod Pending_Capacity;
      E.Pend_Count := E.Pend_Count + 1;
      if E.Live > 0 then
         E.Live := E.Live - 1;
      end if;
   end Post_Pending;

   --  A wakeup a sibling sent.  It was never counted as in flight here, so
   --  unlike every other completion it must not decrement Live.
   procedure Post_Wakeup (E : in out Engine; Token : Unsigned_64) is
   begin
      if E.Pend_Count >= Pending_Capacity then
         return;
      end if;
      E.Pend (E.Pend_Tail) := (Token => Token, Res => No_Result, Flags => 0);
      E.Pend_Tail := (E.Pend_Tail + 1) mod Pending_Capacity;
      E.Pend_Count := E.Pend_Count + 1;
   end Post_Wakeup;

   ---------------------------------------------------------------------------
   --  Slot pool
   ---------------------------------------------------------------------------

   procedure Build_Free_List (E : in out Engine; Shard : Shard_Id) is
   begin
      E.Free := No_Slot;
      for I in reverse Slot_Index loop
         E.Slots (I).Me    := I;
         E.Slots (I).Shard := Shard;
         E.Slots (I).Port  := E.Port;
         E.Slots (I).Waker := E.Wake_Evt;
         E.Slots (I).Busy  := False;
         E.Slots (I).Next  := E.Free;
         E.Free := I;
      end loop;
   end Build_Free_List;

   function Take_Slot (E : in out Engine) return Slot_Ref is
      Got : constant Slot_Ref := E.Free;
   begin
      if Got = No_Slot then
         return No_Slot;
      end if;
      E.Free := E.Slots (Got).Next;
      E.Slots (Got).Busy := True;
      E.Slots (Got).Next := No_Slot;
      E.Slots (Got).Ov := (others => <>);
      E.Slots (Got).Bytes := 0;
      E.Slots (Got).Flags := 0;
      E.Slots (Got).Accepted := Win.Invalid_Socket;
      E.Slots (Got).Listener := Win.Invalid_Socket;
      E.Slots (Got).From_Kernel := False;
      return Got;
   end Take_Slot;

   procedure Give_Slot (E : in out Engine; Which : Slot_Index) is
   begin
      if not E.Slots (Which).Busy then
         return;
      end if;
      E.Slots (Which).Busy := False;
      E.Slots (Which).Next := E.Free;
      E.Free := Which;
   end Give_Slot;

   --  Hand a finished operation back to the shard through the port, so it
   --  arrives in the same stream as everything else and can wake a shard
   --  that has already gone to sleep.
   --
   --  The event afterwards is what lets that shard be asleep on the ring
   --  rather than on the port.  It costs a system call on a path that is
   --  never the hot one -- a timer expiring, a connect finishing, a close
   --  -- and it is what takes the thread-pool bridge off the path that is.
   procedure Post_Done (Slot : access Op_Slot; Res : Io_Result) is
      Ignored : Win.Bool;
   begin
      Slot.Result := Res;
      Ignored := Win.Post_Completion
        (Port    => Slot.Port,
         Bytes   => 0,
         Key     => Key_Done,
         Overlap => Slot.Ov'Address);
      if Slot.Waker /= Win.Null_Handle then
         Ignored := Win.Set_Event (Slot.Waker);
      end if;
   end Post_Done;

   ---------------------------------------------------------------------------
   --  Thread-pool callbacks
   ---------------------------------------------------------------------------

   --  These run on thread-pool threads, not on any Ada task.  Each one
   --  touches exactly one slot and makes exactly one Win32 call, so
   --  nothing here needs the Ada runtime and nothing can raise.

   procedure Ring_Ready (Context : System.Address; Timed_Out : Unsigned_8)
     with Convention => Stdcall;

   procedure Ring_Ready (Context : System.Address; Timed_Out : Unsigned_8) is
      pragma Unreferenced (Timed_Out);
      Which   : constant Integer_Address := To_Integer (Context);
      Ignored : Win.Bool;
   begin
      --  The ring's completion queue has gone from empty to non-empty.
      --  Say so on the port, which is where the shard is asleep.
      if Which in 0 .. Integer_Address (Shard_Id'Last) then
         Ignored := Win.Post_Completion
           (Port    => Engines_Data (Shard_Id (Which)).Port,
            Bytes   => 0,
            Key     => Key_Ring,
            Overlap => System.Null_Address);
      end if;
   end Ring_Ready;

   procedure Timer_Fired
     (Instance : System.Address;
      Context  : System.Address;
      Timer    : System.Address)
     with Convention => Stdcall;

   procedure Timer_Fired
     (Instance : System.Address;
      Context  : System.Address;
      Timer    : System.Address)
   is
      pragma Unreferenced (Instance, Timer);
      Slot : constant Slot_Pointers.Object_Pointer :=
        Slot_Pointers.To_Pointer (Context);
   begin
      --  A timeout reports -ETIME, exactly as IORING_OP_TIMEOUT does, so
      --  callers cannot tell the two backends apart.
      if Slot /= null then
         Post_Done (Slot, -E_Time);
      end if;
   end Timer_Fired;

   procedure Connect_Blocking
     (Instance : System.Address; Context : System.Address)
     with Convention => Stdcall;

   procedure Connect_Blocking
     (Instance : System.Address; Context : System.Address)
   is
      pragma Unreferenced (Instance);
      Slot : constant Slot_Pointers.Object_Pointer :=
        Slot_Pointers.To_Pointer (Context);

      --  The sockaddr the caller handed over.  It is on the suspended
      --  fiber's own stack, which is exactly what keeps it alive until
      --  this call is done with it.
      Endpoint : Inet.Sockaddr_In
        with Import, Address => (if Slot = null
                                 then System.Null_Address
                                 else Slot.Buffer);
      Where  : aliased constant Inet.Sockaddr_In := Endpoint;
      Status : Ffi.C_Int;
   begin
      if Slot = null then
         return;
      end if;

      --  A blocking connect on a thread that is not a shard.  ConnectEx
      --  would be the asynchronous spelling, but it needs the socket on a
      --  completion port, and a socket that has been on a port can never
      --  be read through the IoRing again -- so the whole connection's
      --  data plane would be the price of one call.  This way the socket
      --  stays untouched and no shard blocks.
      Status := Win.C_Connect
        (Slot.Sock, Where'Access, Inet.Sockaddr_In'Size / 8);

      Post_Done (Slot, (if Status = 0 then 0 else Ffi.Sys.Failure_Code));
   end Connect_Blocking;

   ---------------------------------------------------------------------------
   --  Open
   ---------------------------------------------------------------------------

   procedure Open (Shard : Shard_Id; Status : out Io_Result) is
      E : Engine renames Engines_Data (Shard);

      Ring   : aliased Win.Handle := Win.Null_Handle;
      Result : Win.Hresult;
   begin
      Status := 0;

      --  Sockets may already exist -- a server binds its listener before
      --  the shards start -- but a shard that runs first must not find
      --  Winsock uninitialised.
      Ffi.Net.Initialize;

      --  The slot is recovered from the OVERLAPPED address the port hands
      --  back, which is only sound if the two coincide.  Check rather than
      --  trust: a layout change here would be a memory-safety bug, and it
      --  costs one comparison at start-up to make it impossible.
      if E.Slots (0).Ov'Address /= E.Slots (0)'Address then
         Status := -E_Invalid;
         return;
      end if;

      --  One port per shard, and exactly one thread allowed to service it:
      --  its own.  That is the same promise IORING_SETUP_SINGLE_ISSUER
      --  makes on the other backend.
      --  The event anything of ours sets after putting an entry on the
      --  port.  Auto-reset, so a shard that is awake does not spin on it.
      E.Wake_Evt := Win.Create_Event
        (Attributes    => System.Null_Address,
         Manual_Reset  => 0,
         Initial_State => 0,
         Name          => System.Null_Address);

      E.Port := Win.Create_Completion_Port
        (File     => Win.Invalid_Handle,
         Existing => Win.Null_Handle,
         Key      => 0,
         Threads  => 1);
      if E.Port = Win.Null_Handle then
         Status := Ffi.Sys.Failure_Code;
         return;
      end if;

      --  The ring.  A completion queue twice the submission queue, as the
      --  API recommends, so a burst of completions is never dropped.
      Win.Load_Ioring;
      if Win.Ioring_Available then
         --  IORING_CREATE_FLAGS is two words: required flags in the low
         --  one, advisory in the high.  The advisory bit asked for here is
         --  SKIP_BUILDER_PARAM_CHECKS, which drops the argument validation
         --  every BuildIoRing* call would otherwise repeat.  Advisory means
         --  an implementation that does not know it ignores it, and the
         --  kernel checks the arguments regardless -- a bad one still comes
         --  back as a failed completion.  What is given up is catching a
         --  programming error at the builder rather than at the
         --  completion, which is a debug-build concern.
         Result := Win.Create_Io_Ring.all
           (Version => Win.Ioring_Version,
            Flags   => Shift_Left (Unsigned_64 (Win.Skip_Builder_Checks), 32),
            Sq_Size => Ring_Entries,
            Cq_Size => 2 * Ring_Entries,
            Ring    => Ring'Access);
         if Result >= 0 and then Ring /= Win.Null_Handle then
            E.Ring := Ring;
            E.Use_Ring := True;
         end if;
      end if;

      if E.Use_Ring
        and then (Win.Ioring_Features and Win.Feature_Set_Event) /= 0
        and then Win.Set_Completion_Event /= null
      then
         E.Ring_Evt := Win.Create_Event
           (Attributes    => System.Null_Address,
            Manual_Reset  => 0,     --  auto-reset
            Initial_State => 0,
            Name          => System.Null_Address);
         if E.Ring_Evt /= Win.Null_Handle
           and then Win.Set_Completion_Event.all (E.Ring, E.Ring_Evt) >= 0
         then
            E.Ring_Signals := True;
         end if;
      end if;

      Build_Free_List (E, Shard);
      Wake_Flags (Shard) := False;
      E.Kernel_Live := 0;
      E.Bridged := False;
      E.Unsent := 0;
      E.Live := 0;
      E.Ring_Live := 0;
      E.Port_Live := 0;
      E.Pend_Head := 0;
      E.Pend_Tail := 0;
      E.Pend_Count := 0;
      E.Armed := False;
      E.Idle_Ms := 0;
      E.Started := True;
   end Open;

   ---------------------------------------------------------------------------
   --  Shut
   ---------------------------------------------------------------------------

   procedure Shut (Shard : Shard_Id) is
      E       : Engine renames Engines_Data (Shard);
      Ignored : Win.Bool;
      Discard : Win.Hresult;
   begin
      E.Started := False;

      if E.Ring_Wait /= Win.Null_Handle then
         --  Wait for the bridge to stop before the port goes: a callback
         --  still in flight would post to a closed handle.
         Ignored := Win.Unregister_Wait (E.Ring_Wait, Win.Invalid_Handle);
         E.Ring_Wait := Win.Null_Handle;
      end if;

      for I in Slot_Index loop
         if E.Slots (I).Timer /= System.Null_Address then
            Win.Set_Threadpool_Timer
              (E.Slots (I).Timer, null, 0, 0);   --  cancel
            Win.Wait_For_Threadpool_Timer_Callbacks (E.Slots (I).Timer, 1);
            Win.Close_Threadpool_Timer (E.Slots (I).Timer);
            E.Slots (I).Timer := System.Null_Address;
         end if;
      end loop;

      if E.Ring /= Win.Null_Handle and then Win.Close_Io_Ring /= null then
         Discard := Win.Close_Io_Ring.all (E.Ring);
         E.Ring := Win.Null_Handle;
      end if;

      if E.Ring_Evt /= Win.Null_Handle then
         Ignored := Win.Close_Handle (E.Ring_Evt);
         E.Ring_Evt := Win.Null_Handle;
      end if;

      if E.Wake_Evt /= Win.Null_Handle then
         Ignored := Win.Close_Handle (E.Wake_Evt);
         E.Wake_Evt := Win.Null_Handle;
      end if;

      if E.Port /= Win.Null_Handle then
         Ignored := Win.Close_Handle (E.Port);
         E.Port := Win.Null_Handle;
      end if;

      E.Use_Ring := False;
      E.Ring_Signals := False;
      E.Bridged := False;
      E.Live := 0;
      E.Ring_Live := 0;
      E.Port_Live := 0;
      E.Kernel_Live := 0;
      E.Unsent := 0;
   end Shut;

   ---------------------------------------------------------------------------
   --  Submitting one operation
   ---------------------------------------------------------------------------

   --  A read or a write through the ring.  Both builders take their two
   --  reference structures by address, which is what the Win64 ABI does
   --  with a sixteen-byte aggregate anyway; the builder copies them into
   --  the submission queue entry before returning, so locals are enough.
   function Build_Ring_Io
     (E : in out Engine; Slot : Op_Slot; Writing : Boolean) return Boolean
   is
      File : aliased Win.Handle_Ref :=
        (Kind => Win.Ref_Raw, Pad => 0, Value => Slot.Sock);
      Data : aliased Win.Buffer_Ref :=
        (Kind => Win.Ref_Raw, Pad => 0, Address => Slot.Buffer);
      Result : Win.Hresult;
   begin
      if Writing then
         Result := Win.Build_Write.all
           (Ring        => E.Ring,
            File_Ref    => File'Address,
            Buffer_Ref  => Data'Address,
            Bytes       => Capped (Slot.Length),
            Offset      => 0,
            Write_Flags => 0,
            User_Data   => Slot.Token,
            Sqe_Flags   => 0);
      else
         Result := Win.Build_Read.all
           (Ring      => E.Ring,
            File_Ref  => File'Address,
            Data_Ref  => Data'Address,
            Bytes     => Capped (Slot.Length),
            Offset    => 0,
            User_Data => Slot.Token,
            Sqe_Flags => 0);
      end if;
      return Result >= 0;
   end Build_Ring_Io;

   --  Overlapped Winsock, for the systems with no ring.  The socket has to
   --  be on the port for this, which is why it only happens here.
   function Start_Overlapped_Io
     (E : in out Engine; Slot : access Op_Slot; Writing : Boolean)
      return Io_Result
   is
      Status : Ffi.C_Int;
      Err    : Win.Dword;
   begin
      Slot.Wsa := (Len => Unsigned_32 (Capped (Slot.Length)),
                   Buf => Slot.Buffer);
      Slot.Flags := 0;

      if Win.Create_Completion_Port
           (File     => Slot.Sock,
            Existing => E.Port,
            Key      => Key_Socket,
            Threads  => 0) = Win.Null_Handle
      then
         --  Already associated is not an error worth failing on; anything
         --  else is.
         null;
      end if;

      if Writing then
         Status := Win.Wsa_Send
           (S       => Slot.Sock,
            Buffers => Slot.Wsa'Address,
            Count   => 1,
            Sent    => Slot.Bytes'Access,
            Flags   => 0,
            Overlap => Slot.Ov'Address,
            Routine => System.Null_Address);
      else
         Status := Win.Wsa_Recv
           (S        => Slot.Sock,
            Buffers  => Slot.Wsa'Address,
            Count    => 1,
            Received => Slot.Bytes'Access,
            Flags    => Slot.Flags'Access,
            Overlap  => Slot.Ov'Address,
            Routine  => System.Null_Address);
      end if;

      if Status = 0 then
         return 0;   --  finished at once; the port still gets an entry
      end if;
      Err := Win.Dword (Win.Wsa_Get_Last_Error);
      if Err = Win.Error_Io_Pending then
         return 0;
      end if;
      return Win.As_Failure (Err);
   end Start_Overlapped_Io;

   function Start_Accept
     (E : in out Engine; Slot : access Op_Slot) return Io_Result
   is
      Ok  : Win.Bool;
      Err : Win.Dword;
   begin
      if Win.Accept_Ex = null then
         return -E_Invalid;
      end if;

      --  The listener, and only the listener, goes on the port.  It never
      --  carries a byte of data, so nothing is lost by it; the sockets it
      --  produces stay clear of the port and stay readable through the
      --  ring.
      Slot.Listener := Slot.Sock;
      if Win.Create_Completion_Port
           (File     => Slot.Listener,
            Existing => E.Port,
            Key      => Key_Socket,
            Threads  => 0) = Win.Null_Handle
      then
         null;   --  already associated
      end if;

      --  AcceptEx wants the socket to accept into made in advance.
      declare
         Made : Io_Result;
      begin
         Made := Ffi.Net.Tcp_Socket;
         if Made < 0 then
            return Made;
         end if;
         Slot.Accepted := Win.Handle (Made);
      end;

      Ok := Win.Accept_Ex.all
        (Listener       => Slot.Listener,
         Accepted       => Slot.Accepted,
         Output         => Slot.Addrs'Address,
         Receive_Length => 0,     --  do not wait for a first read
         Local_Length   => Win.Accept_Address_Length,
         Remote_Length  => Win.Accept_Address_Length,
         Received       => Slot.Bytes'Access,
         Overlap        => Slot.Ov'Address);

      if Ok /= 0 then
         return 0;   --  immediate; the port still gets an entry
      end if;
      Err := Win.Dword (Win.Wsa_Get_Last_Error);
      if Err = Win.Error_Io_Pending then
         return 0;
      end if;
      Ffi.Net.Close_Quietly (Descriptor (Slot.Accepted));
      Slot.Accepted := Win.Invalid_Socket;
      return Win.As_Failure (Err);
   end Start_Accept;

   function Start_Timeout
     (Slot : access Op_Slot; Nanoseconds : Unsigned_64) return Io_Result
   is
      --  FILETIME units are hundreds of nanoseconds, and a negative value
      --  is what makes it an interval from now rather than a date.
      Ticks : constant Unsigned_64 :=
        (if Nanoseconds = 0 then 1 else Nanoseconds / 100 + 1);
      Due   : aliased Integer_64;
   begin
      if Slot.Timer = System.Null_Address then
         Slot.Timer := Win.Create_Threadpool_Timer
           (Callback    => Timer_Fired'Access,
            Context     => Slot.all'Address,
            Environment => System.Null_Address);
         if Slot.Timer = System.Null_Address then
            return -E_Invalid;
         end if;
      end if;

      if Ticks > Unsigned_64 (Integer_64'Last) then
         Due := Integer_64'First + 1;
      else
         Due := -Integer_64 (Ticks);
      end if;

      Win.Set_Threadpool_Timer (Slot.Timer, Due'Access, 0, 0);
      return 0;
   end Start_Timeout;

   --  A write to something that is not a socket: stdout, stderr, a file.
   --
   --  This one is synchronous, and deliberately.  IoRing will only take a
   --  handle opened for asynchronous access, and the standard streams --
   --  which is what every caller of this actually passes, through
   --  Iour.Text -- are not: a console handle has no overlapped mode to ask
   --  for.  Writing the line here and posting the completion costs the
   --  shard a few microseconds and keeps Iour.Text working the same way on
   --  both systems, which is better than a ring submission that would fail
   --  and have to be redone.
   function Write_Now (Slot : access Op_Slot) return Io_Result is
      Written : aliased Win.Dword := 0;
      Ok      : Win.Bool;
   begin
      Ok := Win.Write_File
        (H        => Slot.Sock,
         Buffer   => Slot.Buffer,
         To_Write => Capped (Slot.Length),
         Written  => Written'Access,
         Overlap  => System.Null_Address);
      if Ok = 0 then
         return Ffi.Sys.Failure_Code;
      end if;
      return Io_Result (Written);
   end Write_Now;

   ---------------------------------------------------------------------------
   --  Push
   ---------------------------------------------------------------------------

   procedure Push (Shard : Shard_Id; Spec : Op_Spec; Queued : out Boolean) is
      E     : Engine renames Engines_Data (Shard);
      Which : Slot_Ref;
      Res   : Io_Result;
   begin
      Queued := False;
      if not E.Started then
         return;
      end if;

      --  A wakeup needs no slot and no bookkeeping: it is one call, and it
      --  lands in the sibling's stream rather than ours.
      if Spec.Kind = Kind_Wake then
         Queued := True;
         if Spec.Target in Active_Shard
           and then Engines_Data (Shard_Id (Spec.Target)).Port
                    /= Win.Null_Handle
         then
            declare
               Ignored : Win.Bool;
            begin
               Ignored := Win.Post_Completion
                 (Port    => Engines_Data (Shard_Id (Spec.Target)).Port,
                  Bytes   => 0,
                  Key     => Key_Wake,
                  --  The token travels as the overlapped pointer, which on
                  --  this platform is the same sixty-four bits.  Nothing
                  --  dereferences it; the key says not to.
                  Overlap => To_Address
                               (Integer_Address (Spec.Target_Token)));

               --  After the post, never before: the target reads this to
               --  decide whether the port is worth a system call, and a
               --  flag set ahead of the thing it announces could be
               --  cleared by a drain that then found nothing.
               Wake_Flags (Shard_Id (Spec.Target)) := True;

               --  And the event, for a sibling that is asleep on its ring
               --  rather than on its port.
               if Engines_Data (Shard_Id (Spec.Target)).Wake_Evt
                  /= Win.Null_Handle
               then
                  Ignored := Win.Set_Event
                    (Engines_Data (Shard_Id (Spec.Target)).Wake_Evt);
               end if;
            end;
         end if;
         return;
      end if;

      --  A ring operation carries its token in the submission and needs
      --  nothing that outlives the call, so it never touches the pool.
      --  Only the port's operations need an OVERLAPPED to stay put.
      if E.Use_Ring and then Spec.Kind in Kind_Recv | Kind_Send then
         declare
            Ring_Op : constant Op_Slot :=
              (Ov     => <>,
               Kind   => Spec.Kind,
               Token  => Spec.Token,
               Sock   => As_Handle (Spec.Fd),
               Buffer => Spec.Buffer,
               Length => Spec.Length,
               others => <>);
         begin
            if not Build_Ring_Io (E, Ring_Op,
                                  Writing => Spec.Kind = Kind_Send)
            then
               --  The submission queue is full.  The caller flushes and
               --  tries again, which is the same contract as a full
               --  io_uring submission queue.
               return;
            end if;
         end;
         E.Unsent := E.Unsent + 1;
         E.Live := E.Live + 1;
         E.Ring_Live := E.Ring_Live + 1;
         Queued := True;
         return;
      end if;

      Which := Take_Slot (E);
      if Which = No_Slot then
         return;   --  pool momentarily empty; the caller flushes and retries
      end if;

      declare
         Slot : constant access Op_Slot := E.Slots (Which)'Access;
      begin
         Slot.Kind   := Spec.Kind;
         Slot.Token  := Spec.Token;
         Slot.Sock   := As_Handle (Spec.Fd);
         Slot.Buffer := Spec.Buffer;
         Slot.Length := Spec.Length;
         Slot.Port   := E.Port;

         case Spec.Kind is

            when Kind_Nop =>
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
               Post_Done (Slot, 0);

            when Kind_Recv | Kind_Send =>
               --  The ring path returned above; this is the fallback, and
               --  overlapped Winsock does need the OVERLAPPED to stay put.
               if False then
                  null;
               else
                  E.Live := E.Live + 1;
                  E.Port_Live := E.Port_Live + 1;
                  E.Kernel_Live := E.Kernel_Live + 1;
                  Slot.From_Kernel := True;
                  Res := Start_Overlapped_Io
                    (E, Slot, Writing => Spec.Kind = Kind_Send);
                  if Res < 0 then
                     Post_Done (Slot, Res);
                  end if;
               end if;

            when Kind_Write =>
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
               Post_Done (Slot, Write_Now (Slot));

            when Kind_Accept =>
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
               E.Kernel_Live := E.Kernel_Live + 1;
               Slot.From_Kernel := True;
               Res := Start_Accept (E, Slot);
               if Res < 0 then
                  Post_Done (Slot, Res);
               end if;

            when Kind_Connect =>
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
               if Spec.Length /= Inet.Sockaddr_In'Size / 8
                 or else Spec.Buffer = System.Null_Address
                 or else Win.Submit_Threadpool_Callback
                           (Callback    => Connect_Blocking'Access,
                            Context     => Slot.all'Address,
                            Environment => System.Null_Address) = 0
               then
                  Post_Done (Slot, -E_Invalid);
               end if;

            when Kind_Close =>
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
               Post_Done (Slot, Ffi.Net.Close (Spec.Fd));

            when Kind_Timeout =>
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
               Res := Start_Timeout (Slot, Spec.Nanoseconds);
               if Res < 0 then
                  Post_Done (Slot, Res);
               end if;

            when Kind_Wake =>
               null;   --  handled above
         end case;
      end;

      Queued := True;
   end Push;

   ---------------------------------------------------------------------------
   --  Draining
   ---------------------------------------------------------------------------

   --  Everything the ring has finished.  Cheap when there is nothing:
   --  PopIoRingCompletion answers S_FALSE without a system call.
   procedure Drain_Ring (E : in out Engine) is
      Cqe    : aliased Win.Ioring_Cqe;
      Result : Win.Hresult;
      Res    : Io_Result;
   begin
      if not E.Use_Ring or else Win.Pop_Completion = null then
         return;
      end if;

      loop
         exit when E.Pend_Count >= Pending_Capacity;
         Cqe := (others => <>);
         Result := Win.Pop_Completion.all (E.Ring, Cqe'Access);
         exit when Result /= Win.S_Ok;

         if Cqe.Result >= 0 then
            --  Information is the byte count, which is what every caller
            --  of a read or a write is waiting for.  A read of zero is the
            --  peer closing, exactly as it is on Linux.
            Res := (if Cqe.Information > Unsigned_64 (Io_Result'Last)
                    then Io_Result'Last
                    else Io_Result (Cqe.Information));
         elsif Win.Means_Unsupported (Cqe.Result) then
            --  The ring refused the handle.  The design is meant to make
            --  this impossible -- no data socket is ever put on a
            --  completion port -- so it means an invariant broke rather
            --  than that the peer did something.  Report it as EINVAL,
            --  which is what the fiber will see and pass on.
            Res := -E_Invalid;
         else
            Res := Win.Hresult_Failure (Cqe.Result);
         end if;

         Post_Pending (E, Cqe.User_Data, Res);
         if E.Ring_Live > 0 then
            E.Ring_Live := E.Ring_Live - 1;
         end if;
      end loop;
   end Drain_Ring;

   --  What one completion-port entry means.
   procedure Absorb (E : in out Engine; Item : Win.Overlapped_Entry) is
      Res : Io_Result;
   begin
      case Item.Key is

         when Key_Wake =>
            --  The token travelled as the pointer.  Nothing to free and
            --  nothing to dereference, and nothing to retire: a wakeup was
            --  never counted as this shard's own work.
            Post_Wakeup (E, Unsigned_64 (To_Integer (Item.Overlap)));

         when Key_Ring =>
            --  The bridge saying the ring has something.  Drain_Ring, which
            --  every pass calls anyway, is what actually collects it.
            null;

         when Key_Done | Key_Socket =>
            if Item.Overlap = System.Null_Address then
               return;
            end if;
            declare
               Slot : constant Slot_Pointers.Object_Pointer :=
                 Slot_Pointers.To_Pointer (Item.Overlap);
            begin
               if Slot = null or else not Slot.Busy then
                  return;
               end if;

               if Item.Key = Key_Done then
                  Res := Slot.Result;
               else
                  --  An overlapped Winsock call.  The port reports how many
                  --  bytes moved; the status is the NTSTATUS the I/O
                  --  manager left in the OVERLAPPED's Internal field.
                  if Slot.Ov.Internal = 0 then
                     Res := Io_Result (Item.Bytes);
                  else
                     Res := Win.Status_Failure (Slot.Ov.Internal);
                  end if;
               end if;

               --  An accept that worked hands back a socket, and Winsock
               --  wants to be told where it came from before anything else
               --  is done with it.
               if Slot.Kind = Kind_Accept then
                  if Res >= 0 and then Slot.Accepted /= Win.Invalid_Socket
                  then
                     declare
                        From    : aliased Win.Handle := Slot.Listener;
                        Ignored : Ffi.C_Int;
                     begin
                        Ignored := Win.C_Setsockopt
                          (S     => Slot.Accepted,
                           Level => Win.Sol_Socket,
                           Name  => Win.So_Update_Accept_Context,
                           Value => From'Address,
                           Len   => Win.Handle'Size / 8);
                     end;

                     --  Without a ring the data plane is overlapped
                     --  Winsock, and only then may the accepted socket go
                     --  on the port.
                     if not E.Use_Ring then
                        if Win.Create_Completion_Port
                             (File     => Slot.Accepted,
                              Existing => E.Port,
                              Key      => Key_Socket,
                              Threads  => 0) = Win.Null_Handle
                        then
                           null;
                        end if;
                     end if;

                     Res := Io_Result (Slot.Accepted);
                  elsif Slot.Accepted /= Win.Invalid_Socket then
                     Ffi.Net.Close_Quietly (Descriptor (Slot.Accepted));
                  end if;
                  Slot.Accepted := Win.Invalid_Socket;
               end if;

               --  A connect that worked has the same courtesy to pay, and
               --  the same question about the port to answer.
               if Slot.Kind = Kind_Connect and then Res >= 0 then
                  declare
                     Ignored : Ffi.C_Int;
                  begin
                     Ignored := Win.C_Setsockopt
                       (S     => Slot.Sock,
                        Level => Win.Sol_Socket,
                        Name  => Win.So_Update_Connect_Context,
                        Value => System.Null_Address,
                        Len   => 0);
                  end;
               end if;

               Post_Pending (E, Slot.Token, Res);
               if E.Port_Live > 0 then
                  E.Port_Live := E.Port_Live - 1;
               end if;
               if Slot.From_Kernel and then E.Kernel_Live > 0 then
                  E.Kernel_Live := E.Kernel_Live - 1;
               end if;
               Give_Slot (E, Slot.Me);
            end;

         when others =>
            null;
      end case;
   end Absorb;

   --  Turn "the ring has something" into an entry on the port, for a
   --  shard that has to sleep on the port anyway.  One registered wait,
   --  never taken down: without WT_EXECUTEONLYONCE it re-arms itself, and
   --  the event is auto-reset, so this is a standing subscription.
   procedure Arm_Bridge (E : in out Engine; Shard : Shard_Id) is
      Wait : aliased Win.Handle := Win.Null_Handle;
      Ok   : Win.Bool;
   begin
      E.Bridged := True;   --  set first: one attempt is enough either way
      if E.Ring_Evt = Win.Null_Handle then
         return;
      end if;
      Ok := Win.Register_Wait
        (Wait_Object  => Wait'Access,
         Object       => E.Ring_Evt,
         Callback     => Ring_Ready'Access,
         Context      => To_Address (Integer_Address (Shard)),
         Milliseconds => Win.Infinite,
         Flags        => Win.Wt_Execute_In_Wait_Thread);
      if Ok /= 0 then
         E.Ring_Wait := Wait;
      end if;
   end Arm_Bridge;

   --  Everything both halves have finished, waiting no longer than
   --  Timeout_Ms for the port.  This is the only place a shard blocks.
   --
   --  The ring goes first, and the port is skipped entirely when it cannot
   --  have anything.  That second part is worth more than it looks.  A
   --  shard serving connections has every one of its completions in the
   --  ring; the port carries accepts, connects, timers and wakeups, and on
   --  every core except the one accepting there are usually none of those.
   --  Asking the port anyway costs a system call, the scheduler asks twice
   --  a pass, and at a hundred thousand round trips a second that is the
   --  largest avoidable cost in this backend.
   --
   --  A blocking drain always asks: the wait is the point, and the port is
   --  where it happens.
   procedure Drain (Shard : Shard_Id; Timeout_Ms_In : Win.Dword) is
      E       : Engine renames Engines_Data (Shard);
      Timeout_Ms : Win.Dword := Timeout_Ms_In;
      Room    : Natural;
      Wanted  : Natural;
      Items   : Win.Entry_Array (0 .. Drain_Batch - 1);
      Removed : aliased Win.Dword := 0;
      Ok      : Win.Bool;
      Woken   : Boolean;
   begin
      if not E.Started or else E.Port = Win.Null_Handle then
         return;
      end if;

      Drain_Ring (E);

      --  Read the flag and clear it before looking, so a wakeup that lands
      --  during the look is seen on the next pass rather than lost.
      Woken := Wake_Flags (Shard);
      if Woken then
         Wake_Flags (Shard) := False;
      end if;

      if Timeout_Ms = 0 and then E.Port_Live = 0 and then not Woken then
         return;
      end if;

      --  A blocking wait on a shard with nothing the kernel will deliver
      --  to the port sleeps on the ring's own event instead.
      --
      --  This is the difference between one wakeup and three.  Going
      --  through the port means the ring signals its event, a thread-pool
      --  thread wakes to notice, that thread posts to the port, and only
      --  then does this shard's wait return -- two extra thread wakeups per
      --  completion, on a path that runs twice per round trip.  Measured
      --  on one idle connection it was most of the difference between this
      --  runtime and the two it is compared against.
      --
      --  Bridged is sticky because the bridge and this wait cannot share
      --  the event: it is auto-reset, so whichever waiter reaches it first
      --  consumes it, and the other sleeps through the completion.  A shard
      --  that has ever needed the port keeps it.
      if Timeout_Ms > 0
        and then E.Ring_Signals
        and then not E.Bridged
        and then E.Kernel_Live = 0
      then
         declare
            Handles : aliased Win.Handle_Array (0 .. 1) :=
              [E.Ring_Evt, E.Wake_Evt];
            Ignored : Win.Dword;
         begin
            Ignored := Win.Wait_For_Objects
              (Count        => 2,
               Handles      => Handles'Address,
               Wait_All     => 0,
               Milliseconds => Timeout_Ms);
         end;

         Drain_Ring (E);
         if Wake_Flags (Shard) then
            Wake_Flags (Shard) := False;
            Woken := True;
         end if;
         if E.Port_Live = 0 and then not Woken then
            return;
         end if;
         --  Something of ours is on the port; take it without waiting
         --  again.
         Timeout_Ms := 0;
      end if;

      --  About to sleep on the port with the kernel owing us something.
      --  Bridge the ring onto it, once, so a ring completion arriving
      --  during that sleep still wakes this shard.
      if Timeout_Ms > 0 and then E.Ring_Signals and then not E.Bridged then
         Arm_Bridge (E, Shard);
      end if;

      Room := Pending_Capacity - E.Pend_Count;
      if Room > 0 then
         Wanted := (if Room > Drain_Batch then Drain_Batch else Room);
         Ok := Win.Get_Completions
           (Port         => E.Port,
            Entries      => Items'Address,
            Count        => Win.Dword (Wanted),
            Removed      => Removed'Access,
            Milliseconds => Timeout_Ms,
            Alertable    => 0);
         if Ok /= 0 and then Removed > 0 then
            for I in 0 .. Natural (Removed) - 1 loop
               exit when I > Items'Last;
               Absorb (E, Items (I));
            end loop;
            --  A blocking wait may have slept through ring completions
            --  that arrived alongside; take them now rather than next pass.
            Drain_Ring (E);
         end if;
      end if;
   end Drain;

   ---------------------------------------------------------------------------
   --  Flush
   ---------------------------------------------------------------------------

   --  How long a shard with nothing to do may sleep.  The idle timer sets
   --  this; without one, a bound that is long enough to be free and short
   --  enough that nothing can be stranded by it.
   Default_Sleep_Ms : constant Win.Dword := 1000;

   --  A ring that cannot signal has to be looked at rather than waited on,
   --  so a sleep with ring operations outstanding is kept short.
   Poll_Sleep_Ms : constant Win.Dword := 1;

   procedure Flush
     (Shard    : Shard_Id;
      Wait_For : Natural;
      Status   : out Io_Result)
   is
      E         : Engine renames Engines_Data (Shard);
      Submitted : aliased Unsigned_32 := 0;
      Result    : Win.Hresult;
      Timeout   : Win.Dword;
   begin
      Status := 0;

      if not E.Started then
         Status := -E_Again;
         return;
      end if;

      --  Hand over everything built into the submission queue.  Asking for
      --  no completions and no wait makes this the exact counterpart of an
      --  io_uring_enter that only submits.
      if E.Use_Ring and then E.Unsent > 0 and then Win.Submit_Io_Ring /= null
      then
         Result := Win.Submit_Io_Ring.all
           (Ring         => E.Ring,
            Wait_For     => 0,
            Milliseconds => 0,
            Submitted    => Submitted'Access);
         if Result >= 0 then
            E.Unsent :=
              (if Natural (Submitted) >= E.Unsent
               then 0 else E.Unsent - Natural (Submitted));
         else
            Status := Win.Hresult_Failure (Result);
            return;
         end if;
      end if;

      if Wait_For = 0 then
         return;
      end if;

      --  Anything already collected means there is no reason to sleep.
      if E.Pend_Count > 0 then
         return;
      end if;

      Timeout := (if E.Armed then E.Idle_Ms else Default_Sleep_Ms);
      if E.Ring_Live > 0 and then not E.Ring_Signals then
         Timeout := (if Timeout > Poll_Sleep_Ms then Poll_Sleep_Ms
                     else Timeout);
      end if;
      E.Armed := False;

      Drain (Shard, Timeout);
   end Flush;

   procedure Flush_Quietly (Shard : Shard_Id) is
      Status : Io_Result;
   begin
      Flush (Shard, 0, Status);
      pragma Unreferenced (Status);
   end Flush_Quietly;

   ---------------------------------------------------------------------------
   --  Harvest
   ---------------------------------------------------------------------------

   procedure Harvest
     (Shard : Shard_Id;
      Batch : out Completion_Batch;
      Count : out Natural)
   is
      E : Engine renames Engines_Data (Shard);
      N : Natural := 0;
   begin
      Batch := [others => (others => <>)];
      Count := 0;
      if not E.Started then
         return;
      end if;

      --  Nothing waiting: look once, without blocking, before saying so.
      if E.Pend_Count = 0 then
         Drain (Shard, 0);
      end if;

      while N < Reap_Batch and then E.Pend_Count > 0 loop
         Batch (N) := E.Pend (E.Pend_Head);
         E.Pend_Head := (E.Pend_Head + 1) mod Pending_Capacity;
         E.Pend_Count := E.Pend_Count - 1;
         N := N + 1;
      end loop;

      Count := N;
   end Harvest;

   procedure In_Flight (Shard : Shard_Id; Count : out Natural) is
   begin
      Count := Engines_Data (Shard).Live;
   end In_Flight;

   ---------------------------------------------------------------------------
   --  Registered files
   ---------------------------------------------------------------------------

   --  Windows has nothing corresponding.  IoRing does have
   --  IORING_OP_REGISTER_FILES, but what it registers is handles for read
   --  and write, and it is accept -- which the ring has no opcode for --
   --  that would have to fill the table.  So every descriptor here is an
   --  ordinary one, which is a path the whole runtime already supports.
   procedure Has_Fixed_Files (Shard : Shard_Id; Yes : out Boolean) is
      pragma Unreferenced (Shard);
   begin
      Yes := False;
   end Has_Fixed_Files;

   procedure Unregister_File
     (Shard : Shard_Id; Slot : File_Slot; Status : out Io_Result)
   is
      pragma Unreferenced (Shard, Slot);
   begin
      Status := -E_Invalid;
   end Unregister_File;

   ---------------------------------------------------------------------------
   --  Arm_Idle_Timer
   ---------------------------------------------------------------------------

   --  No operation is submitted for this.  The completion port takes the
   --  wait in milliseconds, so an idle shard's poll interval is the wait
   --  itself rather than a timer racing it -- which is one fewer thing in
   --  flight, and one fewer completion to reap when it expires.
   procedure Arm_Idle_Timer (Shard : Shard_Id; Level : Natural := 0) is
      E    : Engine renames Engines_Data (Shard);
      Step : constant Natural :=
        (if Level > Max_Backoff then Max_Backoff else Level);
      Nanos : constant Unsigned_64 :=
        Unsigned_64 (Idle_Poll_Nanos) * (2 ** Step);
      Millis : constant Unsigned_64 := Nanos / 1_000_000;
   begin
      E.Idle_Ms := (if Millis = 0 then 1
                    elsif Millis > Unsigned_64 (Win.Dword'Last - 1)
                    then Win.Dword'Last - 1
                    else Win.Dword (Millis));
      E.Armed := True;
   end Arm_Idle_Timer;

   ---------------------------------------------------------------------------
   --  Reporting
   ---------------------------------------------------------------------------

   function Backend_Name return String is ("Windows IoRing");

   procedure Ring_Carries_Sockets (Shard : Shard_Id; Yes : out Boolean) is
   begin
      Yes := Engines_Data (Shard).Use_Ring;
   end Ring_Carries_Sockets;

end Iour.Reactor;
