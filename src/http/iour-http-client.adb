with Iour.Http.Parse;
with Iour.Http.Wire;

package body Iour.Http.Client with SPARK_Mode => On is

   Max_Request_Bytes : constant := 2_048;

   --  A named constrained subtype, and Put_Text takes it rather than an
   --  unconstrained Byte_Array.  Byte_Array is indexed by Natural, so an
   --  unconstrained one running to Natural'Last has a length of
   --  Natural'Last + 1: its 'Length is not itself a Natural, and every
   --  bound written in terms of it carries a range check nothing can
   --  discharge.  Constrained, the length is static.
   subtype Request_Buffer is Iour.Byte_Array (0 .. Max_Request_Bytes - 1);

   procedure Put_Text
     (Into : in out Request_Buffer; Used : in out Natural; Value : String)
     with Pre  => Used <= Max_Request_Bytes
                  and then Value'Length <= Max_Request_Bytes - Used,
          Post => Used = Used'Old + Value'Length;

   procedure Put_Text
     (Into : in out Request_Buffer; Used : in out Natural; Value : String) is
   begin
      for Index in Value'Range loop
         pragma Loop_Invariant (Used = Used'Loop_Entry + (Index - Value'First));
         pragma Loop_Invariant (Used < Max_Request_Bytes);
         Into (Used) := Iour.Byte (Character'Pos (Value (Index)));
         Used := Used + 1;
      end loop;
   end Put_Text;

   procedure Request
     (Sock            : Iour.Net.Socket;
      Request_Method  : Method;
      Host            : String;
      Target          : String;
      Response_Status : out Status_Code;
      Transport       : out Iour.Io_Result;
      Status          : out Parse_Status)
   is
      Outgoing : Request_Buffer := [others => 0];
      Used     : Natural := 0;
      Head     : Head_Buffer;
      Head_Used, Head_End, Line_End : Natural;
      Response_Version : Version;
   begin
      Response_Status := 500;
      Transport := 0;
      Status := Malformed;
      --  64 is the fixed text of the largest request this builds: "POST "
      --  and " HTTP/1.1" CRLF "Host: " and CRLF and "Content-Length: 0"
      --  CRLF and "Connection: close" CRLF CRLF, which is 5 + 17 + 2 + 19
      --  + 21.  Written as two subtractions rather than as a sum, so that
      --  a pathological Host or Target cannot overflow the test itself.
      if (Request_Method /= Get and then Request_Method /= Post)
        or else Host'Length > Max_Request_Bytes - 64
        or else Target'Length > Max_Request_Bytes - 64 - Host'Length
      then
         Transport := -Iour.E_Invalid;
         return;
      end if;
      if Request_Method = Get then
         Put_Text (Outgoing, Used, "GET ");
      else
         Put_Text (Outgoing, Used, "POST ");
      end if;
      Put_Text (Outgoing, Used, Target);
      Put_Text (Outgoing, Used, " HTTP/1.1" & ASCII.CR & ASCII.LF & "Host: ");
      Put_Text (Outgoing, Used, Host);
      Put_Text (Outgoing, Used, "" & ASCII.CR & ASCII.LF);
      if Request_Method = Post then
         Put_Text (Outgoing, Used, "Content-Length: 0" & ASCII.CR & ASCII.LF);
      end if;
      Put_Text (Outgoing, Used, "Connection: close" & ASCII.CR & ASCII.LF
                & ASCII.CR & ASCII.LF);
      Wire.Write_All (Sock, Outgoing (0 .. Used - 1), Transport);
      if Transport < 0 then
         return;
      end if;
      Wire.Read_Head (Sock, Head, Head_Used, Head_End, Status, Transport);
      if Transport < 0 or else Status /= Complete then
         return;
      end if;
      Parse.Find_Line_End (Head, Head_Used, Status, Line_End);
      if Status /= Complete or else Line_End = 0 then
         return;
      end if;
         Parse.Status_Line
            (Head, 0, Line_End - 1, Response_Version, Response_Status, Status);
   end Request;

end Iour.Http.Client;