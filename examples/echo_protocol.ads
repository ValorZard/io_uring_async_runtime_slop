------------------------------------------------------------------------------
--  Echo_Protocol -- the wire format the demo server and client speak.
--
--  Fixed 32-byte frames.  A stream socket splits messages wherever it
--  likes, so something has to define the boundaries; a fixed size keeps the
--  framing to one Receive_Exact and leaves the interesting part of the demo
--  -- thousands of concurrent conversations -- in view.
--
--     bytes  0 .. 3   four-character tag: PING, PONG, BYE
--     bytes  4 .. 5   spaces
--     bytes  6 .. 14  nine decimal digits, zero padded: the sequence number
--     bytes 15 .. 31  spaces
--
--  Nine digits rather than ten so the largest value still fits a 32-bit
--  Natural, which keeps parsing free of overflow checks.
------------------------------------------------------------------------------

with Iour; use Iour;

package Echo_Protocol with SPARK_Mode => On is

   Frame_Size : constant := 32;

   subtype Frame is Byte_Array (0 .. Frame_Size - 1);

   type Message_Kind is
     (Ping,       --  client asks
      Pong,       --  server answers
      Farewell,   --  client is done; server closes
      Malformed); --  anything else

   Digits_First : constant := 6;
   Digits_Last  : constant := 14;
   Max_Sequence : constant := 999_999_999;

   procedure Build
     (Kind : Message_Kind; Sequence : Natural; Into : out Frame)
     with Pre => Kind /= Malformed;

   procedure Parse
     (From : Frame; Kind : out Message_Kind; Sequence : out Natural);

   function Tag_Of (Kind : Message_Kind) return String
     with Post => Tag_Of'Result'Length = 4;

end Echo_Protocol;
