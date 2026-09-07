------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Layout -- where a fiber's first frame goes, in bytes.
--
--  Every target maps a stack the same way: one guard page, then the usable
--  region, with the entry frame built down from the top of it.  What
--  differs is only how much room the ABI entitles the entry point to above
--  its return address -- 128 bytes of red zone on SysV, a 32-byte shadow
--  store on Win64 -- and that is a parameter here rather than a constant.
--
--  This is the arithmetic the parent's Prime used to do inline, in pointer
--  arithmetic, under a comment.  As offsets with a postcondition it is
--  proved instead, and the three things the comment claimed are the three
--  conjuncts of Return_Slot_Offset's Post.
------------------------------------------------------------------------------

package Iour.Ffi.Fiber.Layout with SPARK_Mode => On is

   subtype Page_Bytes is Natural range 4_096 .. 2 ** 20;
   subtype Stack_Bytes is Natural range 0 .. 2 ** 28;

   --  Reserve must be a multiple of 16 or the frame below it could not be
   --  8 modulo 16.  Both ABIs oblige: 128 and 32.
   subtype Reserve_Bytes is Natural range 0 .. 4_096
     with Predicate => Reserve_Bytes mod 16 = 0;

   --  Round Bytes up to a whole number of pages.  Bounded so it cannot
   --  overflow, which the pointer arithmetic this replaced could for a
   --  large enough request.
   function Round_Up_Pages (Bytes : Stack_Bytes; Page : Page_Bytes)
     return Natural
     with Global => null,
          Pre  => Bytes <= Stack_Bytes'Last - Page,
          Post => Round_Up_Pages'Result mod Page = 0
                  and then Round_Up_Pages'Result >= Bytes
                  and then Round_Up_Pages'Result < Bytes + Page;

   --  The assembly's `and $-16` on the top of the stack, as arithmetic.
   --  Modelling the mask rather than deriving 16-alignment from the page
   --  size keeps this in linear arithmetic -- divisibility transitivity is
   --  something provers do not reliably do -- and keeps the model the same
   --  shape as the code.
   function Align_Down_16 (X : Natural) return Natural is (X - X mod 16)
     with Global => null,
          Post => Align_Down_16'Result mod 16 = 0
                  and then Align_Down_16'Result <= X
                  and then X - Align_Down_16'Result < 16;

   --  Where the dummy return address goes, as a byte offset from the base
   --  of the mapping.  The postcondition is the whole point:
   --
   --    mod 16 = 8       what a call leaves, so the entry point sees the
   --                     alignment the ABI promises it and SSE spills do
   --                     not fault;
   --    >= Guard         the eight bytes written are above the guard page,
   --                     so priming a fiber never touches it;
   --    within the map   the reserve above the frame is inside the usable
   --                     region, so an entry point using all of what the
   --                     ABI gives it stays in the mapping.
   function Return_Slot_Offset
     (Guard   : Page_Bytes;
      Usable  : Natural;
      Reserve : Reserve_Bytes)
     return Natural
     with Global => null,
          Pre  => Usable in 4 * Guard .. Stack_Bytes'Last
                  and then Guard <= Stack_Bytes'Last - Usable,
          Post => Return_Slot_Offset'Result mod 16 = 8
                  and then Return_Slot_Offset'Result >= Guard
                  and then Return_Slot_Offset'Result + 8 + Reserve
                             <= Guard + Usable;

end Iour.Ffi.Fiber.Layout;
