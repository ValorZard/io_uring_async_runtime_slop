with Interfaces; use Interfaces;
with Iour.Fibers;

package body Iour.Async with SPARK_Mode => On is

   procedure Perform (Spec : Reactor.Op_Spec; Result : out Io_Result) is
      Shard   : constant Shard_Ref := Fibers.Self;
      Me      : Fiber_Ref;
      Request : Reactor.Op_Spec := Spec;
      Queued  : Boolean;
   begin
      --  Suspending only means anything on a fiber: there is nothing to
      --  switch away from otherwise.
      if Shard not in Active_Shard then
         Result := -E_Invalid;
         return;
      end if;

      Fibers.Running_Fiber (Shard, Me);
      if Me = No_Fiber then
         Result := -E_Invalid;
         return;
      end if;

      --  A registered file is a slot in one ring's table.  Submitting it
      --  elsewhere would operate on whatever that ring's slot holds.
      if Request.Ring in Active_Shard and then Request.Ring /= Shard then
         Result := -E_Invalid;
         return;
      end if;

      --  The token names this fiber, not a future.  The completion is
      --  reaped by this shard, which puts the fiber straight back on its
      --  ready queue with the result beside it: nothing is allocated, no
      --  lock is taken, and the future table never hears about it.  That
      --  is safe because a fiber submits one operation and then sleeps
      --  until it completes, so there is never a second result to confuse
      --  it with -- and because the fiber cannot be resumed by anything
      --  else while it is in there: it holds no future for anyone to
      --  resolve.
      Request.Token :=
        Reactor.Encode (Reactor.Tag_Fiber_Io, Unsigned_32 (Me));

      loop
         Reactor.Push (Shard, Request, Queued);
         exit when Queued;

         --  The submission queue is momentarily full.  Hand the kernel what
         --  is already queued and let sibling fibers run while it drains;
         --  spinning here would stall the very loop that empties it.  The
         --  shard loop is where a failing flush gets counted.
         Reactor.Flush_Quietly (Shard);
         Fibers.Yield;
      end loop;

      --  The fiber stops here.  Its core moves on to other work and comes
      --  back to this exact point once the completion lands.
      Fibers.Await_Direct (Shard, Me, Result);
   end Perform;

end Iour.Async;
