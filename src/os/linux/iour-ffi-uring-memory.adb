------------------------------------------------------------------------------
--  Iour.Ffi.Uring.Memory body -- SPARK_Mode => Off.
--
--  A trusted body: each subprogram takes an address, or overlays an object
--  on one, and does nothing else.
------------------------------------------------------------------------------

package body Iour.Ffi.Uring.Memory with SPARK_Mode => Off is

   ---------------------------------------------------------------------------
   --  Addresses
   ---------------------------------------------------------------------------

   --  One timespec per submission slot of each ring.  About 512 KB at the
   --  default sizes, and static, so nothing here can fail at run time.
   type Timespec_Ring is
     array (Natural range 0 .. Ring_Entries - 1) of aliased Kernel_Timespec;
   type Timespec_Table is array (Natural range 0 .. Max_Shards - 1)
     of Timespec_Ring;

   Timeouts : Timespec_Table :=
     [others => [others => (Seconds => 0, Nanoseconds => 0)]];

   Nanos_Per_Second : constant := 1_000_000_000;

   function Stage_Timeout
     (Shard : Natural; Slot : Natural; Nanoseconds : Unsigned_64)
      return System.Address is
   begin
      Timeouts (Shard) (Slot) :=
        (Seconds     => Integer_64 (Nanoseconds / Nanos_Per_Second),
         Nanoseconds => Integer_64 (Nanoseconds mod Nanos_Per_Second));
      return Timeouts (Shard) (Slot)'Address;
   end Stage_Timeout;

   function Of_Params (P : aliased Params) return System.Address is
     (P'Address);

   function Of_Fd_Table (Table : Fd_Table) return System.Address is
     (Table'Address);

   function Of_Files_Update
     (Update : aliased Files_Update) return System.Address
   is (Update'Address);

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
      Item  : Sqe)
   is
      Slots : Sqe_Array (0 .. Count - 1) with Import, Address => Base;
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
      Item  : out Cqe)
   is
      Slots : Cqe_Array (0 .. Count - 1) with Import, Address => Base;
   begin
      Item := Slots (Index);
   end Read_Cqe;

   procedure Write_Identity_Map (Base : System.Address; Count : Unsigned_32)
   is
      Indices : Index_Array (0 .. Count - 1) with Import, Address => Base;
   begin
      for I in Indices'Range loop
         Indices (I) := I;
      end loop;
   end Write_Identity_Map;

end Iour.Ffi.Uring.Memory;
