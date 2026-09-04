with Echo_Protocol;   use Echo_Protocol;
with Iour.Fibers;
with Iour.Net;
with Iour.Scheduler;
with Iour.Time;

package body Echo_Client_App with SPARK_Mode => On is

   package Fibers renames Iour.Fibers;
   package Net renames Iour.Net;

   Max_Host : constant := 46;   --  enough for any dotted quad

   --  Written once by the environment task before the shards start, read by
   --  every session fiber afterwards.  Atomic components declare the
   --  sharing rather than leaving it to be inferred.
   type Host_Text is array (1 .. Max_Host) of Character
     with Atomic_Components;

   Host_Chars  : Host_Text := [others => ' '];
   Host_Length : Natural := 0 with Atomic;
   Server_Port : Natural := 0 with Atomic;
   Session_Count : Natural := 0 with Atomic;
   Round_Count : Natural := 0 with Atomic;

   protected Stats
     with Priority => Runtime_Priority
   is
      procedure Started_One;
      procedure Finished_One
        (Frames : Natural; Ok : Boolean; Mismatch : Boolean);
      procedure Read
        (N_Started    : out Natural;
         N_Ok         : out Natural;
         N_Failed     : out Natural;
         N_Frames     : out Natural;
         N_Mismatched : out Natural;
         N_Concurrent : out Natural);
      function All_Finished return Boolean;
   private
      Total_Started    : Natural := 0;
      Total_Ok         : Natural := 0;
      Total_Failed     : Natural := 0;
      Total_Frames     : Natural := 0;
      Total_Mismatched : Natural := 0;
      Live             : Natural := 0;
      Peak_Live        : Natural := 0;
   end Stats;

   protected body Stats is

      procedure Started_One is
      begin
         Total_Started := Total_Started + 1;
         Live := Live + 1;
         if Live > Peak_Live then
            Peak_Live := Live;
         end if;
      end Started_One;

      procedure Finished_One
        (Frames : Natural; Ok : Boolean; Mismatch : Boolean) is
      begin
         Total_Frames := Total_Frames + Frames;
         if Ok then
            Total_Ok := Total_Ok + 1;
         else
            Total_Failed := Total_Failed + 1;
         end if;
         if Mismatch then
            Total_Mismatched := Total_Mismatched + 1;
         end if;
         if Live > 0 then
            Live := Live - 1;
         end if;
      end Finished_One;

      function All_Finished return Boolean is
        (Total_Started >= Session_Count
         and then Total_Ok + Total_Failed >= Total_Started);

      procedure Read
        (N_Started    : out Natural;
         N_Ok         : out Natural;
         N_Failed     : out Natural;
         N_Frames     : out Natural;
         N_Mismatched : out Natural;
         N_Concurrent : out Natural) is
      begin
         N_Started    := Total_Started;
         N_Ok         := Total_Ok;
         N_Failed     := Total_Failed;
         N_Frames     := Total_Frames;
         N_Mismatched := Total_Mismatched;
         N_Concurrent := Peak_Live;
      end Read;

   end Stats;

   ---------------------------------------------------------------------------

   procedure Configure
     (Host        : String;
      Port        : Natural;
      Connections : Natural;
      Rounds      : Natural)
   is
      Length : constant Natural :=
        (if Host'Length > Max_Host then Max_Host else Host'Length);
   begin
      for I in 1 .. Length loop
         Host_Chars (I) := Host (Host'First + I - 1);
      end loop;
      Host_Length   := Length;
      Server_Port   := Port;
      Session_Count := Connections;
      Round_Count   := Rounds;
   end Configure;

   function Host_String return String is
      Length : constant Natural := Host_Length;
      Result : String (1 .. Length);
   begin
      for I in 1 .. Length loop
         Result (I) := Host_Chars (I);
      end loop;
      return Result;
   end Host_String;

   ---------------------------------------------------------------------------
   --  Session -- one whole conversation
   ---------------------------------------------------------------------------

   procedure Session (Arg : Fiber_Argument) is
      Rounds : constant Natural := Round_Count;

      --  Both frames live on this fiber's stack, which is what keeps them
      --  valid across every suspension below.
      Outgoing : Frame;
      Incoming : Frame;

      Opened   : Io_Result;
      Sock     : Net.Socket;
      Status   : Io_Result;
      Kind     : Message_Kind;
      Sequence : Natural;

      Frames   : Natural := 0;
      Ok       : Boolean := False;
      Mismatch : Boolean := False;
   begin
      pragma Unreferenced (Arg);
      Stats.Started_One;

      Opened := Net.New_Socket;
      if Failed (Opened) then
         Stats.Finished_One (0, False, False);
         return;
      end if;
      Sock := Net.Socket (Opened);

      --  Suspends here, and at every I/O below.  Meanwhile this core is
      --  driving other sessions.
      Net.Connect (Sock, Host_String, Server_Port, Status);
      if Failed (Status) then
         Net.Close (Sock, Status);
         Stats.Finished_One (0, False, False);
         return;
      end if;

      Ok := True;
      for Round in 1 .. Rounds loop
         Build (Ping, Round, Outgoing);

         Net.Send_All (Sock, Outgoing, Status);
         if Failed (Status) then
            Ok := False;
            exit;
         end if;

         Net.Receive_Exact (Sock, Incoming, Status);
         if Status <= 0 then
            Ok := False;
            exit;
         end if;

         Parse (Incoming, Kind, Sequence);
         if Kind /= Pong or else Sequence /= Round then
            --  The server answered, but not with what we sent.  That is a
            --  protocol failure, distinct from a connection failure.
            Mismatch := True;
            Ok := False;
            exit;
         end if;

         Frames := Frames + 1;
      end loop;

      --  Say goodbye so the server closes its side tidily.
      Build (Farewell, 0, Outgoing);
      Net.Send_All (Sock, Outgoing, Status);

      Net.Close (Sock, Status);
      Stats.Finished_One (Frames, Ok, Mismatch);
   end Session;

   ---------------------------------------------------------------------------
   --  Driver
   ---------------------------------------------------------------------------

   procedure Driver (Arg : Fiber_Argument) is
      Total   : constant Natural := Session_Count;
      Target  : Active_Shard := Active_Shard'First;
      Started : Boolean;
   begin
      pragma Unreferenced (Arg);

      --  Placed a core at a time rather than published on one queue every
      --  core pops from.  Two thousand identical sessions spawned at once
      --  do not need balancing discovered for them, and dealing them round
      --  spreads the cost over four uncontended locks instead of one
      --  contended one.  Work stealing is still underneath for the case
      --  this cannot predict -- sessions that finish at different rates --
      --  but it should have little to do here.
      for I in 1 .. Total loop
         loop
            Fibers.Spawn_On
              (Target, Session'Access, Fiber_Argument (I), Started);
            exit when Started;

            --  The runtime is momentarily at capacity.  Sleep this fiber --
            --  not the core -- and try again once sessions have finished.
            Iour.Time.Sleep_Milliseconds (1);
         end loop;

         --  Modular rather than a guarded increment: with Shard_Count of
         --  one, Target + 1 is out of range even on the branch that never
         --  runs, and the compiler is right to say so.
         Target := Active_Shard ((Natural (Target) + 1) mod Shard_Count);
      end loop;

      --  Wait by sleeping rather than by queueing on a protected entry: an
      --  entry call from a fiber would block the whole shard, stopping
      --  every other session running on this core.
      while not Stats.All_Finished loop
         Iour.Time.Sleep_Milliseconds (1);
      end loop;

      Iour.Scheduler.Request_Shutdown;
   end Driver;

   ---------------------------------------------------------------------------

   procedure Snapshot
     (Started    : out Natural;
      Succeeded  : out Natural;
      Failed     : out Natural;
      Frames     : out Natural;
      Mismatched : out Natural;
      Concurrent : out Natural) is
   begin
      Stats.Read
        (Started, Succeeded, Failed, Frames, Mismatched, Concurrent);
   end Snapshot;

end Echo_Client_App;
