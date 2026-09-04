------------------------------------------------------------------------------
--  echo_server -- a server on the io_uring runtime.
--
--    ./bin/echo_server [port] [connections-to-serve]
--
--  A connections-to-serve of 0 means run until killed.
--
--  Every core gets its own SO_REUSEPORT listener and its own acceptor, and
--  serves the connections it accepted.  Nothing about a connection crosses
--  cores.
--
--  The environment task is pinned to Ada CPU 1 (Linux CPU 0); the shards
--  take First_Shard_Cpu upward.  Keeping them apart matters, because a
--  shard's identity is derived from the core it is running on.
------------------------------------------------------------------------------

with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Text_IO;       use Ada.Text_IO;
with Iour;              use Iour;
with Iour.Ffi.Sys;
with Iour.Fibers;
with Iour.Net;
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
   Opened := Net.Listen (Port => Port, Reuseport => True);
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

   --  Indexed over the base type, so a Shard_Count of one leaves an empty
   --  range rather than a guard the compiler can see is always false.
   for S in Shard_Ref range 1 .. Shard_Ref (Shard_Count - 1) loop
      Opened := Net.Listen (Port => Natural (Bound), Reuseport => True);
      if Failed (Opened) then
         Put_Line ("echo_server: cannot add a listener for shard"
                   & S'Image & " (errno" & Errno (Opened)'Image & ")");
         Ffi.Sys.Exit_Process (1);
      end if;
      Listeners (S) := Opened;
   end loop;

   for S in Active_Shard loop
      Echo_Server_App.Configure (S, Descriptor (Listeners (S)), Target);
   end loop;

   Shards.Activate;
   Scheduler.Wait_Until_Ready;

   Put_Line ("echo_server: listening on port" & Bound'Image
             & " with" & Shard_Count'Image & " shards"
             & ", descriptor limit" & Fd_Limit'Image);
   if Target > 0 then
      Put_Line ("echo_server: will serve" & Target'Image
                & " connections, then stop");
   else
      Put_Line ("echo_server: serving until killed");
   end if;

   --  One acceptor per core, each on its own listener.  Placed rather
   --  than published: an acceptor that landed on the same core as another
   --  would leave a core with no accept queue of its own, and the
   --  connections it accepts are served where it runs.
   for S in Active_Shard loop
      Fibers.Spawn_On
        (S,
         Echo_Server_App.Acceptor'Access,
         Fiber_Argument (Listeners (S)),
         Started);

      if not Started then
         Put_Line ("echo_server: could not start the acceptor for shard"
                   & S'Image);
         Ffi.Sys.Exit_Process (1);
      end if;
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
         Completions, Resumes, Adopted, Stolen, Sleeps, Left, Bad : Natural;
      begin
         Scheduler.Report
           (S, Completions, Resumes, Adopted, Stolen, Sleeps, Left, Bad);
         Put_Line ("  shard" & S'Image
                   & ": completions" & Completions'Image
                   & ", resumes" & Resumes'Image
                   & ", connections adopted" & Adopted'Image
                   & ", stolen" & Stolen'Image
                   & ", kernel sleeps" & Sleeps'Image
                   & (if Bad > 0 then ", FLUSH ERRORS" & Bad'Image else ""));
      end;
   end loop;

   Fibers.Release_All_Stacks;
   Ffi.Sys.Exit_Process (if Errors = 0 then 0 else 1);
end Echo_Server;
