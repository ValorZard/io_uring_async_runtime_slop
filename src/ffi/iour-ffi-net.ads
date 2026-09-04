------------------------------------------------------------------------------
--  Iour.Ffi.Net -- BSD sockets, bound directly.
--
--  socket/bind/listen/setsockopt/getsockname/close are all real libc
--  symbols, so Ada imports them as they are.  struct sockaddr_in is stable
--  kernel ABI and is mirrored here.  Byte-order conversion and dotted-quad
--  parsing are done in Ada rather than borrowed from htons/inet_pton: they
--  are a few lines each, and keeping them here means the whole address path
--  is analysable.
--
--  Only connection setup goes through these calls, and only at startup.
--  Every byte of traffic afterwards moves through io_uring.
------------------------------------------------------------------------------

with Interfaces; use Interfaces;
with System;

package Iour.Ffi.Net with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  Address family constants
   ---------------------------------------------------------------------------

   Af_Inet      : constant := 2;
   Sock_Stream  : constant := 1;
   Sol_Socket   : constant := 1;
   So_Reuseaddr : constant := 2;
   So_Reuseport : constant := 15;
   Ipproto_Tcp  : constant := 6;
   Tcp_Nodelay  : constant := 1;

   ---------------------------------------------------------------------------
   --  struct sockaddr_in
   ---------------------------------------------------------------------------

   type Sockaddr_In is record
      Family : Unsigned_16 := Af_Inet;  --  0
      Port   : Unsigned_16 := 0;        --  2  network byte order
      Addr   : Unsigned_32 := 0;        --  4  network byte order
      Pad    : Unsigned_64 := 0;        --  8  sin_zero
   end record
     with Convention => C, Size => 16 * 8;

   for Sockaddr_In use record
      Family at 0 range 0 .. 15;
      Port   at 2 range 0 .. 15;
      Addr   at 4 range 0 .. 31;
      Pad    at 8 range 0 .. 63;
   end record;

   pragma Compile_Time_Error
     (Sockaddr_In'Size /= 16 * 8, "struct sockaddr_in must be 16 bytes");

   ---------------------------------------------------------------------------
   --  Byte order
   ---------------------------------------------------------------------------

   --  Network byte order is big-endian; these are no-ops on a big-endian
   --  host and a byte swap on a little-endian one.
   function Host_To_Network (Value : Unsigned_16) return Unsigned_16;
   function Network_To_Host (Value : Unsigned_16) return Unsigned_16;

   ---------------------------------------------------------------------------
   --  Address construction
   ---------------------------------------------------------------------------

   Any_Address : constant Unsigned_32 := 0;  --  INADDR_ANY

   --  Parse a dotted-quad into network byte order.  An empty string means
   --  "any address", which is what a server binds to.
   procedure Parse_Ipv4
     (Text    : String;
      Address : out Unsigned_32;
      Valid   : out Boolean);

   function Make_Address (Host : Unsigned_32; Port : Unsigned_16)
     return Sockaddr_In
     with Post => Make_Address'Result.Family = Af_Inet;

   ---------------------------------------------------------------------------
   --  Raw libc bindings
   ---------------------------------------------------------------------------

   function C_Socket (Domain, Kind, Protocol : C_Int) return C_Int
     with Import, Convention => C, External_Name => "socket", Global => null;

   function C_Bind (Fd : C_Int; Addr : System.Address; Len : C_Unsigned)
     return C_Int
     with Import, Convention => C, External_Name => "bind", Global => null;

   function C_Listen (Fd : C_Int; Backlog : C_Int) return C_Int
     with Import, Convention => C, External_Name => "listen", Global => null;

   function C_Setsockopt
     (Fd    : C_Int;
      Level : C_Int;
      Name  : C_Int;
      Value : System.Address;
      Len   : C_Unsigned) return C_Int
     with Import, Convention => C, External_Name => "setsockopt",
          Global => null;

   function C_Getsockname
     (Fd : C_Int; Addr : System.Address; Len : System.Address) return C_Int
     with Import, Convention => C, External_Name => "getsockname",
          Global => null;

   function C_Close (Fd : C_Int) return C_Int
     with Import, Convention => C, External_Name => "close", Global => null;

   Shut_Read  : constant := 0;
   Shut_Write : constant := 1;
   Shut_Both  : constant := 2;

   function C_Shutdown (Fd : C_Int; How : C_Int) return C_Int
     with Import, Convention => C, External_Name => "shutdown",
          Global => null;

   ---------------------------------------------------------------------------
   --  Ada-facing wrappers
   ---------------------------------------------------------------------------

   --  All of these follow io_uring's reporting convention rather than
   --  libc's, so a caller never has to switch between "-1 plus errno" and
   --  "negated errno in the result": at or above zero is the value, below
   --  zero is the negated errno.

   --  A TCP socket with TCP_NODELAY set.  Latency beats coalescing for the
   --  request/response traffic this runtime is built for.
   function Tcp_Socket return Io_Result;

   --  A bound, listening socket.  SO_REUSEADDR always; SO_REUSEPORT when
   --  asked, which lets several shards hold a listener on one port.
   function Tcp_Listener
     (Host      : Unsigned_32;
      Port      : Unsigned_16;
      Backlog   : Natural := 4096;
      Reuseport : Boolean := False) return Io_Result;

   --  The port a socket ended up bound to, which matters when binding to
   --  port 0 and letting the kernel choose.
   function Local_Port (Fd : Descriptor) return Io_Result;

   function Close (Fd : Descriptor) return Io_Result;

   --  Half-close a socket.  On a listening socket this is what makes a
   --  pending accept give up, which is how a server stops accepting without
   --  waiting for one more client to arrive.
   function Shutdown (Fd : Descriptor; How : Natural) return Io_Result;

end Iour.Ffi.Net;
