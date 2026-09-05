------------------------------------------------------------------------------
--  Iour.Ffi.Win32 body.
--
--  Three things happen here that a plain Import cannot express: translating
--  Windows' two error vocabularies into the one the runtime uses, fetching
--  the Winsock extension functions through WSAIoctl, and resolving the
--  IoRing entry points by name so that a Windows 10 machine gets a runtime
--  that works rather than one that will not load.
------------------------------------------------------------------------------

with Ada.Unchecked_Conversion;
with Interfaces.C;

package body Iour.Ffi.Win32 with SPARK_Mode => Off is

   use type Interfaces.C.int;
   use type System.Address;

   ---------------------------------------------------------------------------
   --  Error translation
   ---------------------------------------------------------------------------

   function As_Errno (Code : Dword) return Natural is
   begin
      case Code is
         when Wsaeconnreset | Error_Netname_Deleted => return E_Conn_Reset;
         when Wsaeconnaborted                       => return E_Conn_Aborted;
         when Wsaeshutdown | Wsaenotconn
            | Error_Broken_Pipe | Error_No_Data     => return E_Pipe;
         when Wsaewouldblock                        => return E_Again;
         when Wsaeinval                             => return E_Invalid;
         when Wsaeintr                              => return E_Intr;
         when Error_Operation_Aborted               => return E_Canceled;
         when Wait_Timeout | Wsaetimedout           => return E_Time;
         when 0                                     => return E_Invalid;
         when others =>
            --  Everything else keeps its Windows number.  Nothing is lost:
            --  the codes the runtime reasons about by name are all above,
            --  and the ones that are not are more useful reported as
            --  themselves than flattened into EINVAL.
            if Code < Dword (Natural'Last) then
               return Natural (Code);
            end if;
            return E_Invalid;
      end case;
   end As_Errno;

   function As_Failure (Code : Dword) return Io_Result is
      E : constant Natural := As_Errno (Code);
   begin
      if E > 0 and then E < Natural (Io_Result'Last) then
         return -Io_Result (E);
      end if;
      return -E_Invalid;
   end As_Failure;

   ---------------------------------------------------------------------------
   --  HRESULT translation
   ---------------------------------------------------------------------------

   --  An IoRing completion reports an HRESULT.  Two shapes turn up: a
   --  Win32 code wrapped as 0x8007xxxx, and an NTSTATUS the I/O manager
   --  produced, which arrives with the whole status in the low bits.

   Facility_Win32 : constant Unsigned_32 := 16#8007_0000#;

   --  A few NTSTATUS values worth recognising by name.
   Status_End_Of_File        : constant Unsigned_32 := 16#C000_0011#;
   Status_Connection_Reset   : constant Unsigned_32 := 16#C000_020D#;
   Status_Connection_Aborted : constant Unsigned_32 := 16#C000_0241#;
   Status_Pipe_Broken        : constant Unsigned_32 := 16#C000_014B#;
   Status_Cancelled          : constant Unsigned_32 := 16#C000_0120#;
   Status_Invalid_Handle     : constant Unsigned_32 := 16#C000_0008#;
   Status_Invalid_Parameter  : constant Unsigned_32 := 16#C000_000D#;
   Status_Not_Supported      : constant Unsigned_32 := 16#C000_00BB#;
   Status_Invalid_Device_Req : constant Unsigned_32 := 16#C000_0010#;

   function Raw (Code : Hresult) return Unsigned_32 is
     (Unsigned_32'Mod (Code));

   function Hresult_Failure (Code : Hresult) return Io_Result is
      Bits : constant Unsigned_32 := Raw (Code);
   begin
      --  A Win32 code in HRESULT clothing: unwrap and translate.
      if (Bits and 16#FFFF_0000#) = Facility_Win32 then
         return As_Failure (Bits and 16#FFFF#);
      end if;

      case Bits is
         when Status_End_Of_File        => return 0;
         when Status_Connection_Reset   => return -E_Conn_Reset;
         when Status_Connection_Aborted => return -E_Conn_Aborted;
         when Status_Pipe_Broken        => return -E_Pipe;
         when Status_Cancelled          => return -E_Canceled;
         when others                    => return -E_Invalid;
      end case;
   end Hresult_Failure;

   --  The low thirty-two bits of an OVERLAPPED's Internal field, read as
   --  the signed HRESULT-shaped value the rest of this reasons about.
   --  Hresult is a signed type, so the reinterpretation is arithmetic
   --  rather than an attribute.
   function From_Bits (Bits : Unsigned_32) return Hresult is
     (if Bits <= Unsigned_32 (Hresult'Last) then Hresult (Bits)
      else -Hresult (not Bits) - 1);

   function Status_Failure (Status : Unsigned_64) return Io_Result is
     (Hresult_Failure (From_Bits (Unsigned_32 (Status and 16#FFFF_FFFF#))));

   function Means_Unsupported (Code : Hresult) return Boolean is
      Bits : constant Unsigned_32 := Raw (Code);
   begin
      --  E_INVALIDARG (0x80070057), E_HANDLE (0x80070006), E_NOTIMPL
      --  (0x80004001), and the NTSTATUS forms of the same three.  A socket
      --  that has been associated with a completion port answers with the
      --  first of these, which is the case this predicate exists for.
      return Bits in 16#8007_0057# | 16#8007_0006# | 16#8007_0001#
                   | 16#8007_0032# | 16#8000_4001#
                   | Status_Invalid_Handle | Status_Invalid_Parameter
                   | Status_Not_Supported | Status_Invalid_Device_Req;
   end Means_Unsupported;

   ---------------------------------------------------------------------------
   --  Winsock extension functions
   ---------------------------------------------------------------------------

   type Guid is record
      Data1 : Unsigned_32 := 0;
      Data2 : Unsigned_16 := 0;
      Data3 : Unsigned_16 := 0;
      Data4 : Byte_Array (0 .. 7) := [others => 0];
   end record
     with Convention => C;

   Sio_Get_Extension_Function_Pointer : constant Dword := 16#C800_0006#;

   --  WSAID_ACCEPTEX  {b5367df1-cbac-11cf-95ca-00805f48a192}
   Id_Accept_Ex : constant Guid :=
     (16#B536_7DF1#, 16#CBAC#, 16#11CF#,
      [16#95#, 16#CA#, 16#00#, 16#80#, 16#5F#, 16#48#, 16#A1#, 16#92#]);

   --  WSAID_CONNECTEX {25a207b9-ddf3-4660-8ee9-76e58c74063e}
   Id_Connect_Ex : constant Guid :=
     (16#25A2_07B9#, 16#DDF3#, 16#4660#,
      [16#8E#, 16#E9#, 16#76#, 16#E5#, 16#8C#, 16#74#, 16#06#, 16#3E#]);

   function Wsa_Ioctl
     (S              : Handle;
      Code           : Dword;
      In_Buffer      : System.Address;
      In_Size        : Dword;
      Out_Buffer     : System.Address;
      Out_Size       : Dword;
      Returned       : access Dword;
      Overlap        : System.Address;
      Completion     : System.Address) return C_Int
     with Import, Convention => Stdcall, External_Name => "WSAIoctl";

   Accept_Ex_Ptr  : Accept_Ex_Fn := null;
   Connect_Ex_Ptr : Connect_Ex_Fn := null;
   Extensions_Tried : Boolean := False;

   procedure Load_Socket_Extensions (S : Handle) is
      Returned : aliased Dword := 0;
      Status   : C_Int;

      function To_Accept is new Ada.Unchecked_Conversion
        (System.Address, Accept_Ex_Fn);
      function To_Connect is new Ada.Unchecked_Conversion
        (System.Address, Connect_Ex_Fn);

      Accept_Slot  : aliased System.Address := System.Null_Address;
      Connect_Slot : aliased System.Address := System.Null_Address;
      Which        : aliased Guid;
   begin
      if Extensions_Tried or else S = Invalid_Socket then
         return;
      end if;
      Extensions_Tried := True;

      Which := Id_Accept_Ex;
      Status := Wsa_Ioctl
        (S, Sio_Get_Extension_Function_Pointer,
         Which'Address, Guid'Size / 8,
         Accept_Slot'Address, System.Address'Size / 8,
         Returned'Access, System.Null_Address, System.Null_Address);
      if Status = 0 then
         Accept_Ex_Ptr := To_Accept (Accept_Slot);
      end if;

      Which := Id_Connect_Ex;
      Status := Wsa_Ioctl
        (S, Sio_Get_Extension_Function_Pointer,
         Which'Address, Guid'Size / 8,
         Connect_Slot'Address, System.Address'Size / 8,
         Returned'Access, System.Null_Address, System.Null_Address);
      if Status = 0 then
         Connect_Ex_Ptr := To_Connect (Connect_Slot);
      end if;
   end Load_Socket_Extensions;

   function Accept_Ex return Accept_Ex_Fn is (Accept_Ex_Ptr);
   function Connect_Ex return Connect_Ex_Fn is (Connect_Ex_Ptr);

   ---------------------------------------------------------------------------
   --  IoRing
   ---------------------------------------------------------------------------

   function Load_Library (Name : Interfaces.C.char_array) return Handle
     with Import, Convention => Stdcall, External_Name => "LoadLibraryA";

   function Get_Proc_Address
     (Module : Handle; Name : Interfaces.C.char_array) return System.Address
     with Import, Convention => Stdcall, External_Name => "GetProcAddress";

   Loaded    : Boolean := False;
   Available : Boolean := False;
   Version   : Unsigned_32 := 0;
   Features  : Unsigned_32 := 0;

   Create_Ptr : Create_Io_Ring_Fn := null;
   Close_Ptr  : Close_Io_Ring_Fn := null;
   Submit_Ptr : Submit_Io_Ring_Fn := null;
   Pop_Ptr    : Pop_Completion_Fn := null;
   Event_Ptr  : Set_Completion_Event_Fn := null;
   Read_Ptr   : Build_Read_Fn := null;
   Write_Ptr  : Build_Write_Fn := null;

   procedure Load_Ioring is
      use Interfaces.C;

      function To_Create is new Ada.Unchecked_Conversion
        (System.Address, Create_Io_Ring_Fn);
      function To_Close is new Ada.Unchecked_Conversion
        (System.Address, Close_Io_Ring_Fn);
      function To_Submit is new Ada.Unchecked_Conversion
        (System.Address, Submit_Io_Ring_Fn);
      function To_Pop is new Ada.Unchecked_Conversion
        (System.Address, Pop_Completion_Fn);
      function To_Event is new Ada.Unchecked_Conversion
        (System.Address, Set_Completion_Event_Fn);
      function To_Query is new Ada.Unchecked_Conversion
        (System.Address, Query_Capabilities_Fn);
      function To_Read is new Ada.Unchecked_Conversion
        (System.Address, Build_Read_Fn);
      function To_Write is new Ada.Unchecked_Conversion
        (System.Address, Build_Write_Fn);

      Module : Handle;
      Query  : Query_Capabilities_Fn;
      Caps   : aliased Ioring_Capabilities;
      Status : Hresult;

      function Resolve (Name : String) return System.Address is
        (Get_Proc_Address (Module, To_C (Name)));

   begin
      if Loaded then
         return;
      end if;
      Loaded := True;

      --  The IoRing API set is implemented in KernelBase, and the API-set
      --  stub forwards there.  Ask for the real module: it is present on
      --  every Windows this could run on, and only the entry points inside
      --  it are new.
      Module := Load_Library (To_C ("kernelbase.dll"));
      if Module = Null_Handle then
         return;
      end if;

      Create_Ptr := To_Create (Resolve ("CreateIoRing"));
      Close_Ptr  := To_Close  (Resolve ("CloseIoRing"));
      Submit_Ptr := To_Submit (Resolve ("SubmitIoRing"));
      Pop_Ptr    := To_Pop    (Resolve ("PopIoRingCompletion"));
      Event_Ptr  := To_Event  (Resolve ("SetIoRingCompletionEvent"));
      Read_Ptr   := To_Read   (Resolve ("BuildIoRingReadFile"));
      Write_Ptr  := To_Write  (Resolve ("BuildIoRingWriteFile"));
      Query      := To_Query  (Resolve ("QueryIoRingCapabilities"));

      --  Read and write are both required.  Write arrived one version
      --  after read, and a ring that can only read is no use to a server.
      if Create_Ptr = null or else Submit_Ptr = null
        or else Pop_Ptr = null or else Read_Ptr = null
        or else Write_Ptr = null or else Query = null
      then
         return;
      end if;

      Status := Query (Caps'Access);
      if Status < 0 or else Caps.Max_Version = 0 then
         return;
      end if;

      Version   := Caps.Max_Version;
      Features  := Caps.Features;
      Available := True;
   end Load_Ioring;

   function Ioring_Available return Boolean is (Available);
   function Ioring_Version return Unsigned_32 is (Version);
   function Ioring_Features return Unsigned_32 is (Features);

   function Create_Io_Ring return Create_Io_Ring_Fn is (Create_Ptr);
   function Close_Io_Ring return Close_Io_Ring_Fn is (Close_Ptr);
   function Submit_Io_Ring return Submit_Io_Ring_Fn is (Submit_Ptr);
   function Pop_Completion return Pop_Completion_Fn is (Pop_Ptr);
   function Set_Completion_Event return Set_Completion_Event_Fn is (Event_Ptr);
   function Build_Read return Build_Read_Fn is (Read_Ptr);
   function Build_Write return Build_Write_Fn is (Write_Ptr);

end Iour.Ffi.Win32;
