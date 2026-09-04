------------------------------------------------------------------------------
--  Iour.Promises -- futures you resolve by hand.
--
--  Every future so far has been resolved by the kernel: an I/O completion
--  lands, the reactor resolves it, the waiting fiber resumes.  A promise is
--  the same future with the kernel taken out of the loop.  One side awaits
--  it; any other side -- another fiber on any shard, or the environment
--  task -- fulfils it, and the waiter wakes.
--
--  That makes it the synchronisation primitive for fibers, and the reason
--  a fiber never has to queue on a protected entry.  An entry call would
--  park the whole shard; awaiting a promise parks one fiber.
--
--     Done : Future_Ref;
--     Promises.Create (Done);
--     Fibers.Spawn (Worker'Access, Fiber_Argument (Done), Handle);
--     Promises.Await (Done, Result);          --  this fiber sleeps alone
--
--     ...and in Worker, when finished:
--     Promises.Fulfil (Future_Id (Arg), 0);   --  the awaiter resumes
--
--  A promise resolves once.  Fulfilling it again is ignored, and fulfilling
--  it before anyone awaits is fine: the value is kept until it is taken.
------------------------------------------------------------------------------

with Iour.Fibers;

package Iour.Promises with SPARK_Mode => On is

   --  A fresh, unresolved promise.  No_Future if the table is full.
   procedure Create (Handle : out Future_Ref);

   --  Resolve it and wake whoever is waiting.  Callable from any fiber and
   --  from the environment task.  A wake sent from a shard reaches its
   --  target immediately over MSG_RING; one sent from the environment task,
   --  which owns no ring, is picked up on the target shard's next pass, so
   --  within its idle backoff if it was asleep.
   procedure Fulfil (Handle : Future_Id; Value : Io_Result);

   --  Wait for it and take the value.  Must be called from a fiber.
   procedure Await (Handle : Future_Id; Result : out Io_Result)
     renames Fibers.Await;

   --  Give it up without waiting.  Safe on an already-released handle.
   procedure Discard (Handle : Future_Id);

end Iour.Promises;
