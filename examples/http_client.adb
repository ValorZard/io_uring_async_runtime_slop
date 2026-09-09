with Ada.Text_IO; use Ada.Text_IO;
with Iour;
with Iour.Ffi.Sys;
with Iour.Net;
with Iour.Scheduler;
with Iour.Shards;
with Http_Client_App;

procedure Http_Client with SPARK_Mode => On, CPU => 1 is
   Started : Boolean;
   Code    : Iour.Io_Result;
   Ok      : Boolean;
begin
   Iour.Net.Ignore_Broken_Pipes;
   Iour.Shards.Activate;
   Iour.Scheduler.Wait_Until_Ready;
   Http_Client_App.Start (Started);
   if not Started then
      Put_Line ("http_client: could not start session");
      Iour.Ffi.Sys.Exit_Process (1);
   end if;
   Iour.Scheduler.Wait_For_Shutdown;
   Http_Client_App.Result (Code, Ok);
   Put_Line ("http_client: status" & Code'Image
             & (if Ok then " PASS" else " FAIL"));
   Iour.Ffi.Sys.Exit_Process (if Ok then 0 else 1);
end Http_Client;