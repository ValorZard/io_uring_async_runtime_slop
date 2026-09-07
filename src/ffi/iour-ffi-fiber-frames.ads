------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Frames -- the abstract machine a context switch acts on,
--  over whatever set of machine locations a target owns.
--
--  Three frames and a scratch register is the whole model.  A frame is one
--  value per location, and the model is about which location's contents end
--  up where, not about their encoding -- width is a layout question and is
--  settled by the target's own disjointness lemma.
--
--  Generic over the location set because that is the one thing no two
--  targets agree on: eight locations on SysV, twenty-five on Win64, all of
--  them 64-bit on one and four widths on the other.  Everything else about
--  a switch is the same, which is what Iour.Ffi.Fiber.Target exists to say.
--
--  Not Ghost, though only ghost code ever names these types: a ghost type
--  may not appear in the profile of a generic formal subprogram, and
--  Target's formals need State.  Nothing is emitted for a type
--  declaration, and every object of these types lives inside a Ghost
--  subprogram, so the run-time cost is still nil.
------------------------------------------------------------------------------

generic
   type Location is (<>);
package Iour.Ffi.Fiber.Frames with SPARK_Mode => On is

   type Word is mod 2 ** 64;

   type Frame is array (Location) of Word;

   --  Everything the instruction sequence can read or write.  The scratch
   --  register is not a location: both ABIs make rax caller-saved, so a
   --  switch owes nobody its value.
   type State is record
      Live    : Frame;   --  the live locations, registers and TEB alike
      Out_Ctx : Frame;   --  memory at the outgoing context pointer
      In_Ctx  : Frame;   --  memory at the incoming context pointer
      Rax     : Word;
   end record;

end Iour.Ffi.Fiber.Frames;
