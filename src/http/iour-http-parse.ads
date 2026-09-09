------------------------------------------------------------------------------
--  Iour.Http.Parse -- pure parsing of HTTP start lines and head boundaries.
------------------------------------------------------------------------------

package Iour.Http.Parse with SPARK_Mode => On is

   procedure Find_Head_End
               (Data     : Head_Buffer;
      Available : Natural;
      Status   : out Parse_Status;
      End_At   : out Natural)
              with Pre    => Available <= Data'Length,
          Global => null;

   procedure Request_Line
       (Data         : Head_Buffer;
      First        : Natural;
      Last         : Natural;
      Parsed_Method : out Method;
      Target_First : out Natural;
      Target_Last  : out Natural;
      Parsed_Version : out Version;
      Status       : out Parse_Status)
       with Pre    => First = 0 and then First <= Last and then Last <= Data'Last,
          Global => null;

   procedure Status_Line
       (Data           : Head_Buffer;
      First          : Natural;
      Last           : Natural;
      Parsed_Version : out Version;
      Code           : out Status_Code;
      Status         : out Parse_Status)
       with Pre    => First = 0 and then First <= Last and then Last <= Data'Last,
          Global => null;

end Iour.Http.Parse;