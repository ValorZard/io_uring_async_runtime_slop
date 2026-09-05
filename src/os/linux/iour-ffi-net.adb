------------------------------------------------------------------------------
--  Iour.Ffi.Net body -- Linux.
--
--  BSD sockets, bound directly.  Only connection setup goes through these
--  calls, and only at start-up; every byte of traffic afterwards moves
--  through io_uring.
------------------------------------------------------------------------------

with Iour.Ffi.Inet;
with Iour.Ffi.Posix;

package body Iour.Ffi.Net with SPARK_Mode => On is

   use type C_Int;

   package Posix renames Iour.Ffi.Posix;
   package Inet renames Iour.Ffi.Inet;

   ---------------------------------------------------------------------------
   --  Turn a libc "-1 and errno" result into the runtime's convention.
   ---------------------------------------------------------------------------

   function Adapt (Result : C_Int) return Io_Result is
      Err : C_Int;
   begin
      if Result >= 0 then
         return Io_Result (Result);
      end if;
      Err := Posix.Last_Error;
      --  Never report a failure as success, even if errno was somehow clear.
      return (if Err > 0 then -Io_Result (Err) else -1);
   end Adapt;

   ---------------------------------------------------------------------------
   --  Initialize
   ---------------------------------------------------------------------------

   --  Linux needs no preparation to use sockets.  The declaration exists
   --  for Windows, where WSAStartup does.
   procedure Initialize is null;
   pragma Annotate
     (GNATprove, Intentional, "unused global ""Ffi.Kernel""",
      "The contract is the union of what the two backends do.  This one has"
      & " nothing to prepare; the Windows body calls WSAStartup, which changes"
      & " kernel state for the whole process.");

   ---------------------------------------------------------------------------
   --  Set_Flag -- setsockopt with an int-valued option
   ---------------------------------------------------------------------------

   procedure Set_Flag (Fd : C_Int; Level, Name : C_Int) is
      One   : aliased constant C_Int := 1;
      --  SPARK accepts 'Access only in a declaration, not inline as an
      --  actual parameter.
      Value : constant access constant C_Int := One'Access;
   begin
      --  A refused socket option is never fatal here: TCP_NODELAY and
      --  SO_REUSEPORT are optimisations, and the caller would rather have a
      --  working socket than none.  Hence the procedure form, which does
      --  not return the status at all.
      Posix.Set_Option (Fd, Level, Name, Value, C_Unsigned (C_Int'Size / 8));
   end Set_Flag;

   ---------------------------------------------------------------------------
   --  Tcp_Socket
   ---------------------------------------------------------------------------

   function Tcp_Socket return Io_Result is
      Fd : constant C_Int :=
        Posix.C_Socket (Inet.Af_Inet, Posix.Sock_Stream, 0);
   begin
      if Fd < 0 then
         return Adapt (Fd);
      end if;
      Set_Flag (Fd, Posix.Ipproto_Tcp, Posix.Tcp_Nodelay);
      return Io_Result (Fd);
   end Tcp_Socket;

   ---------------------------------------------------------------------------
   --  Tcp_Listener
   ---------------------------------------------------------------------------

   function Port_Sharing_Available return Boolean is (True);

   function Tcp_Listener
     (Host      : Unsigned_32;
      Port      : Unsigned_16;
      Backlog   : Natural := 4096;
      Reuseport : Boolean := False) return Io_Result
   is
      Fd      : constant C_Int :=
        Posix.C_Socket (Inet.Af_Inet, Posix.Sock_Stream, 0);
      Addr    : aliased constant Inet.Sockaddr_In :=
        Inet.Make_Address (Host, Port);
      Where   : constant access constant Inet.Sockaddr_In := Addr'Access;
      Status  : C_Int;
      Failure : Io_Result;
   begin
      if Fd < 0 then
         return Adapt (Fd);
      end if;

      --  Without SO_REUSEADDR a restarted server trips over its own
      --  lingering TIME_WAIT sockets.
      Set_Flag (Fd, Posix.Sol_Socket, Posix.So_Reuseaddr);
      if Reuseport then
         Set_Flag (Fd, Posix.Sol_Socket, Posix.So_Reuseport);
      end if;

      Status := Posix.C_Bind
        (Fd, Where, C_Unsigned (Inet.Sockaddr_In'Size / 8));
      if Status < 0 then
         --  Capture errno before close(), which would overwrite it.
         Failure := Adapt (Status);
         Posix.Close_Quietly (Fd);
         return Failure;
      end if;

      Status := Posix.C_Listen (Fd, C_Int (Backlog));
      if Status < 0 then
         Failure := Adapt (Status);
         Posix.Close_Quietly (Fd);
         return Failure;
      end if;

      return Io_Result (Fd);
   end Tcp_Listener;

   ---------------------------------------------------------------------------
   --  Local_Port
   ---------------------------------------------------------------------------

   function Local_Port (Fd : Descriptor) return Io_Result is
      Addr   : aliased Inet.Sockaddr_In := (others => <>);
      Len    : aliased C_Unsigned := C_Unsigned (Inet.Sockaddr_In'Size / 8);
      Status : C_Int;
   begin
      --  The borrows live only for the call.  SPARK forbids reading an
      --  object while something still points at it, so Addr.Port below has
      --  to be read after this block has given the pointer back.
      declare
         Where : constant access Inet.Sockaddr_In := Addr'Access;
         Room  : constant access C_Unsigned := Len'Access;
      begin
         Status := Posix.C_Getsockname (C_Int (Fd), Where, Room);
      end;

      if Status < 0 then
         return Adapt (Status);
      end if;
      return Io_Result (Inet.Network_To_Host (Addr.Port));
   end Local_Port;

   ---------------------------------------------------------------------------
   --  Close and Shutdown
   ---------------------------------------------------------------------------

   function Close (Fd : Descriptor) return Io_Result is
      Status : C_Int;
   begin
      if Fd < 0 then
         return 0;
      end if;
      Status := Posix.C_Close (C_Int (Fd));
      return Adapt (Status);
   end Close;

   procedure Close_Quietly (Fd : Descriptor) is
   begin
      if Fd >= 0 then
         Posix.Close_Quietly (C_Int (Fd));
      end if;
   end Close_Quietly;

   function Shutdown (Fd : Descriptor; How : Natural) return Io_Result is
      Status : C_Int;
   begin
      if Fd < 0 then
         return -Io_Result (E_Invalid);
      end if;
      Status := Posix.C_Shutdown (C_Int (Fd), C_Int (How));
      return Adapt (Status);
   end Shutdown;


end Iour.Ffi.Net;
