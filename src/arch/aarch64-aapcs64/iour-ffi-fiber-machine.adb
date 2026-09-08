------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Machine body, AArch64 AAPCS64.
--
--  Laid out to be read side by side with the two x86 bodies: the layout,
--  then the instructions, then what they mean, then what they look like,
--  and the two consumers walk the same snippets in the same order.  What
--  is different is that three of the five classes here need two
--  instructions because the location is not addressable -- the stack
--  pointer and the FPCR are reached through the scratch register, and the
--  resume address is computed into it.
------------------------------------------------------------------------------

package body Iour.Ffi.Fiber.Machine with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  Layout
   ---------------------------------------------------------------------------

   function Class_Of (L : Location) return Location_Class is
     (case L is
        when L_Pc                                 => Class_Pc,
        when L_Sp                                 => Class_Sp,
        when L_X19 | L_X20 | L_X21 | L_X22 | L_X23
           | L_X24 | L_X25 | L_X26 | L_X27 | L_X28
           | L_X29 | L_X30                        => Class_General,
        when L_Fpcr                               => Class_Fpcr,
        when L_D8 .. L_D15                        => Class_Vector);

   --  Written as a case so the parameter is read: every location here is
   --  one 64-bit word, but a function that ignored L would warn under
   --  -gnatwa.  The Win64 model, where the answer really does vary, has
   --  the same shape.
   function Size_Of (L : Location) return Positive is
     (case L is when others => 8);

   function Vec_Number (L : Location) return Natural is
     (First_Vec + Location'Pos (L) - Location'Pos (L_D8));

   function Offset_Of (L : Location) return Natural is
     (case L is
        when L_Pc   => Off_Pc,
        when L_Sp   => Off_Sp,
        when L_X19  => Off_X19,
        when L_X20  => Off_X20,
        when L_X21  => Off_X21,
        when L_X22  => Off_X22,
        when L_X23  => Off_X23,
        when L_X24  => Off_X24,
        when L_X25  => Off_X25,
        when L_X26  => Off_X26,
        when L_X27  => Off_X27,
        when L_X28  => Off_X28,
        when L_X29  => Off_X29,
        when L_X30  => Off_X30,
        when L_Fpcr => Off_Fpcr,
        when L_D8 .. L_D15 =>
          Off_D8 + Vec_Bytes * (Vec_Number (L) - First_Vec));

   --  Nothing to do: the postcondition is a fact about constants, and
   --  gnatprove has to establish it out of nothing.
   procedure Layout_Is_Disjoint is
   begin
      null;
   end Layout_Is_Disjoint;

   procedure Layout_Tiles_Context is
   begin
      null;
   end Layout_Tiles_Context;

   ---------------------------------------------------------------------------
   --  The instruction sequence
   ---------------------------------------------------------------------------

   --  N says how many of Ops are the snippet; Pad fills the rest and is
   --  never read, in either consumer.
   Pad_Op : constant Instruction := (Op => Op_Ret, L => L_Pc);

   --  Whether a location needs the scratch register to reach it.  The two
   --  consumers both branch on this, so it is named once.
   function Two_Step (L : Location) return Boolean is
     (Class_Of (L) in Class_Pc | Class_Sp | Class_Fpcr);

   function Save_Snippet (L : Location) return Snippet is
     (case Class_Of (L) is
        --  The outgoing context receives the address of the resume label,
        --  which is not read from any register.
        when Class_Pc =>
          (Ops => [(Op_Adr_Resume, L), (Op_Store_Scratch, L),
                   Pad_Op, Pad_Op],
           N   => 2),
        --  `str sp, [x0, #8]` does not encode: in that position register
        --  31 reads as the zero register, so the stack pointer has to be
        --  moved into a general register first.
        when Class_Sp =>
          (Ops => [(Op_Read_Sp, L), (Op_Store_Scratch, L), Pad_Op, Pad_Op],
           N   => 2),
        when Class_General =>
          (Ops => [(Op_Store_Reg, L), Pad_Op, Pad_Op, Pad_Op], N => 1),
        --  A system register is reached with mrs/msr, never with a load or
        --  a store, so this one goes through the scratch register too.
        when Class_Fpcr =>
          (Ops => [(Op_Read_Fpcr, L), (Op_Store_Scratch, L), Pad_Op, Pad_Op],
           N   => 2),
        when Class_Vector =>
          (Ops => [(Op_Store_Vec, L), Pad_Op, Pad_Op, Pad_Op], N => 1));

   function Load_Snippet (L : Restorable) return Snippet is
     (case Class_Of (L) is
        when Class_Sp =>
          (Ops => [(Op_Load_Scratch, L), (Op_Write_Sp, L), Pad_Op, Pad_Op],
           N   => 2),
        when Class_General =>
          (Ops => [(Op_Load_Reg, L), Pad_Op, Pad_Op, Pad_Op], N => 1),
        when Class_Fpcr =>
          (Ops => [(Op_Load_Scratch, L), (Op_Write_Fpcr, L), Pad_Op, Pad_Op],
           N   => 2),
        when Class_Vector =>
          (Ops => [(Op_Load_Vec, L), Pad_Op, Pad_Op, Pad_Op], N => 1),
        --  L_Pc is not in Restorable; the case must be complete.
        when Class_Pc =>
          (Ops => [(Op_Load_Reg, L), Pad_Op, Pad_Op, Pad_Op], N => 1));

   --  AArch64 has no branch through memory, so the tail loads the incoming
   --  context's resume address into the scratch register and branches to
   --  it.  Four instructions where both x86 targets need three.
   function Tail_Snippet return Snippet is
     ((Ops => [(Op_Load_Scratch, L_Pc),
               (Op_Br_Scratch, L_Pc),
               (Op_Resume_Label, L_Pc),
               (Op_Ret, L_Pc)],
       N => 4));

   ---------------------------------------------------------------------------
   --  What the sequence means
   ---------------------------------------------------------------------------

   procedure Apply (S : in out Fr.State; I : Instruction) is
   begin
      case I.Op is
         when Op_Adr_Resume =>
            S.Rax := Resume_Address;
         when Op_Read_Sp | Op_Read_Fpcr =>
            S.Rax := S.Live (I.L);
         when Op_Store_Scratch =>
            S.Out_Ctx (I.L) := S.Rax;
         when Op_Store_Reg | Op_Store_Vec =>
            S.Out_Ctx (I.L) := S.Live (I.L);
         when Op_Load_Scratch =>
            S.Rax := S.In_Ctx (I.L);
         when Op_Write_Sp | Op_Write_Fpcr =>
            S.Live (I.L) := S.Rax;
         when Op_Load_Reg | Op_Load_Vec =>
            S.Live (I.L) := S.In_Ctx (I.L);
         when Op_Br_Scratch | Op_Resume_Label | Op_Ret =>
            null;
      end case;
   end Apply;

   procedure Save_One (S : in out Fr.State; L : Location) is
      Sn : constant Snippet := Save_Snippet (L);
   begin
      if Two_Step (L) then
         Apply (S, Sn.Ops (1));
         Apply (S, Sn.Ops (2));
      else
         Apply (S, Sn.Ops (1));
      end if;
   end Save_One;

   procedure Load_One (S : in out Fr.State; L : Location) is
      Sn : constant Snippet := Load_Snippet (L);
   begin
      if Two_Step (L) then
         Apply (S, Sn.Ops (1));
         Apply (S, Sn.Ops (2));
      else
         Apply (S, Sn.Ops (1));
      end if;
   end Load_One;

   ---------------------------------------------------------------------------
   --  What the sequence looks like
   ---------------------------------------------------------------------------

   --  x19 through x30: three characters each, unlike the vector registers.
   subtype Reg_Text is String (1 .. 3);

   function Reg_Name (L : Location) return Reg_Text
     with Pre => Class_Of (L) = Class_General;

   function Reg_Name (L : Location) return Reg_Text is
     (case L is
        when L_X19  => "x19",
        when L_X20  => "x20",
        when L_X21  => "x21",
        when L_X22  => "x22",
        when L_X23  => "x23",
        when L_X24  => "x24",
        when L_X25  => "x25",
        when L_X26  => "x26",
        when L_X27  => "x27",
        when L_X28  => "x28",
        when L_X29  => "x29",
        when L_X30  => "x30",
        --  Excluded by the precondition; a case on Location must be
        --  complete.
        when others => "???");

   --  d8 and d9 are two characters, d10 upward are three, so this cannot
   --  have the fixed subtype the general registers do.
   --
   --  The bound is 2 .. 4 rather than the 2 .. 3 the register names
   --  actually occupy, because that is all Txt.Dec promises: its
   --  postcondition gives 1 .. 3 digits without relating the length to the
   --  magnitude, so nothing here can derive that a number below sixteen
   --  renders in two.  Claiming 2 .. 3 leaves a check that no prover can
   --  discharge; the loose bound is what is actually known, and all any
   --  caller needs is Txt.Max_Line.
   function Vec_Name (L : Location) return String
     with Pre  => Class_Of (L) = Class_Vector,
          Post => Vec_Name'Result'First = 1
                  and then Vec_Name'Result'Length in 2 .. 4;

   function Vec_Name (L : Location) return String is
     ("d" & Txt.Dec (Vec_Number (L)));

   --  The two base registers, from the AAPCS64 argument convention: From
   --  arrives in x0 and To in x1.
   Out_Base : constant String := "x0";
   In_Base  : constant String := "x1";

   --  The scratch register.  x16 is IP0, which AAPCS64 lets a linker veneer
   --  destroy, so no caller can expect it to survive a call.
   Scratch : constant String := "x16";

   --  One instruction's text.  Every displacement comes from Offset_Of and
   --  every register name from Reg_Name or Vec_Name, all applied to the
   --  instruction's own location -- so the register and the offset on a
   --  line are chosen by one expression and cannot be made to disagree.
   procedure Emit
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      I    : Instruction)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Txt.Max_Template
               and then Cur <= Text'Last + 1
               and then (case I.Op is
                           when Op_Store_Reg | Op_Load_Reg =>
                             Class_Of (I.L) = Class_General,
                           when Op_Store_Vec | Op_Load_Vec =>
                             Class_Of (I.L) = Class_Vector,
                           when Op_Read_Sp | Op_Write_Sp =>
                             Class_Of (I.L) = Class_Sp,
                           when Op_Read_Fpcr | Op_Write_Fpcr =>
                             Class_Of (I.L) = Class_Fpcr,
                           when others => True),
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   procedure Emit
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      I    : Instruction) is
   begin
      case I.Op is
         when Op_Adr_Resume =>
            Txt.Expect (Text, Cur, Ok, "adr " & Scratch & ", 1f");
         when Op_Read_Sp =>
            Txt.Expect (Text, Cur, Ok, "mov " & Scratch & ", sp");
         when Op_Read_Fpcr =>
            Txt.Expect (Text, Cur, Ok, "mrs " & Scratch & ", fpcr");
         when Op_Store_Scratch =>
            Txt.Expect (Text, Cur, Ok,
                    "str " & Scratch & ", [" & Out_Base & ", #"
                    & Txt.Dec (Offset_Of (I.L)) & "]");
         when Op_Store_Reg =>
            Txt.Expect (Text, Cur, Ok,
                    "str " & Reg_Name (I.L) & ", [" & Out_Base & ", #"
                    & Txt.Dec (Offset_Of (I.L)) & "]");
         when Op_Store_Vec =>
            Txt.Expect (Text, Cur, Ok,
                    "str " & Vec_Name (I.L) & ", [" & Out_Base & ", #"
                    & Txt.Dec (Offset_Of (I.L)) & "]");
         when Op_Load_Scratch =>
            Txt.Expect (Text, Cur, Ok,
                    "ldr " & Scratch & ", [" & In_Base & ", #"
                    & Txt.Dec (Offset_Of (I.L)) & "]");
         when Op_Write_Sp =>
            Txt.Expect (Text, Cur, Ok, "mov sp, " & Scratch);
         when Op_Write_Fpcr =>
            Txt.Expect (Text, Cur, Ok, "msr fpcr, " & Scratch);
         when Op_Load_Reg =>
            Txt.Expect (Text, Cur, Ok,
                    "ldr " & Reg_Name (I.L) & ", [" & In_Base & ", #"
                    & Txt.Dec (Offset_Of (I.L)) & "]");
         when Op_Load_Vec =>
            Txt.Expect (Text, Cur, Ok,
                    "ldr " & Vec_Name (I.L) & ", [" & In_Base & ", #"
                    & Txt.Dec (Offset_Of (I.L)) & "]");
         when Op_Br_Scratch =>
            Txt.Expect (Text, Cur, Ok, "br " & Scratch);
         when Op_Resume_Label =>
            Txt.Expect (Text, Cur, Ok, "1:");
         when Op_Ret =>
            Txt.Expect (Text, Cur, Ok, "ret");
      end case;
      Txt.Expect (Text, Cur, Ok, Txt.Nl);
   end Emit;

   procedure Emit_Save
     (Text : String; Cur : in out Positive; Ok : in out Boolean;
      L : Location)
   is
      Sn : constant Snippet := Save_Snippet (L);
   begin
      if Two_Step (L) then
         Emit (Text, Cur, Ok, Sn.Ops (1));
         Emit (Text, Cur, Ok, Sn.Ops (2));
      else
         Emit (Text, Cur, Ok, Sn.Ops (1));
      end if;
   end Emit_Save;

   procedure Emit_Load
     (Text : String; Cur : in out Positive; Ok : in out Boolean;
      L : Location)
   is
      Sn : constant Snippet := Load_Snippet (L);
   begin
      if Two_Step (L) then
         Emit (Text, Cur, Ok, Sn.Ops (1));
         Emit (Text, Cur, Ok, Sn.Ops (2));
      else
         Emit (Text, Cur, Ok, Sn.Ops (1));
      end if;
   end Emit_Load;

   procedure Emit_Tail
     (Text : String; Cur : in out Positive; Ok : in out Boolean)
   is
      Sn : constant Snippet := Tail_Snippet;
   begin
      Emit (Text, Cur, Ok, Sn.Ops (1));
      Emit (Text, Cur, Ok, Sn.Ops (2));
      Emit (Text, Cur, Ok, Sn.Ops (3));
      Emit (Text, Cur, Ok, Sn.Ops (4));
   end Emit_Tail;

   ---------------------------------------------------------------------------
   --  The trampoline, and both checks
   ---------------------------------------------------------------------------

   procedure Check_Trampoline_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
   is
      Cur : Positive := 1;
   begin
      Ok := True;
      Txt.Expect (Text, Cur, Ok, "mov x0, x20");
      Txt.Expect (Text, Cur, Ok, Txt.Nl);
      Txt.Expect (Text, Cur, Ok, "br x19");
      Txt.Expect (Text, Cur, Ok, Txt.Nl);
      Ok := Ok and then Txt.Consumed_All (Text, Cur);
      At_Char := (if Ok then 0 else Cur);
   end Check_Trampoline_Text;

   function Emitted_Matches_Model return Boolean is
      Switch_Ok : Boolean;
      Tramp_Ok  : Boolean;
      Ignored   : Natural;
   begin
      --  Provably dead: both templates are static and well within the
      --  bound.  It is here because it is what discharges the two
      --  preconditions below.
      pragma Warnings (Off, "range test optimized away");
      if Switch_Template'First /= 1
        or else Switch_Template'Last not in 0 .. Txt.Max_Template
        or else Trampoline_Template'First /= 1
        or else Trampoline_Template'Last not in 0 .. Txt.Max_Template
      then
         return False;
      end if;
      pragma Warnings (On, "range test optimized away");

      Check_Switch_Text (Switch_Template, Switch_Ok, Ignored);
      Check_Trampoline_Text (Trampoline_Template, Tramp_Ok, Ignored);
      return Switch_Ok and then Tramp_Ok;
   end Emitted_Matches_Model;

end Iour.Ffi.Fiber.Machine;
