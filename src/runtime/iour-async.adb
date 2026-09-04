with Interfaces; use Interfaces;
with Iour.Fibers;
with Iour.Futures;

package body Iour.Async with SPARK_Mode => On is

   procedure Perform (Spec : Reactor.Op_Spec; Result : out Io_Result) is
      Shard   : constant Shard_Ref := Fibers.Self;
      Me      : Fiber_Ref;
      Handle  : Future_Ref;
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

      Futures.Acquire (Worker => No_Fiber,
                       State  => Futures.Pending,
                       Handle => Handle);
      if Handle = No_Future then
         --  The future table is full.  Report it rather than wait: the core
         --  that would free a slot is this one.
         Result := -E_Again;
         return;
      end if;

      Request.Token :=
        Reactor.Encode (Reactor.Tag_Future, Unsigned_32 (Handle));

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
      Fibers.Await (Handle, Result);
   end Perform;

end Iour.Async;
