------------------------------------------------------------------------------
--  Iour.Reactor -- one completion engine per shard, and the operations a
--  fiber submits to it.
--
--  This is the runtime's whole surface onto the operating system's
--  asynchronous I/O.  Everything above it -- Iour.Async, Iour.Net,
--  Iour.Time, Iour.Scheduler -- is written once and compiled unchanged on
--  every platform, because everything platform-shaped is behind this spec.
--
--  Two bodies implement it.
--
--    Linux, src/os/linux: one io_uring instance per shard, driven from
--    Ada.  Claiming a submission slot, filling in an operation, publishing
--    the tail with a release store and draining completions with an
--    acquire load are all written out rather than borrowed from liburing's
--    inline helpers; only io_uring_setup, io_uring_enter, io_uring_register
--    and mmap leave Ada.
--
--    Windows, src/os/windows: one IoRing per shard for the data plane,
--    with a completion port beside it for the operations IoRing has no
--    opcode for -- accept and connect -- and for shard-to-shard wakeups.
--    The port is also the single place the shard sleeps, which is what
--    keeps one loop rather than two.
--
--  A shard's engine is owned outright by that shard.  No other task
--  submits to it or reaps from it.  On Linux that is exactly what
--  IORING_SETUP_SINGLE_ISSUER wants; on Windows it is what makes the
--  IoRing submission queue, which is not thread-safe, safe to build
--  without a lock.  It is the same invariant either way, and it is why
--  submission needs no cross-core synchronisation at all.
--
--  The operation constructors below are plain functions returning a filled
--  in Op_Spec, so what each operation asks for is visible and checkable
--  rather than buried in a macro or a builder call.
------------------------------------------------------------------------------

with Interfaces; use Interfaces;
with System;
with Iour.Ffi;

--  Engines is every shard's reactor state: the descriptors and handles on
--  the Ada side and whatever the system shares with the runtime behind
--  them.  Synchronous because each engine has exactly one owning shard.
--
--  The bodies of this package are outside SPARK's analysable subset (they
--  must hand addresses to the kernel), so these contracts are what every
--  client is checked against.  They are the promise both bodies keep.
package Iour.Reactor with
  SPARK_Mode     => On,
  Abstract_State => (Engines with External, Synchronous),
  Initializes    => Engines
is

   ---------------------------------------------------------------------------
   --  Completion tokens
   ---------------------------------------------------------------------------

   --  Every submission carries 64 bits that the system echoes back
   --  unchanged.  The runtime splits them into a tag and a payload so that
   --  one completion stream can carry I/O results, cross-shard wakeups and
   --  timer expiries without a side table.
   type Token_Tag is
     (Tag_Future,     --  payload is a Future_Id: an awaited operation
      Tag_Fiber_Io,   --  payload is the Fiber_Id that submitted the
                      --  operation and is asleep on this shard until it
                      --  completes.  No future in between: the result
                      --  rides the ready queue straight to the fiber.
      Tag_Wake,       --  payload is a Fiber_Id biased by one, so that a
                      --  payload of zero means "nothing specific, just
                      --  look around"
      Tag_Msg_Send,   --  our own wakeup send completing; carries no news
      Tag_Timer,      --  the idle timer expired
      Tag_Unknown);   --  never produced; guards against a stale token

   function Encode (Tag : Token_Tag; Payload : Unsigned_32) return Unsigned_64
     with Pre => Tag /= Tag_Unknown, Global => null;

   procedure Decode
     (Token   : Unsigned_64;
      Tag     : out Token_Tag;
      Payload : out Unsigned_32)
     with Global => null, Always_Terminates;

   ---------------------------------------------------------------------------
   --  Operations
   ---------------------------------------------------------------------------

   --  What a submission asks for, in terms both systems can honour.  This
   --  used to be a flattened io_uring SQE; it is now the union of what the
   --  nine operations below actually need, which is smaller and says more.
   --  Each backend translates it: on Linux into an SQE, on Windows into an
   --  IoRing builder call, an overlapped Winsock call or a posted
   --  completion, depending on the kind.
   type Op_Kind is
     (Kind_Nop,
      Kind_Accept,
      Kind_Connect,
      Kind_Recv,
      Kind_Send,
      Kind_Write,
      Kind_Close,
      Kind_Timeout,
      Kind_Wake);

   type Op_Spec is record
      Kind : Op_Kind := Kind_Nop;

      --  What the operation acts on: a socket, a file, a standard stream.
      --  Unused by Kind_Timeout and Kind_Wake.
      Fd : Descriptor := Invalid_Descriptor;

      --  The bytes moved, or the sockaddr connected to.  Must stay valid
      --  until the completion arrives, which for a fiber's local variable
      --  is automatic: the fiber's stack is exactly what stays alive while
      --  it is suspended.
      Buffer : System.Address := System.Null_Address;
      Length : Natural := 0;

      --  Echoed back in the completion.  Filled in by Iour.Async, or by
      --  whatever submits directly.
      Token : Unsigned_64 := 0;

      --  Kind_Accept: install the accepted socket straight into this
      --  engine's registered file table and report the slot, rather than
      --  returning an ordinary descriptor.  Only meaningful where
      --  Has_Fixed_Files says the table exists.
      Direct : Boolean := False;

      --  Kind_Timeout: how long, from now.
      Nanoseconds : Unsigned_64 := 0;

      --  Kind_Wake: which shard to wake, and what its completion stream
      --  should show.  Naming the shard rather than a ring descriptor is
      --  what lets Linux send an IORING_OP_MSG_RING and Windows post to a
      --  completion port without the caller knowing which.
      Target       : Shard_Ref   := No_Shard;
      Target_Token : Unsigned_64 := 0;

      --  The engine an operation on a fixed file belongs to: a registered
      --  slot means nothing on any other shard.  No_Shard for an ordinary
      --  descriptor.  Iour.Async refuses to submit an operation whose Ring
      --  is not the calling shard, which is what keeps a slot number from
      --  ever being taken to another core's table.
      Ring : Shard_Ref := No_Shard;
   end record;

   --  Do nothing, but complete.  Useful for exercising the full submission
   --  and completion path without touching a descriptor.
   function Op_Nop (Token : Unsigned_64) return Op_Spec
     with Global => null, Post => Op_Nop'Result.Kind = Kind_Nop;

   --  Accept one connection.  The peer address is not collected: nothing in
   --  the runtime needs it, and asking for it would mean per-operation
   --  storage that has to outlive the submission.
   --
   --  Direct asks for the accepted socket to be installed straight into a
   --  free slot of this shard's registered file table, with the slot
   --  reported as the result.  The caller turns that into a descriptor
   --  with Fixed_File; only shards that registered a table
   --  (Has_Fixed_Files) can honour it.
   function Op_Accept
     (Fd     : Descriptor;
      Token  : Unsigned_64;
      Direct : Boolean := False) return Op_Spec
     with Global => null, Post => Op_Accept'Result.Kind = Kind_Accept;

   function Op_Connect
     (Fd      : Descriptor;
      Address : System.Address;
      Length  : Natural;
      Token   : Unsigned_64) return Op_Spec
     with Global => null, Post => Op_Connect'Result.Kind = Kind_Connect;

   function Op_Recv
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
     with Global => null, Post => Op_Recv'Result.Kind = Kind_Recv;

   function Op_Send
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
     with Global => null, Post => Op_Send'Result.Kind = Kind_Send;

   --  Close a descriptor.  For a fixed file this empties the slot; the
   --  socket goes once no operation refers to it any more.
   function Op_Close (Fd : Descriptor; Token : Unsigned_64) return Op_Spec
     with Global => null, Post => Op_Close'Result.Kind = Kind_Close;

   --  A write to something that is not a socket: stdout, stderr, a file.
   --  Writes at the current position.
   function Op_Write
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
     with Global => null, Post => Op_Write'Result.Kind = Kind_Write;

   --  Relative timeout.  Completes with -ETIME when it runs out.  Unlike
   --  the io_uring operation underneath it on Linux, this takes the
   --  interval by value, so no caller has to keep a timespec alive for the
   --  life of the operation.
   function Op_Timeout
     (Nanoseconds : Unsigned_64; Token : Unsigned_64) return Op_Spec
     with Global => null, Post => Op_Timeout'Result.Kind = Kind_Timeout;

   --  Put a completion into another shard's stream.  This is the whole
   --  cross-core wakeup mechanism: no shared queue, no condition variable,
   --  just a message that lands in the sibling's completion stream and pops
   --  it out of its sleep.  IORING_OP_MSG_RING on Linux,
   --  PostQueuedCompletionStatus on Windows.
   function Op_Wake
     (Target       : Shard_Id;
      Target_Token : Unsigned_64;
      Token        : Unsigned_64) return Op_Spec
     with Global => null, Post => Op_Wake'Result.Kind = Kind_Wake;

   ---------------------------------------------------------------------------
   --  Completions
   ---------------------------------------------------------------------------

   type Completion is record
      Token : Unsigned_64 := 0;
      Res   : Io_Result   := 0;
      Flags : Unsigned_32 := 0;
   end record;

   type Completion_Batch is array (0 .. Reap_Batch - 1) of Completion;

   ---------------------------------------------------------------------------
   --  Per-shard engine lifecycle and use
   ---------------------------------------------------------------------------

   --  Create this shard's engine.  Must be called by the shard task itself:
   --  both backends bind the engine to its creating thread.
   procedure Open (Shard : Shard_Id; Status : out Io_Result)
     with Global => (In_Out => (Engines, Ffi.Kernel)), Always_Terminates;

   procedure Shut (Shard : Shard_Id)
     with Global => (In_Out => (Engines, Ffi.Kernel)), Always_Terminates;

   --  Queue one operation.  Fails only when the submission queue is full,
   --  which the caller resolves by flushing and retrying.
   procedure Push (Shard : Shard_Id; Spec : Op_Spec; Queued : out Boolean)
     with Global => (In_Out => (Engines, Ffi.Kernel)), Always_Terminates;

   --  Hand queued submissions to the system, optionally sleeping until
   --  Wait_For completions are available.  This is the only place a shard
   --  ever blocks.
   procedure Flush
     (Shard    : Shard_Id;
      Wait_For : Natural;
      Status   : out Io_Result)
     with Global => (In_Out => (Engines, Ffi.Kernel)), Always_Terminates;

   --  Flush without reporting.  For callers that only want the queue moved
   --  along and will find out about a broken engine from the shard loop,
   --  which counts every flush failure.
   procedure Flush_Quietly (Shard : Shard_Id)
     with Global => (In_Out => (Engines, Ffi.Kernel)), Always_Terminates;

   --  Copy out everything the system has finished, releasing the completion
   --  slots in one step rather than one at a time.
   procedure Harvest
     (Shard : Shard_Id;
      Batch : out Completion_Batch;
      Count : out Natural)
     with Post => Count <= Reap_Batch,
          Global => (In_Out => (Engines, Ffi.Kernel)), Always_Terminates;

   --  Operations submitted but not yet completed.  A shard with none of
   --  these and nothing runnable has no reason to stay awake.
   --
   --  A procedure rather than a function: it reads shared state, and SPARK
   --  does not allow a function to have a synchronized global.
   procedure In_Flight (Shard : Shard_Id; Count : out Natural)
     with Global => (In_Out => Engines), Always_Terminates;

   ---------------------------------------------------------------------------
   --  Registered files
   ---------------------------------------------------------------------------

   --  Where the system supports it, every engine registers a sparse file
   --  table of Max_Fibers slots when it opens, so that a socket accepted on
   --  a core can live in that core's table for its whole life: the kernel
   --  then pins the file once, and each operation on it skips the
   --  descriptor-table lookup and the reference count that a plain
   --  descriptor pays every time.  This reports whether that happened.
   --
   --  It is False on Windows, where accept is a completion-port operation
   --  rather than a ring one and there is no table for it to fill, and on
   --  a Linux kernel that refuses the registration.  Both leave the runtime
   --  on ordinary descriptors, which is the path every caller already has.
   procedure Has_Fixed_Files (Shard : Shard_Id; Yes : out Boolean)
     with Global => (In_Out => Engines), Always_Terminates;

   --  Empty one slot of this shard's table synchronously, closing the
   --  socket if nothing else holds it.  For contexts that cannot suspend
   --  on an Op_Close; must be called on the owning shard's own thread.
   procedure Unregister_File
     (Shard : Shard_Id; Slot : File_Slot; Status : out Io_Result)
     with Global => (In_Out => (Engines, Ffi.Kernel)), Always_Terminates;

   --  Deepest backoff level Arm_Idle_Timer accepts.
   Max_Backoff : constant := 7;

   --  Arm the idle timer so a shard asleep with nothing in flight still
   --  re-checks the global run queue.  Level 0 waits Idle_Poll_Nanos and
   --  each step doubles it, up to Max_Backoff.
   --
   --  This timer is a safety net, not the wakeup path.  Work handed over by
   --  another shard arrives immediately as a Kind_Wake completion; the
   --  timer exists for work published by a thread that owns no engine and
   --  so cannot send one, which in practice means the environment task at
   --  startup.  Backing off keeps a genuinely idle core near-silent instead
   --  of waking it a thousand times a second for nothing.
   procedure Arm_Idle_Timer
     (Shard : Shard_Id; Level : Natural := 0)
     with Pre => Level <= Max_Backoff,
          Global => (In_Out => (Engines, Ffi.Kernel)), Always_Terminates;

   ---------------------------------------------------------------------------
   --  Reporting
   ---------------------------------------------------------------------------

   --  Which backend this build got, for the banner a server prints at
   --  start-up.  A compile-time fact, so a plain function.
   function Backend_Name return String with Global => null;

   --  Whether this shard's data plane is actually going through the
   --  system's ring, as opposed to a fallback beside it.
   --
   --  On Linux this is true from the moment the ring opens: io_uring has an
   --  opcode for every operation the runtime submits.  On Windows it starts
   --  true and turns false for good the first time the IoRing refuses a
   --  socket -- IoRing has read and write but no accept, connect, recv or
   --  send of its own, so whether a socket handle can be read through it at
   --  all is something only the running system can answer.  Once it has
   --  answered no, that shard's socket traffic goes through overlapped
   --  Winsock on the completion port instead, and this says so.
   --
   --  Reads state the owning shard publishes, so ask after Wait_Until_Ready.
   procedure Ring_Carries_Sockets (Shard : Shard_Id; Yes : out Boolean)
     with Global => (In_Out => Engines), Always_Terminates;

end Iour.Reactor;
