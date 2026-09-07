------------------------------------------------------------------------------
--  Iour.Ffi.Win32 -- the Windows system calls the runtime uses.
--
--  Nothing outside src/os/windows may name this package.  The portable
--  runtime talks to Iour.Ffi.Sys, Iour.Ffi.Net and Iour.Reactor, whose
--  Windows bodies are the only clients here; Linux has Iour.Ffi.Posix in
--  exactly the same role.
--
--  Three groups, and they arrive three different ways.
--
--    Kernel32 and Ws2_32 are ordinary imports.  Every name below is a real
--    export that has been in Windows for decades, so Ada binds to it with
--    Import/Convention => C and no wrapper in between.
--
--    AcceptEx and ConnectEx are not exported the ordinary way at all.
--    Winsock hands them out at run time through WSAIoctl, because they are
--    provider extensions rather than API entry points; Load_Socket_Extensions
--    below fetches them once and the reactor calls them through the access
--    values it left behind.
--
--    Nothing else needs resolving at run time any more.  The IoRing entry
--    points did -- they arrived in Windows 11, and the GNAT toolchain's
--    Kernel32 import library predates them -- and they went with the ring.
--    Everything imported below is old enough to link against directly.
--
--  Every binding takes and returns scalars, addresses or access values,
--  never raw pointers of its own.
------------------------------------------------------------------------------

with System;
with Interfaces; use Interfaces;
with Iour.Ffi.Inet;

package Iour.Ffi.Win32 with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  Base types
   ---------------------------------------------------------------------------

   --  HANDLE, SOCKET and HIORING are all pointer-sized opaque values, and
   --  the Win64 ABI passes each of them in one register exactly as it
   --  passes a 64-bit integer.  One Ada type therefore stands for all
   --  three, and the names below say which is meant where it matters.
   type Handle is new Unsigned_64;

   Null_Handle    : constant Handle := 0;
   Invalid_Handle : constant Handle := Handle'Last;   --  (HANDLE) -1
   Invalid_Socket : constant Handle := Handle'Last;   --  (SOCKET) ~0

   subtype Dword is Unsigned_32;
   subtype Bool is C_Int;
   subtype Hresult is Integer_32;

   S_Ok    : constant Hresult := 0;

   ---------------------------------------------------------------------------
   --  Error codes
   ---------------------------------------------------------------------------

   Error_Io_Pending        : constant := 997;
   Error_Operation_Aborted : constant := 995;
   Error_Handle_Eof        : constant := 38;
   Error_Broken_Pipe       : constant := 109;
   Error_No_Data           : constant := 232;
   Error_Netname_Deleted   : constant := 64;
   Wait_Timeout            : constant := 258;

   Wsaeintr        : constant := 10004;
   Wsaeinval       : constant := 10022;
   Wsaewouldblock  : constant := 10035;
   Wsaenotconn     : constant := 10057;
   Wsaeshutdown    : constant := 10058;
   Wsaeconnaborted : constant := 10053;
   Wsaeconnreset   : constant := 10054;
   Wsaeconnrefused : constant := 10061;
   Wsaetimedout    : constant := 10060;

   function Get_Last_Error return Dword
     with Import, Convention => Stdcall, External_Name => "GetLastError",
          Global => null;

   function Wsa_Get_Last_Error return C_Int
     with Import, Convention => Stdcall, External_Name => "WSAGetLastError",
          Global => null;

   --  A Windows or Winsock code as one of the errno-shaped numbers the rest
   --  of the runtime reasons about.  The handful that have a name in Iour
   --  are translated; anything else is passed through as it stands, which
   --  is unambiguous because Windows codes and errno values do not overlap
   --  in the ranges either side actually uses.
   function As_Errno (Code : Dword) return Natural
     with Global => null;

   --  The same, already negated, as a failed Io_Result.
   function As_Failure (Code : Dword) return Io_Result
     with Global => null,
          Post => As_Failure'Result < 0
                  and then As_Failure'Result > Io_Result'First;

   --  An NTSTATUS-shaped HRESULT as a failed Io_Result.
   function Hresult_Failure (Code : Hresult) return Io_Result
     with Global => null,
          Post => Hresult_Failure'Result < 0
                  and then Hresult_Failure'Result > Io_Result'First;

   --  The same for a raw NTSTATUS, which is what an OVERLAPPED carries in
   --  its Internal field once the operation the kernel was doing is over.
   function Status_Failure (Status : Unsigned_64) return Io_Result
     with Global => null,
          Post => Status_Failure'Result < 0
                  and then Status_Failure'Result > Io_Result'First;

   ---------------------------------------------------------------------------
   --  Process, processor, memory
   ---------------------------------------------------------------------------

   procedure Exit_Process (Status : C_Uint32)
     with Import, Convention => Stdcall, External_Name => "ExitProcess",
          No_Return,
          Global => null;

   function Get_Current_Processor_Number return Dword
     with Import, Convention => Stdcall,
          External_Name => "GetCurrentProcessorNumber",
          Global => null;

   --  A pseudo-handle meaning "the calling thread", which is what every
   --  thread-affinity call wants and what GetCurrentThread returns.
   function Current_Thread return Handle
     with Import, Convention => Stdcall, External_Name => "GetCurrentThread",
          Global => null;

   --  Returns the previous mask, or zero on failure.
   function Set_Thread_Affinity_Mask
     (Thread : Handle; Mask : Unsigned_64) return Unsigned_64
     with Import, Convention => Stdcall,
          External_Name => "SetThreadAffinityMask",
          Global => null;

   --  Give the rest of this time slice back, so a thread that has just
   --  been given a new affinity is moved before it looks again.
   procedure Switch_To_Thread
     with Import, Convention => Stdcall, External_Name => "SwitchToThread",
          Global => (In_Out => Kernel), Always_Terminates;

   Std_Output_Handle : constant := 16#FFFF_FFF5#;   --  (DWORD) -11
   Std_Error_Handle  : constant := 16#FFFF_FFF4#;   --  (DWORD) -12

   function Get_Std_Handle (Which : Dword) return Handle
     with Import, Convention => Stdcall, External_Name => "GetStdHandle",
          Global => null;

   function Close_Handle (H : Handle) return Bool
     with Import, Convention => Stdcall, External_Name => "CloseHandle",
          Global => null;

   --  Cancel outstanding overlapped I/O on a handle.  With Overlap null it
   --  cancels every request on that handle whichever thread issued it,
   --  which is the difference from CancelIo and the reason this is the one
   --  to use here: the accept was submitted by a shard and the cancel comes
   --  from the environment task.
   function Cancel_Io
     (H : Handle; Overlap : System.Address) return Bool
     with Import, Convention => Stdcall, External_Name => "CancelIoEx",
          Side_Effects, Global => (In_Out => Kernel), Always_Terminates;

   function Write_File
     (H         : Handle;
      Buffer    : System.Address;
      To_Write  : Dword;
      Written   : access Dword;
      Overlap   : System.Address) return Bool
     with Import, Convention => Stdcall, External_Name => "WriteFile",
          Global => null;

   --  WriteFile again, with the buffer as an array rather than an address.
   --  For C convention GNAT passes an array as a pointer to its first
   --  element, so nothing here takes an address -- which is what keeps
   --  Iour.Ffi.Sys.Write_Blocking, its only caller, inside SPARK.  The
   --  Linux side imports write(2) exactly this way and for exactly this
   --  reason.  A procedure, because a short or failed write of a trace
   --  line is not something anyone acts on.
   procedure Write_Blocking
     (H         : Handle;
      Buffer    : Byte_Array;
      To_Write  : Dword;
      Written   : access Dword;
      Overlap   : System.Address)
     with Import, Convention => Stdcall, External_Name => "WriteFile",
          Global => (In_Out => Kernel), Always_Terminates;

   Mem_Commit  : constant := 16#0000_1000#;
   Mem_Reserve : constant := 16#0000_2000#;
   Mem_Release : constant := 16#0000_8000#;
   Page_Noaccess  : constant := 16#01#;
   Page_Readwrite : constant := 16#04#;

   function Virtual_Alloc
     (Address : System.Address;
      Size    : C_Size;
      Kind    : Dword;
      Protect : Dword) return System.Address
     with Import, Convention => Stdcall, External_Name => "VirtualAlloc",
          Global => null;

   function Virtual_Free
     (Address : System.Address; Size : C_Size; Kind : Dword) return Bool
     with Import, Convention => Stdcall, External_Name => "VirtualFree",
          Global => null;

   function Virtual_Protect
     (Address  : System.Address;
      Size     : C_Size;
      Protect  : Dword;
      Previous : access Dword) return Bool
     with Import, Convention => Stdcall, External_Name => "VirtualProtect",
          Global => null;

   --  struct SYSTEM_INFO, of which only the page size is wanted.  The rest
   --  is mirrored so the record is the size the call expects to fill.
   type System_Info is record
      Processor_Architecture : Unsigned_32 := 0;
      Page_Size              : Unsigned_32 := 0;
      Minimum_Application_Address : System.Address := System.Null_Address;
      Maximum_Application_Address : System.Address := System.Null_Address;
      Active_Processor_Mask  : Unsigned_64 := 0;
      Number_Of_Processors   : Unsigned_32 := 0;
      Processor_Type         : Unsigned_32 := 0;
      Allocation_Granularity : Unsigned_32 := 0;
      Processor_Level        : Unsigned_16 := 0;
      Processor_Revision     : Unsigned_16 := 0;
   end record
     with Convention => C;

   procedure Get_System_Info (Info : access System_Info)
     with Import, Convention => Stdcall, External_Name => "GetSystemInfo",
          Global => null, Always_Terminates;

   ---------------------------------------------------------------------------
   --  The thread pool
   ---------------------------------------------------------------------------

   --  What is NOT here any more is as informative as what is.  There were
   --  events, WaitForMultipleObjects and RegisterWaitForSingleObject, and
   --  every one of them existed to bridge an IoRing's completion event onto
   --  a completion port so that a shard had one place to sleep.  With the
   --  ring gone the port is the only place a completion can arrive, so it
   --  is also the only place a shard sleeps and the only thing that has to
   --  wake it -- and PostQueuedCompletionStatus already does that.
   --
   --  What remains of the thread pool is the two things the port genuinely
   --  cannot do: a timer, because there is no timeout completion; and a
   --  work item, because there is no asynchronous connect being used yet.

   --  CreateThreadpoolTimer's callback:
   --    void (*)(PTP_CALLBACK_INSTANCE, PVOID, PTP_TIMER)
   type Timer_Callback is access procedure
     (Instance : System.Address;
      Context  : System.Address;
      Timer    : System.Address)
     with Convention => Stdcall;

   function Create_Threadpool_Timer
     (Callback    : Timer_Callback;
      Context     : System.Address;
      Environment : System.Address) return System.Address
     with Import, Convention => Stdcall,
          External_Name => "CreateThreadpoolTimer",
          Global => null;

   --  Due_Time is a FILETIME.  A negative value is a relative interval in
   --  hundred-nanosecond units, which is the only form this runtime uses.
   procedure Set_Threadpool_Timer
     (Timer       : System.Address;
      Due_Time    : access Integer_64;
      Period      : Dword;
      Window      : Dword)
     with Import, Convention => Stdcall,
          External_Name => "SetThreadpoolTimer",
          Global => (In_Out => Kernel), Always_Terminates;

   procedure Close_Threadpool_Timer (Timer : System.Address)
     with Import, Convention => Stdcall,
          External_Name => "CloseThreadpoolTimer",
          Global => (In_Out => Kernel), Always_Terminates;

   procedure Wait_For_Threadpool_Timer_Callbacks
     (Timer : System.Address; Cancel : Bool)
     with Import, Convention => Stdcall,
          External_Name => "WaitForThreadpoolTimerCallbacks",
          Global => (In_Out => Kernel), Always_Terminates;

   --  TrySubmitThreadpoolCallback's callback:
   --    void (*)(PTP_CALLBACK_INSTANCE, PVOID)
   type Simple_Callback is access procedure
     (Instance : System.Address; Context : System.Address)
     with Convention => Stdcall;

   function Submit_Threadpool_Callback
     (Callback    : Simple_Callback;
      Context     : System.Address;
      Environment : System.Address) return Bool
     with Import, Convention => Stdcall,
          External_Name => "TrySubmitThreadpoolCallback",
          Global => null;

   ---------------------------------------------------------------------------
   --  Completion ports
   ---------------------------------------------------------------------------

   type Overlapped is record
      Internal      : Unsigned_64 := 0;
      Internal_High : Unsigned_64 := 0;
      Offset        : Unsigned_32 := 0;
      Offset_High   : Unsigned_32 := 0;
      Event         : Handle      := 0;
   end record
     with Convention => C;

   --  The tail padding is spelled out, because this record is only ever
   --  used as an element of an array the kernel fills: a stride that did
   --  not match the C one would misread every entry after the first.
   type Overlapped_Entry is record
      Key      : Unsigned_64    := 0;
      Overlap  : System.Address := System.Null_Address;
      Internal : Unsigned_64    := 0;
      Bytes    : Unsigned_32    := 0;
      Pad      : Unsigned_32    := 0;
   end record
     with Convention => C, Size => 32 * 8;

   for Overlapped_Entry use record
      Key      at  0 range 0 .. 63;
      Overlap  at  8 range 0 .. 63;
      Internal at 16 range 0 .. 63;
      Bytes    at 24 range 0 .. 31;
      Pad      at 28 range 0 .. 31;
   end record;

   type Entry_Array is array (Natural range <>) of Overlapped_Entry
     with Convention => C;

   function Create_Completion_Port
     (File     : Handle;
      Existing : Handle;
      Key      : Unsigned_64;
      Threads  : Dword) return Handle
     with Import, Convention => Stdcall,
          External_Name => "CreateIoCompletionPort",
          Global => null;

   function Get_Completions
     (Port         : Handle;
      Entries      : System.Address;
      Count        : Dword;
      Removed      : access Dword;
      Milliseconds : Dword;
      Alertable    : Bool) return Bool
     with Import, Convention => Stdcall,
          External_Name => "GetQueuedCompletionStatusEx",
          Global => null;

   function Post_Completion
     (Port    : Handle;
      Bytes   : Dword;
      Key     : Unsigned_64;
      Overlap : System.Address) return Bool
     with Import, Convention => Stdcall,
          External_Name => "PostQueuedCompletionStatus",
          Global => null;

   ---------------------------------------------------------------------------
   --  Winsock
   ---------------------------------------------------------------------------

   Af_Inet     : constant := 2;
   Sock_Stream : constant := 1;

   Sol_Socket   : constant := 16#FFFF#;
   So_Reuseaddr : constant := 16#0004#;
   So_Update_Accept_Context  : constant := 16#700B#;
   So_Update_Connect_Context : constant := 16#7010#;
   Ipproto_Tcp  : constant := 6;
   Tcp_Nodelay  : constant := 1;

   Wsa_Flag_Overlapped : constant := 16#01#;
   Somaxconn           : constant := 16#7FFF_FFFF#;

   Sd_Receive : constant := 0;
   Sd_Send    : constant := 1;
   Sd_Both    : constant := 2;

   --  WSADATA, of which nothing is read.  Mirrored at full size so
   --  WSAStartup has the room it expects.
   type Wsa_Data is record
      Version       : Unsigned_16 := 0;
      High_Version  : Unsigned_16 := 0;
      Max_Sockets   : Unsigned_16 := 0;
      Max_Udp_Dg    : Unsigned_16 := 0;
      Vendor_Info   : System.Address := System.Null_Address;
      Description   : String (1 .. 257) := [others => ASCII.NUL];
      System_Status : String (1 .. 129) := [others => ASCII.NUL];
   end record
     with Convention => C;

   function Wsa_Startup
     (Version : Unsigned_16; Data : access Wsa_Data) return C_Int
     with Import, Convention => Stdcall, External_Name => "WSAStartup",
          Side_Effects, Global => (In_Out => Kernel), Always_Terminates;

   function Wsa_Socket
     (Family         : C_Int;
      Kind           : C_Int;
      Protocol       : C_Int;
      Protocol_Info  : System.Address;
      Group          : Unsigned_32;
      Flags          : Dword) return Handle
     with Import, Convention => Stdcall, External_Name => "WSASocketW",
          Global => null;

   function C_Bind
     (S    : Handle;
      Addr : access constant Inet.Sockaddr_In;
      Len  : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "bind",
          Global => null;

   function C_Listen (S : Handle; Backlog : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "listen",
          Global => null;

   function C_Connect
     (S    : Handle;
      Addr : access constant Inet.Sockaddr_In;
      Len  : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "connect",
          Global => null;

   function C_Getsockname
     (S    : Handle;
      Addr : access Inet.Sockaddr_In;
      Len  : access C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "getsockname",
          Global => null;

   function C_Setsockopt
     (S     : Handle;
      Level : C_Int;
      Name  : C_Int;
      Value : System.Address;
      Len   : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "setsockopt",
          Global => null;

   --  setsockopt again, with the option value as an access-to-constant
   --  rather than an address, and imported as a procedure because a
   --  refused TCP_NODELAY is never something a caller acts on.  The Linux
   --  side has Set_Option in the same shape and for the same reason: it is
   --  what lets Iour.Ffi.Net set a flag without taking an address.
   procedure Set_Option
     (S     : Handle;
      Level : C_Int;
      Name  : C_Int;
      Value : access constant C_Int;
      Len   : C_Int)
     with Import, Convention => Stdcall, External_Name => "setsockopt",
          Global => (In_Out => Kernel), Always_Terminates;

   function C_Closesocket (S : Handle) return C_Int
     with Import, Convention => Stdcall, External_Name => "closesocket",
          Side_Effects, Global => (In_Out => Kernel), Always_Terminates;

   --  The same call for the paths that want the effect and not the
   --  result: an error unwind, or a ring being torn down.
   procedure Close_Quietly (S : Handle)
     with Import, Convention => Stdcall, External_Name => "closesocket",
          Global => (In_Out => Kernel), Always_Terminates;

   function C_Shutdown (S : Handle; How : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "shutdown",
          Side_Effects, Global => (In_Out => Kernel), Always_Terminates;

   type Wsabuf is record
      Len : Unsigned_32    := 0;
      Buf : System.Address := System.Null_Address;
   end record
     with Convention => C;

   function Wsa_Recv
     (S        : Handle;
      Buffers  : System.Address;
      Count    : Dword;
      Received : access Dword;
      Flags    : access Dword;
      Overlap  : System.Address;
      Routine  : System.Address) return C_Int
     with Import, Convention => Stdcall, External_Name => "WSARecv",
          Global => null;

   function Wsa_Send
     (S       : Handle;
      Buffers : System.Address;
      Count   : Dword;
      Sent    : access Dword;
      Flags   : Dword;
      Overlap : System.Address;
      Routine : System.Address) return C_Int
     with Import, Convention => Stdcall, External_Name => "WSASend",
          Global => null;

   ---------------------------------------------------------------------------
   --  AcceptEx and ConnectEx
   ---------------------------------------------------------------------------

   --  The address block AcceptEx insists on filling: room for a local and a
   --  remote sockaddr, each padded by sixteen bytes, as the call documents.
   --  sizeof (struct sockaddr_in), which Iour.Ffi.Inet mirrors, plus the
   --  sixteen bytes of slack AcceptEx documents that it needs.
   Accept_Address_Length : constant Dword := 16 + 16;
   subtype Accept_Buffer is Byte_Array (0 .. 2 * 32 - 1);

   pragma Compile_Time_Error
     (Inet.Sockaddr_In'Size / 8 /= 16,
      "AcceptEx's address block is sized from struct sockaddr_in");

   type Accept_Ex_Fn is access function
     (Listener        : Handle;
      Accepted        : Handle;
      Output          : System.Address;
      Receive_Length  : Dword;
      Local_Length    : Dword;
      Remote_Length   : Dword;
      Received        : access Dword;
      Overlap         : System.Address) return Bool
     with Convention => Stdcall;

   type Connect_Ex_Fn is access function
     (S            : Handle;
      Name         : System.Address;
      Name_Length  : C_Int;
      Send_Buffer  : System.Address;
      Send_Length  : Dword;
      Sent         : access Dword;
      Overlap      : System.Address) return Bool
     with Convention => Stdcall;

   --  Fetch both from Winsock, using any socket of the right family.
   --  Idempotent; the pointers are process-wide.
   --
   --  The pointers themselves are lazily resolved process-wide state, and
   --  they are modelled as part of Kernel for the same reason Ffi.Fiber's
   --  slot table is: they are machine state the runtime owns, written once
   --  by whichever shard gets here first and read by all of them.  Saying
   --  so is what stops a caller being verified against a Load that claims
   --  to change nothing and an Accept_Ex that claims to be a constant.
   procedure Load_Socket_Extensions (S : Handle)
     with Global => (In_Out => Kernel), Always_Terminates;

   --  Volatile_Function, because the answer before Load_Socket_Extensions
   --  runs is not the answer after it: a plain function reading Kernel
   --  would let SPARK fold two calls into one.
   function Accept_Ex return Accept_Ex_Fn
     with Volatile_Function, Global => (Input => Kernel);

   function Connect_Ex return Connect_Ex_Fn
     with Volatile_Function, Global => (Input => Kernel);

end Iour.Ffi.Win32;
