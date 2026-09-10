with Iour.Http;
with Iour.Http.Server;
with Iour.Ffi.Net;
with Iour.Scheduler;

package body Http_Server_App with SPARK_Mode => On is

   use type Iour.Http.Method;

   protected Control with Priority => Iour.Runtime_Priority is
      procedure Set (Listener : Iour.Descriptor; Goal : Natural);
      procedure Finished (Last : out Boolean);
      procedure Listener (Value : out Iour.Descriptor);
   private
      Socket : Iour.Descriptor := Iour.Invalid_Descriptor;
      Target : Natural := 0;
      Count  : Natural := 0;
   end Control;

   protected body Control is
      procedure Set (Listener : Iour.Descriptor; Goal : Natural) is
      begin
         Socket := Listener;
         Target := Goal;
         Count := 0;
      end Set;

      procedure Finished (Last : out Boolean) is
      begin
         if Count < Natural'Last then
            Count := Count + 1;
         end if;
         Last := Target > 0 and then Count = Target;
      end Finished;

      procedure Listener (Value : out Iour.Descriptor) is
      begin
         Value := Socket;
      end Listener;
   end Control;

   procedure Request_Completed is
      Last : Boolean;
      Socket : Iour.Descriptor;
      Status : Iour.Io_Result;
   begin
      Control.Finished (Last);
      if Last then
         Control.Listener (Socket);
         --  Shutdown is a Side_Effects function, so its result has to be
         --  assigned somewhere; there is nothing useful to do with it when
         --  the run is already ending.  Echo_Server_App.Stop_One says the
         --  same thing the same way.
         Status := Iour.Ffi.Net.Shutdown (Socket, Iour.Ffi.Net.Shut_Both);
         pragma Unreferenced (Status);
         Iour.Scheduler.Request_Shutdown;
      end if;
   end Request_Completed;

   procedure Health
     (Request_Method : Iour.Http.Method;
      Head           : Iour.Http.Head_Buffer;
      Target_First   : Natural;
      Target_Last    : Natural;
      Payload        : out Iour.Byte_Array;
      Payload_Length : out Natural)
   is
      pragma Unreferenced (Head, Target_First, Target_Last);
      Text : constant String :=
      (if Request_Method = Iour.Http.Get then "0123456789abcdef0123456789abcdef"
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

   package Server is new Iour.Http.Server
     (Handle => Health, Completed => Request_Completed);

   procedure Configure (Listener : Iour.Descriptor; Goal : Natural) is
   begin
      Control.Set (Listener, Goal);
   end Configure;

   procedure Start
     (Shard : Iour.Active_Shard; Listener : Iour.Descriptor; Started : out Boolean) is
   begin
      Server.Start_Acceptor (Shard, Listener, Started);
   end Start;

end Http_Server_App;