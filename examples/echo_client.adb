------------------------------------------------------------------------------
--  echo_client -- drives the server with many simultaneous conversations.
--
--    ./bin/echo_client [host] [port] [connections] [rounds]
--
--  Every connection is one fiber.  With the defaults that is 1000
--  conversations in flight at once, all of them running on Shard_Count
--  operating system threads -- which is the point of the exercise.
--
--  Timing uses Ada.Real_Time; Jorvik forbids Ada.Calendar outright.
------------------------------------------------------------------------------

with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Real_Time;     use Ada.Real_Time;
with Ada.Text_IO;       use Ada.Text_IO;
with Iour;              use Iour;
with Iour.Ffi.Sys;
with Iour.Fibers;
with Iour.Net;
with Iour.Scheduler;
with Iour.Shards;
with Echo_Client_App;

procedure Echo_Client with SPARK_Mode => On, CPU => 1 is

   function Argument_Or (Index : Positive; Default : Natural) return Natural is
   begin
      if Argument_Count < Index then
         return Default;
      end if;
      declare
         Value : Integer;
      begin
         Value := Integer'Value (Argument (Index));
         return (if Value < 0 then Default else Value);
      exception
         when others =>
            return Default;
      end;
   end Argument_Or;

   function Host_Argument return String is
     (if Argument_Count >= 1 then Argument (1) else "127.0.0.1");

   Host        : constant String  := Host_Argument;
   Port        : constant Natural := Argument_Or (2, 9099);
   Connections : constant Natural := Argument_Or (3, 1000);
   Rounds      : constant Natural := Argument_Or (4, 8);

   Handle   : Future_Ref;
   Fd_Limit : Natural;

   Started, Succeeded, Failures, Frames, Mismatched, Concurrent : Natural;
   Live, Peak : Natural;

   Start_Time : Time;
   Elapsed    : Duration;
begin
   Net.Ignore_Broken_Pipes;
   Fd_Limit := Ffi.Sys.Raise_Descriptor_Limit;

   Echo_Client_App.Configure (Host, Port, Connections, Rounds);

   Shards.Activate;
   Scheduler.Wait_Until_Ready;

   Put_Line ("echo_client: " & Host & " port" & Port'Image
             & ", " & Connections'Image & " connections"
             & "," & Rounds'Image & " rounds each");
   Put_Line ("echo_client: " & Shard_Count'Image & " shards"
             & ", descriptor limit" & Fd_Limit'Image);

   Start_Time := Clock;

   Fibers.Spawn (Echo_Client_App.Driver'Access, 0, Handle);
   if Handle = No_Future then
      Put_Line ("echo_client: could not start the driver");
      Ffi.Sys.Exit_Process (1);
   end if;

   Scheduler.Wait_For_Shutdown;
   Elapsed := To_Duration (Clock - Start_Time);

   Echo_Client_App.Snapshot
     (Started, Succeeded, Failures, Frames, Mismatched, Concurrent);
   Fibers.Live_Fibers (Live, Peak);

   New_Line;
   Put_Line ("echo_client: sessions started" & Started'Image
             & ", succeeded" & Succeeded'Image
             & ", failed" & Failures'Image);
   Put_Line ("echo_client: frames exchanged" & Frames'Image
             & ", protocol mismatches" & Mismatched'Image);
   Put_Line ("echo_client: peak concurrent sessions" & Concurrent'Image
             & ", peak fibers" & Peak'Image);
   Put_Line ("echo_client: elapsed " & Elapsed'Image & " s");

   if Elapsed > 0.0 then
      declare
         --  Each frame is one request and one response, so the round trip
         --  count is the frame count.
         Per_Second : constant Long_Float :=
           Long_Float (Frames) / Long_Float (Elapsed);
      begin
         Put_Line ("echo_client: round trips per second"
                   & Long_Float'Image (Per_Second));
      end;
   end if;

   for S in Active_Shard loop
      declare
         Completions, Resumes, Adopted, Sleeps, Left, Bad : Natural;
      begin
         Scheduler.Report
           (S, Completions, Resumes, Adopted, Sleeps, Left, Bad);
         Put_Line ("  shard" & S'Image
                   & ": completions" & Completions'Image
                   & ", resumes" & Resumes'Image
                   & ", sessions adopted" & Adopted'Image
                   & ", kernel sleeps" & Sleeps'Image
                   & (if Bad > 0 then ", FLUSH ERRORS" & Bad'Image else ""));
      end;
   end loop;

   Fibers.Release_All_Stacks;

   Ffi.Sys.Exit_Process
     (if Succeeded = Connections and then Mismatched = 0 then 0 else 1);
end Echo_Client;
