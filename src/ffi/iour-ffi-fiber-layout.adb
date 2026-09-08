------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Layout body.
------------------------------------------------------------------------------

package body Iour.Ffi.Fiber.Layout with SPARK_Mode => On is

   function Round_Up_Pages (Bytes : Stack_Bytes; Page : Page_Bytes)
     return Natural
   is ((Bytes + Page - 1) / Page * Page);

   function Return_Slot_Offset
     (Guard   : Page_Bytes;
      Usable  : Natural;
      Reserve : Reserve_Bytes)
     return Natural
   is (Align_Down_16 (Guard + Usable) - Reserve - 8);

   --  No return slot to subtract: x30 carries the return address, so the
   --  top of the usable region rounded down to 16 is already where the
   --  first stack pointer goes.  Reserve stays in the expression because
   --  the reserve is above the frame on every ABI, even where it is zero.
   function Entry_Sp_Offset
     (Guard   : Page_Bytes;
      Usable  : Natural;
      Reserve : Reserve_Bytes)
     return Natural
   is (Align_Down_16 (Guard + Usable) - Reserve);

end Iour.Ffi.Fiber.Layout;
