------------------------------------------------------------------------------
--  Iour.Http.Wire -- bounded HTTP transport primitives over Iour.Net.
------------------------------------------------------------------------------

with Iour.Net;
with Iour.Ffi;
with Iour.Fibers;
with Iour.Reactor;

package Iour.Http.Wire with SPARK_Mode => On is

  --  Fill Head until its terminating empty line arrives. Used is the number
  --  of bytes received, which may include body bytes; Head_End names the
  --  final byte of CRLF CRLF so the caller retains that remainder.
   procedure Read_Head
     (Sock     : Iour.Net.Socket;
      Head     : out Head_Buffer;
      Used     : out Natural;
      Head_End : out Natural;
      Status   : out Parse_Status;
      Transport : out Iour.Io_Result)
       with Global => (In_Out => (Iour.Reactor.Engines, Iour.Fibers.Registry,
                    Iour.Ffi.Kernel)),
          Post => Used <= Head'Length;

   procedure Write_All
     (Sock      : Iour.Net.Socket;
      Data      : Iour.Byte_Array;
      Transport : out Iour.Io_Result)
     with Global => (In_Out => (Iour.Reactor.Engines, Iour.Fibers.Registry,
                                  Iour.Ffi.Kernel));
end Iour.Http.Wire;