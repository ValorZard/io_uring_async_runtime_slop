------------------------------------------------------------------------------
--  Iour.Ffi.Sys body -- Windows.
--
--  Each of these is one Win32 call plus the translation into the runtime's
--  own conventions.  The raw imports are next door in Iour.Ffi.Win32.
------------------------------------------------------------------------------

with System;
with Interfaces; use Interfaces;
with Iour.Ffi.Win32;

package body Iour.Ffi.Sys with SPARK_Mode => On is

   package Win renames Iour.Ffi.Win32;

   use type Win.Handle;
   use type C_Int;
   use type C_Size;

   ---------------------------------------------------------------------------
   --  Failure_Code
   ---------------------------------------------------------------------------

   function Failure_Code return Io_Result is
      Wsa : constant C_Int := Win.Wsa_Get_Last_Error;
   begin
      --  Winsock keeps its own last-error slot, and it is the one that
      --  matters for everything this runtime does.  It is set from the
      --  same thread-local storage as GetLastError on every Windows since
      --  NT, so asking Winsock first and Win32 second never loses a code.
      if Wsa > 0 then
         return Win.As_Failure (Win.Dword (Wsa));
      end if;
      return Win.As_Failure (Win.Get_Last_Error);
   end Failure_Code;

   ---------------------------------------------------------------------------
   --  Scheduling
   ---------------------------------------------------------------------------

   --  GNAT for Windows accepts Ada's CPU aspect and does nothing with it,
   --  so a shard that wants a core to itself has to say so.  Affinity is
   --  not immediate: SetThreadAffinityMask records where the thread may
   --  run and the scheduler moves it at the next opportunity, so this
   --  yields and looks again rather than believing the first answer.
   --
   --  GetCurrentProcessorNumber answers within the calling thread's
   --  processor group, and a mask assigns within one group too, so the two
   --  agree for every machine up to sixty-four cores -- which Max_Shards
   --  is a long way inside.
   Bind_Attempts : constant := 8;

   function Bind_To_Cpu (Cpu : Natural) return Boolean is
   begin
      --  A mask assigns within one processor group, which is sixty-four
      --  cores; Max_Shards is a long way inside that.  The check comes
      --  first so the shift below is known to be in range.
      if Cpu >= 64 then
         return False;
      end if;

      declare
         Mask : constant Unsigned_64 := Shift_Left (1, Cpu);
         Want : constant Win.Dword   := Win.Dword (Cpu);
      begin
         if Win.Set_Thread_Affinity_Mask (Win.Current_Thread, Mask) = 0 then
            return False;
         end if;
         --  Compared as a Dword rather than converted down to Natural:
         --  GetCurrentProcessorNumber has no upper bound SPARK can see,
         --  and Cpu does.
         for Attempt in 1 .. Bind_Attempts loop
            if Win.Get_Current_Processor_Number = Want then
               return True;
            end if;
            Win.Switch_To_Thread;
         end loop;
         return Win.Get_Current_Processor_Number = Want;
      end;
   end Bind_To_Cpu;

   procedure Exit_Process (Status : C_Int) is
   begin
      Win.Exit_Process (C_Uint32 (if Status < 0 then 1 else Status));
   end Exit_Process;

   ---------------------------------------------------------------------------
   --  Page_Size
   ---------------------------------------------------------------------------

   function Page_Size return Natural is
      Info : aliased Win.System_Info;
   begin
      --  The borrow is scoped so SPARK can follow the ownership; the Linux
      --  body does the same around getrlimit.  GetSystemInfo only fills
      --  the record, so this stays a function with no global effect.
      declare
         Cell : constant access Win.System_Info := Info'Access;
      begin
         Win.Get_System_Info (Cell);
      end;
      --  4 KiB on every Windows this targets.  The floor is what keeps the
      --  guard page below a fiber stack thick enough to catch an overrun.
      if Info.Page_Size >= 4096 and then Info.Page_Size <= 16#100_0000# then
         return Natural (Info.Page_Size);
      end if;
      return 4096;
   end Page_Size;

   ---------------------------------------------------------------------------
   --  Raise_Descriptor_Limit
   ---------------------------------------------------------------------------

   --  Windows has no per-process handle rlimit to raise: the ceiling is
   --  16,777,216 handles per process, set by the kernel and not adjustable,
   --  and nothing in between refuses a socket the way a 1024-descriptor
   --  soft limit does on Linux.  Reporting the real ceiling keeps the
   --  start-up banner honest without inventing a limit that is not there.
   Windows_Handle_Ceiling : constant := 16_777_216;

   function Raise_Descriptor_Limit return Natural is (Windows_Handle_Ceiling);

   ---------------------------------------------------------------------------
   --  Standard streams
   ---------------------------------------------------------------------------

   --  A standard stream on Windows is a HANDLE the process is given at
   --  start-up, not a number the ABI fixes, so these ask each time rather
   --  than caching: the answer is a table lookup in the process block.
   function As_Descriptor (H : Win.Handle) return Descriptor is
     (if H = Win.Null_Handle or else H = Win.Invalid_Handle
        or else Unsigned_64 (H) > Unsigned_64 (Descriptor'Last)
      then Invalid_Descriptor
      else Descriptor (H));

   function Standard_Output return Descriptor is
     (As_Descriptor (Win.Get_Std_Handle (Win.Std_Output_Handle)));

   function Standard_Error return Descriptor is
     (As_Descriptor (Win.Get_Std_Handle (Win.Std_Error_Handle)));

   procedure Write_Blocking
     (Fd : Descriptor; Buffer : Byte_Array; Count : C_Size)
   is
      Written : aliased Win.Dword := 0;
      N       : constant C_Size :=
        (if Count > Buffer'Length then Buffer'Length else Count);
   begin
      if Fd = Invalid_Descriptor or else N = 0 then
         return;
      end if;

      --  Win.Write_Blocking rather than Win.Write_File: the array-typed
      --  import passes the same pointer without this body ever taking an
      --  address, which is what keeps it in SPARK.  WriteFile insists on
      --  a non-null byte count when it is not given an OVERLAPPED, so the
      --  cell is real even though nothing reads it -- a short or failed
      --  write of a trace line is not something anyone acts on.
      declare
         Cell : constant access Win.Dword := Written'Access;
      begin
         Win.Write_Blocking
           (H        => Win.Handle (Fd),
            Buffer   => Buffer,
            To_Write => Win.Dword (N),
            Written  => Cell,
            Overlap  => System.Null_Address);
      end;
   end Write_Blocking;

   ---------------------------------------------------------------------------
   --  Ignore_Broken_Pipe
   ---------------------------------------------------------------------------

   --  Windows has no SIGPIPE.  Writing to a socket whose peer has gone
   --  fails the operation and nothing else, which is exactly the behaviour
   --  Linux needs SIG_IGN to obtain.
   procedure Ignore_Broken_Pipe is null;
   pragma Annotate
     (GNATprove, Intentional, "unused global ""Ffi.Kernel""",
      "The contract is the union of what the two backends do.  The Linux"
      & " body installs SIG_IGN for SIGPIPE, which changes kernel state;"
      & " Windows has no such signal and needs to do nothing.  Narrowing"
      & " the contract to this body would be wrong for the other backend,"
      & " which is the same trade Ffi.Net.Initialize makes in reverse.");

end Iour.Ffi.Sys;
