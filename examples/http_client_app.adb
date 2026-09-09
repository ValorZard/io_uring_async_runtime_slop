with Iour.Fibers.Job;
with Iour.Http;
with Iour.Http.Client;
with Iour.Net;
with Iour.Scheduler;
with Iour.Time;

package body Http_Client_App with SPARK_Mode => On is

   package Rt renames Ada.Real_Time;

   use type Iour.Future_Ref;
   use type Iour.Http.Parse_Status;
   use type Iour.Http.Status_Code;

   Max_Host : constant := 46;
   type Host_Text is array (1 .. Max_Host) of Character;

   protected Configuration with Priority => Iour.Runtime_Priority is
      procedure Set
        (Host : String; Port : Natural; Connections : Natural; Rounds : Natural);
      procedure Get
            (Host : out Host_Text; Last : out Natural; Port : out Natural;
         Connections : out Natural; Rounds : out Natural);
   private
      Text : Host_Text := [others => ' '];
      Held : Natural := 0;
      Server_Port : Natural := 8080;
      Session_Count : Natural := 1;
      Round_Count : Natural := 1;
   end Configuration;

   protected body Configuration is
      procedure Set
        (Host : String; Port : Natural; Connections : Natural; Rounds : Natural) is
         Length : constant Natural := Natural'Min (Host'Length, Max_Host);
         Destination : Natural := 1;
      begin
         Text := [others => ' '];
         for Index in Host'Range loop
            exit when Destination > Length;
            Text (Destination) := Host (Index);
            Destination := Destination + 1;
         end loop;
         Held := Length;
         Server_Port := Port;
         Session_Count := Connections;
         Round_Count := Rounds;
      end Set;

      procedure Get
            (Host : out Host_Text; Last : out Natural; Port : out Natural;
         Connections : out Natural; Rounds : out Natural) is
      begin
         Host := [others => ' '];
         for Index in 1 .. Held loop
            Host (Index) := Text (Index);
         end loop;
         Last := Held;
         Port := Server_Port;
         Connections := Session_Count;
         Rounds := Round_Count;
      end Get;
   end Configuration;

   protected Stats with Priority => Iour.Runtime_Priority is
      procedure Set_Goal (Value : Natural);
         procedure Finished
            (Ok : Boolean; Requests : Natural; At_Time : Rt.Time);
      procedure Read
        (Started : out Natural; Succeeded : out Natural;
         Failed : out Natural; Requests : out Natural);
      procedure Goal (Value : out Natural);
         procedure Open_Window (At_Time : Rt.Time);
         procedure Window (From, To : out Rt.Time);
   private
      Session_Goal : Natural := 1;
      Total_Started : Natural := 0;
      Total_Succeeded : Natural := 0;
      Total_Failed : Natural := 0;
      Total_Requests : Natural := 0;
      Opened : Rt.Time := Rt.Time_First;
      Last_End : Rt.Time := Rt.Time_First;
   end Stats;

   protected body Stats is
      procedure Set_Goal (Value : Natural) is
      begin
         Session_Goal := Value;
      end Set_Goal;

      procedure Finished
        (Ok : Boolean; Requests : Natural; At_Time : Rt.Time) is
      begin
         Last_End := At_Time;
         if Total_Started < Natural'Last then
            Total_Started := Total_Started + 1;
         end if;
         if Requests > Natural'Last - Total_Requests then
            Total_Requests := Natural'Last;
         else
            Total_Requests := Total_Requests + Requests;
         end if;
         if Ok then
            if Total_Succeeded < Natural'Last then
               Total_Succeeded := Total_Succeeded + 1;
            end if;
         else
            if Total_Failed < Natural'Last then
               Total_Failed := Total_Failed + 1;
            end if;
         end if;
      end Finished;

      procedure Read
        (Started : out Natural; Succeeded : out Natural;
         Failed : out Natural; Requests : out Natural) is
      begin
         Started := Total_Started;
         Succeeded := Total_Succeeded;
         Failed := Total_Failed;
         Requests := Total_Requests;
      end Read;

      procedure Goal (Value : out Natural) is
      begin
         Value := Session_Goal;
      end Goal;

      procedure Open_Window (At_Time : Rt.Time) is
      begin
         Opened := At_Time;
      end Open_Window;

      procedure Window (From, To : out Rt.Time) is
      begin
         From := Opened;
         To := Last_End;
      end Window;
   end Stats;

   procedure Session (Arg : Iour.Fiber_Argument);
   package Session_Job is new Iour.Fibers.Job (Work => Session);
   procedure Driver (Arg : Iour.Fiber_Argument);
   package Driver_Job is new Iour.Fibers.Job (Work => Driver);

   procedure Session (Arg : Iour.Fiber_Argument) is
      pragma Unreferenced (Arg);
      Opened, Transport   : Iour.Io_Result;
      Port : Natural;
      Rounds, Connections, Host_Len : Natural;
      Host : Host_Text;
      Requests : Natural := 0;
      Ok : Boolean := True;
      Now : Rt.Time;
      Sock : Iour.Net.Socket;
      Code : Iour.Http.Status_Code;
      Parse_State : Iour.Http.Parse_Status;
   begin
      Configuration.Get (Host, Host_Len, Port, Connections, Rounds);
      for Round in 1 .. Rounds loop
         Opened := Iour.Net.New_Socket;
         if Iour.Failed (Opened) then
            Ok := False;
            exit;
         end if;
         Sock := Iour.Net.Socket (Opened);
             Iour.Net.Connect
                (Sock, String (Host (1 .. Host_Len)), Port, Transport);
         if Iour.Failed (Transport) then
            Iour.Net.Close (Sock, Transport);
            Ok := False;
            exit;
         end if;
         Iour.Http.Client.Request
                (Sock, Iour.Http.Get, String (Host (1 .. Host_Len)), "/", Code,
                  Transport, Parse_State);
         Iour.Net.Close (Sock, Transport);
         if Transport < 0 or else Parse_State /= Iour.Http.Complete
           or else Code /= 200
         then
            Ok := False;
            exit;
         end if;
         if Requests < Natural'Last then
            Requests := Requests + 1;
         end if;
      end loop;
      Now := Rt.Clock;
      Stats.Finished (Ok, Requests, Now);
   end Session;

   procedure Driver (Arg : Iour.Fiber_Argument) is
      pragma Unreferenced (Arg);
      Total, Started, Succeeded, Failed, Requests : Natural;
      Handle : Iour.Future_Ref;
      Now : Rt.Time;
   begin
      Stats.Goal (Total);
      Now := Rt.Clock;
      Stats.Open_Window (Now);
      for Index in 1 .. Total loop
         Session_Job.Spawn (Iour.Fiber_Argument (Index), Handle);
      end loop;
      loop
         Stats.Read (Started, Succeeded, Failed, Requests);
         exit when Started = Total;
         Iour.Time.Sleep_Milliseconds (1);
      end loop;
      Iour.Scheduler.Request_Shutdown;
   end Driver;

   procedure Configure
     (Host : String; Port : Natural; Connections : Natural; Rounds : Natural) is
   begin
      Configuration.Set (Host, Port, Connections, Rounds);
      Stats.Set_Goal (Connections);
   end Configure;

   procedure Start (Started : out Boolean) is
      Handle : Iour.Future_Ref;
   begin
      Driver_Job.Spawn (0, Handle);
      Started := Handle /= Iour.No_Future;
   end Start;

   procedure Result
     (Started : out Natural; Succeeded : out Natural;
      Failed : out Natural; Requests : out Natural) is
   begin
      Stats.Read (Started, Succeeded, Failed, Requests);
   end Result;

   procedure Session_Window
     (From : out Ada.Real_Time.Time; To : out Ada.Real_Time.Time) is
   begin
      Stats.Window (From, To);
   end Session_Window;

end Http_Client_App;