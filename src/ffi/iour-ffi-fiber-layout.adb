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

end Iour.Ffi.Fiber.Layout;
