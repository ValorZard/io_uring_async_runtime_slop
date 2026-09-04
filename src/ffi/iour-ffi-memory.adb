------------------------------------------------------------------------------
--  Iour.Ffi.Memory body -- SPARK_Mode => Off.
--
--  One of the runtime's two trusted bodies.  Each subprogram is a handful
--  of lines, and each does exactly one of the two things SPARK forbids:
--  takes an address, or overlays an object on one.
------------------------------------------------------------------------------

with System.Storage_Elements; use System.Storage_Elements;

package body Iour.Ffi.Memory with SPARK_Mode => Off is

   ---------------------------------------------------------------------------
   --  Addresses
   ---------------------------------------------------------------------------

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
     (Endpoint : aliased Net.Sockaddr_In) return System.Address
   is (Endpoint'Address);

   function Of_Timespec
     (Deadline : aliased Uring.Kernel_Timespec) return System.Address
   is (Deadline'Address);

   function Of_Params (P : aliased Uring.Params) return System.Address is
     (P'Address);

   ---------------------------------------------------------------------------
   --  Ring words
   ---------------------------------------------------------------------------

   procedure Load_Word (Addr : System.Address; Value : out Unsigned_32) is
      Cell : Unsigned_32 with Import, Atomic, Address => Addr;
   begin
      Value := Cell;
   end Load_Word;

   procedure Store_Word (Addr : System.Address; Value : Unsigned_32) is
      Cell : Unsigned_32 with Import, Atomic, Address => Addr;
   begin
      Cell := Value;
   end Store_Word;

   ---------------------------------------------------------------------------
   --  Ring entries
   ---------------------------------------------------------------------------

   procedure Write_Sqe
     (Base  : System.Address;
      Count : Unsigned_32;
      Index : Unsigned_32;
      Item  : Uring.Sqe)
   is
      Slots : Uring.Sqe_Array (0 .. Count - 1)
        with Import, Address => Base;
   begin
      --  Whole-record assignment: every field is written, including the
      --  ones this opcode does not use, so a recycled slot cannot leak the
      --  previous operation's bytes to the kernel.
      Slots (Index) := Item;
   end Write_Sqe;

   procedure Read_Cqe
     (Base  : System.Address;
      Count : Unsigned_32;
      Index : Unsigned_32;
      Item  : out Uring.Cqe)
   is
      Slots : Uring.Cqe_Array (0 .. Count - 1)
        with Import, Address => Base;
   begin
      Item := Slots (Index);
   end Read_Cqe;

   procedure Write_Identity_Map (Base : System.Address; Count : Unsigned_32)
   is
      Indices : Uring.Index_Array (0 .. Count - 1)
        with Import, Address => Base;
   begin
      for I in Indices'Range loop
         Indices (I) := I;
      end loop;
   end Write_Identity_Map;

end Iour.Ffi.Memory;
