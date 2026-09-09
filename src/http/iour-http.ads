------------------------------------------------------------------------------
--  Iour.Http -- bounded HTTP/1.1 vocabulary shared by the wire layer.
------------------------------------------------------------------------------

package Iour.Http with SPARK_Mode => On is

   Max_Request_Line : constant := 2_048;
   Max_Header_Bytes : constant := 8_192;
   Max_Headers      : constant := 32;
   Max_Chunk_Line   : constant := 128;

  subtype Head_Buffer is Byte_Array (0 .. Max_Header_Bytes - 1);

   type Method is (Get, Head, Post, Put, Delete, Options, Patch, Connect);

   type Version is (Http_10, Http_11);

   type Status_Code is range 100 .. 599;

   type Parse_Status is (Complete, Incomplete, Malformed, Too_Large);

   --  The body rules deliberately take facts about framing headers rather
   --  than a header table.  This leaves the protocol decision pure and makes
   --  the wire layer responsible only for obtaining those facts.
   type Body_Kind is (No_Body, Chunked, Fixed_Length, Until_Close);

   function Body_Framing
     (Request_Method      : Method;
      Response_Status     : Status_Code;
      Has_Chunked         : Boolean;
      Has_Content_Length  : Boolean) return Body_Kind
     with Global => null;

end Iour.Http;