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
--    The IoRing entry points are resolved with GetProcAddress rather than
--    linked.  Two reasons.  They arrived in Windows 11, so a binary that
--    imported them would refuse to start on Windows 10 instead of falling
--    back to overlapped Winsock, which is what this runtime does.  And the
--    GNAT toolchain ships a Kernel32 import library that predates them, so
--    there is nothing to link against even where they exist.
--
--  Every binding takes and returns scalars, addresses or access values,
--  never raw pointers of its own.
------------------------------------------------------------------------------

with System;
with Interfaces; use Interfaces;
with Iour.Ffi.Inet;

package Iour.Ffi.Win32 with SPARK_Mode => Off is

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
   S_False : constant Hresult := 1;

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
     with Import, Convention => Stdcall, External_Name => "GetLastError";

   function Wsa_Get_Last_Error return C_Int
     with Import, Convention => Stdcall, External_Name => "WSAGetLastError";

   --  A Windows or Winsock code as one of the errno-shaped numbers the rest
   --  of the runtime reasons about.  The handful that have a name in Iour
   --  are translated; anything else is passed through as it stands, which
   --  is unambiguous because Windows codes and errno values do not overlap
   --  in the ranges either side actually uses.
   function As_Errno (Code : Dword) return Natural;

   --  The same, already negated, as a failed Io_Result.
   function As_Failure (Code : Dword) return Io_Result
     with Post => As_Failure'Result < 0
                  and then As_Failure'Result > Io_Result'First;

   --  An NTSTATUS-shaped HRESULT -- which is what an IoRing completion
   --  reports -- as a failed Io_Result.
   function Hresult_Failure (Code : Hresult) return Io_Result
     with Post => Hresult_Failure'Result < 0
                  and then Hresult_Failure'Result > Io_Result'First;

   --  The same for a raw NTSTATUS, which is what an OVERLAPPED carries in
   --  its Internal field once the operation the kernel was doing is over.
   function Status_Failure (Status : Unsigned_64) return Io_Result
     with Post => Status_Failure'Result < 0
                  and then Status_Failure'Result > Io_Result'First;

   --  Whether an IoRing completion code means "this handle is not something
   --  an IoRing can read or write", as opposed to an ordinary I/O failure.
   --  A socket that has been associated with a completion port is the case
   --  that matters: the ring refuses it with E_INVALIDARG.
   function Means_Unsupported (Code : Hresult) return Boolean;

   ---------------------------------------------------------------------------
   --  Process, processor, memory
   ---------------------------------------------------------------------------

   procedure Exit_Process (Status : C_Uint32)
     with Import, Convention => Stdcall, External_Name => "ExitProcess",
          No_Return;

   function Get_Current_Processor_Number return Dword
     with Import, Convention => Stdcall,
          External_Name => "GetCurrentProcessorNumber";

   --  A pseudo-handle meaning "the calling thread", which is what every
   --  thread-affinity call wants and what GetCurrentThread returns.
   function Current_Thread return Handle
     with Import, Convention => Stdcall, External_Name => "GetCurrentThread";

   --  Returns the previous mask, or zero on failure.
   function Set_Thread_Affinity_Mask
     (Thread : Handle; Mask : Unsigned_64) return Unsigned_64
     with Import, Convention => Stdcall,
          External_Name => "SetThreadAffinityMask";

   --  Give the rest of this time slice back, so a thread that has just
   --  been given a new affinity is moved before it looks again.
   procedure Switch_To_Thread
     with Import, Convention => Stdcall, External_Name => "SwitchToThread";

   Std_Output_Handle : constant := 16#FFFF_FFF5#;   --  (DWORD) -11
   Std_Error_Handle  : constant := 16#FFFF_FFF4#;   --  (DWORD) -12

   function Get_Std_Handle (Which : Dword) return Handle
     with Import, Convention => Stdcall, External_Name => "GetStdHandle";

   function Close_Handle (H : Handle) return Bool
     with Import, Convention => Stdcall, External_Name => "CloseHandle";

   function Write_File
     (H         : Handle;
      Buffer    : System.Address;
      To_Write  : Dword;
      Written   : access Dword;
      Overlap   : System.Address) return Bool
     with Import, Convention => Stdcall, External_Name => "WriteFile";

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
     with Import, Convention => Stdcall, External_Name => "VirtualAlloc";

   function Virtual_Free
     (Address : System.Address; Size : C_Size; Kind : Dword) return Bool
     with Import, Convention => Stdcall, External_Name => "VirtualFree";

   function Virtual_Protect
     (Address  : System.Address;
      Size     : C_Size;
      Protect  : Dword;
      Previous : access Dword) return Bool
     with Import, Convention => Stdcall, External_Name => "VirtualProtect";

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
     with Import, Convention => Stdcall, External_Name => "GetSystemInfo";

   ---------------------------------------------------------------------------
   --  Events and the thread pool
   ---------------------------------------------------------------------------

   function Create_Event
     (Attributes    : System.Address;
      Manual_Reset  : Bool;
      Initial_State : Bool;
      Name          : System.Address) return Handle
     with Import, Convention => Stdcall, External_Name => "CreateEventW";

   --  RegisterWaitForSingleObject's callback: void (*)(PVOID, BOOLEAN).
   type Wait_Callback is access procedure
     (Context : System.Address; Timed_Out : Unsigned_8)
     with Convention => Stdcall;

   Wt_Execute_In_Wait_Thread : constant := 16#0000_0004#;
   Infinite                  : constant Dword := 16#FFFF_FFFF#;

   function Set_Event (Event : Handle) return Bool
     with Import, Convention => Stdcall, External_Name => "SetEvent";

   --  WaitForMultipleObjects over a small, fixed set: a shard waits on its
   --  ring's completion event and on its own wake event, and on nothing
   --  else.
   type Handle_Array is array (Natural range <>) of Handle
     with Convention => C;

   Wait_Object_0 : constant Dword := 0;

   function Wait_For_Objects
     (Count        : Dword;
      Handles      : System.Address;
      Wait_All     : Bool;
      Milliseconds : Dword) return Dword
     with Import, Convention => Stdcall,
          External_Name => "WaitForMultipleObjects";

   function Register_Wait
     (Wait_Object : access Handle;
      Object      : Handle;
      Callback    : Wait_Callback;
      Context     : System.Address;
      Milliseconds : Dword;
      Flags       : Dword) return Bool
     with Import, Convention => Stdcall,
          External_Name => "RegisterWaitForSingleObject";

   function Unregister_Wait
     (Wait_Object : Handle; Completion : Handle) return Bool
     with Import, Convention => Stdcall, External_Name => "UnregisterWaitEx";

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
          External_Name => "CreateThreadpoolTimer";

   --  Due_Time is a FILETIME.  A negative value is a relative interval in
   --  hundred-nanosecond units, which is the only form this runtime uses.
   procedure Set_Threadpool_Timer
     (Timer       : System.Address;
      Due_Time    : access Integer_64;
      Period      : Dword;
      Window      : Dword)
     with Import, Convention => Stdcall,
          External_Name => "SetThreadpoolTimer";

   procedure Close_Threadpool_Timer (Timer : System.Address)
     with Import, Convention => Stdcall,
          External_Name => "CloseThreadpoolTimer";

   procedure Wait_For_Threadpool_Timer_Callbacks
     (Timer : System.Address; Cancel : Bool)
     with Import, Convention => Stdcall,
          External_Name => "WaitForThreadpoolTimerCallbacks";

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
          External_Name => "TrySubmitThreadpoolCallback";

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
          External_Name => "CreateIoCompletionPort";

   function Get_Completions
     (Port         : Handle;
      Entries      : System.Address;
      Count        : Dword;
      Removed      : access Dword;
      Milliseconds : Dword;
      Alertable    : Bool) return Bool
     with Import, Convention => Stdcall,
          External_Name => "GetQueuedCompletionStatusEx";

   function Post_Completion
     (Port    : Handle;
      Bytes   : Dword;
      Key     : Unsigned_64;
      Overlap : System.Address) return Bool
     with Import, Convention => Stdcall,
          External_Name => "PostQueuedCompletionStatus";

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
     with Import, Convention => Stdcall, External_Name => "WSAStartup";

   function Wsa_Socket
     (Family         : C_Int;
      Kind           : C_Int;
      Protocol       : C_Int;
      Protocol_Info  : System.Address;
      Group          : Unsigned_32;
      Flags          : Dword) return Handle
     with Import, Convention => Stdcall, External_Name => "WSASocketW";

   function C_Bind
     (S    : Handle;
      Addr : access constant Inet.Sockaddr_In;
      Len  : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "bind";

   function C_Listen (S : Handle; Backlog : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "listen";

   function C_Connect
     (S    : Handle;
      Addr : access constant Inet.Sockaddr_In;
      Len  : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "connect";

   function C_Getsockname
     (S    : Handle;
      Addr : access Inet.Sockaddr_In;
      Len  : access C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "getsockname";

   function C_Setsockopt
     (S     : Handle;
      Level : C_Int;
      Name  : C_Int;
      Value : System.Address;
      Len   : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "setsockopt";

   function C_Closesocket (S : Handle) return C_Int
     with Import, Convention => Stdcall, External_Name => "closesocket";

   function C_Shutdown (S : Handle; How : C_Int) return C_Int
     with Import, Convention => Stdcall, External_Name => "shutdown";

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
     with Import, Convention => Stdcall, External_Name => "WSARecv";

   function Wsa_Send
     (S       : Handle;
      Buffers : System.Address;
      Count   : Dword;
      Sent    : access Dword;
      Flags   : Dword;
      Overlap : System.Address;
      Routine : System.Address) return C_Int
     with Import, Convention => Stdcall, External_Name => "WSASend";

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
   procedure Load_Socket_Extensions (S : Handle);

   function Accept_Ex return Accept_Ex_Fn;
   function Connect_Ex return Connect_Ex_Fn;

   ---------------------------------------------------------------------------
   --  IoRing
   ---------------------------------------------------------------------------

   --  IORING_OP_CODE, of which the runtime submits two.
   Ioring_Op_Read  : constant Unsigned_32 := 1;
   Ioring_Op_Write : constant Unsigned_32 := 5;

   --  IORING_FEATURE_FLAGS
   Feature_Um_Emulation : constant Unsigned_32 := 1;
   Feature_Set_Event    : constant Unsigned_32 := 2;

   --  IORING_CREATE_ADVISORY_FLAGS.  Advisory means an implementation that
   --  does not recognise it ignores it, so this is safe to ask for
   --  everywhere.
   Skip_Builder_Checks : constant Unsigned_32 := 1;

   --  The constant SubmitIoRing takes to mean "wait for everything
   --  submitted so far".
   Submit_Wait_All : constant Unsigned_32 := 16#FFFF_FFFF#;

   type Ioring_Capabilities is record
      Max_Version : Unsigned_32 := 0;
      Max_Sq      : Unsigned_32 := 0;
      Max_Cq      : Unsigned_32 := 0;
      Features    : Unsigned_32 := 0;
   end record
     with Convention => C;

   type Ioring_Cqe is record
      User_Data   : Unsigned_64 := 0;
      Result      : Hresult     := 0;
      Information : Unsigned_64 := 0;
   end record
     with Convention => C;

   --  IORING_REF_KIND
   Ref_Raw : constant Unsigned_32 := 0;

   --  IORING_HANDLE_REF and IORING_BUFFER_REF are sixteen-byte structures
   --  that the Win64 ABI passes by address rather than by value, so the
   --  builders below take the address of one of these and the caller keeps
   --  it alive for the length of the call.
   type Handle_Ref is record
      Kind  : Unsigned_32 := Ref_Raw;
      Pad   : Unsigned_32 := 0;
      Value : Handle      := 0;
   end record
     with Convention => C;

   type Buffer_Ref is record
      Kind    : Unsigned_32    := Ref_Raw;
      Pad     : Unsigned_32    := 0;
      Address : System.Address := System.Null_Address;
   end record
     with Convention => C;

   pragma Compile_Time_Error
     (Handle_Ref'Size /= 16 * 8, "IORING_HANDLE_REF must be 16 bytes");
   pragma Compile_Time_Error
     (Buffer_Ref'Size /= 16 * 8, "IORING_BUFFER_REF must be 16 bytes");
   pragma Compile_Time_Error
     (Ioring_Cqe'Size /= 24 * 8, "IORING_CQE must be 24 bytes");
   pragma Compile_Time_Error
     (Overlapped'Size /= 32 * 8, "OVERLAPPED must be 32 bytes");
   pragma Compile_Time_Error
     (Overlapped_Entry'Size /= 32 * 8, "OVERLAPPED_ENTRY must be 32 bytes");

   --  IORING_CREATE_FLAGS is two 32-bit enums in an eight-byte structure,
   --  which the Win64 ABI passes in a single register exactly as it passes
   --  a 64-bit integer.  Declaring the parameter as one is what makes the
   --  call correct without asking the compiler to reason about aggregate
   --  passing rules.
   type Create_Io_Ring_Fn is access function
     (Version : Unsigned_32;
      Flags   : Unsigned_64;
      Sq_Size : Unsigned_32;
      Cq_Size : Unsigned_32;
      Ring    : access Handle) return Hresult
     with Convention => Stdcall;

   type Close_Io_Ring_Fn is access function (Ring : Handle) return Hresult
     with Convention => Stdcall;

   type Submit_Io_Ring_Fn is access function
     (Ring         : Handle;
      Wait_For     : Unsigned_32;
      Milliseconds : Unsigned_32;
      Submitted    : access Unsigned_32) return Hresult
     with Convention => Stdcall;

   type Pop_Completion_Fn is access function
     (Ring : Handle; Cqe : access Ioring_Cqe) return Hresult
     with Convention => Stdcall;

   type Set_Completion_Event_Fn is access function
     (Ring : Handle; Event : Handle) return Hresult
     with Convention => Stdcall;

   type Query_Capabilities_Fn is access function
     (Capabilities : access Ioring_Capabilities) return Hresult
     with Convention => Stdcall;

   type Op_Supported_Fn is access function
     (Ring : Handle; Op : Unsigned_32) return Bool
     with Convention => Stdcall;

   type Build_Read_Fn is access function
     (Ring      : Handle;
      File_Ref  : System.Address;
      Data_Ref  : System.Address;
      Bytes     : Unsigned_32;
      Offset    : Unsigned_64;
      User_Data : Unsigned_64;
      Sqe_Flags : Unsigned_32) return Hresult
     with Convention => Stdcall;

   type Build_Write_Fn is access function
     (Ring        : Handle;
      File_Ref    : System.Address;
      Buffer_Ref  : System.Address;
      Bytes       : Unsigned_32;
      Offset      : Unsigned_64;
      Write_Flags : Unsigned_32;
      User_Data   : Unsigned_64;
      Sqe_Flags   : Unsigned_32) return Hresult
     with Convention => Stdcall;

   --  Resolve the IoRing entry points once.  Idempotent, and safe to call
   --  on a system that has none: Available then stays False and the
   --  reactor uses overlapped Winsock throughout.
   procedure Load_Ioring;

   function Ioring_Available return Boolean;
   function Ioring_Version return Unsigned_32;
   function Ioring_Features return Unsigned_32;

   function Create_Io_Ring return Create_Io_Ring_Fn;
   function Close_Io_Ring return Close_Io_Ring_Fn;
   function Submit_Io_Ring return Submit_Io_Ring_Fn;
   function Pop_Completion return Pop_Completion_Fn;
   function Set_Completion_Event return Set_Completion_Event_Fn;
   function Build_Read return Build_Read_Fn;
   function Build_Write return Build_Write_Fn;

end Iour.Ffi.Win32;
