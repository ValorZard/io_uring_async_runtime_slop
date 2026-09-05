------------------------------------------------------------------------------
--  Iour.Ffi.Sys body -- Windows.
--
--  Each of these is one Win32 call plus the translation into the runtime's
--  own conventions.  The raw imports are next door in Iour.Ffi.Win32.
------------------------------------------------------------------------------

with System;
with Interfaces; use Interfaces;
with Iour.Ffi.Win32;

package body Iour.Ffi.Sys with SPARK_Mode => Off is

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
      if Wsa /= 0 then
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
      Mask : constant Unsigned_64 := Shift_Left (1, Cpu);
   begin
      if Cpu >= 64 then
         return False;
      end if;
      if Win.Set_Thread_Affinity_Mask (Win.Current_Thread, Mask) = 0 then
         return False;
      end if;
      for Attempt in 1 .. Bind_Attempts loop
         if Natural (Win.Get_Current_Processor_Number) = Cpu then
            return True;
         end if;
         Win.Switch_To_Thread;
      end loop;
      return Natural (Win.Get_Current_Processor_Number) = Cpu;
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
      Win.Get_System_Info (Info'Access);
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
      Ignored : Win.Bool;
      N       : constant C_Size :=
        (if Count > Buffer'Length then Buffer'Length else Count);
   begin
      if Fd = Invalid_Descriptor or else N = 0 then
         return;
      end if;
      Ignored := Win.Write_File
        (H        => Win.Handle (Fd),
         Buffer   => Buffer'Address,
         To_Write => Win.Dword (N),
         Written  => Written'Access,
         Overlap  => System.Null_Address);
      --  A short or failed write of a trace line is not something anyone
      --  acts on; this call exists for its effect.
   end Write_Blocking;

   ---------------------------------------------------------------------------
   --  Ignore_Broken_Pipe
   ---------------------------------------------------------------------------

   --  Windows has no SIGPIPE.  Writing to a socket whose peer has gone
   --  fails the operation and nothing else, which is exactly the behaviour
   --  Linux needs SIG_IGN to obtain.
   procedure Ignore_Broken_Pipe is null;

end Iour.Ffi.Sys;
