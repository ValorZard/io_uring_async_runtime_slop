with Iour.Http.Parse;
with Iour.Http.Wire;
with Iour.Fibers.Job;
with Iour.Net;

package body Iour.Http.Server with SPARK_Mode => On is

   procedure Serve (Arg : Iour.Fiber_Argument);
   procedure Acceptor (Arg : Iour.Fiber_Argument);

   package Serve_Job is new Iour.Fibers.Job (Work => Serve);
   package Acceptor_Job is new Iour.Fibers.Job (Work => Acceptor);

   Max_Response_Bytes : constant := 2_048;

   --  A named constrained subtype, and the three writers below take it
   --  rather than an unconstrained Byte_Array.  Byte_Array is indexed by
   --  Natural, so an unconstrained one running to Natural'Last has a
   --  length of Natural'Last + 1: its 'Length is not itself a Natural,
   --  and every bound written in terms of it carries a range check
   --  nothing can discharge.  Constrained, the length is static and the
   --  arithmetic below is ordinary.
   subtype Response_Buffer is Iour.Byte_Array (0 .. Max_Response_Bytes - 1);

   --  Max_Response_Body is 1024, which is four digits, and that is what
   --  bounds Put_Length's output and so the size of the response head.
   Max_Length_Digits : constant := 4;

   procedure Put_Byte
     (Into : in out Response_Buffer; Used : in out Natural; Value : Character)
     with Pre  => Used < Max_Response_Bytes,
          Post => Used = Used'Old + 1;

   procedure Put_Text
     (Into : in out Response_Buffer; Used : in out Natural; Value : String)
     with Pre  => Used <= Max_Response_Bytes
                  and then Value'Length <= Max_Response_Bytes - Used,
          Post => Used = Used'Old + Value'Length;

   procedure Put_Length
     (Into : in out Response_Buffer; Used : in out Natural; Value : Natural)
     with Pre  => Value <= Max_Response_Body
                  and then Used <= Max_Response_Bytes - Max_Length_Digits,
          Post => Used in Used'Old + 1 .. Used'Old + Max_Length_Digits;

   procedure Put_Byte
     (Into : in out Response_Buffer; Used : in out Natural; Value : Character) is
   begin
      Into (Used) := Iour.Byte (Character'Pos (Value));
      Used := Used + 1;
   end Put_Byte;

   procedure Put_Text
     (Into : in out Response_Buffer; Used : in out Natural; Value : String) is
   begin
      for Index in Value'Range loop
         pragma Loop_Invariant (Used = Used'Loop_Entry + (Index - Value'First));
         pragma Loop_Invariant (Used < Max_Response_Bytes);
         Put_Byte (Into, Used, Value (Index));
      end loop;
   end Put_Text;

   --  Least significant digit first into a small local, then out in
   --  reverse.  The divisor loop this replaced could not be proved
   --  without bounding the divisor, and bounding the divisor is harder to
   --  read than bounding the digit count: Value is at most
   --  Max_Response_Body, so four digits is the whole story.
   procedure Put_Length
     (Into : in out Response_Buffer; Used : in out Natural; Value : Natural)
   is
      Digit_Text : String (1 .. Max_Length_Digits) := [others => '0'];
      Count      : Natural := 0;
      Rest       : Natural := Value;
   begin
      loop
         pragma Loop_Invariant (Count in 0 .. Max_Length_Digits - 1);
         pragma Loop_Invariant (Rest <= Max_Response_Body);
         Count := Count + 1;
         Digit_Text (Count) :=
           Character'Val (Character'Pos ('0') + Rest mod 10);
         Rest := Rest / 10;
         exit when Rest = 0 or else Count = Max_Length_Digits;
      end loop;

      for Index in reverse 1 .. Count loop
         pragma Loop_Invariant
           (Used = Used'Loop_Entry + (Count - Index));
         pragma Loop_Invariant (Used < Max_Response_Bytes);
         Put_Byte (Into, Used, Digit_Text (Index));
      end loop;
   end Put_Length;

   procedure Serve (Arg : Iour.Fiber_Argument) is
      Sock        : Iour.Net.Socket;
      Head        : Head_Buffer;
      Used        : Natural;
      Head_End    : Natural;
      Parse_State : Parse_Status;
      Transport   : Iour.Io_Result;
      Closed      : Iour.Io_Result;
      Line_End    : Natural;
      Request_Method : Method;
      Target_First, Target_Last : Natural;
      Request_Version : Version;
      Payload        : Iour.Byte_Array (0 .. Max_Response_Body - 1);
      Payload_Length : Natural := 0;
      Response    : Response_Buffer := [others => 0];
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
      --  Handle is a generic formal and carries no contract, so what it
      --  reports is checked rather than trusted.  This is also what gives
      --  Put_Length its bound.
      if Payload_Length > Max_Response_Body then
         Iour.Net.Close (Sock, Transport);
         return;
      end if;
      Put_Text (Response, Response_Used, "HTTP/1.1 200 OK" & ASCII.CR & ASCII.LF);
      Put_Text (Response, Response_Used, "Content-Length: ");
      Put_Length (Response, Response_Used, Payload_Length);
      Put_Text (Response, Response_Used,
                "" & ASCII.CR & ASCII.LF & "Connection: close" & ASCII.CR
                & ASCII.LF & ASCII.CR & ASCII.LF);
      if Payload_Length > Max_Response_Bytes - Response_Used then
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
      --  Nothing can be done about a failed write here -- the peer is gone
      --  or the socket is broken -- but the close is still owed, and its
      --  result belongs in its own variable rather than on top of the
      --  write's.
      Iour.Net.Close (Sock, Closed);
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