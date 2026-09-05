------------------------------------------------------------------------------
--  Iour.Ffi.Net body -- Windows.
--
--  Winsock, with one rule running through it: every socket is created
--  overlapped, and no socket that will carry data is ever handed to a
--  completion port.  The second half of that is not a style preference.  A
--  socket associated with a port is refused by CreateIoRing's read and
--  write builders with E_INVALIDARG, so associating one would silently
--  move that connection off the ring for the rest of its life.  The
--  listener is the single exception, and it carries no data: see the
--  Windows Iour.Reactor body, which owns that decision.
------------------------------------------------------------------------------

with Iour.Ffi.Inet;
with Iour.Ffi.Sys;
with Iour.Ffi.Win32;

package body Iour.Ffi.Net with SPARK_Mode => Off is

   package Win renames Iour.Ffi.Win32;
   package Inet renames Iour.Ffi.Inet;

   use type C_Int;
   use type Win.Handle;

   ---------------------------------------------------------------------------
   --  Winsock start-up
   ---------------------------------------------------------------------------

   Started : Boolean := False;

   procedure Initialize is
      Data   : aliased Win.Wsa_Data;
      Status : C_Int;
   begin
      if Started then
         return;
      end if;
      --  Version 2.2, as every Winsock since 1996 supports.
      Status := Win.Wsa_Startup (16#0202#, Data'Access);
      Started := Status = 0;
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
      One     : aliased constant C_Int := 1;
      Ignored : C_Int;
   begin
      --  A refused socket option is never fatal here: TCP_NODELAY and
      --  address reuse are optimisations, and the caller would rather have
      --  a working socket than none.
      Ignored := Win.C_Setsockopt
        (S, Level, Name, One'Address, C_Int'Size / 8);
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
      Ignored : C_Int;
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
         Ignored := Win.C_Closesocket (S);
         return Failure;
      end if;

      Status := Win.C_Listen (S, Depth);
      if Status /= 0 then
         Failure := Ffi.Sys.Failure_Code;
         Ignored := Win.C_Closesocket (S);
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
      Status := Win.C_Getsockname (Win.Handle (Fd), Addr'Access, Len'Access);
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
      return Adapt (Win.C_Closesocket (Win.Handle (Fd)));
   end Close;

   procedure Close_Quietly (Fd : Descriptor) is
      Ignored : C_Int;
   begin
      if Fd >= 0 then
         Ignored := Win.C_Closesocket (Win.Handle (Fd));
      end if;
   end Close_Quietly;

   function Shutdown (Fd : Descriptor; How : Natural) return Io_Result is
      Which : constant C_Int :=
        (case How is
            when Shut_Read  => Win.Sd_Receive,
            when Shut_Write => Win.Sd_Send,
            when others     => Win.Sd_Both);
   begin
      if Fd < 0 then
         return -E_Invalid;
      end if;
      return Adapt (Win.C_Shutdown (Win.Handle (Fd), Which));
   end Shutdown;

end Iour.Ffi.Net;
