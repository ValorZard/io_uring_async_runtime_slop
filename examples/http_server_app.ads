with Iour;

package Http_Server_App with SPARK_Mode => On is

  procedure Configure (Listener : Iour.Descriptor; Goal : Natural);

   procedure Start
     (Shard : Iour.Active_Shard; Listener : Iour.Descriptor; Started : out Boolean);

end Http_Server_App;