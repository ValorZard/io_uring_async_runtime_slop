with Echo_Protocol;   use Echo_Protocol;
with Iour.Fibers;
with Iour.Net;
with Iour.Scheduler;

package body Echo_Server_App with SPARK_Mode => On is

   package Fibers renames Iour.Fibers;
   package Net renames Iour.Net;

   --  Set once by the environment task before any shard runs, read by many
   --  fibers afterwards.  Atomic so the sharing is declared, not assumed.
   --  One listener per shard: they share a port through SO_REUSEPORT, and
   --  all of them have to be shut down to stop the server.
   type Listener_Table is array (Active_Shard) of Descriptor
     with Atomic_Components;

   Listeners : Listener_Table := [others => Invalid_Descriptor];
   Goal      : Natural := 0 with Atomic;

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
   private
      Total_Accepted  : Natural := 0;
      Total_Completed : Natural := 0;
      Total_Rejected  : Natural := 0;
      Total_Frames    : Natural := 0;
      Total_Errors    : Natural := 0;
      Live            : Natural := 0;
      Peak_Live       : Natural := 0;
   end Stats;

   protected body Stats is

      procedure Accepted_One is
      begin
         Total_Accepted := Total_Accepted + 1;
         Live := Live + 1;
         if Live > Peak_Live then
            Peak_Live := Live;
         end if;
      end Accepted_One;

      procedure Rejected_One is
      begin
         Total_Rejected := Total_Rejected + 1;
         if Live > 0 then
            Live := Live - 1;
         end if;
      end Rejected_One;

      procedure Completed_One
        (Frames : Natural; Failed : Boolean; Last : out Boolean) is
      begin
         Total_Completed := Total_Completed + 1;
         Total_Frames := Total_Frames + Frames;
         if Failed then
            Total_Errors := Total_Errors + 1;
         end if;
         if Live > 0 then
            Live := Live - 1;
         end if;
         Last := Goal > 0 and then Total_Completed = Goal;
      end Completed_One;

      function Accept_Limit_Reached return Boolean is
        (Goal > 0 and then Total_Accepted >= Goal);

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
     (Shard : Active_Shard; Listener : Descriptor; Target : Natural) is
   begin
      Listeners (Shard) := Listener;
      Goal := Target;
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
         if Listeners (S) /= Invalid_Descriptor then
            Stop_One (Listeners (S));
         end if;
      end loop;
   end Stop_Listening;

   ---------------------------------------------------------------------------
   --  Serve -- one connection, start to finish
   ---------------------------------------------------------------------------

   --  Reads as a blocking conversation, and is not one.  Each Receive_Exact
   --  and Send_All below suspends this fiber and hands the core to another
   --  connection until the kernel has the answer.
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

   procedure Acceptor (Arg : Fiber_Argument) is
      Listener : constant Net.Socket := Net.Socket (Arg);
      Incoming : Io_Result;
      Started  : Boolean;
   begin
      loop
         exit when Stats.Accept_Limit_Reached;

         Net.Accept_Connection (Listener, Incoming);

         if Incoming < 0 then
            --  Retry the transient cases; anything else -- including the
            --  error a shutdown listener produces -- ends the loop.
            exit when Errno (Incoming) not in E_Intr | E_Again;
         else
            Stats.Accepted_One;

            --  Run the handler on this core.  The socket was accepted
            --  here, so its reads and writes will go through this core's
            --  ring; sending it to the global queue would only mean
            --  another core doing the same work with a colder cache and a
            --  shared lock on the way.
            Fibers.Spawn_Here
              (Serve'Access, Fiber_Argument (Incoming), Started);

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
