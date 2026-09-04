------------------------------------------------------------------------------
--  Iour.Futures -- the global, shard-agnostic future table.
--
--  A future is a slot in one statically sized table that every shard can
--  reach.  Handing out an index rather than a pointer is what lets the whole
--  runtime avoid access types and dynamic allocation, and it means a future
--  resolved on one core is trivially visible from another.
--
--  Two kinds of future share the table:
--
--    * an I/O future, created when an operation is submitted and resolved by
--      the shard that reaps its completion;
--    * a task future, created by Iour.Fibers.Spawn, carried on the global
--      run queue, and resolved when the spawned fiber returns.
--
--  A future has at most one waiter.  That is not a simplification for its
--  own sake: a fiber awaits one thing at a time, and forbidding fan-out
--  keeps wakeup a single assignment rather than a list walk.
------------------------------------------------------------------------------

package Iour.Futures with
  SPARK_Mode      => On,
  Abstract_State  => (Table with Synchronous, External),
  Initializes     => Table
is

   type Future_State is
     (Free,      --  slot is available
      Queued,    --  a task future waiting on the global run queue
      Pending,   --  work is under way; nobody has resolved it yet
      Ready);    --  resolved; Result is meaningful

   ---------------------------------------------------------------------------
   --  Allocation
   ---------------------------------------------------------------------------

   --  Take a slot.  Yields No_Future when the table is exhausted, which the
   --  caller must handle: this runtime never blocks waiting for a handle.
   procedure Acquire
     (Worker : Fiber_Ref;
      State  : Future_State;
      Handle : out Future_Ref)
     with Pre  => State in Queued | Pending,
          Global => (In_Out => Table);

   --  Return a slot to the pool.  Safe to call on an already-free slot so
   --  that error paths do not have to track ownership precisely.
   procedure Release (Handle : Future_Id)
     with Global => (In_Out => Table);

   ---------------------------------------------------------------------------
   --  Resolution
   ---------------------------------------------------------------------------

   --  Publish a result.  Reports the fiber that was waiting, if any, and the
   --  shard it must be resumed on -- a fiber may only ever run again on the
   --  shard whose ring holds its in-flight operations.
   procedure Resolve
     (Handle : Future_Id;
      Result : Io_Result;
      Waiter : out Fiber_Ref;
      Home   : out Shard_Ref)
     with Global => (In_Out => Table);

   --  Register the caller as the waiter, unless the future is already
   --  resolved (in which case Resolved is True and Result is meaningful).
   --  Doing both in one protected action is what closes the race between a
   --  fiber deciding to sleep and another core resolving the future
   --  underneath it.
   procedure Subscribe
     (Handle : Future_Id;
      Waiter : Fiber_Id;
      Home   : Shard_Id;
      Resolved : out Boolean;
      Result : out Io_Result)
     with Global => (In_Out => Table);

   --  Read a resolved future's result and free the slot in one step.
   procedure Take
     (Handle : Future_Id;
      Result : out Io_Result)
     with Global => (In_Out => Table);

   ---------------------------------------------------------------------------
   --  Task futures
   ---------------------------------------------------------------------------

   --  The fiber that will fulfil this future, for a future created by Spawn.
   procedure Worker_Of (Handle : Future_Id; Worker : out Fiber_Ref)
     with Global => (In_Out => Table);

   --  Move a queued task future to Pending as a shard adopts it.
   procedure Adopt (Handle : Future_Id; Worker : out Fiber_Ref)
     with Global => (In_Out => Table);

   ---------------------------------------------------------------------------
   --  Introspection
   ---------------------------------------------------------------------------

   procedure Stats (Live : out Natural; High_Water : out Natural)
     with Global => (In_Out => Table);

end Iour.Futures;
