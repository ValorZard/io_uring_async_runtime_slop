------------------------------------------------------------------------------
--  Iour.Ffi.Memory body -- SPARK_Mode => Off.
--
--  One of the runtime's trusted bodies.  Each subprogram is one line, and
--  each does the single thing SPARK forbids: takes an address.
------------------------------------------------------------------------------

with System.Storage_Elements; use System.Storage_Elements;

package body Iour.Ffi.Memory with SPARK_Mode => Off is

   function Of_Bytes (Buffer : Byte_Array) return System.Address is
     (Buffer'Address);

   --  Buffer is `out` for SPARK's benefit and deliberately never written
   --  here: the kernel fills it, later.
   pragma Warnings (Off, "*""Buffer"" is never assigned*");
   pragma Warnings (Off, "*""Buffer"" is not modified*");
   function Of_Output (Buffer : out Byte_Array) return System.Address is
   begin
      return Buffer'Address;
   end Of_Output;
   pragma Warnings (On, "*""Buffer"" is not modified*");
   pragma Warnings (On, "*""Buffer"" is never assigned*");

   function Advance
     (Base : System.Address; By : Natural) return System.Address
   is (Base + Storage_Offset (By));

   function Of_Sockaddr
     (Endpoint : aliased Inet.Sockaddr_In) return System.Address
   is (Endpoint'Address);

end Iour.Ffi.Memory;
