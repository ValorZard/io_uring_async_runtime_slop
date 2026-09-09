with Iour;
with Iour.Ffi;
with Iour.Fibers;
with Iour.Net;
with Iour.Reactor;

package Iour.Http.Client with SPARK_Mode => On is

   --  Send a GET or empty POST over a socket the caller already connected.
   --  The caller owns Sock, including any subsequent body reads and close.
   procedure Request
     (Sock            : Iour.Net.Socket;
      Request_Method  : Method;
      Host            : String;
      Target          : String;
      Response_Status : out Status_Code;
      Transport       : out Iour.Io_Result;
      Status          : out Parse_Status)
     with Global => (In_Out => (Iour.Reactor.Engines, Iour.Fibers.Registry,
                                Iour.Ffi.Kernel));

end Iour.Http.Client;