------------------------------------------------------------------------------
--  Iour.Ffi.Memory -- the raw-memory operations SPARK cannot see through.
--
--  Two things a kernel interface needs are outside SPARK by design.  Taking
--  an object's address as a value: SPARK forbids it so that pointers can
--  never be forged from integers.  And reading or writing memory at an
--  address only known at run time, which is what a memory-mapped ring is.
--
--  SPARK's own manual prescribes the shape used here: hoist each such
--  operation into a subprogram whose declaration is in SPARK, with a
--  contract, and whose body is SPARK_Mode => Off.  Callers are then
--  verified against the contract, and the body is the trusted part -- a
--  few lines each, all in one place, all listed below.  This body and the
--  context switch in Iour.Ffi.Fiber are the runtime's entire trusted base.
--
--  The contracts say what can be said.  An address handed to the kernel is
--  never null; a ring index is inside the ring.  What no contract can say
--  is that the bytes at an address mean what the caller thinks they mean:
--  that is exactly the trust these bodies carry.
------------------------------------------------------------------------------

with System;
with Interfaces; use Interfaces;
with Iour.Ffi.Net;
with Iour.Ffi.Uring;

package Iour.Ffi.Memory with SPARK_Mode => On is

   use type System.Address;

   ---------------------------------------------------------------------------
   --  Addresses of Ada objects, for a submission queue entry
   ---------------------------------------------------------------------------

   --  Record parameters are `aliased`, which Ada guarantees are passed by
   --  reference, so the address returned is the caller's object and not a
   --  copy.  Arrays are passed by reference by GNAT unconditionally.

   function Of_Bytes (Buffer : Byte_Array) return System.Address
     with Global => null,
          Pre  => Buffer'Length > 0,
          Post => Of_Bytes'Result /= System.Null_Address;

   --  For a buffer the kernel will FILL.  Declared `out`, so that in
   --  SPARK's model the buffer counts as initialised once its address has
   --  been handed over: the kernel writes it before the completion arrives,
   --  and that promise is exactly what this trusted body stands for.  A
   --  function with an out parameter has side effects, so it may only be
   --  called as the right-hand side of an assignment.
   function Of_Output (Buffer : out Byte_Array) return System.Address
     with Side_Effects, Global => null,
          Pre  => Buffer'Length > 0,
          Post => Of_Output'Result /= System.Null_Address;

   --  Base advanced by By bytes, for the unread remainder of a buffer whose
   --  address has already been taken.  Never past the end of the object.
   function Advance
     (Base : System.Address; By : Natural) return System.Address
     with Global => null,
          Pre  => Base /= System.Null_Address,
          Post => Advance'Result /= System.Null_Address;

   function Of_Sockaddr
     (Endpoint : aliased Net.Sockaddr_In) return System.Address
     with Global => null,
          Post   => Of_Sockaddr'Result /= System.Null_Address;

   function Of_Timespec
     (Deadline : aliased Uring.Kernel_Timespec) return System.Address
     with Global => null,
          Pre    => Deadline.Seconds >= 0
                    and then Deadline.Nanoseconds in 0 .. 999_999_999,
          Post   => Of_Timespec'Result /= System.Null_Address;

   function Of_Params (P : aliased Uring.Params) return System.Address
     with Global => null,
          Post   => Of_Params'Result /= System.Null_Address;

   function Of_Fd_Table (Table : Uring.Fd_Table) return System.Address
     with Global => null,
          Pre    => Table'Length > 0,
          Post   => Of_Fd_Table'Result /= System.Null_Address;

   function Of_Files_Update
     (Update : aliased Uring.Files_Update) return System.Address
     with Global => null,
          Post   => Of_Files_Update'Result /= System.Null_Address;

   ---------------------------------------------------------------------------
   --  The memory-mapped rings
   ---------------------------------------------------------------------------

   --  The ring words and entries live in memory the kernel writes
   --  concurrently, so every access is through Kernel, the runtime's model
   --  of external state.  Reads are procedures with an out parameter: SPARK
   --  does not let a function read state something else may be writing.
   --
   --  None of them is called from inside a protected operation.  SPARK
   --  cannot see that an Off body does not block, so the reactor keeps its
   --  protected operations to bookkeeping and does the memory access
   --  outside the lock -- which is sound, since each ring has one owner.

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
      Item  : Uring.Sqe)
     with Global => (In_Out => Kernel),
          Pre    => Base /= System.Null_Address and then Index < Count,
          Always_Terminates;

   --  Read one completion entry from slot Index of a ring of Count.
   procedure Read_Cqe
     (Base  : System.Address;
      Count : Unsigned_32;
      Index : Unsigned_32;
      Item  : out Uring.Cqe)
     with Global => (Input => Kernel),
          Pre    => Base /= System.Null_Address and then Index < Count,
          Always_Terminates;

   --  Fill the submission index array with the identity mapping: entry I
   --  points at SQE I.  Done once at ring creation.
   procedure Write_Identity_Map (Base : System.Address; Count : Unsigned_32)
     with Global => (In_Out => Kernel),
          Pre    => Base /= System.Null_Address,
          Always_Terminates;

end Iour.Ffi.Memory;
