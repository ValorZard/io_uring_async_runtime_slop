------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Text -- the assembler-text scanner, shared by every
--  target.
--
--  A target's model renders its proved instruction sequence and compares it
--  with the static string GNAT actually assembled.  The comparison walks
--  the template once, left to right, and this package is that walk: a
--  cursor, an "expect these characters next" primitive, and the decimal
--  conversion every displacement needs.  None of it knows what a register
--  is, so none of it belongs in a per-target file.
--
--  Expect is written to fail *early and stay failed*: once Ok is False the
--  cursor stops advancing, so the position it leaves behind is where the
--  divergence began rather than wherever the walk happened to run out.
--  That is what makes "mismatch at character 153" a usable diagnostic.
------------------------------------------------------------------------------

package Iour.Ffi.Fiber.Text with SPARK_Mode => On is

   --  A newline, and the doubled percent GCC wants in an extended-asm
   --  template.  Both appear in the emitted constants and in the checker,
   --  so neither can be got right in one place and wrong in the other.
   --
   --  Nl is a concatenation rather than an aggregate on purpose: GNAT folds
   --  concatenation of literals into a static string and an Asm template
   --  must be static, while an array aggregate never is.
   Nl    : constant String := "" & ASCII.LF;
   Sigil : constant String := "%%";

   --  Longest single rendered instruction, and the largest template a
   --  checker will look at.  Both are bounds for the proof, not budgets.
   Max_Line     : constant := 64;
   Max_Template : constant := 8192;

   --  Displacements fit in three digits on every target so far: the Win64
   --  context is 272 bytes and the SysV one 64.
   subtype Small is Natural range 0 .. 999;

   function Dec (N : Small) return String
     with Global => null,
          Post => Dec'Result'First = 1
                  and then Dec'Result'Length in 1 .. 3;

   --  Consume S from Text at Cur, or give up.
   procedure Expect
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      S    : String)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Max_Template
               and then Cur <= Text'Last + 1
               and then S'Length <= Max_Line,
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   --  Whether the walk consumed the template exactly.  Text that merely
   --  begins with the right instructions is not the right instructions:
   --  anything trailing would be assembled too.
   function Consumed_All (Text : String; Cur : Positive) return Boolean is
     (Cur = Text'Last + 1)
     with Global => null,
          Pre => Text'First = 1 and then Text'Last in 0 .. Max_Template;

end Iour.Ffi.Fiber.Text;
