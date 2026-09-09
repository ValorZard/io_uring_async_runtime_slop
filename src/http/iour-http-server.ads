with Iour;
with Iour.Ffi;
with Iour.Fibers;
with Iour.Net;
with Iour.Reactor;

generic
   with procedure Handle
     (Request_Method : Method;
         Head           : Head_Buffer;
         Target_First   : Natural;
         Target_Last    : Natural;
      Payload        : out Iour.Byte_Array;
      Payload_Length : out Natural);
   with procedure Completed;

package Iour.Http.Server with SPARK_Mode => On is

   Max_Response_Body : constant := 1_024;

   --  Start one detached acceptor on Shard. Each accepted socket belongs to
   --  its handler fiber until the response is complete and the socket closes.
   procedure Start_Acceptor
     (Shard : Iour.Active_Shard; Listener : Iour.Descriptor; Started : out Boolean)
     with Global => (In_Out => (Iour.Reactor.Engines, Iour.Fibers.Registry,
                                Iour.Ffi.Kernel));

end Iour.Http.Server;