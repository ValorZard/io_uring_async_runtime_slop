with Interfaces; use Interfaces;
with Iour.Fibers;
with Iour.Futures;
with Iour.Reactor;
with Iour.Run_Queue;
with Iour.Trace;

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

   --  Statistics only.  A shard runs for as long as the process does, so an
   --  unguarded counter really would wrap; saturating keeps the arithmetic
   --  total without pretending the number stays exact for ever.
   procedure Bump (Counter : in out Natural; By : Natural := 1) is
   begin
      if Natural'Last - Counter >= By then
         Counter := Counter + By;
      else
         Counter := Natural'Last;
      end if;
   end Bump;

   ---------------------------------------------------------------------------
   --  Control -- startup barrier, shutdown flag and tallies
   ---------------------------------------------------------------------------

   protected Control
     with Priority => Runtime_Priority
   is

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
         Stolen      : Natural;
         Slept       : Natural;
         Left_Over   : Natural;
         Flush_Fail  : Natural);

      procedure Read
        (Shard       : Shard_Id;
         Completions : out Natural;
         Fibers_Run  : out Natural;
         Adopted     : out Natural;
         Stolen      : out Natural;
         Slept       : out Natural;
         Left_Over   : out Natural;
         Flush_Fail  : out Natural);

   private
      Rings_Up  : Natural := 0;
      Stopped   : Natural := 0;
      Stop_Flag : Boolean := False;

      N_Completions : Counter_Array := [others => 0];
      N_Fibers      : Counter_Array := [others => 0];
      N_Adopted     : Counter_Array := [others => 0];
      N_Stolen      : Counter_Array := [others => 0];
      N_Sleeps      : Counter_Array := [others => 0];
      N_Abandoned   : Counter_Array := [others => 0];
      N_Flush_Bad   : Counter_Array := [others => 0];
   end Control;

   --  Barrier-only entries: the body is "null" because the wait is the
   --  point, and SPARK reports a null statement as having no effect.
   pragma Warnings
     (GNATprove, Off, "statement has no effect",
      Reason => "Barrier-only entry: the wait is the point.");
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
         Stolen      : Natural;
         Slept       : Natural;
         Left_Over   : Natural;
         Flush_Fail  : Natural) is
      begin
         N_Completions (Shard) := Completions;
         N_Fibers (Shard)      := Fibers_Run;
         N_Adopted (Shard)     := Adopted;
         N_Stolen (Shard)      := Stolen;
         N_Sleeps (Shard)      := Slept;
         N_Abandoned (Shard)   := Left_Over;
         N_Flush_Bad (Shard)   := Flush_Fail;
      end Tally;

      procedure Read
        (Shard       : Shard_Id;
         Completions : out Natural;
         Fibers_Run  : out Natural;
         Adopted     : out Natural;
         Stolen      : out Natural;
         Slept       : out Natural;
         Left_Over   : out Natural;
         Flush_Fail  : out Natural) is
      begin
         Completions := N_Completions (Shard);
         Fibers_Run  := N_Fibers (Shard);
         Adopted     := N_Adopted (Shard);
         Stolen      := N_Stolen (Shard);
         Slept       := N_Sleeps (Shard);
         Left_Over   := N_Abandoned (Shard);
         Flush_Fail  := N_Flush_Bad (Shard);
      end Read;

   end Control;
   pragma Warnings (GNATprove, On, "statement has no effect");

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
      Status      : Io_Result;
      Pinned      : Boolean;
      Contexts_Ok : Boolean;

      Progress : Boolean;
      Useful   : Boolean;
      Posted   : Boolean;
      Offered  : Boolean;
      Item     : Future_Ref;
      Fiber    : Fiber_Ref;
      Started  : Boolean;
      Ready    : Natural;
      Queued   : Natural;
      Outstanding    : Natural;
      Stop_Requested : Boolean;

      --  A flush that fails leaves submissions queued and the shard looping
      --  on them.  Counting it is what makes a broken ring visible instead
      --  of a silent hot loop.
      N_Flush_Errors : Natural := 0;
      Resumed  : Natural;

      N_Completions : Natural := 0;
      N_Fibers      : Natural := 0;
      N_Adopted     : Natural := 0;
      N_Stolen      : Natural := 0;
      Stolen        : Natural;
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

      --  The machine-context table has to exist before any fiber can be
      --  primed.  Idempotent, so every shard calling it is fine; the first
      --  one through does the work.
      Fibers.Reserve_Contexts (Contexts_Ok);

      --  Confirm this task really is on the core its static CPU aspect
      --  promised, because shard identity is derived from that.
      Fibers.Verify_Cpu (Shard, Pinned);

      Reactor.Open (Shard, Status);
      if Failed (Status) or else not Pinned or else not Contexts_Ok then
         --  A shard with no ring cannot take part.  Count it as finished so
         --  the environment task is not left waiting on it forever.
         Control.Ring_Up;
         Control.Shard_Finished;
         return;
      end if;

      Control.Ring_Up;
      Control.Await_Ready;
      Trace.Event (Shard, "up, ring ready");

      loop
         Progress := False;

         --  0. Wakeups posted by threads that own no ring -------------
         --  The environment task fulfilling a promise lands here.  They are
         --  converted to ordinary local wakeups on this shard, which is the
         --  only place it is safe to touch this shard's ready queue.  The
         --  flag is an atomic read, so the usual case -- nothing posted --
         --  takes no lock.
         Fibers.Inbox_Pending (Shard, Posted);
         if Posted then
            loop
               Fibers.Take_Posted (Shard, Fiber);
               exit when Fiber = No_Fiber;
               Fibers.Wake (Shard, Fiber, Shard);
               Progress := True;
            end loop;
         end if;

         --  1. Harvest completions -------------------------------------
         loop
            Reactor.Harvest (Shard, Batch, Count);
            exit when Count = 0;
            Bump (N_Completions, Count);
            for I in 0 .. Count - 1 loop
               Dispatch (Shard, Batch (I), Useful);
               Progress := Progress or Useful;
            end loop;
         end loop;

         --  2. Adopt new work from the global queue ---------------------
         --  Every shard passes here on every loop, and the queue is the one
         --  lock they all share; asking an atomic flag first is what keeps
         --  an empty queue from being a point of contention.
         Run_Queue.Might_Have_Work (Offered);
         if Offered then
            loop
               Run_Queue.Pop (Item);
               exit when Item = No_Future;
               Fibers.Adopt (Shard, Item, Started);
               if Started then
                  Progress := True;
                  Bump (N_Adopted);
               end if;
            end loop;
         end if;

         --  3. Run whatever is ready ------------------------------------
         Resumed := 0;
         loop
            exit when Resumed = Resume_Budget;
            Fibers.Pop_Ready (Shard, Fiber);
            exit when Fiber = No_Fiber;

            Fibers.Resume (Shard, Fiber);
            Fibers.After_Resume (Shard, Fiber);

            Progress := True;
            Bump (Resumed);
            Bump (N_Fibers);
         end loop;

         --  4. Steal, then submit, and sleep if there is still nothing --

         --  Nothing of our own left.  Before going to sleep, take some of
         --  a sibling's backlog: this is the one place the runtime looks
         --  at another core's queue, and a shard with work of its own
         --  never reaches it.
         if not Progress then
            Fibers.Steal_Work (Shard, Stolen);
            if Stolen > 0 then
               Bump (N_Stolen, Stolen);
               Progress := True;
            end if;
         end if;

         if Progress then
            --  Fibers queued submissions while they ran; hand them over
            --  without waiting, then go round again.
            if Idle_Streak > 0 then
               Trace.Event (Shard, "woke with work");
            end if;
            Idle_Streak := 0;
            Reactor.Flush (Shard, 0, Status);
            if Failed (Status) then
               Bump (N_Flush_Errors);
            end if;
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

               --  Only on entering an idle spell, not on every re-arm of
               --  the backoff timer.  Otherwise a quiet shard buries the
               --  trace in repeats of its own polling.
               if Idle_Streak = 0 then
                  Trace.Event (Shard, "going idle, in flight", Outstanding);
               end if;

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
               Bump (N_Sleeps);
               Reactor.Flush (Shard, 1, Status);
               if Failed (Status) then
                  Bump (N_Flush_Errors);
               end if;
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
               Bump (Draining);
               if Draining >= Drain_Passes then
                  Abandoned := Outstanding;
                  exit;
               end if;
               Reactor.Arm_Idle_Timer (Shard);
               Reactor.Flush (Shard, 1, Status);
               if Failed (Status) then
                  Bump (N_Flush_Errors);
               end if;
            else
               Draining := 0;
            end if;
         end if;
      end loop;

      Trace.Event (Shard, "stopping, fibers run", N_Fibers);
      Control.Tally (Shard, N_Completions, N_Fibers, N_Adopted, N_Stolen,
                     N_Sleeps, Abandoned, N_Flush_Errors);
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
      Stolen       : out Natural;
      Sleeps       : out Natural;
      Abandoned    : out Natural;
      Flush_Errors : out Natural) is
   begin
      Control.Read
        (Shard, Completions, Fibers_Run, Adopted, Stolen, Sleeps, Abandoned,
         Flush_Errors);
   end Report;

end Iour.Scheduler;
