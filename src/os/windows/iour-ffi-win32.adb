------------------------------------------------------------------------------
--  Iour.Ffi.Win32 body.
--
--  Two things happen here that a plain Import cannot express: translating
--  Windows' two error vocabularies into the one the runtime uses, and
--  fetching the Winsock extension functions through WSAIoctl.
--
--  There was a third -- resolving the IoRing entry points by name, so that
--  a binary built on Windows 11 would still start on Windows 10 -- and it
--  went with the ring.  Everything imported here now is old enough to link
--  against directly.
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

   --  Two shapes of failure code turn up on the completion path: a Win32
   --  code wrapped as an HRESULT, 0x8007xxxx, and an NTSTATUS the I/O
   --  manager produced, which arrives with the whole status in the low
   --  bits.  An OVERLAPPED's Internal field is the second kind.

   Facility_Win32 : constant Unsigned_32 := 16#8007_0000#;

   --  A few NTSTATUS values worth recognising by name.
   Status_End_Of_File        : constant Unsigned_32 := 16#C000_0011#;
   Status_Connection_Reset   : constant Unsigned_32 := 16#C000_020D#;
   Status_Connection_Aborted : constant Unsigned_32 := 16#C000_0241#;
   Status_Pipe_Broken        : constant Unsigned_32 := 16#C000_014B#;
   Status_Cancelled          : constant Unsigned_32 := 16#C000_0120#;

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

   --  Atomic because the shards resolve these concurrently.  Every shard
   --  runs Reactor.Open the instant its task activates, and there is no
   --  barrier before that point: the tasks are library-level, so they are
   --  running before the environment task's first statement.
   Accept_Ex_Ptr  : Accept_Ex_Fn := null with Atomic;
   Connect_Ex_Ptr : Connect_Ex_Fn := null with Atomic;

   --  Set only when the lookup has been tried and genuinely failed, so
   --  that a machine without the extensions does not repeat it on every
   --  accept.  It is NOT an "in progress" flag, and the distinction is the
   --  whole point: see the guard in Load_Socket_Extensions below.
   Extensions_Missing : Boolean := False with Atomic;

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
      --  Guard on the RESULT, never on having started.
      --
      --  This is the shape a once-only initialiser has to have here, and it
      --  is not the shape one usually gets written in.  Every shard reaches
      --  this at once -- the shard tasks are library-level, so they are
      --  running before the environment task's first statement -- and a
      --  flag set on entry would let whichever arrived second conclude
      --  "already done" while both pointers were still null.  Start_Accept
      --  would then refuse every accept on that shard.  The identical bug
      --  in the IoRing loader that used to live here cost roughly one
      --  start-up in six: the losing shard silently ran a different data
      --  plane from its siblings.
      --
      --  Guarding on the result costs a second ioctl on the rare occasion
      --  two callers overlap.  Both compute the same pointer, so the racing
      --  writes store the same value.
      if S = Invalid_Socket
        or else Extensions_Missing
        or else (Accept_Ex_Ptr /= null and then Connect_Ex_Ptr /= null)
      then
         return;
      end if;

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

      --  Nothing came back, and nothing will.  Stop asking.
      if Accept_Ex_Ptr = null and then Connect_Ex_Ptr = null then
         Extensions_Missing := True;
      end if;
   end Load_Socket_Extensions;

   function Accept_Ex return Accept_Ex_Fn is (Accept_Ex_Ptr);
   function Connect_Ex return Connect_Ex_Fn is (Connect_Ex_Ptr);

end Iour.Ffi.Win32;
