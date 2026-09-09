with Ada.Text_IO; use Ada.Text_IO;
with Iour;        use Iour;
with Iour.Ffi.Sys;
with Iour.Http;
with Iour.Http.Parse;

procedure Http_Parse_Test with SPARK_Mode => On, CPU => 1 is

  use type Http.Body_Kind;
  use type Http.Method;
  use type Http.Parse_Status;
  use type Http.Status_Code;
  use type Http.Version;

  Cr_Lf : constant String := "" & ASCII.CR & ASCII.LF;

   procedure Load
     (Text : String; Data : out Byte_Array; Available : out Natural)
    with Pre  => Text'Length <= Data'Length,
       Post => Available = Text'Length and then Available <= Data'Length
   is
    Position : Natural := 0;
   begin
      Data := [others => 0];
      for Index in Text'Range loop
      pragma Loop_Invariant
        (Position = Natural (Index - Text'First));
      pragma Loop_Invariant (Position <= Data'Last);
         Data (Position) := Byte (Character'Pos (Text (Index)));
         Position := Position + 1;
      end loop;
      Available := Text'Length;
   end Load;

  Data      : Http.Head_Buffer;
   Available : Natural;
   End_At    : Natural;
   Method    : Http.Method;
   Version   : Http.Version;
   Code      : Http.Status_Code;
   First     : Natural;
   Last      : Natural;
   Status    : Http.Parse_Status;
   Passed    : Boolean := True;
begin
     Load ("GET /ready HTTP/1.1" & Cr_Lf & "Host: example" & Cr_Lf & Cr_Lf,
       Data, Available);
   Http.Parse.Find_Head_End (Data, Available, Status, End_At);
   Passed := Passed and then Status = Http.Complete
     and then End_At = Available - 1;

   Http.Parse.Request_Line
     (Data, 0, 18, Method, First, Last, Version, Status);
   Passed := Passed and then Status = Http.Complete
     and then Method = Http.Get and then Version = Http.Http_11
     and then First = 4 and then Last = 9;

   Load ("POST / HTTP/1.0", Data, Available);
   Http.Parse.Request_Line
     (Data, 0, Available - 1, Method, First, Last, Version, Status);
   Passed := Passed and then Status = Http.Complete
     and then Method = Http.Post and then Version = Http.Http_10;

   Load ("GET  HTTP/1.1", Data, Available);
   Http.Parse.Request_Line
     (Data, 0, Available - 1, Method, First, Last, Version, Status);
   Passed := Passed and then Status = Http.Malformed;

   Load ("HTTP/1.1 204 No Content", Data, Available);
   Http.Parse.Status_Line
     (Data, 0, Available - 1, Version, Code, Status);
   Passed := Passed and then Status = Http.Complete
     and then Version = Http.Http_11 and then Code = 204;

   Passed := Passed and then Http.Body_Framing
     (Http.Get, 101, True, True) = Http.No_Body;
   Passed := Passed and then Http.Body_Framing
     (Http.Get, 200, True, True) = Http.Chunked;
   Passed := Passed and then Http.Body_Framing
     (Http.Head, 200, True, True) = Http.No_Body;

   Put_Line (if Passed then "http_parse_test: PASS" else "http_parse_test: FAIL");
   Ffi.Sys.Exit_Process (if Passed then 0 else 1);
end Http_Parse_Test;