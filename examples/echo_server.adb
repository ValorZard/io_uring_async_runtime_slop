------------------------------------------------------------------------------
--  echo_server -- a server on the io_uring runtime.
--
--    ./bin/echo_server [port] [connections-to-serve]
--
--  A connections-to-serve of 0 means run until killed.
--
--  Where the system can share a listening port -- SO_REUSEPORT on Linux --
--  every core gets its own listener and its own acceptor and serves the
--  connections it accepted, and nothing about a connection crosses cores.
--  Windows has no equivalent, so there is one listener, one acceptor, and
--  the connections are dealt round the cores as they arrive.
--
--  The environment task asks for Ada CPU 1 and the shards take
--  First_Shard_Cpu upward, so that start-up and reporting stay off the
--  cores that are serving traffic.
------------------------------------------------------------------------------

with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Text_IO;       use Ada.Text_IO;
with Iour;              use Iour;
with Iour.Ffi.Sys;
with Iour.Fibers;
with Iour.Net;
with Iour.Reactor;
with Iour.Scheduler;
with Iour.Shards;
with Iour.Trace;
with Ada.Environment_Variables;
with Echo_Server_App;

procedure Echo_Server with SPARK_Mode => On, CPU => 1 is

   function Argument_Or (Index : Positive; Default : Natural) return Natural is
   begin
      if Argument_Count < Index then
         return Default;
      end if;
      declare
         Text  : constant String := Argument (Index);
         Value : Integer;
      begin
         Value := Integer'Value (Text);
         return (if Value < 0 then Default else Value);
      exception
         when others =>
            return Default;
      end;
   end Argument_Or;

   Port     : constant Natural := Argument_Or (1, 9099);
   Target   : constant Natural := Argument_Or (2, 0);

   type Listener_Table is array (Active_Shard) of Io_Result;

   --  Whether every core can have a listener of its own on one port.
   Shared_Port : constant Boolean := Net.Port_Sharing_Available;

   Listeners : Listener_Table := [others => 0];
   Opened    : Io_Result;
   Bound     : Io_Result;
   Started   : Boolean;
   Fd_Limit  : Natural;

   Accepted, Completed, Rejected, Frames, Errors, Concurrent : Natural;
   Live, Peak : Natural;
begin
   if Ada.Environment_Variables.Exists ("IOUR_TRACE") then
      Trace.Enable;
   end if;
   Net.Ignore_Broken_Pipes;
   Fd_Limit := Ffi.Sys.Raise_Descriptor_Limit;

   --  One listener per shard, all on the same port through SO_REUSEPORT,
   --  so the kernel gives every core its own accept queue and spreads
   --  arriving connections between them.  The first one binds the port --
   --  which matters when Port is zero and the kernel chooses -- and the
   --  rest join the port it settled on.
   Opened := Net.Listen (Port => Port, Reuseport => Shared_Port);
   if Failed (Opened) then
      Put_Line ("echo_server: cannot listen on port" & Port'Image
                & " (errno" & Errno (Opened)'Image & ")");
      Ffi.Sys.Exit_Process (1);
   end if;
   Listeners (Active_Shard'First) := Opened;

   Bound := Net.Port_Of (Descriptor (Opened));
   if Failed (Bound) then
      Put_Line ("echo_server: cannot read back the bound port");
      Ffi.Sys.Exit_Process (1);
   end if;

   if Shared_Port then
      for S in Active_Shard loop
         if S /= Active_Shard'First then
            Opened := Net.Listen (Port      => Natural (Bound),
                                  Reuseport => True);
            if Failed (Opened) then
               Put_Line ("echo_server: cannot add a listener for shard"
                         & S'Image & " (errno" & Errno (Opened)'Image & ")");
               Ffi.Sys.Exit_Process (1);
            end if;
            Listeners (S) := Opened;
         end if;

         Echo_Server_App.Configure (S, Descriptor (Listeners (S)), Target);
      end loop;
   else
      --  One listener, and the acceptor on it deals its connections round
      --  the cores.  The remaining entries stay Invalid_Descriptor, which
      --  is what Stop_Listening skips over.
      Echo_Server_App.Configure
        (Active_Shard'First, Descriptor (Listeners (Active_Shard'First)),
         Target, Spread => True);
   end if;

   Shards.Activate;
   Scheduler.Wait_Until_Ready;

   Put_Line ("echo_server: listening on port" & Bound'Image
             & " with" & Shard_Count'Image & " shards"
             & ", descriptor limit" & Fd_Limit'Image);
   declare
      On_Ring : Boolean;
   begin
      Reactor.Ring_Carries_Sockets (Active_Shard'First, On_Ring);
      Put_Line ("echo_server: " & Reactor.Backend_Name
                & (if On_Ring then ", ring carries connections"
                   else ", no ring")
                & (if Shared_Port
                   then ", one listener per core"
                   else ", one listener, connections dealt round the cores"));
   end;
   if Target > 0 then
      Put_Line ("echo_server: will serve" & Target'Image
                & " connections, then stop");
   else
      Put_Line ("echo_server: serving until killed");
   end if;

   --  Acceptors on each core that has a listener.  Placed rather than
   --  published: an acceptor that landed on the same core as another would
   --  leave a core with no accept queue of its own, and the connections it
   --  accepts are served where it runs.
   --
   --  Several per listener, not one.  A single acceptor leaves the
   --  listener with nothing outstanding for as long as it takes one
   --  completion to be dispatched and the fiber resumed, and a client that
   --  opens hundreds of connections at once fills the accept queue in that
   --  gap.  Echo_Server_App.Concurrent_Acceptors says how many and why.
   for S in Active_Shard loop
      exit when not Shared_Port and then S /= Active_Shard'First;

      for I in 1 .. Echo_Server_App.Concurrent_Acceptors loop
         Fibers.Spawn_On
           (S,
            Echo_Server_App.Acceptor'Access,
            Fiber_Argument (Listeners (S)),
            Started);

         if not Started then
            Put_Line ("echo_server: could not start acceptor" & I'Image
                      & " for shard" & S'Image);
            Ffi.Sys.Exit_Process (1);
         end if;
      end loop;
   end loop;

   Scheduler.Wait_For_Shutdown;

   Echo_Server_App.Snapshot
     (Accepted, Completed, Rejected, Frames, Errors, Concurrent);
   Fibers.Live_Fibers (Live, Peak);

   New_Line;
   Put_Line ("echo_server: accepted" & Accepted'Image
             & ", completed" & Completed'Image
             & ", rejected" & Rejected'Image);
   Put_Line ("echo_server: frames echoed" & Frames'Image
             & ", protocol errors" & Errors'Image);
   Put_Line ("echo_server: peak concurrent connections" & Concurrent'Image
             & ", peak fibers" & Peak'Image);

   for S in Active_Shard loop
      declare
         Completions, Resumes, Adopted, Sleeps, Left, Bad : Natural;
      begin
         Scheduler.Report
           (S, Completions, Resumes, Adopted, Sleeps, Left, Bad);
         Put_Line ("  shard" & S'Image
                   & ": completions" & Completions'Image
                   & ", resumes" & Resumes'Image
                   & ", connections adopted" & Adopted'Image
                   & ", kernel sleeps" & Sleeps'Image
                   & (if Bad > 0 then ", FLUSH ERRORS" & Bad'Image else ""));
      end;
   end loop;

   Fibers.Release_All_Stacks;
   Ffi.Sys.Exit_Process (if Errors = 0 then 0 else 1);
end Echo_Server;
