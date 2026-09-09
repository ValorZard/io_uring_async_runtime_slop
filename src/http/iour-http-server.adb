with Iour.Http.Parse;
with Iour.Http.Wire;
with Iour.Fibers.Job;

package body Iour.Http.Server with SPARK_Mode => On is

   procedure Serve (Arg : Iour.Fiber_Argument);
   procedure Acceptor (Arg : Iour.Fiber_Argument);

   package Serve_Job is new Iour.Fibers.Job (Work => Serve);
   package Acceptor_Job is new Iour.Fibers.Job (Work => Acceptor);

   procedure Put_Byte
     (Into : in out Iour.Byte_Array; Used : in out Natural; Value : Character) is
   begin
      Into (Into'First + Used) := Iour.Byte (Character'Pos (Value));
      Used := Used + 1;
   end Put_Byte;

   procedure Put_Text
     (Into : in out Iour.Byte_Array; Used : in out Natural; Value : String) is
   begin
      for Index in Value'Range loop
         Put_Byte (Into, Used, Value (Index));
      end loop;
   end Put_Text;

   procedure Put_Length
     (Into : in out Iour.Byte_Array; Used : in out Natural; Value : Natural) is
      Divisor : Natural := 1;
      Rest    : Natural := Value;
   begin
      while Rest >= 10 loop
         Rest := Rest / 10;
         Divisor := Divisor * 10;
      end loop;
      Rest := Value;
      loop
         Put_Byte (Into, Used, Character'Val (Character'Pos ('0') + Rest / Divisor));
         Rest := Rest mod Divisor;
         exit when Divisor = 1;
         Divisor := Divisor / 10;
      end loop;
   end Put_Length;

   procedure Serve (Arg : Iour.Fiber_Argument) is
      Sock        : Iour.Net.Socket;
      Head        : Head_Buffer;
      Used        : Natural;
      Head_End    : Natural;
      Parse_State : Parse_Status;
      Transport   : Iour.Io_Result;
      Line_End    : Natural;
      Request_Method : Method;
      Target_First, Target_Last : Natural;
      Request_Version : Version;
      Payload        : Iour.Byte_Array (0 .. Max_Response_Body - 1);
      Payload_Length : Natural := 0;
      Response    : Iour.Byte_Array (0 .. 2_047) := [others => 0];
      Response_Used : Natural := 0;
   begin
      if Arg not in Iour.Fiber_Argument (Iour.Net.Socket'First) ..
                    Iour.Fiber_Argument (Iour.Net.Socket'Last)
      then
         return;
      end if;
      Sock := Iour.Net.Socket (Arg);
      Wire.Read_Head (Sock, Head, Used, Head_End, Parse_State, Transport);
      if Transport < 0 or else Parse_State /= Complete then
         Iour.Net.Close (Sock, Transport);
         return;
      end if;
      Parse.Find_Line_End (Head, Used, Parse_State, Line_End);
         if Parse_State /= Complete or else Line_End = 0
            or else Line_End > Head'Last
         then
         Iour.Net.Close (Sock, Transport);
         return;
      end if;
      Parse.Request_Line
        (Head, 0, Line_End - 1, Request_Method, Target_First, Target_Last,
         Request_Version, Parse_State);
      if Parse_State /= Complete then
         Iour.Net.Close (Sock, Transport);
         return;
      end if;
      Handle
        (Request_Method, Head, Target_First, Target_Last, Payload,
         Payload_Length);
      if Payload_Length > Payload'Length then
         Iour.Net.Close (Sock, Transport);
         return;
      end if;
      Put_Text (Response, Response_Used, "HTTP/1.1 200 OK" & ASCII.CR & ASCII.LF);
      Put_Text (Response, Response_Used, "Content-Length: ");
      Put_Length (Response, Response_Used, Payload_Length);
      Put_Text (Response, Response_Used,
                "" & ASCII.CR & ASCII.LF & "Connection: close" & ASCII.CR
                & ASCII.LF & ASCII.CR & ASCII.LF);
      if Payload_Length > Response'Length - Response_Used then
         Iour.Net.Close (Sock, Transport);
         return;
      end if;
      if Payload_Length > 0 then
         for Index in 0 .. Payload_Length - 1 loop
            Response (Response_Used + Index) := Payload (Index);
         end loop;
      end if;
      Response_Used := Response_Used + Payload_Length;
      Wire.Write_All (Sock, Response (0 .. Response_Used - 1), Transport);
      Iour.Net.Close (Sock, Transport);
      Completed;
   end Serve;

   procedure Acceptor (Arg : Iour.Fiber_Argument) is
      Listener : Iour.Net.Socket;
      Incoming : Iour.Io_Result;
      Started  : Boolean;
   begin
      if Arg not in Iour.Fiber_Argument (Iour.Net.Socket'First) ..
                    Iour.Fiber_Argument (Iour.Net.Socket'Last)
      then
         return;
      end if;
      Listener := Iour.Net.Socket (Arg);
      loop
         Iour.Net.Accept_Connection (Listener, Incoming);
         exit when Incoming < 0;
         Serve_Job.Spawn_Here (Iour.Fiber_Argument (Incoming), Started);
         if not Started then
            Incoming := Iour.Net.Close_Now (Iour.Net.Socket (Incoming));
         end if;
      end loop;
   end Acceptor;

   procedure Start_Acceptor
     (Shard : Iour.Active_Shard; Listener : Iour.Descriptor; Started : out Boolean) is
   begin
      Acceptor_Job.Spawn_On (Shard, Iour.Fiber_Argument (Listener), Started);
   end Start_Acceptor;

end Iour.Http.Server;