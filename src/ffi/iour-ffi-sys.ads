------------------------------------------------------------------------------
--  Iour.Ffi.Sys -- the handful of operating-system services the runtime
--  needs that are not I/O.
--
--  This spec is the portable one: every declaration below means the same
--  thing on Linux and on Windows, and the body that implements it lives
--  under src/os/<system>.  Nothing here names a libc symbol or a Win32
--  one; the raw imports are in Iour.Ffi.Posix and Iour.Ffi.Win32
--  respectively, where each backend can see its own system and no other.
--
--  What "the same thing" means for each is written next to it, because two
--  systems that both have a notion of, say, the descriptor limit do not
--  necessarily mean the same by it.
------------------------------------------------------------------------------

package Iour.Ffi.Sys with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  Errors
   ---------------------------------------------------------------------------

   --  The last failure this thread saw, in the runtime's own convention:
   --  always negative, so it can never be mistaken for a count, and never
   --  Io_Result'First, so it can be negated.
   --
   --  Both backends report the errno-shaped codes named in Iour (E_Again,
   --  E_Pipe, E_Conn_Reset and the rest).  On Linux those are errno itself;
   --  on Windows the WSA and Win32 codes are translated to the same
   --  numbers, so everything above this layer reasons about one vocabulary.
   function Failure_Code return Io_Result
     with Post => Failure_Code'Result < 0
                  and then Failure_Code'Result > Io_Result'First;

   ---------------------------------------------------------------------------
   --  Scheduling
   ---------------------------------------------------------------------------

   --  Bind the calling thread to one processor, counting from zero, and
   --  report whether it is there.
   --
   --  Ada asks for this with the CPU aspect, and on Linux GNAT implements
   --  it with sched_setaffinity before the task body runs, so the Linux
   --  body only confirms.  GNAT for Windows accepts the aspect and ignores
   --  it -- a task with CPU => 3 runs wherever the scheduler likes -- so
   --  the Windows body does the binding itself and waits to be moved.
   --
   --  A shard that cannot be bound still works: identity comes from
   --  Iour.Ffi.Identity, not from the core.  It just shares a processor
   --  with a sibling, which the shard loop reports and the caller can act
   --  on.
   pragma Warnings
     (GNATprove, Off, "*is not modified, could be INPUT*",
      Reason => "The Windows body writes Kernel; the Linux one does not. The contract is the union, and narrowing it would be wrong for the other backend.");
   function Bind_To_Cpu (Cpu : Natural) return Boolean
     with Side_Effects, Global => (In_Out => Kernel);
   pragma Warnings
     (GNATprove, On, "*is not modified, could be INPUT*");

   --  A Jorvik partition never terminates on its own: the environment task
   --  blocks forever once tasks are activated, and No_Task_Termination
   --  means shards are not supposed to end.  Shutdown is therefore an
   --  explicit process exit once the runtime has drained.
   procedure Exit_Process (Status : C_Int)
     with No_Return, Global => null;

   ---------------------------------------------------------------------------
   --  Memory
   ---------------------------------------------------------------------------

   --  Bytes in a page, for sizing the fiber stacks and their guard pages.
   --  On Windows this is the allocation granularity's page, not the 64 KiB
   --  reservation granularity.
   function Page_Size return Natural
     with Post => Page_Size'Result >= 4096;

   ---------------------------------------------------------------------------
   --  Resource limits
   ---------------------------------------------------------------------------

   --  Raise the open-descriptor limit to its ceiling and report the result.
   --  A server holding thousands of connections needs this on Linux, where
   --  the usual soft limit of 1024 would refuse them long before the
   --  runtime ran out of anything.  Windows has no per-process handle
   --  limit worth raising, so its body reports the ceiling it does have.
   function Raise_Descriptor_Limit return Natural;

   ---------------------------------------------------------------------------
   --  Blocking write
   ---------------------------------------------------------------------------

   --  The standard streams, as descriptors this runtime can hand to
   --  Write_Blocking or submit to a ring.  Functions rather than
   --  constants: on Windows a standard stream is a HANDLE the process is
   --  told at start-up, not a number fixed by the ABI.
   function Standard_Output return Descriptor with Global => null;
   function Standard_Error  return Descriptor with Global => null;

   --  A write that does not suspend, for the contexts where suspending is
   --  not an option: the scheduler loop itself, the environment task, and
   --  tracing.  A short or failed write of a trace line is not something
   --  anyone acts on, so nothing is reported.
   procedure Write_Blocking
     (Fd : Descriptor; Buffer : Byte_Array; Count : C_Size)
     with Global => (In_Out => Kernel), Always_Terminates;

   ---------------------------------------------------------------------------
   --  Signals
   ---------------------------------------------------------------------------

   --  Writing to a socket whose peer has gone must surface as an error on
   --  the completion, not as a signal that kills the process.  On Linux
   --  this ignores SIGPIPE; Windows has no such signal, so its body does
   --  nothing and the guarantee holds for free.
   procedure Ignore_Broken_Pipe
     with Global => (In_Out => Kernel), Always_Terminates;

end Iour.Ffi.Sys;
