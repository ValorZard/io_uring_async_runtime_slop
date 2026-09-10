with Iour.Fibers;

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
   --
   --  The global is the job registry alone.  Everything the acceptor and
   --  its handlers go on to touch -- the reactor, the kernel -- is reached
   --  from the fiber, and this call only puts a job number on a shard's
   --  run queue.  Claiming more here is not conservative, it is a global
   --  gnatprove then reports as unused at every instantiation.
   procedure Start_Acceptor
     (Shard : Iour.Active_Shard; Listener : Iour.Descriptor; Started : out Boolean)
     with Global => (In_Out => Iour.Fibers.Registry);

end Iour.Http.Server;