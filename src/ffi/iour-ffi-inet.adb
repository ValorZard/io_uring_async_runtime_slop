with System;

package body Iour.Ffi.Inet with SPARK_Mode => On is

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
      --  Bounded subtypes are what let the arithmetic below be proved:
      --  an octet never exceeds 255, and never has more than three digits.
      Octet       : Natural range 0 .. 255 := 0;
      Count       : Natural range 0 .. 4   := 0;   --  octets completed
      Digits_Seen : Natural range 0 .. 3   := 0;
      Result      : Unsigned_32 := 0;
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

            declare
               Digit : constant Natural range 0 .. 9 :=
                 Character'Pos (Text (I)) - Character'Pos ('0');
            begin
               --  Reject before accumulating, so Octet * 10 + Digit is
               --  known to fit 0 .. 255 at the point it is computed.
               if Octet > (255 - Digit) / 10 then
                  Valid := False;
                  return;
               end if;
               Octet := Octet * 10 + Digit;
            end;
            Digits_Seen := Digits_Seen + 1;

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

      --  Result holds the first octet most significant.  The wire wants
      --  exactly that byte order, which on a big-endian host is already
      --  the case and on a little-endian one needs a swap.
      Address :=
        (if System."=" (System.Default_Bit_Order, System.High_Order_First)
         then Result
         else Shift_Left (Result and 16#0000_00FF#, 24) or
              Shift_Left (Result and 16#0000_FF00#, 8)  or
              Shift_Right (Result and 16#00FF_0000#, 8) or
              Shift_Right (Result and 16#FF00_0000#, 24));
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

end Iour.Ffi.Inet;
