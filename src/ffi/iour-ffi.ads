------------------------------------------------------------------------------
--  Iour.Ffi -- bindings to the C shim and to the libraries the runtime uses.
--
--  The shim exists for reasons that are not negotiable rather than for
--  convenience:
--
--    * iour_fiber -- saving and restoring a machine context cannot be
--      written in Ada at all, and the saved contexts live beside it.
--
--  Everything else binds directly: liburing's two exported syscall wrappers
--  and libc's socket, memory-mapping and resource-limit calls are all real
--  symbols.  No scheduling, buffering or retry policy lives on the C side.
--
--  Every binding takes and returns scalars, addresses or access values,
--  never raw pointers of its own, so the Ada runtime above stays free of
--  address arithmetic.
--
--  Kernel models the operating system as SPARK external state.  A binding
--  whose whole purpose is a side effect -- installing a signal handler,
--  setting a socket option, switching a machine context -- declares that it
--  writes Kernel, so SPARK knows the call does something even though it
--  cannot see what.  Synchronous because the kernel serialises its own
--  state: two shards making system calls at once do not race in any sense
--  SPARK's data-race check is about.
------------------------------------------------------------------------------

with Interfaces.C;

package Iour.Ffi with
  SPARK_Mode     => On,
  Abstract_State => (Kernel with External, Synchronous)
is
   --  A spec with only subtypes would not normally get a body; the body is
   --  needed to carry Kernel's (empty) refinement.
   pragma Elaborate_Body;


   subtype C_Int is Interfaces.C.int;
   subtype C_Long is Interfaces.C.long;
   subtype C_Unsigned is Interfaces.C.unsigned;
   subtype C_Size is Interfaces.C.size_t;
   subtype C_Uint64 is Interfaces.Unsigned_64;
   subtype C_Uint32 is Interfaces.Unsigned_32;
   subtype C_Int64 is Interfaces.Integer_64;

end Iour.Ffi;
