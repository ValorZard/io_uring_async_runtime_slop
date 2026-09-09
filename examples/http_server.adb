with Ada.Command_Line; use Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;
with Iour;        use Iour;
with Iour.Ffi.Sys;
with Iour.Net;
with Iour.Scheduler;
with Iour.Shards;
with Http_Server_App;

procedure Http_Server with SPARK_Mode => On, CPU => 1 is

   function Argument_Or (Index : Positive; Default : Natural) return Natural is
   begin
      if Argument_Count < Index then
         return Default;
      end if;
      return Natural'Value (Argument (Index));
   exception
      when Constraint_Error => return Default;
   end Argument_Or;

   Listener : Io_Result;
   Bound    : Io_Result;
   Started  : Boolean;
begin
   Net.Ignore_Broken_Pipes;
   Listener := Net.Listen (Argument_Or (1, 8080));
   if Failed (Listener) then
      Put_Line ("http_server: cannot listen");
      Ffi.Sys.Exit_Process (1);
   end if;
   Bound := Net.Port_Of (Descriptor (Listener));
   Shards.Activate;
   Scheduler.Wait_Until_Ready;
    Http_Server_App.Configure
       (Descriptor (Listener), Argument_Or (2, 0));
    Http_Server_App.Start
       (Active_Shard'First, Descriptor (Listener), Started);
   if not Started then
      Put_Line ("http_server: cannot start acceptor");
      Ffi.Sys.Exit_Process (1);
   end if;
   Put_Line ("http_server: listening on port" & Bound'Image
             & " with" & Shard_Count'Image & " shards");
   Scheduler.Wait_For_Shutdown;
   Ffi.Sys.Exit_Process (0);
end Http_Server;