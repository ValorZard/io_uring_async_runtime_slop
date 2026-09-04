with Iour.Futures;
with Iour.Trace;

package body Iour.Promises with SPARK_Mode => On is

   procedure Create (Handle : out Future_Ref) is
   begin
      Futures.Acquire (Worker => No_Fiber,
                       State  => Futures.Pending,
                       Handle => Handle);
   end Create;

   procedure Fulfil (Handle : Future_Id; Value : Io_Result) is
      Me     : constant Shard_Ref := Fibers.Self;
      Waiter : Fiber_Ref;
      Home   : Shard_Ref;
   begin
      Futures.Resolve (Handle, Value, Waiter, Home);
      Trace.Event (Me, "promise fulfilled", Integer (Handle));

      --  Nobody waiting yet: the value sits in the table until Await.
      if Waiter = No_Fiber or else Home not in Active_Shard then
         return;
      end if;

      if Me in Active_Shard then
         --  From a shard: local enqueue, or MSG_RING to the owning core.
         Fibers.Wake (Me, Waiter, Home);
      else
         --  From the environment task: no ring to send from, so leave it
         --  in the home shard's inbox for its next pass.
         Fibers.Post_Wake (Waiter, Home);
      end if;
   end Fulfil;

   procedure Discard (Handle : Future_Id) is
   begin
      Futures.Release (Handle);
   end Discard;

end Iour.Promises;
