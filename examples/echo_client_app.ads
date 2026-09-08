with Iour.Fibers.Race_Witness;
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

   --  Every fiber body this program registers.  Never executed: it is
   --  reached only through Races.Never_Runs, which the main subprogram
   --  calls once and which is guarded by a flag nothing ever sets.
   --
   --  A body missing from here is a body checked for nothing, and nothing
   --  will say so.  Keep it in step with the Iour.Fibers.Job instances.
   procedure All_Fiber_Bodies;

   package Races is new Iour.Fibers.Race_Witness (All_Fiber_Bodies);


   --  Start Driver as a fiber.  The instantiation of Iour.Fibers.Job that
   --  makes this possible has to be at library level, so it lives in this
   --  package's body rather than in the main procedure's declarations.
   procedure Start_Driver (Handle : out Future_Ref);

   procedure Snapshot
     (Started    : out Natural;
      Succeeded  : out Natural;
      Failed     : out Natural;
      Frames     : out Natural;
      Mismatched : out Natural;
      Concurrent : out Natural);

end Echo_Client_App;
