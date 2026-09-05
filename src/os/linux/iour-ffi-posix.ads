------------------------------------------------------------------------------
--  Iour.Ffi.Posix -- direct bindings to the libc entry points the Linux
--  backend needs.  Every one of these is a real exported symbol, so Ada
--  binds to it with Import/Convention => C and no wrapper in between.
--
--  Nothing outside src/os/linux may name this package.  The portable
--  runtime talks to Iour.Ffi.Sys and Iour.Ffi.Net, whose Linux bodies are
--  the only clients here; Windows has Iour.Ffi.Win32 in the same role.
--
--  Every binding takes and returns scalars, addresses or access values,
--  never raw pointers of its own, so the Ada above stays free of address
--  arithmetic.
------------------------------------------------------------------------------

with System;
with Interfaces;
with Iour.Ffi.Inet;

package Iour.Ffi.Posix with SPARK_Mode => On is

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
   --  Memory mapping (the io_uring shared rings, and the fiber stacks)
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

   --  The same call for teardown, where the result carries nothing anyone
   --  acts on.  Imported as a procedure with its effect declared.
   procedure Unmap (Addr : System.Address; Length : C_Size)
     with Import, Convention => C, External_Name => "munmap",
          Global => (In_Out => Kernel), Always_Terminates;

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

   function Sched_Getcpu return C_Int
     with Import, Convention => C, External_Name => "sched_getcpu",
          Global => null;

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

   ---------------------------------------------------------------------------
   --  Blocking write
   ---------------------------------------------------------------------------

   Stdout_Fd : constant := 1;
   Stderr_Fd : constant := 2;

   --  write(2), for the contexts where suspending is not an option.  For C
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

   ---------------------------------------------------------------------------
   --  Sockets
   ---------------------------------------------------------------------------

   Sock_Stream  : constant := 1;
   Sol_Socket   : constant := 1;
   So_Reuseaddr : constant := 2;
   So_Reuseport : constant := 15;
   Ipproto_Tcp  : constant := 6;
   Tcp_Nodelay  : constant := 1;

   function C_Socket (Domain, Kind, Protocol : C_Int) return C_Int
     with Import, Convention => C, External_Name => "socket", Global => null;

   --  Pointer parameters are expressed as Ada access types rather than
   --  addresses.  GNAT passes an access value as a plain pointer, so the C
   --  side is unchanged, and no caller has to take the address of an Ada
   --  object -- which is what keeps this package inside SPARK.
   function C_Bind
     (Fd   : C_Int;
      Addr : access constant Inet.Sockaddr_In;
      Len  : C_Unsigned) return C_Int
     with Import, Convention => C, External_Name => "bind", Global => null;

   function C_Listen (Fd : C_Int; Backlog : C_Int) return C_Int
     with Import, Convention => C, External_Name => "listen", Global => null;

   function C_Getsockname
     (Fd   : C_Int;
      Addr : access Inet.Sockaddr_In;
      Len  : access C_Unsigned) return C_Int
     with Import, Convention => C, External_Name => "getsockname",
          Global => null;

   --  close(2) and shutdown(2) change kernel state and return a status, so
   --  they are Side_Effects functions: callable only as the right-hand side
   --  of an assignment.
   function C_Close (Fd : C_Int) return C_Int
     with Import, Convention => C, External_Name => "close",
          Side_Effects, Global => (In_Out => Kernel), Always_Terminates;

   function C_Shutdown (Fd : C_Int; How : C_Int) return C_Int
     with Import, Convention => C, External_Name => "shutdown",
          Side_Effects, Global => (In_Out => Kernel), Always_Terminates;

   --  The same two calls imported as procedures, for the places that want
   --  the effect and not the result.  Declaring the effect on Kernel is
   --  what tells SPARK these calls do something.
   procedure Set_Option
     (Fd    : C_Int;
      Level : C_Int;
      Name  : C_Int;
      Value : access constant C_Int;
      Len   : C_Unsigned)
     with Import, Convention => C, External_Name => "setsockopt",
          Global => (In_Out => Kernel), Always_Terminates;

   procedure Close_Quietly (Fd : C_Int)
     with Import, Convention => C, External_Name => "close",
          Global => (In_Out => Kernel), Always_Terminates;

end Iour.Ffi.Posix;
