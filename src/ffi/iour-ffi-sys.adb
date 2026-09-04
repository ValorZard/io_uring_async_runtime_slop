with System.Storage_Elements;

package body Iour.Ffi.Sys with SPARK_Mode => On is

   use System.Storage_Elements;

   ---------------------------------------------------------------------------
   --  Last_Error
   ---------------------------------------------------------------------------

   function Last_Error return C_Int is
      Cell : constant Errno_Cell := Errno_Location;
   begin
      --  glibc always returns a valid pointer here; the guard is so this
      --  function stays total rather than because it can happen.
      if Cell = null then
         return 0;
      end if;
      return Cell.all;
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

      --  Each borrow is confined to its own block.  SPARK forbids reading
      --  or writing an object while something still points at it, and the
      --  code below has to inspect Limit between calls.
      procedure Read is
         Cell : constant access Rlimit := Limit'Access;
      begin
         Status := Getrlimit (Rlimit_Nofile, Cell);
      end Read;

      procedure Write is
         Cell : constant access constant Rlimit := Limit'Access;
      begin
         Status := Setrlimit (Rlimit_Nofile, Cell);
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
   --  Ignore_Sigpipe
   ---------------------------------------------------------------------------

   procedure Ignore_Sigpipe is
   begin
      --  SIG_IGN is the constant 1 reinterpreted as a handler address.
      Set_Signal (Sig_Pipe, To_Address (1));
   end Ignore_Sigpipe;

end Iour.Ffi.Sys;
