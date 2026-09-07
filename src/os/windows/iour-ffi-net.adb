------------------------------------------------------------------------------
--  Iour.Ffi.Net body -- Windows.
--
--  Winsock, with one rule running through it: every socket is created
--  overlapped.  Overlapped is what a completion port requires, and this is
--  the only place sockets are made, so it is the only place that rule has
--  to hold.
--
--  There used to be a second half to that rule -- no socket that will
--  carry data is ever handed to a completion port -- because an IoRing
--  refuses a socket that has been on one.  The ring is gone and so is the
--  rule; associating sockets with a port is now what the reactor does with
--  all of them.
------------------------------------------------------------------------------

with Iour.Ffi.Inet;
with Iour.Ffi.Sys;
with Iour.Ffi.Win32;

package body Iour.Ffi.Net with SPARK_Mode => On is

   package Win renames Iour.Ffi.Win32;
   package Inet renames Iour.Ffi.Inet;

   use type C_Int;
   use type Win.Handle;

   ---------------------------------------------------------------------------
   --  Winsock start-up
   ---------------------------------------------------------------------------

   procedure Initialize is
      Data    : aliased Win.Wsa_Data;
      Ignored : C_Int;
   begin
      --  Version 2.2, as every Winsock since 1996 supports.
      --
      --  Called once per shard as each opens its engine, and deliberately
      --  not guarded by a "have we already" flag.  WSAStartup is
      --  reference-counted and meant to be called by every component that
      --  wants Winsock; this runtime never calls WSACleanup, so the count
      --  is never read.  The flag that used to be here was shared mutable
      --  state written by every shard, which is a race for the sake of
      --  skipping three calls at start-up.
      declare
         Cell : constant access Win.Wsa_Data := Data'Access;
      begin
         Ignored := Win.Wsa_Startup (16#0202#, Cell);
      end;
   end Initialize;

   ---------------------------------------------------------------------------
   --  Result translation
   ---------------------------------------------------------------------------

   --  A socket handle as a Descriptor.  Windows hands out small handle
   --  values -- multiples of four, a few hundred thousand at the very most
   --  -- so they fit inside Descriptor with room to spare.  The check is
   --  what makes that a checked fact rather than an assumption, and in
   --  particular keeps a handle from ever colliding with the fixed-file
   --  range Iour reserves at the top of Descriptor.
   function As_Descriptor (S : Win.Handle) return Io_Result is
   begin
      if S = Win.Invalid_Socket or else S = Win.Null_Handle then
         return Ffi.Sys.Failure_Code;
      end if;
      if Unsigned_64 (S) >= Unsigned_64 (Fixed_File_Base) then
         --  Far outside anything Windows produces; refuse rather than let
         --  Is_Fixed_File start answering yes about a real socket.
         return -E_Invalid;
      end if;
      return Io_Result (S);
   end As_Descriptor;

   function Adapt (Status : C_Int) return Io_Result is
     (if Status = 0 then 0 else Ffi.Sys.Failure_Code);

   ---------------------------------------------------------------------------
   --  Socket options
   ---------------------------------------------------------------------------

   procedure Set_Flag (S : Win.Handle; Level, Name : C_Int) is
      One : aliased constant C_Int := 1;
   begin
      --  A refused socket option is never fatal here: TCP_NODELAY and
      --  address reuse are optimisations, and the caller would rather have
      --  a working socket than none.  Win.Set_Option is the procedure form
      --  precisely because there is no result to look at.
      declare
         Value : constant access constant C_Int := One'Access;
      begin
         Win.Set_Option (S, Level, Name, Value, C_Int'Size / 8);
      end;
   end Set_Flag;

   ---------------------------------------------------------------------------
   --  Tcp_Socket
   ---------------------------------------------------------------------------

   function New_Overlapped_Socket return Win.Handle is
     (Win.Wsa_Socket
        (Family        => Win.Af_Inet,
         Kind          => Win.Sock_Stream,
         Protocol      => 0,
         Protocol_Info => System.Null_Address,
         Group         => 0,
         Flags         => Win.Wsa_Flag_Overlapped));

   function Tcp_Socket return Io_Result is
      S : Win.Handle;
   begin
      Initialize;
      S := New_Overlapped_Socket;
      if S = Win.Invalid_Socket then
         return Ffi.Sys.Failure_Code;
      end if;
      Set_Flag (S, Win.Ipproto_Tcp, Win.Tcp_Nodelay);

      --  The reactor needs AcceptEx and ConnectEx, and Winsock will only
      --  hand them over through a socket.  Any socket of the right family
      --  will do, and this is the first one the process makes.
      Win.Load_Socket_Extensions (S);

      return As_Descriptor (S);
   end Tcp_Socket;

   ---------------------------------------------------------------------------
   --  Tcp_Listener
   ---------------------------------------------------------------------------

   --  Windows has nothing that behaves like SO_REUSEPORT.  Its SO_REUSEADDR
   --  is not the same thing at all: a second bind to a live port does not
   --  join it, it takes it over, and every subsequent connection goes to
   --  the newcomer while the original listener quietly stops receiving any.
   --  A server that asked for one listener per core and got that would look
   --  like it was running on every core and in fact be running on one.
   --
   --  So the answer is no, and it is the caller's business what to do about
   --  it: Echo_Server_App puts a single acceptor on one core and spreads
   --  the connections it accepts across the others through the global run
   --  queue.
   function Port_Sharing_Available return Boolean is (False);

   function Tcp_Listener
     (Host      : Unsigned_32;
      Port      : Unsigned_16;
      Backlog   : Natural := 4096;
      Reuseport : Boolean := False) return Io_Result
   is
      pragma Unreferenced (Reuseport);
      S       : Win.Handle;
      Addr    : aliased constant Inet.Sockaddr_In :=
        Inet.Make_Address (Host, Port);
      Where   : constant access constant Inet.Sockaddr_In := Addr'Access;
      Status  : C_Int;
      Failure : Io_Result;
      --  Windows reads SOMAXCONN as "the largest backlog this provider
      --  will give", and silently clamps any explicit number to a system
      --  maximum that is 200 on client editions.  A server that asks for
      --  4096 and is given 200 turns a thousand simultaneous connects
      --  into hundreds of refusals -- measured, on this machine, at up to
      --  two thirds of them -- so anything above that cap is asked for
      --  the way Windows wants it asked.
      Depth   : constant C_Int :=
        (if Backlog > 200 then Win.Somaxconn else C_Int (Backlog));
   begin
      Initialize;
      S := New_Overlapped_Socket;
      if S = Win.Invalid_Socket then
         return Ffi.Sys.Failure_Code;
      end if;
      Win.Load_Socket_Extensions (S);

      --  Deliberately NOT SO_REUSEADDR.  On Linux it stops a restarted
      --  server tripping over its own TIME_WAIT sockets and nothing else;
      --  on Windows the same name lets an unrelated process take a port
      --  this one is already listening on, which is a worse problem than
      --  the one it would solve.
      Status := Win.C_Bind (S, Where, Inet.Sockaddr_In'Size / 8);
      if Status /= 0 then
         Failure := Ffi.Sys.Failure_Code;
         Win.Close_Quietly (S);
         return Failure;
      end if;

      Status := Win.C_Listen (S, Depth);
      if Status /= 0 then
         Failure := Ffi.Sys.Failure_Code;
         Win.Close_Quietly (S);
         return Failure;
      end if;

      return As_Descriptor (S);
   end Tcp_Listener;

   ---------------------------------------------------------------------------
   --  Local_Port
   ---------------------------------------------------------------------------

   function Local_Port (Fd : Descriptor) return Io_Result is
      Addr   : aliased Inet.Sockaddr_In := (others => <>);
      Len    : aliased C_Int := Inet.Sockaddr_In'Size / 8;
      Status : C_Int;
   begin
      if Fd < 0 then
         return -E_Invalid;
      end if;
      declare
         Where : constant access Inet.Sockaddr_In := Addr'Access;
         Size  : constant access C_Int            := Len'Access;
      begin
         Status := Win.C_Getsockname (Win.Handle (Fd), Where, Size);
      end;
      if Status /= 0 then
         return Ffi.Sys.Failure_Code;
      end if;
      return Io_Result (Inet.Network_To_Host (Addr.Port));
   end Local_Port;

   ---------------------------------------------------------------------------
   --  Close and Shutdown
   ---------------------------------------------------------------------------

   function Close (Fd : Descriptor) return Io_Result is
   begin
      if Fd < 0 then
         return 0;
      end if;
      declare
         Status : C_Int;
      begin
         Status := Win.C_Closesocket (Win.Handle (Fd));
         return Adapt (Status);
      end;
   end Close;

   procedure Close_Quietly (Fd : Descriptor) is
   begin
      if Fd >= 0 then
         Win.Close_Quietly (Win.Handle (Fd));
      end if;
   end Close_Quietly;

   --  The spec promises that shutting down a listening socket is what makes
   --  a pending accept give up.  On Linux shutdown(2) does exactly that.
   --  On Windows it does not: shutdown is about a connection's two
   --  directions, a listening socket has none, and the call comes straight
   --  back with WSAENOTCONN having cancelled nothing.  A server that asked
   --  its acceptors to stop then waited for accepts that would never
   --  complete -- measured here as a sixty-four second shutdown, one
   --  drain pass per second until the scheduler gave up on them.
   --
   --  CancelIoEx is the call that does mean it.  Reaching for it only when
   --  shutdown has already refused keeps a connected socket's behaviour
   --  exactly as it was: there, shutdown succeeds and this never runs.
   --  Closing the listener would work too and is what a Windows server
   --  usually does, but it is not what the caller asked for, and a handle
   --  closed underneath a pending AcceptEx is a harder thing to reason
   --  about than one whose I/O has been cancelled.
   function Shutdown (Fd : Descriptor; How : Natural) return Io_Result is
      Which : constant C_Int :=
        (case How is
            when Shut_Read  => Win.Sd_Receive,
            when Shut_Write => Win.Sd_Send,
            when others     => Win.Sd_Both);
      Status  : C_Int;
      Raw     : C_Int;
      Failure : Win.Dword;
      Ignored : Win.Bool;
   begin
      if Fd < 0 then
         return -E_Invalid;
      end if;

      Status := Win.C_Shutdown (Win.Handle (Fd), Which);
      if Status = 0 then
         return 0;
      end if;

      --  WSAGetLastError is typed as a signed int and every code it can
      --  return here is positive -- the two named below are 10057 and
      --  10022 -- so the conversion to Dword needs the guard that the
      --  value already satisfies.  Without it the conversion is the one
      --  unproved check in the whole Windows backend.
      Raw := Win.Wsa_Get_Last_Error;
      if Raw <= 0 then
         return -E_Invalid;
      end if;

      Failure := Win.Dword (Raw);
      if Failure = Win.Wsaenotconn or else Failure = Win.Wsaeinval then
         --  A listening socket, or one that never connected.  Cancel what
         --  is outstanding on it instead; the pending AcceptEx then
         --  complete with ERROR_OPERATION_ABORTED, which the acceptors
         --  read as "stop", exactly as they read a shutdown listener on
         --  Linux.
         Ignored := Win.Cancel_Io (Win.Handle (Fd), System.Null_Address);
         return 0;
      end if;

      return Win.As_Failure (Failure);
   end Shutdown;

end Iour.Ffi.Net;
