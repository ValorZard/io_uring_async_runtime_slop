with Ada.Command_Line; use Ada.Command_Line;
with Ada.Real_Time; use Ada.Real_Time;
with Ada.Text_IO; use Ada.Text_IO;
with Iour;
with Iour.Ffi.Sys;
with Iour.Net;
with Iour.Scheduler;
with Iour.Shards;
with Http_Client_App;

procedure Http_Client with SPARK_Mode => On, CPU => 1 is
   pragma Annotate
     (GNATprove, Intentional,
      "all paths",
      "A Jorvik partition ends by calling Exit_Process; returning from the "
      & "main subprogram would hang on tasks that may not terminate.");

   Max_Argument : constant := 1_000_000;
   Max_Host_Arg : constant := 46;

   function Elapsed_Milliseconds (From, To : Time) return Integer
     with Global => null;

   function Elapsed_Milliseconds (From, To : Time) return Integer
     with SPARK_Mode => Off is
   begin
      if To <= From then
         return 0;
      end if;
      return (To - From) / Milliseconds (1);
   end Elapsed_Milliseconds;

   function Argument_Or (Index : Positive; Default : Natural) return Natural is
      Value : Natural := 0;
   begin
      if Argument_Count < Index then
         return Default;
      end if;
      declare
         Text : constant String := Argument (Index);
      begin
         if Text'Length = 0 then
            return Default;
         end if;
         for Character_At in Text'Range loop
            pragma Loop_Invariant (Value <= Max_Argument);
            if Text (Character_At) not in '0' .. '9' then
               return Default;
            end if;
            if Value > (Max_Argument - (Character'Pos (Text (Character_At))
                                        - Character'Pos ('0'))) / 10
            then
               return Default;
            end if;
            Value := Value * 10
              + (Character'Pos (Text (Character_At)) - Character'Pos ('0'));
         end loop;
         return Value;
      end;
   end Argument_Or;

   function Host_Argument return String is
     (if Argument_Count = 0 then "127.0.0.1"
      elsif Argument (1)'Length = 0 then "127.0.0.1"
      elsif Argument (1)'Length > Max_Host_Arg
      then Argument (1) (Argument (1)'First
                         .. Argument (1)'First + Max_Host_Arg - 1)
      else Argument (1));

   Host : constant String := Host_Argument;
   Port : constant Natural := Argument_Or (2, 8080);
   Connections : constant Natural := Argument_Or (3, 1);
   Rounds : constant Natural := Argument_Or (4, 1);
   Started : Boolean;
   Sessions, Succeeded, Failed, Requests : Natural;
   From, To : Time;
begin
   Iour.Net.Ignore_Broken_Pipes;
   Iour.Shards.Activate;
   Iour.Scheduler.Wait_Until_Ready;
   Http_Client_App.Configure (Host, Port, Connections, Rounds);
   Http_Client_App.Start (Started);
   if not Started then
      Put_Line ("http_client: could not start session");
      Iour.Ffi.Sys.Exit_Process (1);
   end if;
   Iour.Scheduler.Wait_For_Shutdown;
   Http_Client_App.Session_Window (From, To);
   Http_Client_App.Result (Sessions, Succeeded, Failed, Requests);
   Put_Line ("http_client: " & Host & " port" & Port'Image & "," & Connections'Image
             & " connections," & Rounds'Image & " rounds each");
   Put_Line ("http_client: sessions started" & Sessions'Image & ", succeeded"
             & Succeeded'Image & ", failed" & Failed'Image);
   Put_Line ("http_client: frames exchanged" & Requests'Image);
   declare
      Elapsed : constant Integer := Elapsed_Milliseconds (From, To);
   begin
      Put_Line ("http_client: elapsed" & Elapsed'Image & " ms");
      if Elapsed > 0 and then Requests <= Natural'Last / 1000 then
         Put_Line ("http_client: round trips per second"
                   & Natural'Image (Requests * 1000 / Natural (Elapsed)));
      end if;
   end;
   Iour.Ffi.Sys.Exit_Process (if Failed = 0 then 0 else 1);
end Http_Client;