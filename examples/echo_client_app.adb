with Echo_Protocol;   use Echo_Protocol;
with Iour.Fibers.Job;
with Iour.Net;
with Iour.Scheduler;
with Iour.Time;

package body Echo_Client_App with SPARK_Mode => On is

   package Net renames Iour.Net;

   --  Driver is declared in the spec, so its job instance can stand here.
   --  Session's is further down, after the forward declaration it needs.
   package Driver_Job is new Iour.Fibers.Job (Work => Driver);

   Max_Host : constant := 46;   --  enough for any dotted quad

   --  Written once by the environment task before the shards start, read by
   --  every session fiber afterwards.  Atomic components declare the
   --  sharing rather than leaving it to be inferred.
   --  A protected object, not an array with Atomic_Components.  That was
   --  what this used to be, and it is not synchronized: SPARK counts an
   --  Atomic *object* as synchronized and an array of atomic components as
   --  an ordinary variable -- which Iour.Per_Shard's header says at length,
   --  and which is why that package holds Max_Shards separate scalars
   --  rather than one array.  The race witness at the bottom of this body
   --  reported it as soon as it could see the session fibers.
   --
   --  Nothing here is on a hot path: written once at start-up, read once
   --  per session when it connects.
   type Host_Text is array (1 .. Max_Host) of Character;

   protected Server_Host
     with Priority => Runtime_Priority
   is
      procedure Put (Text : String; Count : Natural)
        with Pre => Text'First = 1 and then Text'Length >= Max_Host
                    and then Count <= Max_Host;
      procedure Get (Text : out String; Last : out Natural)
        with Pre  => Text'First = 1 and then Text'Length >= Max_Host,
             Post => Last <= Max_Host;
   private
      Chars : Host_Text := [others => ' '];
      Held  : Natural range 0 .. Max_Host := 0;
   end Server_Host;

   protected body Server_Host is

      procedure Put (Text : String; Count : Natural) is
      begin
         Chars := [others => ' '];
         for I in 1 .. Count loop
            Chars (I) := Text (I);
         end loop;
         Held := Count;
      end Put;

      procedure Get (Text : out String; Last : out Natural) is
      begin
         Text := [others => ' '];
         for I in 1 .. Held loop
            Text (I) := Chars (I);
         end loop;
         Last := Held;
      end Get;

   end Server_Host;

   --  The same sharing, one scalar at a time -- and with the external
   --  properties spelled out rather than defaulted, because they say what
   --  these actually are: written by one thread, read by others, Atomic
   --  for the synchronisation.
   --
   --  Defaulted, Atomic means External with all four True, and that is a
   --  different object.  Effective_Reads => True says reading is itself an
   --  act that changes the thing read -- true of a hardware FIFO, of
   --  nothing here -- and it forbids reading one inside a larger
   --  expression (E0004); Effective_Writes => True with Async_Readers
   --  makes the variable an output of any function that reads it, which
   --  SPARK forbids outright (E0005).  SPARK RM 7.1.2(6) then requires at
   --  least one of Async_Readers and Async_Writers, so the shape is
   --  Async_Writers alone -- which is also how Iour.Trace declares its
   --  Enabled flag, for the same reasons.
   Server_Port : Natural := 0
     with Atomic, Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;
   Round_Count : Natural := 0
     with Atomic, Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;

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
      --  How many sessions the run is for, set once by Configure before
      --  any shard runs.  Protected state rather than an Atomic variable
      --  beside the others, because All_Finished reads it and SPARK
      --  forbids a function from reading a volatile object (E0005) -- and
      --  because it is compared with counters held under this same lock.
      procedure Set_Session_Count (Count : Natural);
      procedure Session_Goal (Count : out Natural);
   private
      Session_Count    : Natural := 0;
      Total_Started    : Natural := 0;
      Total_Ok         : Natural := 0;
      Total_Failed     : Natural := 0;
      Total_Frames     : Natural := 0;
      Total_Mismatched : Natural := 0;
      Live             : Natural := 0;
      Peak_Live        : Natural := 0;
   end Stats;

   protected body Stats is

      --  Statistics only, and saturating, so the arithmetic is total and
      --  therefore provable.  Iour.Scheduler counts the same way.
      --
      --  Declared here rather than beside the package's other helpers on
      --  purpose: no protected body in this program calls anything outside
      --  itself, which is what makes the absence of nested protected calls
      --  -- and so of lock cycles -- checkable by reading one screen.  See
      --  *What SPARK proves about deadlock and data races* in CLAUDE.md.
      procedure Bump (Counter : in out Natural; By : Natural := 1) is
      begin
         if Natural'Last - Counter >= By then
            Counter := Counter + By;
         else
            Counter := Natural'Last;
         end if;
      end Bump;

      procedure Started_One is
      begin
         Bump (Total_Started);
         Bump (Live);
         if Live > Peak_Live then
            Peak_Live := Live;
         end if;
      end Started_One;

      procedure Finished_One
        (Frames : Natural; Ok : Boolean; Mismatch : Boolean) is
      begin
         Bump (Total_Frames, Frames);
         if Ok then
            Bump (Total_Ok);
         else
            Bump (Total_Failed);
         end if;
         if Mismatch then
            Bump (Total_Mismatched);
         end if;
         if Live > 0 then
            Live := Live - 1;
         end if;
      end Finished_One;

      --  Written so the sum cannot overflow: Total_Ok and Total_Failed are
      --  each at most Natural'Last, and comparing the difference is the
      --  same question with no addition in it.
      function All_Finished return Boolean is
        (Total_Started >= Session_Count
         and then Total_Ok >= Total_Started - Total_Failed);

      procedure Set_Session_Count (Count : Natural) is
      begin
         Session_Count := Count;
      end Set_Session_Count;

      procedure Session_Goal (Count : out Natural) is
      begin
         Count := Session_Count;
      end Session_Goal;

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
      declare
         Text : String (1 .. Max_Host) := [others => ' '];
      begin
         for I in 1 .. Length loop
            pragma Loop_Invariant (Length <= Host'Length);
            Text (I) := Host (Host'First + (I - 1));
         end loop;
         Server_Host.Put (Text, Length);
      end;
      Server_Port   := Port;
      Round_Count   := Rounds;
      Stats.Set_Session_Count (Connections);
   end Configure;

   --  A procedure rather than a function returning String: a protected
   --  operation cannot be called from a SPARK function, and the caller
   --  supplying the buffer also keeps the whole thing on the fiber's own
   --  stack.
   procedure Host_String (Result : out String; Last : out Natural)
     with Pre  => Result'First = 1 and then Result'Length >= Max_Host,
          Post => Last <= Max_Host
   is
   begin
      Server_Host.Get (Result, Last);
   end Host_String;

   ---------------------------------------------------------------------------
   --  Session -- one whole conversation
   ---------------------------------------------------------------------------

   --  Declared ahead of its body so the Iour.Fibers.Job instance below can
   --  name it.  A generic actual has to be declared before the
   --  instantiation, and the instance has to be at library level because
   --  it registers from its own elaboration.
   procedure Session (Arg : Fiber_Argument);

   package Session_Job is new Iour.Fibers.Job (Work => Session);

   procedure Session (Arg : Fiber_Argument) is
      Rounds : constant Natural := Round_Count;

      --  Both frames live on this fiber's stack, which is what keeps them
      --  valid across every suspension below.
      Outgoing : Frame;
      Incoming : Frame;

      Opened   : Io_Result;
      Sock     : Net.Socket;
      Status   : Io_Result;

      --  The server's address, copied out of the shared, Atomic store
      --  onto this fiber's own stack.  A volatile object may not be an
      --  actual parameter (SPARK RM 7.1.3(9)), so Server_Port comes the
      --  same way.
      Host_Buf : String (1 .. Max_Host);
      Host_Len : Natural;
      Port     : Natural;
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
      Host_String (Host_Buf, Host_Len);
      Port := Server_Port;
      Net.Connect (Sock, Host_Buf (1 .. Host_Len), Port, Status);
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

         --  Saturating; see Echo_Server_App's Serve for why the race
         --  witness is what turned this into a visible obligation.
         if Frames < Natural'Last then
            Frames := Frames + 1;
         end if;
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
      Total    : Natural;
      Handle   : Future_Ref;
      Finished : Boolean;
   begin
      pragma Unreferenced (Arg);
      Stats.Session_Goal (Total);

      for I in 1 .. Total loop
         loop
            Session_Job.Spawn (Fiber_Argument (I), Handle);
            exit when Handle /= No_Future;

            --  The runtime is momentarily at capacity.  Sleep this fiber --
            --  not the core -- and try again once sessions have finished.
            Iour.Time.Sleep_Milliseconds (1);
         end loop;
      end loop;

      --  Wait by sleeping rather than by queueing on a protected entry: an
      --  entry call from a fiber would block the whole shard, stopping
      --  every other session running on this core.
      --
      --  Done through a local because a protected function is a volatile
      --  function, and SPARK RM 7.1.3(9) allows a call to one only as the
      --  whole right-hand side of an assignment.
      loop
         Finished := Stats.All_Finished;
         exit when Finished;
         Iour.Time.Sleep_Milliseconds (1);
      end loop;

      Iour.Scheduler.Request_Shutdown;
   end Driver;

   ---------------------------------------------------------------------------

   procedure Start_Driver (Handle : out Future_Ref) is
   begin
      Driver_Job.Spawn (0, Handle);
   end Start_Driver;

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


   --  The list the race witness in the spec is instantiated with; see
   --  Iour.Fibers.Race_Witness.  Never executed.
   procedure All_Fiber_Bodies is
   begin
      Session (0);
      Driver (0);
   end All_Fiber_Bodies;

end Echo_Client_App;
