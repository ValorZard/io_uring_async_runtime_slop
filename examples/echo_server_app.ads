with Iour.Fibers.Race_Witness;
------------------------------------------------------------------------------
--  Echo_Server_App -- the server's fiber bodies.
--
--  Two kinds of fiber:
--
--    * acceptors.  Where the system can share a listening port between
--      sockets -- SO_REUSEPORT, which Linux has and Windows has nothing
--      like -- there is one per shard, each with its own listener on the
--      same port, so the kernel spreads arriving connections across the
--      cores' accept queues and no single core is the gate.  Each acceptor
--      then spawns its handlers onto its own core, so a connection is
--      served by the core that accepted it: the core whose ring already
--      carries its socket.
--
--      Where the port cannot be shared there is one accepting core, and it
--      deals the connections it accepts round the other cores instead.
--      Accepting is cheap and echoing is not, so one core can keep the
--      rest fed; what is lost is the locality, not the parallelism.
--
--      That core runs Concurrent_Acceptors acceptor fibers rather than
--      one.  See the constant below for why one is not enough.
--
--    * one handler per connection, which reads a frame, answers it, and
--      repeats until the client says goodbye.  It is written as ordinary
--      straight-line code; every Receive and Send in it suspends the fiber
--      and lets its core serve other connections in the meantime.
--
--  Thousands of these run at once.  What bounds them is fiber stacks, not
--  threads: the process still has exactly Shard_Count worker threads.
------------------------------------------------------------------------------

with Iour; use Iour;

package Echo_Server_App with SPARK_Mode => On is

   --  Target is how many connections to serve before shutting the runtime
   --  down; zero means run until killed.  Call once per listener, before
   --  the acceptors start; the listeners are remembered so that reaching
   --  the target can shut all of them down at once.
   --
   --  Spread says an acceptor should hand each connection to the next core
   --  in turn rather than serve it where it landed, which is what a single
   --  acceptor has to do to use more than its own core.
   procedure Configure
     (Shard    : Active_Shard;
      Listener : Descriptor;
      Target   : Natural;
      Spread   : Boolean := False);

   --  How many accepts to keep outstanding on one listener.
   --
   --  One is not enough, and the reason is specific to how accept is
   --  spelled on each system.  An acceptor fiber submits one accept and
   --  suspends; the next accept is not submitted until the completion has
   --  come back, been dispatched and resumed the fiber.  Between those two
   --  points the listener has nothing pending, and every connection that
   --  arrives in the gap waits in the kernel's accept queue -- or, once
   --  that fills, is refused.  With a client that opens hundreds of
   --  connections at once the gap is the whole story: measured here, a Go
   --  client offering 500 simultaneous connections to a single acceptor
   --  lost 239 of them.
   --
   --  Several fibers on the same listener close the gap without any of
   --  them doing anything differently: while one is between completion and
   --  resubmission, the others' accepts are still outstanding.  On Windows
   --  each is a separate AcceptEx with its own socket made in advance,
   --  which is exactly the shape the kernel wants; on Linux each is an
   --  IORING_OP_ACCEPT on the same listener.
   --
   --  Thirty-two, by measurement rather than by argument.  With a Go
   --  client offering 500 simultaneous connections to a four-shard server
   --  on this machine, one acceptor lost 239 of them; eight lost between
   --  none and 225, depending on the run; sixteen still lost one run in
   --  four; thirty-two and sixty-four lost none across eight runs each,
   --  and neither changed throughput.  The number that matters is how many
   --  connections arrive while one acceptor is between its completion and
   --  its next submission, and it is set by how fast a client can call
   --  connect -- so the right answer is "comfortably more than enough",
   --  and one more costs a fiber stack and an accept slot.
   Concurrent_Acceptors : constant := 32;

   --  Fiber body: accept connections on the listener passed as Arg and run
   --  each one on this core, or deal it round the cores when Configure was
   --  told to spread.  Several of these may share one listener.
   procedure Acceptor (Arg : Fiber_Argument);

   --  Every fiber body this program registers.  Never executed: it is
   --  reached only through Races.Never_Runs, which the main subprogram
   --  calls once and which is guarded by a flag nothing ever sets.
   --
   --  A body missing from here is a body checked for nothing, and nothing
   --  will say so.  Keep it in step with the Iour.Fibers.Job instances.
   procedure All_Fiber_Bodies;

   package Races is new Iour.Fibers.Race_Witness (All_Fiber_Bodies);

   --  Start an acceptor on a named shard.  As with the client, the
   --  Iour.Fibers.Job instance must be at library level and so lives in
   --  this package's body.
   procedure Start_Acceptor
     (Shard : Active_Shard; Listener : Descriptor; Started : out Boolean);

   procedure Snapshot
     (Accepted   : out Natural;
      Completed  : out Natural;
      Rejected   : out Natural;
      Frames     : out Natural;
      Errors     : out Natural;
      Concurrent : out Natural);

end Echo_Server_App;
