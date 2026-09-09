with Iour.Fibers.Job;
with Iour.Http;
with Iour.Http.Client;
with Iour.Net;
with Iour.Scheduler;

package body Http_Client_App with SPARK_Mode => On is

   use type Iour.Future_Ref;
   use type Iour.Http.Parse_Status;
   use type Iour.Http.Status_Code;

   protected Outcome with Priority => Iour.Runtime_Priority is
      procedure Put (Code : Iour.Io_Result; Success : Boolean);
      procedure Get (Code : out Iour.Io_Result; Success : out Boolean);
   private
      Response_Code : Iour.Io_Result := 0;
      Completed     : Boolean := False;
   end Outcome;

   protected body Outcome is
      procedure Put (Code : Iour.Io_Result; Success : Boolean) is
      begin
         Response_Code := Code;
         Completed := Success;
      end Put;

      procedure Get (Code : out Iour.Io_Result; Success : out Boolean) is
      begin
         Code := Response_Code;
         Success := Completed;
      end Get;
   end Outcome;

   procedure Session (Arg : Iour.Fiber_Argument);
   package Session_Job is new Iour.Fibers.Job (Work => Session);

   procedure Session (Arg : Iour.Fiber_Argument) is
      pragma Unreferenced (Arg);
      Opened   : Iour.Io_Result;
      Transport : Iour.Io_Result;
      Code     : Iour.Http.Status_Code;
      Status   : Iour.Http.Parse_Status;
      Sock     : Iour.Net.Socket;
   begin
      Opened := Iour.Net.New_Socket;
      if Iour.Failed (Opened) then
         Outcome.Put (Opened, False);
         Iour.Scheduler.Request_Shutdown;
         return;
      end if;
      Sock := Iour.Net.Socket (Opened);
      Iour.Net.Connect (Sock, "127.0.0.1", 8080, Transport);
      if Iour.Failed (Transport) then
         Iour.Net.Close (Sock, Transport);
         Outcome.Put (Transport, False);
         Iour.Scheduler.Request_Shutdown;
         return;
      end if;
      Iour.Http.Client.Request
        (Sock, Iour.Http.Get, "127.0.0.1", "/", Code, Transport, Status);
      Iour.Net.Close (Sock, Transport);
      Outcome.Put (Iour.Io_Result (Code),
                   Status = Iour.Http.Complete and then Transport >= 0
                   and then Code = 200);
      Iour.Scheduler.Request_Shutdown;
   end Session;

   procedure Start (Started : out Boolean) is
      Handle : Iour.Future_Ref;
   begin
      Session_Job.Spawn (0, Handle);
      Started := Handle /= Iour.No_Future;
   end Start;

   procedure Result (Code : out Iour.Io_Result; Ok : out Boolean) is
   begin
      Outcome.Get (Code, Ok);
   end Result;

end Http_Client_App;