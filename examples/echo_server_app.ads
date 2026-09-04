------------------------------------------------------------------------------
--  Echo_Server_App -- the server's fiber bodies.
--
--  Two kinds of fiber:
--
--    * one acceptor per shard, each with its own SO_REUSEPORT listener on
--      the same port, so the kernel spreads incoming connections across
--      the cores' accept queues and no single core is the gate.  Each
--      acceptor spawns its handlers onto its own core, so a connection is
--      served by the core that accepted it -- the core whose ring already
--      carries its socket.
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
   procedure Configure
     (Shard : Active_Shard; Listener : Descriptor; Target : Natural);

   --  Fiber body: accept connections on the listener passed as Arg and run
   --  each one on this core.
   procedure Acceptor (Arg : Fiber_Argument);

   procedure Snapshot
     (Accepted   : out Natural;
      Completed  : out Natural;
      Rejected   : out Natural;
      Frames     : out Natural;
      Errors     : out Natural;
      Concurrent : out Natural);

end Echo_Server_App;
