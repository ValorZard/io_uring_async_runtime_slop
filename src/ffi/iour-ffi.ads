------------------------------------------------------------------------------
--  Iour.Ffi -- bindings to the libraries the runtime uses, and the one
--  machine-level primitive it needs.
--
--  Everything binds directly: liburing's two exported syscall wrappers and
--  libc's socket, memory-mapping and resource-limit calls are all real
--  symbols.  The context switch, which no library provides, is GNAT inline
--  Asm in Iour.Ffi.Fiber.  There is no C in this runtime.
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
--
--  The external properties are spelled out rather than defaulted, and the
--  one that matters is Effective_Reads => False.  Defaulted, External means
--  all four, and Effective_Reads => True says that reading the state is
--  itself an act that changes it -- true of a hardware FIFO, and the
--  reason SPARK forbids a function from reading such a state at all.
--  Nothing here is a FIFO.  Kernel is a marker meaning "the operating
--  system did something", so asking it a question twice gives the same
--  answer, and saying so is what lets a query like Win32.Accept_Ex -- a
--  Winsock extension pointer resolved once at run time, machine state the
--  runtime owns in the same sense as Ffi.Fiber's slot table -- be a
--  function instead of a procedure with an out parameter.
------------------------------------------------------------------------------

with Interfaces.C;

package Iour.Ffi with
  SPARK_Mode     => On,
  Abstract_State =>
    (Kernel with
       Synchronous,
       External => (Async_Readers    => True,
                    Async_Writers    => True,
                    Effective_Reads  => False,
                    Effective_Writes => True))
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
