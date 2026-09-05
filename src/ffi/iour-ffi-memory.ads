------------------------------------------------------------------------------
--  Iour.Ffi.Memory -- taking the address of an Ada object, which SPARK
--  forbids and a kernel interface cannot do without.
--
--  SPARK will not let a program turn an object into an address, so that
--  pointers can never be forged from integers.  But a submission -- to a
--  ring, to a completion port, to anything -- is exactly a promise that
--  some bytes will be at some address until the operation finishes.
--
--  SPARK's own manual prescribes the shape used here: hoist each such
--  operation into a subprogram whose declaration is in SPARK, with a
--  contract, and whose body is SPARK_Mode => Off.  Callers are then
--  verified against the contract, and the body is the trusted part -- four
--  one-line functions, all in one place, all listed below.
--
--  The contracts say what can be said: an address handed to the kernel is
--  never null.  What no contract can say is that the bytes at an address
--  mean what the caller thinks they mean; that is exactly the trust these
--  bodies carry.
--
--  What used to live here too -- reading and writing the memory-mapped
--  io_uring rings -- has moved to Iour.Ffi.Uring.Memory, under the Linux
--  backend, because it is not portable and nothing else needs it.
------------------------------------------------------------------------------

with System;
with Iour.Ffi.Inet;

package Iour.Ffi.Memory with SPARK_Mode => On is

   use type System.Address;

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
     (Endpoint : aliased Inet.Sockaddr_In) return System.Address
     with Global => null,
          Post   => Of_Sockaddr'Result /= System.Null_Address;

end Iour.Ffi.Memory;
