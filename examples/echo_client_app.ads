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

with Ada.Real_Time;
with Iour; use Iour;

package Echo_Client_App with SPARK_Mode => On is

   procedure Configure
     (Host        : String;
      Port        : Natural;
      Connections : Natural;
      Rounds      : Natural);

   --  Fiber body: fan out the sessions, wait for them, stop the runtime.
   procedure Driver (Arg : Fiber_Argument);

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

   --  The window the sessions actually occupied: taken just before the
   --  first one is spawned, and again as the last one finishes.
   --
   --  Deliberately not the whole of the client's run, and this is the
   --  second time that distinction has cost a wrong number.  The main
   --  procedure used to take Clock either side of
   --  Iour.Scheduler.Wait_For_Shutdown, which put the entire runtime
   --  teardown inside the measured window -- every shard draining its
   --  ring and stopping.  The Go and Tokio clients measure none of that:
   --  both stop their clock when the last session task joins, and neither
   --  shuts anything down before reading it.
   --
   --  It is not a rounding error.  Measured paired against the version
   --  that timed the shutdown -- one server, the two clients alternating
   --  rep by rep, 100 connections by 1000 rounds -- the reported window
   --  fell from a median of 897 ms to 769 ms, shorter in 8 reps of 8.
   --  So about a seventh of what this client called "elapsed" was the
   --  runtime stopping, and every round-trips-per-second figure it has
   --  ever printed was understated by roughly a sixth.
   --
   --  What is left in the window at one connection is still tens of
   --  milliseconds for microseconds of work, and that part is not a bug:
   --  it is the connect, which on Windows is a blocking connect(2) on a
   --  thread-pool thread and costs a scheduler tick when it misses one.
   --  Go and Tokio connect inside their measured windows too, so it
   --  belongs in this one.  See CLAUDE.md, *Measurement traps*.
   --
   --  If no session ever finished, To is left at or below From and the
   --  caller reports no throughput at all, which is the truth about such
   --  a run.
   procedure Session_Window
     (From : out Ada.Real_Time.Time;
      To   : out Ada.Real_Time.Time);

end Echo_Client_App;
