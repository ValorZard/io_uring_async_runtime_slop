with Iour;

package Http_Client_App with SPARK_Mode => On is

   procedure Start (Started : out Boolean);
   procedure Result (Code : out Iour.Io_Result; Ok : out Boolean);

end Http_Client_App;