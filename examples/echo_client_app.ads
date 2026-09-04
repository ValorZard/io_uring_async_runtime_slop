------------------------------------------------------------------------------
--  Echo_Client_App -- the client's fiber bodies.
--
--  One fiber per connection, all spawned onto the global run queue and
--  spread over the shards by whichever core takes them.  Each session
--  connects, exchanges a fixed number of request/response frames, says
--  goodbye and closes -- written as straight-line code that suspends at
--  every I/O point.
--
--  The interesting number is the ratio: hundreds or thousands of
--  conversations in flight at once, on Shard_Count operating system
--  threads.
------------------------------------------------------------------------------

with Iour; use Iour;

package Echo_Client_App with SPARK_Mode => On is

   procedure Configure
     (Host        : String;
      Port        : Natural;
      Connections : Natural;
      Rounds      : Natural);

   --  Fiber body: fan out the sessions, wait for them, stop the runtime.
   procedure Driver (Arg : Fiber_Argument);

   procedure Snapshot
     (Started    : out Natural;
      Succeeded  : out Natural;
      Failed     : out Natural;
      Frames     : out Natural;
      Mismatched : out Natural;
      Concurrent : out Natural);

end Echo_Client_App;
