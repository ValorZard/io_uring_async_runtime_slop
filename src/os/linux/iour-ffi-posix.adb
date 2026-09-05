with System.Storage_Elements;

package body Iour.Ffi.Posix with SPARK_Mode => On is

   use System.Storage_Elements;

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

   function Map_Failed return System.Address is
     (To_Address (Integer_Address'Last));

end Iour.Ffi.Posix;
