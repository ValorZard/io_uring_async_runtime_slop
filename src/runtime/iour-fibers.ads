------------------------------------------------------------------------------
--  Iour.Fibers -- stackful green threads, and the Await that suspends them.
--
--  A fiber is a slot in a fixed table plus a stack of its own.  Because it
--  has a real stack, suspending is just a matter of saving one machine
--  context and restoring another, and Await can therefore be an ordinary
--  function call:
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
--
--  Mutable state here is of two kinds.  What two shards can contend for --
--  the fiber table, a ready queue, an inbox -- is protected-object state,
--  one object per shard where the design allows it so the lock a shard takes
--  on its own path is uncontended.  What only a shard itself ever touches --
--  which fiber is on its core, why the last one gave the core back -- is an
--  atomic cell per shard (Iour.Per_Shard), with no lock at all: an
--  uncontended protected action still costs a mutex round trip each way,
--  and the hot path was taking a dozen of them per I/O operation.  Machine
--  contexts are not this package's state: they live in Iour.Ffi.Fiber and
--  are named by slot index, which is what leaves this package with nothing
--  to race over and no address to hand out.
------------------------------------------------------------------------------

package Iour.Fibers with
  SPARK_Mode     => On,
  Abstract_State => (Registry with Synchronous, External),
  Initializes    => Registry
is

   ---------------------------------------------------------------------------
   --  Identity
   ---------------------------------------------------------------------------

   --  Which shard the calling thread is.
   --
   --  Shard N is pinned to Ada CPU First_Shard_Cpu + N by a static aspect,
   --  and Ada numbers CPUs from one where Linux numbers them from zero, so
   --  the answer is arithmetic on the CPU the kernel reports.  No lookup
   --  table, so nothing to keep in step and nothing for two shards to race
   --  over.  Yields No_Shard on any thread that is not a shard, including
   --  the environment task.
   function Self return Shard_Ref
     with Global => null;

   --  Confirm a shard is running on the core its CPU aspect promised.
   --  Purely a check: it records nothing.
   procedure Verify_Cpu (Shard : Active_Shard; Ok : out Boolean)
     with Global => null;

   --  The fiber currently on this shard's core, or No_Fiber between fibers.
   procedure Running_Fiber (Shard : Shard_Id; Fiber : out Fiber_Ref);

   ---------------------------------------------------------------------------
   --  Start-up
   ---------------------------------------------------------------------------

   --  Whether the machine-context slot table was reserved successfully.
   --  The table is built during elaboration, which sequential elaboration
   --  guarantees happens before any task is activated; this only reports
   --  the outcome, so shards can refuse to start rather than prime a slot
   --  that does not exist.
   procedure Reserve_Contexts (Ok : out Boolean);

   --  Slots the context table currently holds, for reporting.
   procedure Context_Slots (Count : out Natural)
     with Global => null;

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

   --  Await for the fiber that registered itself as the waiter when it
   --  acquired the future, and has just submitted the operation behind it
   --  to this shard's ring.  Such a future cannot resolve before this
   --  shard's scheduler runs again -- only this shard reaps this ring -- so
   --  the fiber goes straight to sleep, with no trip through the future's
   --  lock on the way in.  Iour.Async is the caller; anything else should
   --  use Await, which makes no such assumption.
   procedure Await_Submitted
     (Shard  : Active_Shard;
      Me     : Fiber_Id;
      Handle : Future_Id;
      Result : out Io_Result);

   ---------------------------------------------------------------------------
   --  Scheduler-facing operations
   ---------------------------------------------------------------------------
   --  Used by Iour.Scheduler; not part of the application-facing API.

   --  Take a task future off the global queue and make its fiber runnable
   --  on this shard, allocating and priming a stack for it.
   procedure Adopt
     (Shard   : Shard_Id;
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
   procedure Wake (From : Shard_Id; Fiber : Fiber_Id; Home : Shard_Id);

   --  Hand a fiber back to its home shard from a thread that owns no ring,
   --  which means the environment task.  The fiber is not put on the ready
   --  queue directly: only a shard may enqueue onto its own ready queue, or
   --  a fiber caught between registering as a waiter and switching out
   --  could be queued twice.  It goes into the shard's inbox instead, and
   --  the shard converts it to a local Wake on its next pass -- within the
   --  idle backoff if it was asleep.
   procedure Post_Wake (Fiber : Fiber_Id; Home : Shard_Id);

   --  Whether anything may have been posted since the last drain, cleared
   --  by the asking.  The shard loop asks this every pass; the answer is an
   --  atomic read, so an empty inbox costs no lock.  Cleared before the
   --  drain rather than after, so a post that lands during the drain is
   --  seen on the next pass rather than lost.
   procedure Inbox_Pending (Shard : Shard_Id; Pending : out Boolean);

   --  Drain one posted wakeup, or No_Fiber.  Called by the owning shard.
   procedure Take_Posted (Shard : Shard_Id; Fiber : out Fiber_Ref);

   --  Record that a shard is about to sleep, or has woken.  Spawn consults
   --  this to decide whom to nudge.
   procedure Set_Idle (Shard : Shard_Id; Idle : Boolean);

   procedure Live_Fibers (Count : out Natural; High_Water : out Natural);

   --  Release every stack.  Called once, after the shards have stopped.
   procedure Release_All_Stacks;

end Iour.Fibers;
