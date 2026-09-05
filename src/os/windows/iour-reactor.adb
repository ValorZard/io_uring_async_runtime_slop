------------------------------------------------------------------------------
--  Iour.Reactor body -- Windows, on a completion port.
--
--  One port per shard.  Every operation this backend performs either is an
--  overlapped Win32 call whose completion the kernel delivers to that port,
--  or is finished by the runtime itself and announced on the port with
--  PostQueuedCompletionStatus.  Either way a shard has exactly one place to
--  look and exactly one place to sleep, which is what
--  GetQueuedCompletionStatusEx gives it: a batch of completions and a
--  bounded wait, in one system call.
--
--  There used to be an IoRing here as well, carrying the data plane while
--  the port carried everything the ring had no opcode for.  It was removed,
--  and the reason is worth keeping because the conclusion is not the one
--  the Linux side would suggest.
--
--  Windows' IoRing has opcodes for read, write, register-files,
--  register-buffers, cancel and flush.  That is the whole list: no accept,
--  no connect, no timeout, nothing like MSG_RING.  So the completion port
--  had to exist anyway, and the ring's only real saving was one system call
--  per *batch* of submissions.  Against that it cost a wakeup: a ring
--  completion signals an event that a shard waits on, where a port
--  completion is handed to a waiting thread by the I/O manager directly.
--  It also cost a rule -- a socket associated with a completion port cannot
--  be read or written through an IoRing -- that shaped the whole backend
--  around keeping data sockets off the port.
--
--  Measured, with both paths built from one binary and run alternately:
--  a tie or slightly behind at high connection counts, and clearly behind
--  on the single-connection latency path, where there is no batch to
--  amortise and only the wakeup is left.  The port won 26 of 28 paired
--  runs there at 25-40% more round trips a second and half the CPU.  See
--  the README for the table.
--
--  What that removal bought, beyond the deletion: data sockets may now be
--  associated with a port freely, so the accept path has no rule to keep;
--  a shard has one sleep rather than two and needs no thread-pool bridge
--  between them; and nothing has to be told, by an event, that a wakeup
--  has been posted -- the post is the wakeup.
--
--  What it did not buy, and should: connect is still a blocking connect(2)
--  handed to a thread pool.  That was forced by the ring -- ConnectEx needs
--  the socket on a port, which would have cost that connection the ring for
--  the rest of its life -- and nothing forces it now.  See *Open work*.
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
   use type Interfaces.C.int;

   ---------------------------------------------------------------------------
   --  Completion-port keys
   ---------------------------------------------------------------------------

   --  What the completion key says about an entry the port hands back.
   Key_Socket : constant Unsigned_64 := 0;  --  overlapped op finished
   Key_Done   : constant Unsigned_64 := 1;  --  result already in the slot
   Key_Wake   : constant Unsigned_64 := 2;  --  the pointer IS the token

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
   --  Sockets already on a shard's completion port
   ---------------------------------------------------------------------------

   --  Winsock delivers an overlapped completion only to a port the socket
   --  has been associated with, so something has to associate it -- and
   --  the only place that knows both the socket and the shard that will
   --  serve it is the first operation that shard issues on it.
   --
   --  Associating on every operation is correct, and was what this did:
   --  CreateIoCompletionPort on an already associated socket simply fails.
   --  It is also a system call per read and per write, which on this
   --  backend is the whole of the data plane.
   --
   --  So: remember what has been associated.  A direct-mapped table, one
   --  per shard, touched only by that shard.
   --
   --  It is a cache and not a register, which is what makes it safe to
   --  keep small.  Two sockets whose handles collide evict each other, and
   --  an evicted socket pays one redundant call on its next operation --
   --  exactly what every operation used to pay.  The entry is written
   --  whether the call succeeded or not, because either it is on this
   --  shard's port now or it is on another's and repeating the call will
   --  never change that.
   --
   --  The one thing it does rest on: a socket that has had an operation
   --  issued on it is closed through the reactor, so that Kind_Close can
   --  forget it before Windows hands the same handle value to something
   --  else.  Iour.Net.Close_Now closes without telling the reactor, and is
   --  used only for sockets that were never operated on -- a connection
   --  refused before its handler started.
   Port_Cache_Size : constant := 4096;
   type Cache_Index is mod Port_Cache_Size;
   type Handle_Cache is array (Cache_Index) of Win.Handle;

   --  Windows hands out socket handles in multiples of four, so the low two
   --  bits carry nothing and dropping them is what makes consecutive
   --  sockets land in consecutive entries.
   function Cache_Slot (H : Win.Handle) return Cache_Index is
     (Cache_Index (Shift_Right (Unsigned_64 (H), 2) mod Port_Cache_Size));

   ---------------------------------------------------------------------------
   --  One shard's engine
   ---------------------------------------------------------------------------

   type Engine is record
      Port      : Win.Handle := Win.Null_Handle;

      Started   : Boolean := False;

      --  Submitted, completion not yet seen.  Live is what In_Flight
      --  reports and what the scheduler's shutdown drain waits on;
      --  Port_Live is the same count restricted to operations that will
      --  arrive as an entry on the port, which is what decides whether a
      --  non-blocking drain is worth a system call at all.
      --
      --  The two differ only in that a cross-shard wakeup is counted in
      --  neither: it is a sibling's work, not ours.
      Live      : Natural := 0;
      Port_Live : Natural := 0;

      --  How long the next blocking wait may last, in milliseconds.  Set
      --  by Arm_Idle_Timer and consumed by the wait that follows it.
      Idle_Ms   : Win.Dword := 0;
      Armed     : Boolean := False;

      Free      : Slot_Ref := No_Slot;
      Slots     : Slot_Array;

      --  Sockets this shard has already put on its port; see above.  Only
      --  the no-ring path writes it.
      On_Port   : Handle_Cache := [others => Win.Null_Handle];

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
   --  arrives in the same stream as everything else and wakes a shard that
   --  has already gone to sleep.
   --
   --  The post IS the wakeup, and that is the whole of it.  While there was
   --  a ring here this had to set an event afterwards as well, because a
   --  shard with nothing on the port slept on the ring's completion event
   --  instead and would not have heard the post.  With one place to sleep
   --  there is nothing to tell.
   procedure Post_Done (Slot : access Op_Slot; Res : Io_Result) is
      Ignored : Win.Bool;
   begin
      Slot.Result := Res;
      Ignored := Win.Post_Completion
        (Port    => Slot.Port,
         Bytes   => 0,
         Key     => Key_Done,
         Overlap => Slot.Ov'Address);
   end Post_Done;

   ---------------------------------------------------------------------------
   --  Thread-pool callbacks
   ---------------------------------------------------------------------------

   --  These run on thread-pool threads, not on any Ada task.  Each one
   --  touches exactly one slot and makes exactly one Win32 call, so
   --  nothing here needs the Ada runtime and nothing can raise.

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

      --  A blocking connect on a thread that is not a shard.  ConnectEx is
      --  the asynchronous spelling and this should now be using it: it
      --  needs the socket on a completion port, which was disqualifying
      --  while an IoRing carried the data plane -- a socket that has been
      --  on a port can never be read through a ring again, so one call at
      --  the start of a connection would have cost it the ring for the
      --  rest of its life -- and is exactly what every data socket does
      --  here anyway now.  Until then this blocks a thread-pool thread
      --  rather than a shard, which is correct and costs a thread hop per
      --  connect.  See *Open work* in CLAUDE.md.
      Status := Win.C_Connect
        (Slot.Sock, Where'Access, Inet.Sockaddr_In'Size / 8);

      Post_Done (Slot, (if Status = 0 then 0 else Ffi.Sys.Failure_Code));
   end Connect_Blocking;

   ---------------------------------------------------------------------------
   --  Open
   ---------------------------------------------------------------------------

   procedure Open (Shard : Shard_Id; Status : out Io_Result) is
      E : Engine renames Engines_Data (Shard);
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
      --  makes on the other backend, and it is what lets everything below
      --  this line be plain per-shard state with no lock on it.
      E.Port := Win.Create_Completion_Port
        (File     => Win.Invalid_Handle,
         Existing => Win.Null_Handle,
         Key      => 0,
         Threads  => 1);
      if E.Port = Win.Null_Handle then
         Status := Ffi.Sys.Failure_Code;
         return;
      end if;

      Build_Free_List (E, Shard);
      E.On_Port := [others => Win.Null_Handle];
      Wake_Flags (Shard) := False;
      E.Live := 0;
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
   begin
      E.Started := False;

      --  Timers before the port.  A thread-pool timer that fired while the
      --  port was closing would post to a closed handle, so each one is
      --  cancelled and then waited for.
      for I in Slot_Index loop
         if E.Slots (I).Timer /= System.Null_Address then
            Win.Set_Threadpool_Timer
              (E.Slots (I).Timer, null, 0, 0);   --  cancel
            Win.Wait_For_Threadpool_Timer_Callbacks (E.Slots (I).Timer, 1);
            Win.Close_Threadpool_Timer (E.Slots (I).Timer);
            E.Slots (I).Timer := System.Null_Address;
         end if;
      end loop;

      if E.Port /= Win.Null_Handle then
         Ignored := Win.Close_Handle (E.Port);
         E.Port := Win.Null_Handle;
      end if;

      E.Live := 0;
      E.Port_Live := 0;
   end Shut;

   ---------------------------------------------------------------------------
   --  Submitting one operation
   ---------------------------------------------------------------------------

   --  A socket read or write: the data plane, and the only operation here
   --  that runs at a per-round-trip rate.  WSARecv and WSASend with an
   --  OVERLAPPED, which the kernel completes onto this shard's port.
   function Start_Overlapped_Io
     (E : in out Engine; Slot : access Op_Slot; Writing : Boolean)
      return Io_Result
   is
      Status : Ffi.C_Int;
      Err    : Win.Dword;
      Where  : constant Cache_Index := Cache_Slot (Slot.Sock);
      Ignored_Port : Win.Handle;
   begin
      Slot.Wsa := (Len => Unsigned_32 (Capped (Slot.Length)),
                   Buf => Slot.Buffer);
      Slot.Flags := 0;

      --  The socket has to be on this shard's port before the completion
      --  can arrive, and this is the first place that knows both.  Once is
      --  enough; the cache is what makes it once rather than once per
      --  operation.
      if E.On_Port (Where) /= Slot.Sock then
         Ignored_Port := Win.Create_Completion_Port
           (File     => Slot.Sock,
            Existing => E.Port,
            Key      => Key_Socket,
            Threads  => 0);
         E.On_Port (Where) := Slot.Sock;
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
   --  This one is synchronous, and deliberately.  Overlapped I/O needs a
   --  handle opened for asynchronous access, and the standard streams --
   --  which is what every caller of this actually passes, through
   --  Iour.Text -- are not: a console handle has no overlapped mode to ask
   --  for.  Writing the line here and posting the completion costs the
   --  shard a few microseconds and keeps Iour.Text working the same way on
   --  both systems, which is better than a submission that would fail and
   --  have to be redone.
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
            end;
         end if;
         return;
      end if;

      --  Everything else needs an OVERLAPPED that stays put from here
      --  until the completion comes back, so everything else takes a slot.
      --  A pool momentarily empty is not an error: the caller flushes what
      --  is outstanding, lets sibling fibers run, and tries again, which is
      --  the same contract a full io_uring submission queue has.
      Which := Take_Slot (E);
      if Which = No_Slot then
         return;
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
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
               Res := Start_Overlapped_Io
                 (E, Slot, Writing => Spec.Kind = Kind_Send);
               if Res < 0 then
                  Post_Done (Slot, Res);
               end if;

            when Kind_Write =>
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
               Post_Done (Slot, Write_Now (Slot));

            when Kind_Accept =>
               E.Live := E.Live + 1;
               E.Port_Live := E.Port_Live + 1;
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

               --  Forget it before the handle goes back to Windows to be
               --  handed out again, or the next socket to be given this
               --  number would be taken for one already on the port and
               --  would never be associated with it.
               declare
                  Where : constant Cache_Index := Cache_Slot (Slot.Sock);
               begin
                  if E.On_Port (Where) = Slot.Sock then
                     E.On_Port (Where) := Win.Null_Handle;
                  end if;
               end;

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

                     --  Deliberately NOT associated with a port here,
                     --  although it must be on one before its first read.
                     --
                     --  A socket may be associated with exactly one port
                     --  for as long as it is open, and it is the shard
                     --  that SERVES the connection that has to own it --
                     --  not the shard that accepted it.  Where the port
                     --  cannot be shared there is one acceptor dealing
                     --  connections round the cores, so those two are
                     --  usually different, and associating here sent three
                     --  quarters of every server's completions to a shard
                     --  that had no fiber waiting for them: the entry was
                     --  resolved against the wrong shard's slot table and
                     --  woke whichever fiber happened to hold that index.
                     --  Measured as 500 connections managing 2158 frames
                     --  between them before every one of them failed.
                     --
                     --  Start_Overlapped_Io associates it instead, on the
                     --  shard that issues the first read -- which is the
                     --  shard the connection was dealt to, and the one
                     --  that will hold it for its whole life.

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
               Give_Slot (E, Slot.Me);
            end;

         when others =>
            null;
      end case;
   end Absorb;

   --  Everything the port has finished, waiting no longer than Timeout_Ms
   --  for it.  This is the only place a shard blocks.
   --
   --  GetQueuedCompletionStatusEx is doing three jobs in one system call:
   --  it is the wait, it is the batch collection, and -- because a
   --  sibling's PostQueuedCompletionStatus lands in the same queue -- it is
   --  the cross-shard wakeup.  That is why there is nothing else here.
   --
   --  The one thing worth keeping is the early return.  A non-blocking
   --  drain on a shard that has nothing outstanding and no wakeup pending
   --  cannot find anything, and the scheduler asks twice a pass; at a
   --  hundred thousand round trips a second a system call that can only
   --  answer "nothing" is worth not making.  A blocking drain always asks,
   --  because the wait is the point.
   procedure Drain (Shard : Shard_Id; Timeout_Ms : Win.Dword) is
      E       : Engine renames Engines_Data (Shard);
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

      --  Read the flag and clear it before looking, so a wakeup that lands
      --  during the look is seen on the next pass rather than lost.
      Woken := Wake_Flags (Shard);
      if Woken then
         Wake_Flags (Shard) := False;
      end if;

      if Timeout_Ms = 0 and then E.Port_Live = 0 and then not Woken then
         return;
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

   --  There is nothing to hand over.  Every operation this backend takes is
   --  already with the kernel by the time Push returns -- WSARecv, WSASend
   --  and AcceptEx are submitted where they are built -- so Flush is only
   --  ever the sleep half of what its name suggests.  It keeps the name
   --  because the spec is shared with a backend where it is both.
   procedure Flush
     (Shard    : Shard_Id;
      Wait_For : Natural;
      Status   : out Io_Result)
   is
      E       : Engine renames Engines_Data (Shard);
      Timeout : Win.Dword;
   begin
      Status := 0;

      if not E.Started then
         Status := -E_Again;
         return;
      end if;

      if Wait_For = 0 then
         return;
      end if;

      --  Anything already collected means there is no reason to sleep.
      if E.Pend_Count > 0 then
         return;
      end if;

      Timeout := (if E.Armed then E.Idle_Ms else Default_Sleep_Ms);
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

   --  Windows has nothing corresponding.  Registered files are an
   --  io_uring idea: a table the kernel indexes instead of looking a
   --  descriptor up, filled by accept and referenced by everything after
   --  it.  Nothing on the completion port takes an index in place of a
   --  handle, so every descriptor here is an ordinary one -- which is a
   --  path the whole runtime already supports.
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

   function Backend_Name return String is ("Windows IOCP");

   --  There is no ring here, so no ring carries anything.  The question the
   --  spec asks is whether the backend has a submission ring that the data
   --  plane goes through, and on Windows the answer is now simply no.
   procedure Ring_Carries_Sockets (Shard : Shard_Id; Yes : out Boolean) is
      pragma Unreferenced (Shard);
   begin
      Yes := False;
   end Ring_Carries_Sockets;

end Iour.Reactor;
