------------------------------------------------------------------------------
--  Iour.Fibers -- stackful green threads, and the Await that suspends them.
--
--  A fiber is a slot in a fixed table plus a stack of its own.  Because it
--  has a real stack, suspending is just a matter of saving the machine
--  context and restoring another one, and Await can therefore be an
--  ordinary function call:
--
--     Bytes := Net.Receive (Conn, Buffer);   --  suspends, resumes, returns
--
--  There is no async colouring here, no continuation to write, no state
--  machine to hand-roll.  Code that reads top to bottom runs top to bottom;
--  it just happens to let the core do other things in the gaps.  This is
--  the model Seastar exposes as seastar::thread, and the reason it is worth
--  the cost of a stack per task.
--
--  A fiber is bound to a shard the moment one adopts it, and stays there.
--  It has to: its in-flight operations sit in that shard's ring, and only
--  that shard will ever see their completions.
--
--  Stacks are allocated lazily and never returned to the OS while running.
--  A fiber slot that has finished keeps its mapping for the next occupant,
--  so accepting a connection after the first costs no system call.
------------------------------------------------------------------------------

package Iour.Fibers with
  SPARK_Mode     => On,
  Abstract_State =>
    ((Registry with Synchronous, External),

     --  Scheduling is the lock-free half: atomic arrays holding which CPU
     --  belongs to which shard, which fiber each shard is running, and
     --  which shards are asleep.  Each is written by other tasks
     --  (Async_Writers) but nothing outside the program reads them
     --  (Async_Readers => False) and reading one has no side effect
     --  (Effective_Reads => False) -- which is what lets Self and
     --  Running_Fiber be functions rather than procedures with an out
     --  parameter, and keeps them off the critical path of every Await.
     (Scheduling with External => (Async_Writers => True))),
  Initializes    => (Registry, Scheduling)
is

   type Fiber_State is
     (Slot_Free,   --  unused table entry
      Runnable,    --  ready to be resumed
      Running,     --  currently on a core
      Suspended,   --  waiting for a future
      Completed);  --  body returned; slot is about to be recycled

   ---------------------------------------------------------------------------
   --  Identity
   ---------------------------------------------------------------------------

   --  Which shard the calling thread is.  Every shard is pinned to its own
   --  core, so the CPU number the kernel reports is a sufficient and very
   --  cheap identity -- no thread-local storage, no registration lookup.
   --  Returns No_Shard when called from a thread that is not a shard, such
   --  as the environment task.
   function Self return Shard_Ref
     with Volatile_Function, Global => (Input => Scheduling);

   --  The fiber currently on this shard's core, or No_Fiber between fibers.
   function Running_Fiber (Shard : Shard_Id) return Fiber_Ref
     with Volatile_Function, Global => (Input => Scheduling);

   --  Claim a CPU as belonging to a shard.  Called once, by the shard.
   procedure Claim_Cpu (Shard : Shard_Id; Ok : out Boolean)
     with Global => (In_Out => Scheduling);

   ---------------------------------------------------------------------------
   --  Creating work
   ---------------------------------------------------------------------------

   --  Create a fiber and publish it on the global run queue, returning the
   --  future that resolves when it finishes.  Callable from any shard and
   --  from the environment task.
   --
   --  Yields No_Future if the fiber table, the future table or the run
   --  queue is full.  The runtime never blocks to obtain a handle: doing so
   --  on a shard would stall the very core that could free one.
   procedure Spawn
     (Work   : Fiber_Body;
      Arg    : Fiber_Argument;
      Handle : out Future_Ref)
     with Pre => Work /= null;

   ---------------------------------------------------------------------------
   --  Suspension
   ---------------------------------------------------------------------------

   --  Wait for a future and consume it.  Must be called from a fiber.
   --
   --  If the future is already resolved this returns without suspending.
   --  Otherwise the calling fiber is registered as the waiter and the core
   --  switches to the shard's scheduler, which runs other fibers and polls
   --  the ring; the call returns once the future has been resolved.
   procedure Await (Handle : Future_Id; Result : out Io_Result);

   --  Give the core up without waiting for anything, so a fiber in a long
   --  computation does not starve its shard.
   procedure Yield;

   --  True when the caller is running on a fiber, and so may Await.
   function In_Fiber return Boolean with Volatile_Function;

   ---------------------------------------------------------------------------
   --  Scheduler-facing operations
   ---------------------------------------------------------------------------
   --  Used by Iour.Scheduler; not part of the application-facing API.

   --  Take a task future off the global queue and make its fiber runnable
   --  on this shard, allocating and priming a stack for it.
   procedure Adopt
     (Shard   : Active_Shard;
      Handle  : Future_Id;
      Started : out Boolean);

   --  Switch the core into a runnable fiber.  Returns when that fiber
   --  suspends, yields or finishes.
   procedure Resume (Shard : Shard_Id; Fiber : Fiber_Id);

   --  Tidy up after Resume: recycle the slot if the fiber finished.
   procedure After_Resume (Shard : Shard_Id; Fiber : Fiber_Id);

   procedure Push_Ready
     (Shard : Shard_Id; Fiber : Fiber_Id; Accepted : out Boolean);
   procedure Pop_Ready (Shard : Shard_Id; Fiber : out Fiber_Ref);
   procedure Ready_Depth (Shard : Shard_Id; Count : out Natural);

   --  Where a fiber must be resumed.
   procedure Home_Of (Fiber : Fiber_Id; Shard : out Shard_Ref);

   --  Make a suspended fiber runnable again after its future resolved.
   --  When the fiber belongs to another shard this goes out as a MSG_RING
   --  submission, which lands in that shard's completion stream and lifts
   --  it out of io_uring_enter without any shared lock.
   procedure Wake
     (From : Shard_Id; Fiber : Fiber_Id; Home : Shard_Id);

   --  Record that a shard is about to sleep, or has woken.  Spawn consults
   --  this to decide whom to nudge.
   procedure Set_Idle (Shard : Shard_Id; Idle : Boolean)
     with Global => (In_Out => Scheduling);

   procedure Live_Fibers (Count : out Natural; High_Water : out Natural);

   ---------------------------------------------------------------------------
   --  Startup
   ---------------------------------------------------------------------------

   --  Verify that the Ada context record and the C one agree before any
   --  fiber is created.
   function Context_Layout_Matches return Boolean;

   --  Release every stack.  Called once, after the shards have stopped.
   procedure Release_All_Stacks;

end Iour.Fibers;
