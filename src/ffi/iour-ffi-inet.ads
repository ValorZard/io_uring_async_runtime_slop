------------------------------------------------------------------------------
--  Iour.Ffi.Inet -- IPv4 addressing, in Ada and on every platform.
--
--  struct sockaddr_in is the same sixteen bytes on Linux and on Windows --
--  it is IETF wire layout with a family tag on the front, not an OS
--  invention -- so it is mirrored once, here, and both backends hand the
--  same record to their own bind/connect.
--
--  Byte-order conversion and dotted-quad parsing are done in Ada rather
--  than borrowed from htons/inet_pton: they are a few lines each, they are
--  identical on both systems, and keeping them here means the whole address
--  path stays inside SPARK instead of disappearing into libc.
------------------------------------------------------------------------------

with Interfaces; use Interfaces;

package Iour.Ffi.Inet with SPARK_Mode => On is

   --  AF_INET is 2 on Linux and on Windows.  The one address-family
   --  constant this runtime needs is therefore not platform state.
   Af_Inet : constant := 2;

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

end Iour.Ffi.Inet;
