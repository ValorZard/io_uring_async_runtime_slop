with Iour.Http;
with Iour.Http.Server;

package body Http_Server_App with SPARK_Mode => On is

   use type Iour.Http.Method;

   procedure Health
     (Request_Method : Iour.Http.Method;
      Target         : String;
      Payload        : out Iour.Byte_Array;
      Payload_Length : out Natural)
   is
      pragma Unreferenced (Target);
      Text : constant String :=
        (if Request_Method = Iour.Http.Get then "GET ok" & ASCII.LF
         elsif Request_Method = Iour.Http.Post then "POST ok" & ASCII.LF
         else "method not supported" & ASCII.LF);
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