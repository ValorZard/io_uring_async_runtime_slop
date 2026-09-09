with Iour.Http.Parse;
with Iour.Http.Wire;

package body Iour.Http.Client with SPARK_Mode => On is

   Max_Request_Bytes : constant := 2_048;

   procedure Put_Text
     (Into : in out Iour.Byte_Array; Used : in out Natural; Value : String) is
   begin
      for Index in Value'Range loop
         Into (Into'First + Used) := Iour.Byte (Character'Pos (Value (Index)));
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
      Outgoing : Iour.Byte_Array (0 .. Max_Request_Bytes - 1) := [others => 0];
      Used     : Natural := 0;
      Head     : Head_Buffer;
      Head_Used, Head_End, Line_End : Natural;
      Response_Version : Version;
   begin
      Response_Status := 500;
      Transport := 0;
      Status := Malformed;
      if (Request_Method /= Get and then Request_Method /= Post)
        or else Host'Length + Target'Length + 64 > Outgoing'Length
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