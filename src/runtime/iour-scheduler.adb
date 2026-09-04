with Interfaces; use Interfaces;
with Iour.Fibers;
with Iour.Futures;
with Iour.Reactor;
with Iour.Run_Queue;

package body Iour.Scheduler with SPARK_Mode => On is

   --  How many fibers a shard resumes before going back to check the ring.
   --  Without a bound, a stream of always-runnable fibers would starve
   --  completion harvesting and the shard would stop doing I/O.
   Resume_Budget : constant := 256;

   --  Idle passes a shard will spend waiting for in-flight operations to
   --  come back after shutdown is requested.  Draining is the normal path;
   --  this bound is what stops one operation that never completes -- a
   --  pending accept nobody connects to, say -- from hanging the process.
   Drain_Passes : constant := 64;

   type Counter_Array is array (Shard_Id) of Natural;

   ---------------------------------------------------------------------------
   --  Control -- startup barrier, shutdown flag and tallies
   ---------------------------------------------------------------------------

   protected Control is

      procedure Ring_Up;
      entry Await_Ready;

      procedure Request_Stop;
      function Stopping return Boolean;

      procedure Shard_Finished;
      entry Await_All_Stopped;

      procedure Tally
        (Shard       : Shard_Id;
         Completions : Natural;
         Fibers_Run  : Natural;
         Adopted     : Natural;
         Slept       : Natural;
         Left_Over   : Natural);

      procedure Read
        (Shard       : Shard_Id;
         Completions : out Natural;
         Fibers_Run  : out Natural;
         Adopted     : out Natural;
         Slept       : out Natural;
         Left_Over   : out Natural);

   private
      Rings_Up  : Natural := 0;
      Stopped   : Natural := 0;
      Stop_Flag : Boolean := False;

      N_Completions : Counter_Array := [others => 0];
      N_Fibers      : Counter_Array := [others => 0];
      N_Adopted     : Counter_Array := [others => 0];
      N_Sleeps      : Counter_Array := [others => 0];
      N_Abandoned   : Counter_Array := [others => 0];
   end Control;

   protected body Control is

      procedure Ring_Up is
      begin
         if Rings_Up < Shard_Count then
            Rings_Up := Rings_Up + 1;
         end if;
      end Ring_Up;

      --  Jorvik allows a barrier like this and lets more than one caller
      --  queue on it; Ravenscar would not.
      entry Await_Ready when Rings_Up = Shard_Count is
      begin
         null;
      end Await_Ready;

      procedure Request_Stop is
      begin
         Stop_Flag := True;
      end Request_Stop;

      function Stopping return Boolean is (Stop_Flag);

      procedure Shard_Finished is
      begin
         if Stopped < Shard_Count then
            Stopped := Stopped + 1;
         end if;
      end Shard_Finished;

      entry Await_All_Stopped when Stopped = Shard_Count is
      begin
         null;
      end Await_All_Stopped;

      procedure Tally
        (Shard       : Shard_Id;
         Completions : Natural;
         Fibers_Run  : Natural;
         Adopted     : Natural;
         Slept       : Natural;
         Left_Over   : Natural) is
      begin
         N_Completions (Shard) := Completions;
         N_Fibers (Shard)      := Fibers_Run;
         N_Adopted (Shard)     := Adopted;
         N_Sleeps (Shard)      := Slept;
         N_Abandoned (Shard)   := Left_Over;
      end Tally;

      procedure Read
        (Shard       : Shard_Id;
         Completions : out Natural;
         Fibers_Run  : out Natural;
         Adopted     : out Natural;
         Slept       : out Natural;
         Left_Over   : out Natural) is
      begin
         Completions := N_Completions (Shard);
         Fibers_Run  := N_Fibers (Shard);
         Adopted     := N_Adopted (Shard);
         Slept       := N_Sleeps (Shard);
         Left_Over   := N_Abandoned (Shard);
      end Read;

   end Control;

   ---------------------------------------------------------------------------
   --  Dispatching one completion
   ---------------------------------------------------------------------------

   --  Useful reports whether this completion actually advanced any work.
   --  A timer expiry or our own message completing did not, and must not
   --  reset the idle backoff -- otherwise a shard waiting on its own poll
   --  timer would keep re-arming it at the shortest interval for ever.
   procedure Dispatch
     (Shard : Shard_Id; Item : Reactor.Completion; Useful : out Boolean)
   is
      Tag     : Reactor.Token_Tag;
      Payload : Unsigned_32;
      Waiter  : Fiber_Ref;
      Home    : Shard_Ref;
      Fiber   : Fiber_Ref;
   begin
      Useful := False;
      Reactor.Decode (Item.Token, Tag, Payload);

      case Tag is

         when Reactor.Tag_Future =>
            --  An awaited operation finished.  Publishing the result may
            --  hand back a fiber to resume, possibly on another core.
            if Payload <= Unsigned_32 (Future_Id'Last) then
               Futures.Resolve
                 (Future_Id (Payload), Item.Res, Waiter, Home);
               Useful := True;
               if Waiter /= No_Fiber and then Home in Active_Shard then
                  Fibers.Wake (Shard, Waiter, Home);
               end if;
            end if;

         when Reactor.Tag_Wake =>
            --  A sibling handed a fiber back to us, or simply nudged us
            --  awake so we would notice the global queue.
            if Payload > 0
              and then Payload - 1 <= Unsigned_32 (Fiber_Id'Last)
            then
               Fiber := Fiber_Ref (Payload - 1);
               Fibers.Wake (Shard, Fiber, Shard);
               Useful := True;
            end if;

         when Reactor.Tag_Msg_Send | Reactor.Tag_Timer
            | Reactor.Tag_Unknown =>
            --  Our own message completing, the idle timer expiring, or a
            --  token from an abandoned operation.  All three mean only
            --  "go round the loop again", which is what we are doing.
            null;
      end case;
   end Dispatch;

   ---------------------------------------------------------------------------
   --  Run
   ---------------------------------------------------------------------------

   procedure Run (Shard : Shard_Id) is
      Batch   : Reactor.Completion_Batch;
      Count   : Natural;
      Status  : Io_Result;
      Pinned  : Boolean;

      Progress : Boolean;
      Useful   : Boolean;
      Item     : Future_Ref;
      Fiber    : Fiber_Ref;
      Started  : Boolean;
      Ready    : Natural;
      Queued   : Natural;
      Outstanding : Natural := 0;
      Stop_Requested : Boolean := False;
      Resumed  : Natural;

      N_Completions : Natural := 0;
      N_Fibers      : Natural := 0;
      N_Adopted     : Natural := 0;
      N_Sleeps      : Natural := 0;

      Draining  : Natural := 0;
      Abandoned : Natural := 0;

      --  Consecutive idle passes, which sets how long the shard is willing
      --  to sleep before looking around again.
      Idle_Streak : Natural := 0;
   begin
      --  Shards past Shard_Count take no part.  Returning here, rather than
      --  narrowing the index at the call site, is what keeps the surplus
      --  task declarations in Iour.Shards free of any conversion that could
      --  fail.
      if Shard not in Active_Shard then
         return;
      end if;

      --  Establish this thread's identity before anything can Await.  The
      --  CPU it reports is fixed for the life of the task, because the
      --  static CPU aspect pinned it there.
      Fibers.Claim_Cpu (Shard, Pinned);

      Reactor.Open (Shard, Status);
      if Failed (Status) or else not Pinned then
         --  A shard with no ring cannot take part.  Count it as finished so
         --  the environment task is not left waiting on it forever.
         Control.Ring_Up;
         Control.Shard_Finished;
         return;
      end if;

      Control.Ring_Up;
      Control.Await_Ready;

      loop
         Progress := False;

         --  1. Harvest completions -------------------------------------
         loop
            Reactor.Harvest (Shard, Batch, Count);
            exit when Count = 0;
            N_Completions := N_Completions + Count;
            for I in 0 .. Count - 1 loop
               Dispatch (Shard, Batch (I), Useful);
               Progress := Progress or Useful;
            end loop;
         end loop;

         --  2. Adopt new work from the global queue ---------------------
         loop
            Run_Queue.Pop (Item);
            exit when Item = No_Future;
            Fibers.Adopt (Shard, Item, Started);
            if Started then
               Progress := True;
               N_Adopted := N_Adopted + 1;
            end if;
         end loop;

         --  3. Run whatever is ready ------------------------------------
         Resumed := 0;
         loop
            exit when Resumed = Resume_Budget;
            Fibers.Pop_Ready (Shard, Fiber);
            exit when Fiber = No_Fiber;

            Fibers.Resume (Shard, Fiber);
            Fibers.After_Resume (Shard, Fiber);

            Progress := True;
            Resumed := Resumed + 1;
            N_Fibers := N_Fibers + 1;
         end loop;

         --  4. Submit, and sleep if there is nothing else to do ---------
         if Progress then
            --  Fibers queued submissions while they ran; hand them over
            --  without waiting, then go round again.
            Idle_Streak := 0;
            Reactor.Flush (Shard, 0, Status);
         else
            --  Announce the sleep BEFORE the final check.  A sibling that
            --  publishes work after this point is guaranteed to see us
            --  idle and send a wakeup, and one that published before it is
            --  caught by the re-check below; either way the wakeup cannot
            --  be lost.
            Fibers.Set_Idle (Shard, True);

            Run_Queue.Depth (Queued);
            Fibers.Ready_Depth (Shard, Ready);

            if Queued = 0 and then Ready = 0 then
               Reactor.In_Flight (Shard, Outstanding);
               if Outstanding = 0 then
                  --  Nothing in flight means no completion could ever wake
                  --  us.  Arm a timer so work published by a thread that
                  --  owns no ring is still picked up -- backing off as the
                  --  idle spell lengthens, so a quiet core stays quiet.
                  Reactor.Arm_Idle_Timer
                    (Shard,
                     (if Idle_Streak > Reactor.Max_Backoff
                      then Reactor.Max_Backoff else Idle_Streak));
               end if;
               if Idle_Streak <= Reactor.Max_Backoff then
                  Idle_Streak := Idle_Streak + 1;
               end if;
               N_Sleeps := N_Sleeps + 1;
               Reactor.Flush (Shard, 1, Status);
            end if;

            Fibers.Set_Idle (Shard, False);
         end if;

         --  Stop once asked to, and only after the work in hand is done.
         Stop_Requested := Control.Stopping;
         if Stop_Requested then
            Run_Queue.Depth (Queued);
            Fibers.Ready_Depth (Shard, Ready);

            if Queued = 0 and then Ready = 0 then
               Reactor.In_Flight (Shard, Outstanding);
               exit when Outstanding = 0;

               --  Still waiting on the kernel.  Keep draining, but not for
               --  ever: give up after a bounded number of idle passes so a
               --  never-completing operation cannot wedge shutdown.
               Draining := Draining + 1;
               if Draining >= Drain_Passes then
                  Abandoned := Outstanding;
                  exit;
               end if;
               Reactor.Arm_Idle_Timer (Shard);
               Reactor.Flush (Shard, 1, Status);
            else
               Draining := 0;
            end if;
         end if;
      end loop;

      Control.Tally (Shard, N_Completions, N_Fibers, N_Adopted, N_Sleeps,
                     Abandoned);
      Reactor.Shut (Shard);
      Control.Shard_Finished;
   end Run;

   ---------------------------------------------------------------------------

   procedure Request_Shutdown is
   begin
      Control.Request_Stop;
   end Request_Shutdown;

   procedure Wait_For_Shutdown is
   begin
      Control.Await_All_Stopped;
   end Wait_For_Shutdown;

   procedure Wait_Until_Ready is
   begin
      Control.Await_Ready;
   end Wait_Until_Ready;

   procedure Report
     (Shard        : Shard_Id;
      Completions  : out Natural;
      Fibers_Run   : out Natural;
      Adopted      : out Natural;
      Sleeps       : out Natural;
      Abandoned    : out Natural) is
   begin
      Control.Read
        (Shard, Completions, Fibers_Run, Adopted, Sleeps, Abandoned);
   end Report;

end Iour.Scheduler;
