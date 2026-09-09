with Iour.Http.Parse;

package body Iour.Http.Wire with SPARK_Mode => On is

   procedure Read_Head
     (Sock      : Iour.Net.Socket;
      Head      : out Head_Buffer;
      Used      : out Natural;
   Head_End  : out Natural;
      Status    : out Parse_Status;
      Transport : out Iour.Io_Result)
   is
      Received : Iour.Io_Result;
      End_At   : Natural;
   begin
      Head := [others => 0];
      Used := 0;
      Head_End := 0;
      Status := Incomplete;
      Transport := 0;

      loop
         if Used = Head'Length then
            Status := Too_Large;
            return;
         end if;

         Net.Receive (Sock, Head (Used .. Head'Last), Received);
         if Received <= 0 then
            Transport := Received;
            return;
         elsif Received > Iour.Io_Result (Head'Length - Used) then
            Transport := -Iour.E_Invalid;
            return;
         end if;

         Used := Used + Natural (Received);
         Parse.Find_Head_End (Head, Used, Status, End_At);
         if Status = Complete or else Status = Too_Large then
            Head_End := End_At;
            return;
         end if;
      end loop;
   end Read_Head;

   procedure Write_All
     (Sock      : Iour.Net.Socket;
      Data      : Iour.Byte_Array;
      Transport : out Iour.Io_Result) is
   begin
      Net.Send_All (Sock, Data, Transport);
   end Write_All;

end Iour.Http.Wire;