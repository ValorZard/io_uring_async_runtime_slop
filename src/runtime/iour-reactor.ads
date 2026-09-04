------------------------------------------------------------------------------
--  Iour.Reactor -- one io_uring instance per shard, driven from Ada.
--
--  This is the part liburing normally hides behind inline functions, written
--  out in Ada instead: claiming a submission slot, filling in an operation,
--  publishing the tail with a release store, and draining completions with
--  an acquire load.  The kernel side of that protocol is UAPI, so nothing
--  here depends on liburing's internal layout; the only calls that leave Ada
--  are io_uring_setup, io_uring_enter, mmap and munmap.
--
--  A ring is owned outright by the shard that created it.  No other task
--  submits to it or reaps from it, which is precisely the promise
--  IORING_SETUP_SINGLE_ISSUER wants and is why submission needs no
--  cross-core synchronisation at all.
--
--  The operation constructors below mirror liburing's io_uring_prep_*
--  helpers.  They are plain functions returning a filled-in Op_Spec, so the
--  encoding of each opcode is visible and checkable rather than buried in a
--  macro.
------------------------------------------------------------------------------

with Interfaces; use Interfaces;
with System;
with Iour.Ffi;
with Iour.Ffi.Uring;

--  Rings is every shard's ring state: the protected descriptors on the Ada
--  side and the memory shared with the kernel behind them.  Synchronous
--  because each ring is a protected object and is touched by one shard.
--
--  The body of this package is outside SPARK's analysable subset (it must
--  hand addresses to the kernel), so these contracts are what every client
--  is checked against.  They are the promise the body keeps.
package Iour.Reactor with
  SPARK_Mode     => On,
  Abstract_State => (Rings with External, Synchronous),
  Initializes    => Rings
is

   ---------------------------------------------------------------------------
   --  Completion tokens
   ---------------------------------------------------------------------------

   --  Every submission carries 64 bits that the kernel echoes back
   --  unchanged.  The runtime splits them into a tag and a payload so that
   --  one completion stream can carry I/O results, cross-shard wakeups and
   --  timer expiries without a side table.
   type Token_Tag is
     (Tag_Future,     --  payload is a Future_Id: an awaited operation
      Tag_Wake,       --  payload is a Fiber_Id biased by one, so that a
                      --  payload of zero means "nothing specific, just
                      --  look around"
      Tag_Msg_Send,   --  our own MSG_RING send completing; carries no news
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

   --  A submission, in the kernel's own terms.  Building this rather than
   --  calling a prep function keeps every field the kernel reads in one
   --  place, next to the constructor that sets it.
   type Op_Spec is record
      Opcode    : Unsigned_8  := Ffi.Uring.Op_Nop;
      Sqe_Flags : Unsigned_8  := 0;
      Fd        : Integer_32  := -1;
      Off       : Unsigned_64 := 0;
      Addr      : Unsigned_64 := 0;
      Length    : Unsigned_32 := 0;
      Op_Flags  : Unsigned_32 := 0;
      Token     : Unsigned_64 := 0;
   end record;

   --  Do nothing, but complete.  Useful for exercising the full submission
   --  and completion path without touching a descriptor.
   function Op_Nop (Token : Unsigned_64) return Op_Spec
     with Global => null;

   --  Accept one connection.  The peer address is not collected: nothing in
   --  the runtime needs it, and asking for it would mean per-operation
   --  storage that has to outlive the submission.
   function Op_Accept (Fd : Descriptor; Token : Unsigned_64) return Op_Spec
     with Global => null;

   function Op_Connect
     (Fd      : Descriptor;
      Address : System.Address;
      Length  : Natural;
      Token   : Unsigned_64) return Op_Spec
     with Global => null;

   function Op_Recv
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
     with Global => null;

   function Op_Send
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
     with Global => null;

   function Op_Close (Fd : Descriptor; Token : Unsigned_64) return Op_Spec
     with Global => null;

   --  write(2) through the ring, for descriptors that are not sockets:
   --  stdout, stderr, files.  Writes at the current file position.
   function Op_Write
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
     with Global => null;

   --  Relative timeout.  Completes with -ETIME when it runs out.  The
   --  timespec must stay put until the completion arrives, so callers pass
   --  the address of something that outlives the operation, never a local.
   function Op_Timeout
     (Timespec : System.Address; Token : Unsigned_64) return Op_Spec
     with Global => null;

   --  Post a completion on another shard's ring.  This is the whole
   --  cross-core wakeup mechanism: no shared queue, no eventfd, no
   --  condition variable, just a message that lands in the sibling's
   --  completion stream and pops it out of its sleep.
   function Op_Msg_Ring
     (Target_Ring : Descriptor;
      Target_Token : Unsigned_64;
      Token        : Unsigned_64) return Op_Spec
     with Global => null;

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
   --  Per-shard ring lifecycle and use
   ---------------------------------------------------------------------------

   --  Create this shard's ring.  Must be called by the shard task itself:
   --  IORING_SETUP_SINGLE_ISSUER binds the ring to its creating thread.
   procedure Open (Shard : Shard_Id; Status : out Io_Result)
     with Global => (In_Out => (Rings, Ffi.Kernel)), Always_Terminates;

   procedure Shut (Shard : Shard_Id)
     with Global => (In_Out => (Rings, Ffi.Kernel)), Always_Terminates;

   --  Queue one operation.  Fails only when the submission queue is full,
   --  which the caller resolves by flushing and retrying.
   procedure Push (Shard : Shard_Id; Spec : Op_Spec; Queued : out Boolean)
     with Global => (In_Out => Rings), Always_Terminates;

   --  Hand queued submissions to the kernel, optionally sleeping until
   --  Wait_For completions are available.  This is the only system call on
   --  the hot path, and the only place a shard ever blocks.
   procedure Flush
     (Shard    : Shard_Id;
      Wait_For : Natural;
      Status   : out Io_Result)
     with Global => (In_Out => (Rings, Ffi.Kernel)), Always_Terminates;

   --  Flush without reporting.  For callers that only want the queue moved
   --  along and will find out about a broken ring from the shard loop,
   --  which counts every flush failure.
   procedure Flush_Quietly (Shard : Shard_Id)
     with Global => (In_Out => (Rings, Ffi.Kernel)), Always_Terminates;

   --  Copy out everything the kernel has finished, releasing the completion
   --  slots in one step rather than one at a time.
   procedure Harvest
     (Shard : Shard_Id;
      Batch : out Completion_Batch;
      Count : out Natural)
     with Post => Count <= Reap_Batch,
          Global => (In_Out => Rings), Always_Terminates;

   --  Operations submitted but not yet completed.  A shard with none of
   --  these and nothing runnable has no reason to stay awake.
   --
   --  A procedure rather than a function: it reads protected state, and
   --  SPARK does not allow a function to have a synchronized global.
   procedure In_Flight (Shard : Shard_Id; Count : out Natural)
     with Global => (In_Out => Rings), Always_Terminates;

   --  This ring's descriptor, which a sibling needs in order to message it.
   procedure Ring_Descriptor (Shard : Shard_Id; Fd : out Descriptor)
     with Global => (In_Out => Rings), Always_Terminates;

   --  Deepest backoff level Arm_Idle_Timer accepts.
   Max_Backoff : constant := 7;

   --  Arm the idle timer so a shard asleep on an empty ring still re-checks
   --  the global run queue.  Level 0 waits Idle_Poll_Nanos and each step
   --  doubles it, up to Max_Backoff.
   --
   --  This timer is a safety net, not the wakeup path.  Work handed over by
   --  another shard arrives immediately over MSG_RING; the timer exists for
   --  work published by a thread that owns no ring and so cannot send one,
   --  which in practice means the environment task at startup.  Backing off
   --  keeps a genuinely idle core near-silent instead of waking it a
   --  thousand times a second for nothing.
   procedure Arm_Idle_Timer
     (Shard : Shard_Id; Level : Natural := 0)
     with Pre => Level <= Max_Backoff,
          Global => (In_Out => Rings), Always_Terminates;

end Iour.Reactor;
