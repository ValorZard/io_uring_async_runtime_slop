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

   --  The same question on an ABI that passes the return address in a
   --  register rather than on the stack, which is why it is a separate
   --  function rather than a parameter of the one above.
   --
   --  Both x86 targets want 8 modulo 16 because a `call` has already
   --  pushed a return address and the ABI's 16-byte guarantee is measured
   --  before that push.  AAPCS64 puts the return address in x30 and
   --  requires the stack pointer to be 16-byte aligned whenever it is
   --  used to access memory -- the hardware faults otherwise if
   --  SCTLR_EL1.SA is set -- so a fiber's first stack pointer is 0 modulo
   --  16 and there is no return slot on the stack to leave room for.
   --
   --  The other two conjuncts are the same promises Return_Slot_Offset
   --  makes: above the guard page, and with the ABI's reserve above it
   --  still inside the mapping.  AAPCS64 defines no red zone, so its
   --  Reserve is zero and the third conjunct is slack; it is stated
   --  anyway so the function does not silently depend on that.
   function Entry_Sp_Offset
     (Guard   : Page_Bytes;
      Usable  : Natural;
      Reserve : Reserve_Bytes)
     return Natural
     with Global => null,
          Pre  => Usable in 4 * Guard .. Stack_Bytes'Last
                  and then Guard <= Stack_Bytes'Last - Usable,
          Post => Entry_Sp_Offset'Result mod 16 = 0
                  and then Entry_Sp_Offset'Result >= Guard
                  and then Entry_Sp_Offset'Result + Reserve
                             <= Guard + Usable;

end Iour.Ffi.Fiber.Layout;
