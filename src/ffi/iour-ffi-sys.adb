with System.Storage_Elements;

package body Iour.Ffi.Sys with SPARK_Mode => On is

   use System.Storage_Elements;

   ---------------------------------------------------------------------------
   --  Last_Error
   ---------------------------------------------------------------------------

   function Last_Error return C_Int is
      --  Overlay an integer on the address glibc hands back.  This is the
      --  documented way to reach errno from a non-C caller.
      Cell : aliased C_Int
        with Import, Volatile, Address => Errno_Location;
   begin
      return Cell;
   end Last_Error;

   ---------------------------------------------------------------------------
   --  Map_Failed
   ---------------------------------------------------------------------------

   function Map_Failed return System.Address is
     (To_Address (Integer_Address'Last));

   ---------------------------------------------------------------------------
   --  Raise_Descriptor_Limit
   ---------------------------------------------------------------------------

   function Raise_Descriptor_Limit return Natural is
      use type Interfaces.Unsigned_64;
      use type C_Int;
      Limit  : aliased Rlimit;
      Status : C_Int;
   begin
      Status := Getrlimit (Rlimit_Nofile, Limit'Address);
      if Status /= 0 then
         return 0;
      end if;

      if Limit.Soft < Limit.Hard then
         Limit.Soft := Limit.Hard;
         Status := Setrlimit (Rlimit_Nofile, Limit'Address);
         if Status /= 0 then
            --  Refused: carry on with whatever the soft limit already was.
            Status := Getrlimit (Rlimit_Nofile, Limit'Address);
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
   --  Ignore_Sigpipe
   ---------------------------------------------------------------------------

   procedure Ignore_Sigpipe is
      --  SIG_IGN is the constant 1 reinterpreted as a handler address.
      Ignored : constant System.Address :=
        Signal (Sig_Pipe, To_Address (1));
   begin
      pragma Unreferenced (Ignored);
   end Ignore_Sigpipe;

end Iour.Ffi.Sys;
