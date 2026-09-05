------------------------------------------------------------------------------
--  Iour.Ffi.Uring.Memory -- reading and writing the memory-mapped rings.
--
--  The second thing a kernel interface needs that SPARK cannot see through:
--  accessing memory at an address only known at run time.  The rings are
--  exactly that, and the kernel is writing them concurrently.
--
--  Same shape as Iour.Ffi.Memory, and for the same reason: each operation
--  is a subprogram whose declaration is in SPARK, with a contract, and
--  whose body is SPARK_Mode => Off.  Callers are verified against the
--  contract; the body is trusted.  The contracts say what can be said -- an
--  address is never null, a ring index is inside the ring.
--
--  None of these is called from inside a protected operation.  SPARK cannot
--  see that an Off body does not block, so the reactor keeps its protected
--  operations to bookkeeping and does the memory access outside the lock --
--  which is sound, since each ring has exactly one owner.
--
--  Linux only.  The Windows backend has nothing corresponding: its IoRing
--  submission and completion queues are reached through builder and pop
--  calls, not through memory the process maps for itself.
------------------------------------------------------------------------------

with System;

package Iour.Ffi.Uring.Memory with SPARK_Mode => On is

   use type System.Address;

   ---------------------------------------------------------------------------
   --  Addresses of Ada objects, for a submission
   ---------------------------------------------------------------------------

   --  Record parameters are `aliased`, which Ada guarantees are passed by
   --  reference, so the address returned is the caller's object and not a
   --  copy.  Arrays are passed by reference by GNAT unconditionally.

   --  A relative timeout, staged where the kernel can read it.
   --
   --  IORING_OP_TIMEOUT points at a struct __kernel_timespec rather than
   --  carrying the interval in the SQE, so the bytes have to live
   --  somewhere.  Op_Spec carries the interval by value -- that is what
   --  makes it portable, and what frees callers from keeping a timespec
   --  alive across a suspension -- so the storage is here, in this body,
   --  one timespec per submission slot of each ring.  Like the saved
   --  register file in Iour.Ffi.Fiber it is modelled as part of Kernel:
   --  machine state the runtime owns and SPARK does not look inside.
   --
   --  Indexing by submission slot is what makes the lifetime argument
   --  trivial.  The kernel copies the timespec in while it processes that
   --  SQE, and the slot is not written again until the ring has wrapped
   --  every one of its entries past it.
   function Stage_Timeout
     (Shard : Natural; Slot : Natural; Nanoseconds : Unsigned_64)
      return System.Address
     with Side_Effects, Global => (In_Out => Kernel), Always_Terminates,
          Pre  => Shard < Max_Shards and then Slot < Ring_Entries,
          Post => Stage_Timeout'Result /= System.Null_Address;

   function Of_Params (P : aliased Params) return System.Address
     with Global => null,
          Post   => Of_Params'Result /= System.Null_Address;

   function Of_Fd_Table (Table : Fd_Table) return System.Address
     with Global => null,
          Pre    => Table'Length > 0,
          Post   => Of_Fd_Table'Result /= System.Null_Address;

   function Of_Files_Update
     (Update : aliased Files_Update) return System.Address
     with Global => null,
          Post   => Of_Files_Update'Result /= System.Null_Address;

   ---------------------------------------------------------------------------
   --  The memory-mapped rings
   ---------------------------------------------------------------------------

   --  The ring words and entries live in memory the kernel writes
   --  concurrently, so every access is through Kernel, the runtime's model
   --  of external state.  Reads are procedures with an out parameter: SPARK
   --  does not let a function read state something else may be writing.

   --  Atomic load of a ring word: a head, a tail, a mask.
   procedure Load_Word (Addr : System.Address; Value : out Unsigned_32)
     with Global => (Input => Kernel),
          Pre    => Addr /= System.Null_Address,
          Always_Terminates;

   --  Atomic store of a ring word.  On x86-64 GNAT compiles this to a
   --  locked exchange, which is what publishing a tail needs.
   procedure Store_Word (Addr : System.Address; Value : Unsigned_32)
     with Global => (In_Out => Kernel),
          Pre    => Addr /= System.Null_Address,
          Always_Terminates;

   --  Write one submission entry into slot Index of a ring of Count.
   procedure Write_Sqe
     (Base  : System.Address;
      Count : Unsigned_32;
      Index : Unsigned_32;
      Item  : Sqe)
     with Global => (In_Out => Kernel),
          Pre    => Base /= System.Null_Address and then Index < Count,
          Always_Terminates;

   --  Read one completion entry from slot Index of a ring of Count.
   procedure Read_Cqe
     (Base  : System.Address;
      Count : Unsigned_32;
      Index : Unsigned_32;
      Item  : out Cqe)
     with Global => (Input => Kernel),
          Pre    => Base /= System.Null_Address and then Index < Count,
          Always_Terminates;

   --  Fill the submission index array with the identity mapping: entry I
   --  points at SQE I.  Done once at ring creation.
   procedure Write_Identity_Map (Base : System.Address; Count : Unsigned_32)
     with Global => (In_Out => Kernel),
          Pre    => Base /= System.Null_Address,
          Always_Terminates;

end Iour.Ffi.Uring.Memory;
