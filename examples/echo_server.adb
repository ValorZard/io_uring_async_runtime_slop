------------------------------------------------------------------------------
--  echo_server -- a server on the io_uring runtime.
--
--    ./bin/echo_server [port] [connections-to-serve]
--
--  A connections-to-serve of 0 means run until killed.
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

   Listener : Io_Result;
   Bound    : Io_Result;
   Handle   : Future_Ref;
   Fd_Limit : Natural;

   Accepted, Completed, Rejected, Frames, Errors, Concurrent : Natural;
   Live, Peak : Natural;
begin
   Net.Ignore_Broken_Pipes;
   Fd_Limit := Ffi.Sys.Raise_Descriptor_Limit;

   Listener := Net.Listen (Port);
   if Failed (Listener) then
      Put_Line ("echo_server: cannot listen on port" & Port'Image
                & " (errno" & Errno (Listener)'Image & ")");
      Ffi.Sys.Exit_Process (1);
   end if;

   Bound := Net.Port_Of (Descriptor (Listener));

   Echo_Server_App.Configure (Descriptor (Listener), Target);

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

   --  One acceptor fiber.  Everything else is spawned by it, onto the
   --  global run queue, and picked up by whichever core is free.
   Fibers.Spawn
     (Echo_Server_App.Acceptor'Access,
      Fiber_Argument (Listener),
      Handle);

   if Handle = No_Future then
      Put_Line ("echo_server: could not start the acceptor");
      Ffi.Sys.Exit_Process (1);
   end if;

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
         Completions, Resumes, Adopted, Sleeps, Left : Natural;
      begin
         Scheduler.Report (S, Completions, Resumes, Adopted, Sleeps, Left);
         Put_Line ("  shard" & S'Image
                   & ": completions" & Completions'Image
                   & ", resumes" & Resumes'Image
                   & ", connections adopted" & Adopted'Image
                   & ", kernel sleeps" & Sleeps'Image);
      end;
   end loop;

   Fibers.Release_All_Stacks;
   Ffi.Sys.Exit_Process (if Errors = 0 then 0 else 1);
end Echo_Server;
