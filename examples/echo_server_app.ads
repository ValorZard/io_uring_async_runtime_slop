------------------------------------------------------------------------------
--  Echo_Server_App -- the server's fiber bodies.
--
--  Two kinds of fiber:
--
--    * one acceptor, which loops on Accept_Connection and spawns a handler
--      per connection.  Spawning publishes the handler on the global run
--      queue, so whichever core is free picks it up -- the acceptor never
--      decides where a connection will be served.
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
   --  down; zero means run until killed.
   procedure Configure (Listener : Descriptor; Target : Natural);

   --  Fiber body: accept connections and hand each to the global queue.
   procedure Acceptor (Arg : Fiber_Argument);

   procedure Snapshot
     (Accepted   : out Natural;
      Completed  : out Natural;
      Rejected   : out Natural;
      Frames     : out Natural;
      Errors     : out Natural;
      Concurrent : out Natural);

end Echo_Server_App;
