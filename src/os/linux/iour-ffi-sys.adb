------------------------------------------------------------------------------
--  Iour.Ffi.Sys body -- Linux.
--
--  Each of these is one libc call plus the translation into the runtime's
--  own conventions.  The raw imports are next door in Iour.Ffi.Posix.
------------------------------------------------------------------------------

with System.Storage_Elements;
with Iour.Ffi.Posix;

package body Iour.Ffi.Sys with SPARK_Mode => On is

   use System.Storage_Elements;
   use type C_Int;

   package Posix renames Iour.Ffi.Posix;

   ---------------------------------------------------------------------------
   --  Failure_Code
   ---------------------------------------------------------------------------

   function Failure_Code return Io_Result is
      E : constant C_Int := Posix.Last_Error;
   begin
      --  A positive errno is negated; anything else -- errno already
      --  clear, or a value that would not survive negation -- is reported
      --  as EINVAL rather than as a success or an overflow.
      if E > 0 and then E < C_Int'Last then
         return -Io_Result (E);
      end if;
      return -E_Invalid;
   end Failure_Code;

   ---------------------------------------------------------------------------
   --  Scheduling
   ---------------------------------------------------------------------------

   --  GNAT for Linux honours the CPU aspect, with sched_setaffinity,
   --  before the task body starts running.  There is nothing left to do
   --  but confirm it landed.
   function Bind_To_Cpu (Cpu : Natural) return Boolean is
   begin
      return Posix.Sched_Getcpu = C_Int (Cpu);
   end Bind_To_Cpu;
   pragma Annotate
     (GNATprove, Intentional, "unused global ""Ffi.Kernel""",
      "The contract is the union of what the two backends do, and this is the"
      & " one that does less: the Windows body binds the thread and changes"
      & " kernel state, this one only confirms what the CPU aspect already"
      & " arranged.  Narrowing the contract to match this body would make it"
      & " wrong for the other.");

   procedure Exit_Process (Status : C_Int) is
   begin
      Posix.Exit_Process (Status);
   end Exit_Process;

   ---------------------------------------------------------------------------
   --  Page_Size
   ---------------------------------------------------------------------------

   function Page_Size return Natural is
      P : constant C_Int := Posix.Getpagesize;
   begin
      --  The postcondition is a floor, not a guess: no Linux this runtime
      --  targets has pages smaller than 4 KiB, and a smaller answer would
      --  make the guard page below every fiber stack too thin to catch an
      --  overrun.
      return (if P >= 4096 then Natural (P) else 4096);
   end Page_Size;

   ---------------------------------------------------------------------------
   --  Raise_Descriptor_Limit
   ---------------------------------------------------------------------------

   function Raise_Descriptor_Limit return Natural is
      use type Interfaces.Unsigned_64;
      Limit  : aliased Posix.Rlimit;
      Status : C_Int;

      --  Each borrow is confined to its own block.  SPARK forbids reading
      --  or writing an object while something still points at it, and the
      --  code below has to inspect Limit between calls.
      procedure Read is
         Cell : constant access Posix.Rlimit := Limit'Access;
      begin
         Status := Posix.Getrlimit (Posix.Rlimit_Nofile, Cell);
      end Read;

      procedure Write is
         Cell : constant access constant Posix.Rlimit := Limit'Access;
      begin
         Status := Posix.Setrlimit (Posix.Rlimit_Nofile, Cell);
      end Write;

   begin
      Read;
      if Status /= 0 then
         return 0;
      end if;

      if Limit.Soft < Limit.Hard then
         Limit.Soft := Limit.Hard;
         Write;
         if Status /= 0 then
            --  Refused: carry on with whatever the soft limit already was.
            Read;
            if Status /= 0 then
               return 0;
            end if;
         end if;
      end if;

      if Limit.Soft > Interfaces.Unsigned_64 (Natural'Last) then
         return Natural'Last;
      end if;
      return Natural (Limit.Soft);
   end Raise_Descriptor_Limit;

   ---------------------------------------------------------------------------
   --  Standard streams
   ---------------------------------------------------------------------------

   function Standard_Output return Descriptor is (Posix.Stdout_Fd);
   function Standard_Error return Descriptor is (Posix.Stderr_Fd);

   procedure Write_Blocking
     (Fd : Descriptor; Buffer : Byte_Array; Count : C_Size) is
   begin
      Posix.Write_Blocking (C_Int (Fd), Buffer, Count);
   end Write_Blocking;

   ---------------------------------------------------------------------------
   --  Ignore_Broken_Pipe
   ---------------------------------------------------------------------------

   procedure Ignore_Broken_Pipe is
   begin
      --  SIG_IGN is the constant 1 reinterpreted as a handler address.
      Posix.Set_Signal (Posix.Sig_Pipe, To_Address (1));
   end Ignore_Broken_Pipe;

end Iour.Ffi.Sys;
