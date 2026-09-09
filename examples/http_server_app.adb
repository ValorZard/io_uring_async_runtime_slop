with Iour.Http;
with Iour.Http.Server;

package body Http_Server_App with SPARK_Mode => On is

   procedure Health
     (Request_Method : Iour.Http.Method;
      Target         : String;
      Payload        : out Iour.Byte_Array;
      Payload_Length : out Natural)
   is
      pragma Unreferenced (Request_Method, Target);
      Text : constant String := "ok\n";
   begin
      Payload := [others => 0];
      for Index in Text'Range loop
         Payload (Index - Text'First) :=
           Iour.Byte (Character'Pos (Text (Index)));
      end loop;
      Payload_Length := Text'Length;
   end Health;

   package Server is new Iour.Http.Server (Handle => Health);

   procedure Start
     (Shard : Iour.Active_Shard; Listener : Iour.Descriptor; Started : out Boolean) is
   begin
      Server.Start_Acceptor (Shard, Listener, Started);
   end Start;

end Http_Server_App;