------------------------------------------------------------------------------
--  Iour.Futures -- the shard-agnostic future table, banked per core.
--
--  A future is a slot in one statically sized table that every shard can
--  reach.  Handing out an index rather than a pointer is what lets the whole
--  runtime avoid access types and dynamic allocation, and it means a future
--  resolved on one core is trivially visible from another.
--
--  The table is split into one bank per shard, each its own protected
--  object.  Which bank a handle belongs to is fixed by the handle itself,
--  so "any shard can resolve any future" still holds exactly as before --
--  what changes is that the common case does not have to.  An I/O future is
--  acquired, subscribed to, resolved and released by the same core in the
--  overwhelming majority of cases, and all four of those now take a lock no
--  other core is contending for.  Before, every operation on every core
--  serialised through one lock: four cores bought 1.6x the throughput of
--  one, and eight bought less than four did.
--
--  Acquire therefore takes the caller's shard.  It is a preference, not a
--  constraint: a caller whose own bank is full falls through to the others,
--  so a lopsided workload still gets the whole table rather than a quarter
--  of it.
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

   --  Take a slot, preferring the bank belonging to Near -- pass the
   --  caller's own shard, or No_Shard from a thread that has none.  Yields
   --  No_Future only when every bank is exhausted, which the caller must
   --  handle: this runtime never blocks waiting for a handle.
   procedure Acquire
     (Near   : Shard_Ref;
      Worker : Fiber_Ref;
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

   --  Summed across the banks.  Live is exact; High_Water is the sum of the
   --  banks' own high-water marks, so it is an upper bound on the number
   --  ever live at one instant rather than a reading of it.
   procedure Stats (Live : out Natural; High_Water : out Natural)
     with Global => (In_Out => Table),
          Post   => Live <= Max_Futures and then High_Water <= Max_Futures;

end Iour.Futures;
