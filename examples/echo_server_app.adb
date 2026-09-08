with Echo_Protocol;   use Echo_Protocol;
with Iour.Fibers.Job;
with Iour.Net;
with Iour.Scheduler;

package body Echo_Server_App with SPARK_Mode => On is

   package Net renames Iour.Net;

   --  Acceptor is declared in the spec, so its job instance can stand
   --  here.  Serve's is further down, after the forward declaration it
   --  needs.
   package Acceptor_Job is new Iour.Fibers.Job (Work => Acceptor);

   --  Set once by the environment task before any shard runs, read by many
   --  fibers afterwards.  Atomic so the sharing is declared, not assumed.
   --  One listener per shard: they share a port through SO_REUSEPORT, and
   --  all of them have to be shut down to stop the server.
   type Listener_Table is array (Active_Shard) of Descriptor
     with Atomic_Components;

   Listeners : Listener_Table := [others => Invalid_Descriptor];

   --  Whether an acceptor deals its connections round the cores instead of
   --  keeping them.  Set before any shard runs, read by acceptors after.
   --
   --  The external properties are spelled out rather than defaulted, and
   --  they say what this is: written by one thread and read by others,
   --  Atomic for the synchronisation.  Defaulted, Atomic means External
   --  with all four True, which forbids reading one from a function
   --  (E0005) and inside a larger expression (E0004); SPARK RM 7.1.2(6)
   --  requires at least one of the two Async properties, so it is
   --  Async_Writers alone.  Iour.Trace's Enabled flag is the same shape.
   Distribute : Boolean := False
     with Atomic, Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;

   --  Where the next dealt connection goes.  Shared by every acceptor
   --  fiber, and a plain variable on purpose: it is read and written only
   --  when Distribute is set, and Distribute is set only in the
   --  one-listener configuration, where every acceptor fiber lives on the
   --  same shard.  Fibers on one shard run one at a time and switch only
   --  at an explicit suspension point, so this increment cannot be
   --  interleaved with another's.  Giving each acceptor its own counter
   --  instead would be no simpler and would deal badly: thirty-two
   --  counters all starting at the first core would send thirty-two
   --  connections there before any went to the second.
   Next_Core : Active_Shard := Active_Shard'First;

   protected Stats
     with Priority => Runtime_Priority
   is
      procedure Accepted_One;
      procedure Rejected_One;
      --  Reports whether this was the connection the server was waiting
      --  for, so the caller can wind the runtime down.
      procedure Completed_One
        (Frames : Natural; Failed : Boolean; Last : out Boolean);
      procedure Read
        (N_Accepted   : out Natural;
         N_Completed  : out Natural;
         N_Rejected   : out Natural;
         N_Frames     : out Natural;
         N_Errors     : out Natural;
         N_Concurrent : out Natural);
      function Accept_Limit_Reached return Boolean;
      --  The connection target, set once by Configure before any shard
      --  runs.  It lives here rather than in an Atomic variable beside
      --  Listeners because the only things that read it are the two
      --  operations just above: SPARK forbids a function from reading a
      --  volatile object at all (E0005), and protected state is both the
      --  simpler answer and the one that says what is true -- this is
      --  read under the same lock as the counters it is compared with.
      procedure Set_Goal (Target : Natural);
   private
      Goal            : Natural := 0;
      Total_Accepted  : Natural := 0;
      Total_Completed : Natural := 0;
      Total_Rejected  : Natural := 0;
      Total_Frames    : Natural := 0;
      Total_Errors    : Natural := 0;
      Live            : Natural := 0;
      Peak_Live       : Natural := 0;
   end Stats;

   protected body Stats is

      --  Statistics only, and a server runs for as long as the process
      --  does, so an unguarded counter really would wrap.  Saturating
      --  keeps the arithmetic total -- which is what makes it provable --
      --  without pretending the number stays exact for ever.
      --  Iour.Scheduler counts the same way, for the same reason.
      --
      --  Declared here rather than beside the package's other helpers on
      --  purpose: no protected body in this program calls anything outside
      --  itself, which is what makes the absence of nested protected calls
      --  -- and so of lock cycles -- checkable by reading one screen.  See
      --  *What SPARK proves about deadlock and data races* in CLAUDE.md.
      procedure Bump (Counter : in out Natural; By : Natural := 1) is
      begin
         if Natural'Last - Counter >= By then
            Counter := Counter + By;
         else
            Counter := Natural'Last;
         end if;
      end Bump;

      procedure Accepted_One is
      begin
         Bump (Total_Accepted);
         Bump (Live);
         if Live > Peak_Live then
            Peak_Live := Live;
         end if;
      end Accepted_One;

      procedure Rejected_One is
      begin
         Bump (Total_Rejected);
         if Live > 0 then
            Live := Live - 1;
         end if;
      end Rejected_One;

      procedure Completed_One
        (Frames : Natural; Failed : Boolean; Last : out Boolean) is
      begin
         Bump (Total_Completed);
         Bump (Total_Frames, Frames);
         if Failed then
            Bump (Total_Errors);
         end if;
         if Live > 0 then
            Live := Live - 1;
         end if;
         Last := Goal > 0 and then Total_Completed = Goal;
      end Completed_One;

      function Accept_Limit_Reached return Boolean is
        (Goal > 0 and then Total_Accepted >= Goal);

      procedure Set_Goal (Target : Natural) is
      begin
         Goal := Target;
      end Set_Goal;

      procedure Read
        (N_Accepted   : out Natural;
         N_Completed  : out Natural;
         N_Rejected   : out Natural;
         N_Frames     : out Natural;
         N_Errors     : out Natural;
         N_Concurrent : out Natural) is
      begin
         N_Accepted   := Total_Accepted;
         N_Completed  := Total_Completed;
         N_Rejected   := Total_Rejected;
         N_Frames     := Total_Frames;
         N_Errors     := Total_Errors;
         N_Concurrent := Peak_Live;
      end Read;

   end Stats;

   ---------------------------------------------------------------------------
   --  Configure
   ---------------------------------------------------------------------------

   procedure Configure
     (Shard    : Active_Shard;
      Listener : Descriptor;
      Target   : Natural;
      Spread   : Boolean := False) is
   begin
      Listeners (Shard) := Listener;
      Stats.Set_Goal (Target);
      Distribute := Spread;
   end Configure;

   ---------------------------------------------------------------------------
   --  Small helpers whose results genuinely carry no information
   ---------------------------------------------------------------------------

   procedure Drop (S : Net.Socket) is
      Ignored : Io_Result;
   begin
      Ignored := Net.Close_Now (S);
      pragma Unreferenced (Ignored);
   end Drop;

   procedure Stop_One (S : Descriptor) is
      Ignored : Io_Result;
   begin
      Ignored := Net.Shutdown_Now (S, Net.Shut_Both);
      pragma Unreferenced (Ignored);
   end Stop_One;

   --  Break every acceptor out of its pending accept.  Shutting a
   --  listening socket down is what makes accept give up; with one
   --  listener per core, stopping means stopping all of them.
   procedure Stop_Listening is
   begin
      for S in Active_Shard loop
         --  Read into a local before testing it: SPARK RM 7.1.3(9) lets a
         --  volatile object appear as the whole right-hand side of an
         --  assignment and nowhere else, so it cannot be the operand of a
         --  comparison or an actual parameter.
         declare
            Listener : constant Descriptor := Listeners (S);
         begin
            if Listener /= Invalid_Descriptor then
               Stop_One (Listener);
            end if;
         end;
      end loop;
   end Stop_Listening;

   ---------------------------------------------------------------------------
   --  Serve -- one connection, start to finish
   ---------------------------------------------------------------------------

   --  Reads as a blocking conversation, and is not one.  Each Receive_Exact
   --  and Send_All below suspends this fiber and hands the core to another
   --  connection until the kernel has the answer.
   --  Declared ahead of its body so the Iour.Fibers.Job instance below can
   --  name it; see Echo_Client_App for why the instance is at library
   --  level.
   procedure Serve (Arg : Fiber_Argument);

   package Serve_Job is new Iour.Fibers.Job (Work => Serve);

   procedure Serve (Arg : Fiber_Argument) is
      Conn : constant Net.Socket := Net.Socket (Arg);

      --  On the fiber's own stack, which is exactly what keeps them valid
      --  while the kernel is reading and writing them.
      Request  : Frame;
      Response : Frame;

      Status   : Io_Result;
      Kind     : Message_Kind;
      Sequence : Natural;
      Frames   : Natural := 0;
      Failed   : Boolean := False;
      Last     : Boolean;
   begin
      loop
         Net.Receive_Exact (Conn, Request, Status);
         exit when Status <= 0;   --  peer closed, or the read failed

         Parse (Request, Kind, Sequence);
         exit when Kind = Farewell;

         if Kind /= Ping then
            Failed := True;
            exit;
         end if;

         Build (Pong, Sequence, Response);
         Net.Send_All (Conn, Response, Status);
         if Status < 0 then
            --  A peer that vanished mid-conversation is ordinary, not an
            --  error worth counting.
            Failed := not Peer_Gone (Status);
            exit;
         end if;

         Frames := Frames + 1;
      end loop;

      Net.Close (Conn, Status);
      Stats.Completed_One (Frames, Failed, Last);

      if Last then
         --  The connection we were counting to.  Break the acceptors out
         --  of their pending accepts, then wind the runtime down.
         Stop_Listening;
         Iour.Scheduler.Request_Shutdown;
      end if;
   end Serve;

   ---------------------------------------------------------------------------
   --  Acceptor
   ---------------------------------------------------------------------------

   --  Choose the core for the next dealt connection: plain round robin
   --  over every core, the acceptors' own included.
   --
   --  Skipping the acceptors' core is the obvious-looking refinement and
   --  it does not pay.  The argument for it is real -- a pending accept is
   --  an operation the kernel completes on the completion port, and a
   --  shard with any of those outstanding cannot take the cheap sleep, so
   --  it bridges the ring's completion event onto the port and pays two
   --  extra thread wakeups on every completion it then receives -- but the
   --  arithmetic goes the other way.  Skipping it moves a quarter of the
   --  connections onto the remaining cores rather than sparing them
   --  anything, and giving up a quarter of the serving capacity costs more
   --  than the bridge does.  Measured with it and without, on this
   --  machine: 500 connections 139.0k against 131.9k round trips a second,
   --  2000 connections 211.7k against 201.4k, one connection no
   --  distinguishable difference at all.  It stays round robin.
   --
   --  Counted in the base type and wrapped rather than compared against
   --  Active_Shard'Last and incremented: with Shard_Count of one the
   --  increment is statically outside the subtype, and the compiler
   --  rejects it even on the branch that never runs.
   procedure Advance_Core is
   begin
      Next_Core := Active_Shard ((Integer (Next_Core) + 1) mod Shard_Count);
   end Advance_Core;

   procedure Acceptor (Arg : Fiber_Argument) is
      --  Arg arrives through the context switch's trampoline, so this is
      --  the one boundary where the language has not carried its range.
      --  Checked rather than converted blindly; Serve does not need the
      --  same guard only because it is always called with a descriptor
      --  that an accept has just returned.
      Listener : Net.Socket;
      Incoming : Io_Result;
      Started  : Boolean;

      --  Distribute read into a local before it is tested; see
      --  Stop_Listening for why a volatile object cannot be a condition.
      Dealing  : Boolean;

      --  The same, for the protected function that says when the target
      --  has been met.
      Enough   : Boolean;
   begin
      if Arg not in Fiber_Argument (Net.Socket'First)
                 .. Fiber_Argument (Net.Socket'Last)
      then
         return;
      end if;
      Listener := Net.Socket (Arg);

      loop
         --  A protected function is a volatile function, and SPARK RM
         --  7.1.3(9) allows a call to one only as the whole right-hand
         --  side of an assignment -- not as an exit condition.
         Enough := Stats.Accept_Limit_Reached;
         exit when Enough;

         Net.Accept_Connection (Listener, Incoming);

         if Incoming < 0 then
            --  Retry the transient cases; anything else -- including the
            --  error a shutdown listener produces -- ends the loop.
            exit when Errno (Incoming) not in E_Intr | E_Again;
         else
            Stats.Accepted_One;

            Dealing := Distribute;
            if Dealing then
               --  One acceptor for the whole server, so the connections
               --  have to be dealt out or every other core sits idle.
               --  Spawn_On rather than Spawn: it names the core, and it
               --  needs no future, which matters for a fiber that nothing
               --  will ever await.
               Serve_Job.Spawn_On
                 (Next_Core, Fiber_Argument (Incoming), Started);
               Advance_Core;
            else
               --  Run the handler on this core.  The socket was accepted
               --  here, so its reads and writes will go through this
               --  core's ring; sending it elsewhere would only mean
               --  another core doing the same work with a colder cache.
               Serve_Job.Spawn_Here (Fiber_Argument (Incoming), Started);
            end if;

            if not Started then
               --  Runtime at capacity: refuse cleanly rather than leak the
               --  descriptor or stall the accept loop.
               Stats.Rejected_One;
               Drop (Net.Socket (Incoming));
            end if;
         end if;
      end loop;
   end Acceptor;

   ---------------------------------------------------------------------------

   procedure Start_Acceptor
     (Shard : Active_Shard; Listener : Descriptor; Started : out Boolean) is
   begin
      Acceptor_Job.Spawn_On (Shard, Fiber_Argument (Listener), Started);
   end Start_Acceptor;

   procedure Snapshot
     (Accepted   : out Natural;
      Completed  : out Natural;
      Rejected   : out Natural;
      Frames     : out Natural;
      Errors     : out Natural;
      Concurrent : out Natural) is
   begin
      Stats.Read (Accepted, Completed, Rejected, Frames, Errors, Concurrent);
   end Snapshot;

end Echo_Server_App;
