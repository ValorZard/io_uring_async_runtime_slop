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

   --  End_At names the CR of the first CRLF, so a caller that has found a
   --  line can pass End_At - 1 as its last byte.  The postcondition is
   --  what makes that legal without a second guard: a found position is
   --  inside Data, and 0 -- the not-found answer -- is too.
   procedure Find_Line_End
     (Data      : Head_Buffer;
      Available : Natural;
      Status    : out Parse_Status;
      End_At    : out Natural)
     with Pre    => Available <= Data'Length,
          Post   => End_At <= Data'Last,
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