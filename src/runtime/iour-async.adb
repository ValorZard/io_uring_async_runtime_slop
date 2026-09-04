with Interfaces; use Interfaces;
with Iour.Fibers;
with Iour.Futures;

package body Iour.Async with SPARK_Mode => On is

   procedure Perform (Spec : Reactor.Op_Spec; Result : out Io_Result) is
      Shard    : constant Shard_Ref := Fibers.Self;
      On_Fiber : constant Boolean := Fibers.In_Fiber;
      Handle  : Future_Ref;
      Request : Reactor.Op_Spec := Spec;
      Queued  : Boolean;
      Status  : Io_Result;
   begin
      --  Suspending only means anything on a fiber: there is nothing to
      --  switch away from otherwise.
      if Shard not in Active_Shard or else not On_Fiber then
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
         --  spinning here would stall the very loop that empties it.
         Reactor.Flush (Shard, 0, Status);
         Fibers.Yield;
      end loop;

      --  The fiber stops here.  Its core moves on to other work and comes
      --  back to this exact point once the completion lands.
      Fibers.Await (Handle, Result);
   end Perform;

end Iour.Async;
