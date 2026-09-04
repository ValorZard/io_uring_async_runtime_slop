------------------------------------------------------------------------------
--  Iour.Async -- the one primitive every asynchronous operation is built
--  from: submit to this shard's ring, suspend the fiber, resume with the
--  result.
--
--  Iour.Net and Iour.Time are both thin layers over Perform.  Anything else
--  io_uring can do is added the same way: build an Op_Spec, call Perform,
--  and the suspension, the wakeup and the shard bookkeeping come for free.
------------------------------------------------------------------------------

with Iour.Reactor;

package Iour.Async with SPARK_Mode => On is

   --  Submit Spec on the calling fiber's shard and wait for its completion.
   --  The Token field of Spec is filled in by this call and any value in it
   --  is ignored.
   --
   --  Must be called from a fiber; yields -EINVAL otherwise.  Any memory
   --  the operation refers to -- a buffer, a socket address, a timespec --
   --  has to stay valid until this returns, which a local variable of the
   --  fiber body does automatically.
   procedure Perform
     (Spec : Reactor.Op_Spec; Result : out Io_Result);

end Iour.Async;
