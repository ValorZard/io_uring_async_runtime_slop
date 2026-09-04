with Iour.Ffi.Sys;

package body Iour.Ffi.Net with SPARK_Mode => On is

   use type C_Int;

   ---------------------------------------------------------------------------
   --  Turn a libc "-1 and errno" result into the runtime's convention.
   ---------------------------------------------------------------------------

   function Adapt (Result : C_Int) return Io_Result is
      Err : C_Int;
   begin
      if Result >= 0 then
         return Io_Result (Result);
      end if;
      Err := Sys.Last_Error;
      --  Never report a failure as success, even if errno was somehow clear.
      return (if Err > 0 then -Io_Result (Err) else -1);
   end Adapt;

   ---------------------------------------------------------------------------
   --  Byte order
   ---------------------------------------------------------------------------

   function Host_To_Network (Value : Unsigned_16) return Unsigned_16 is
     (if System."=" (System.Default_Bit_Order, System.High_Order_First)
      then Value
      else Shift_Left (Value and 16#00FF#, 8) or Shift_Right (Value, 8));

   function Network_To_Host (Value : Unsigned_16) return Unsigned_16 is
     (Host_To_Network (Value));

   ---------------------------------------------------------------------------
   --  Parse_Ipv4
   ---------------------------------------------------------------------------

   procedure Parse_Ipv4
     (Text    : String;
      Address : out Unsigned_32;
      Valid   : out Boolean)
   is
      Octet  : Natural := 0;
      Count  : Natural := 0;   --  octets completed
      Digits_Seen : Natural := 0;
      Result : Unsigned_32 := 0;
   begin
      Address := Any_Address;
      Valid   := True;

      --  An empty host means INADDR_ANY, which is how a server binds to
      --  every interface.
      if Text'Length = 0 then
         return;
      end if;

      for I in Text'Range loop
         --  Four octets already complete means trailing junk.
         exit when Count > 3;

         if Text (I) in '0' .. '9' then
            if Digits_Seen = 3 then
               Valid := False;
               return;
            end if;
            Octet := Octet * 10 + (Character'Pos (Text (I)) - Character'Pos ('0'));
            Digits_Seen := Digits_Seen + 1;
            if Octet > 255 then
               Valid := False;
               return;
            end if;

         elsif Text (I) = '.' then
            if Digits_Seen = 0 or else Count = 3 then
               Valid := False;
               return;
            end if;
            Result := Shift_Left (Result, 8) or Unsigned_32 (Octet);
            Count := Count + 1;
            Octet := 0;
            Digits_Seen := 0;

         else
            Valid := False;
            return;
         end if;
      end loop;

      --  Exactly four octets, the last one non-empty.
      if Count /= 3 or else Digits_Seen = 0 then
         Valid := False;
         return;
      end if;

      Result := Shift_Left (Result, 8) or Unsigned_32 (Octet);

      --  Result is in host order with the first octet most significant;
      --  the wire wants that same order byte-for-byte, so swap into
      --  network order explicitly rather than relying on the host's.
      Address :=
        Shift_Left (Result and 16#0000_00FF#, 24) or
        Shift_Left (Result and 16#0000_FF00#, 8)  or
        Shift_Right (Result and 16#00FF_0000#, 8) or
        Shift_Right (Result and 16#FF00_0000#, 24);

      if System."=" (System.Default_Bit_Order, System.High_Order_First) then
         Address := Result;
      end if;
   end Parse_Ipv4;

   ---------------------------------------------------------------------------
   --  Make_Address
   ---------------------------------------------------------------------------

   function Make_Address (Host : Unsigned_32; Port : Unsigned_16)
     return Sockaddr_In
   is
     (Family => Af_Inet,
      Port   => Host_To_Network (Port),
      Addr   => Host,
      Pad    => 0);

   ---------------------------------------------------------------------------
   --  Set_Flag -- setsockopt with an int-valued option
   ---------------------------------------------------------------------------

   procedure Set_Flag (Fd : C_Int; Level, Name : C_Int) is
      One     : aliased constant C_Int := 1;
      Ignored : constant C_Int :=
        C_Setsockopt (Fd, Level, Name, One'Address, C_Unsigned (C_Int'Size / 8));
   begin
      --  A refused socket option is never fatal here: TCP_NODELAY and
      --  SO_REUSEPORT are optimisations, and the caller would rather have a
      --  working socket than none.
      pragma Unreferenced (Ignored);
   end Set_Flag;

   ---------------------------------------------------------------------------
   --  Discard_Close -- close a descriptor on an error path, where the
   --  close result itself carries no useful information.
   ---------------------------------------------------------------------------

   procedure Discard_Close (Fd : C_Int) is
      Ignored : constant C_Int := C_Close (Fd);
   begin
      pragma Unreferenced (Ignored);
   end Discard_Close;

   ---------------------------------------------------------------------------
   --  Tcp_Socket
   ---------------------------------------------------------------------------

   function Tcp_Socket return Io_Result is
      Fd : constant C_Int := C_Socket (Af_Inet, Sock_Stream, 0);
   begin
      if Fd < 0 then
         return Adapt (Fd);
      end if;
      Set_Flag (Fd, Ipproto_Tcp, Tcp_Nodelay);
      return Io_Result (Fd);
   end Tcp_Socket;

   ---------------------------------------------------------------------------
   --  Tcp_Listener
   ---------------------------------------------------------------------------

   function Tcp_Listener
     (Host      : Unsigned_32;
      Port      : Unsigned_16;
      Backlog   : Natural := 4096;
      Reuseport : Boolean := False) return Io_Result
   is
      Fd     : constant C_Int := C_Socket (Af_Inet, Sock_Stream, 0);
      Addr   : aliased constant Sockaddr_In := Make_Address (Host, Port);
      Status : C_Int;
      Failure : Io_Result;
   begin
      if Fd < 0 then
         return Adapt (Fd);
      end if;

      --  Without SO_REUSEADDR a restarted server trips over its own
      --  lingering TIME_WAIT sockets.
      Set_Flag (Fd, Sol_Socket, So_Reuseaddr);
      if Reuseport then
         Set_Flag (Fd, Sol_Socket, So_Reuseport);
      end if;

      Status := C_Bind (Fd, Addr'Address, C_Unsigned (Sockaddr_In'Size / 8));
      if Status < 0 then
         --  Capture errno before close(), which would overwrite it.
         Failure := Adapt (Status);
         Discard_Close (Fd);
         return Failure;
      end if;

      Status := C_Listen (Fd, C_Int (Backlog));
      if Status < 0 then
         Failure := Adapt (Status);
         Discard_Close (Fd);
         return Failure;
      end if;

      return Io_Result (Fd);
   end Tcp_Listener;

   ---------------------------------------------------------------------------
   --  Local_Port
   ---------------------------------------------------------------------------

   function Local_Port (Fd : Descriptor) return Io_Result is
      Addr   : aliased Sockaddr_In := (others => <>);
      Len    : aliased C_Unsigned := C_Unsigned (Sockaddr_In'Size / 8);
      Status : constant C_Int :=
        C_Getsockname (C_Int (Fd), Addr'Address, Len'Address);
   begin
      if Status < 0 then
         return Adapt (Status);
      end if;
      return Io_Result (Network_To_Host (Addr.Port));
   end Local_Port;

   ---------------------------------------------------------------------------
   --  Close
   ---------------------------------------------------------------------------

   function Close (Fd : Descriptor) return Io_Result is
   begin
      if Fd < 0 then
         return 0;
      end if;
      return Adapt (C_Close (C_Int (Fd)));
   end Close;

   function Shutdown (Fd : Descriptor; How : Natural) return Io_Result is
   begin
      if Fd < 0 then
         return -Io_Result (E_Invalid);
      end if;
      return Adapt (C_Shutdown (C_Int (Fd), C_Int (How)));
   end Shutdown;

end Iour.Ffi.Net;
