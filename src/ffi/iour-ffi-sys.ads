------------------------------------------------------------------------------
--  Iour.Ffi.Sys -- direct bindings to the libc entry points the runtime
--  needs.  Every one of these is a real exported symbol, so Ada binds to it
--  with Import/Convention => C and no wrapper in between.
------------------------------------------------------------------------------

with System;

package Iour.Ffi.Sys with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  errno
   ---------------------------------------------------------------------------

   --  glibc's errno is a macro over this function, which is the symbol a
   --  foreign caller is expected to use.  It is bound as returning a named
   --  access type rather than an address: dereferencing an access value is
   --  something SPARK can follow, whereas overlaying an object on an
   --  address is not.
   type Errno_Cell is access all C_Int;

   function Errno_Location return Errno_Cell
     with Import, Convention => C, External_Name => "__errno_location",
          Global => null;

   --  Read the calling thread's errno.
   function Last_Error return C_Int;

   ---------------------------------------------------------------------------
   --  Memory mapping (used for the io_uring shared rings)
   ---------------------------------------------------------------------------

   Prot_None     : constant := 0;
   Prot_Read     : constant := 1;
   Prot_Write    : constant := 2;
   Map_Shared    : constant := 1;
   Map_Private   : constant := 2;
   Map_Anonymous : constant := 16#20#;
   Map_Populate  : constant := 16#8000#;

   --  mmap reports failure as (void *) -1 rather than NULL.
   function Map_Failed return System.Address;

   function Mmap
     (Addr   : System.Address;
      Length : C_Size;
      Prot   : C_Int;
      Flags  : C_Int;
      Fd     : C_Int;
      Offset : C_Int64) return System.Address
     with Import, Convention => C, External_Name => "mmap", Global => null;

   function Munmap (Addr : System.Address; Length : C_Size) return C_Int
     with Import, Convention => C, External_Name => "munmap", Global => null;

   function Mprotect
     (Addr : System.Address; Length : C_Size; Prot : C_Int) return C_Int
     with Import, Convention => C, External_Name => "mprotect",
          Global => null;

   function Getpagesize return C_Int
     with Import, Convention => C, External_Name => "getpagesize",
          Global => null;

   ---------------------------------------------------------------------------
   --  Scheduling and process control
   ---------------------------------------------------------------------------

   --  Which CPU the calling thread is on.  Because every shard is pinned to
   --  a distinct core by a static CPU aspect, this doubles as a cheap,
   --  allocation-free identity for the running shard.
   function Sched_Getcpu return C_Int
     with Import, Convention => C, External_Name => "sched_getcpu",
          Global => null;

   --  A Jorvik partition never terminates on its own: the environment task
   --  blocks forever once tasks are activated, and No_Task_Termination means
   --  shards are not supposed to end.  Shutdown is therefore an explicit
   --  _exit once the runtime has drained.
   procedure Exit_Process (Status : C_Int)
     with Import, Convention => C, External_Name => "_exit",
          No_Return, Global => null;

   ---------------------------------------------------------------------------
   --  Resource limits
   ---------------------------------------------------------------------------

   --  struct rlimit: two 64-bit counts on every Linux ABI this targets.
   type Rlimit is record
      Soft : Interfaces.Unsigned_64 := 0;
      Hard : Interfaces.Unsigned_64 := 0;
   end record
     with Convention => C;

   Rlimit_Nofile : constant := 7;

   --  Pointer parameters expressed as access types, so no caller has to
   --  take the address of an Ada object.
   function Getrlimit
     (Resource : C_Int; Value : access Rlimit) return C_Int
     with Import, Convention => C, External_Name => "getrlimit",
          Global => null;

   function Setrlimit
     (Resource : C_Int; Value : access constant Rlimit) return C_Int
     with Import, Convention => C, External_Name => "setrlimit",
          Global => null;

   --  Raise the open-descriptor limit to its hard ceiling and report the
   --  result.  A server holding thousands of connections needs this; the
   --  usual soft limit of 1024 would refuse them long before the runtime
   --  ran out of anything.
   function Raise_Descriptor_Limit return Natural;

   ---------------------------------------------------------------------------
   --  Blocking write
   ---------------------------------------------------------------------------

   Stdout : constant := 1;
   Stderr : constant := 2;

   --  write(2), for the contexts where suspending is not an option: the
   --  scheduler loop itself, the environment task, and tracing.  For C
   --  convention GNAT passes an array as a pointer to its first element, so
   --  no address is taken on the Ada side.  Imported as a procedure: a
   --  short or failed write of a trace line is not something anyone acts on.
   procedure Write_Blocking
     (Fd : C_Int; Buffer : Byte_Array; Count : C_Size)
     with Import, Convention => C, External_Name => "write",
          Global => (In_Out => Kernel), Always_Terminates;

   ---------------------------------------------------------------------------
   --  Signals
   ---------------------------------------------------------------------------

   Sig_Pipe : constant := 13;

   --  signal(2) returns the previous handler, which nothing here wants.
   --  Importing it as a procedure discards that and lets the binding say
   --  what it is actually for: changing kernel state.
   procedure Set_Signal (Sig : C_Int; Handler : System.Address)
     with Import, Convention => C, External_Name => "signal",
          Global => (In_Out => Kernel), Always_Terminates;

   --  Writing to a socket whose peer has gone must surface as EPIPE on the
   --  completion, not as a signal that kills the process.
   procedure Ignore_Sigpipe;

end Iour.Ffi.Sys;
