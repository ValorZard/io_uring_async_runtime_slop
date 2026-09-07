------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Machine body, x86-64 SysV.
--
--  Three things live here and they are deliberately adjacent, because the
--  whole argument is that they describe one object:
--
--    Save_Snippet / Load_Snippet / Tail_Snippet   the instructions
--    Apply / Save_One / Load_One                  what they mean
--    Emit_Save / Emit_Load / Emit_Tail            what they look like
--
--  The two consumers -- Iour.Ffi.Fiber.Target's Model_Switch and its text
--  walk -- drive both from the same location set in the same order, so a
--  location the meaning covers is a location the text covers.  Adding a
--  register to Location adds it to both, and the proof and the check both
--  fail until the template is updated to match, which is the point.
------------------------------------------------------------------------------

package body Iour.Ffi.Fiber.Machine with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  Layout
   ---------------------------------------------------------------------------

   function Size_Of (L : Location) return Positive is
     (case L is when others => 8);

   function Offset_Of (L : Location) return Natural is
     (case L is
        when L_Rip => Off_Rip,
        when L_Rsp => Off_Rsp,
        when L_Rbp => Off_Rbp,
        when L_Rbx => Off_Rbx,
        when L_R12 => Off_R12,
        when L_R13 => Off_R13,
        when L_R14 => Off_R14,
        when L_R15 => Off_R15);

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

   --  Op_Array is fixed length because SPARK has no heap and this package
   --  wants none; N says how many of its entries are the snippet, and Pad
   --  fills the rest.  Nothing ever reads past N, in either consumer.
   Pad : constant Instruction := (Op => Op_Ret, L => L_Rip);

   function Save_Snippet (L : Location) return Snippet is
     (if L = L_Rip then
        --  rip is not read from a register.  The outgoing context receives
        --  the address of the resume label, which is what the switch will
        --  jump back to when something switches to this context again.
        (Ops => [(Op_Lea_Resume, L_Rip), (Op_Store_Rax, L_Rip), Pad], N => 2)
      else
        (Ops => [(Op_Store_Reg, L), Pad, Pad], N => 1));

   function Load_Snippet (L : Restorable) return Snippet is
     ((Ops => [(Op_Load_Reg, L), Pad, Pad], N => 1));

   function Tail_Snippet return Snippet is
     ((Ops => [(Op_Jump_Ctx, L_Rip),
               (Op_Resume_Label, L_Rip),
               (Op_Ret, L_Rip)],
       N => 3));

   ---------------------------------------------------------------------------
   --  What the sequence means
   ---------------------------------------------------------------------------

   procedure Apply (S : in out Fr.State; I : Instruction) is
   begin
      case I.Op is
         when Op_Lea_Resume =>
            S.Rax := Resume_Address;
         when Op_Store_Rax =>
            S.Out_Ctx (I.L) := S.Rax;
         when Op_Store_Reg =>
            S.Out_Ctx (I.L) := S.Live (I.L);
         when Op_Load_Reg =>
            S.Live (I.L) := S.In_Ctx (I.L);
         when Op_Jump_Ctx | Op_Resume_Label | Op_Ret =>
            null;
      end case;
   end Apply;

   procedure Save_One (S : in out Fr.State; L : Location) is
      Sn : constant Snippet := Save_Snippet (L);
   begin
      if L = L_Rip then
         Apply (S, Sn.Ops (1));
         Apply (S, Sn.Ops (2));
      else
         Apply (S, Sn.Ops (1));
      end if;
   end Save_One;

   procedure Load_One (S : in out Fr.State; L : Location) is
      Sn : constant Snippet := Load_Snippet (L);
   begin
      Apply (S, Sn.Ops (1));
   end Load_One;

   ---------------------------------------------------------------------------
   --  What the sequence looks like
   ---------------------------------------------------------------------------

   subtype Reg_Text is String (1 .. 3);

   function Reg_Name (L : Location) return Reg_Text is
     (case L is
        when L_Rip => "rip",
        when L_Rsp => "rsp",
        when L_Rbp => "rbp",
        when L_Rbx => "rbx",
        when L_R12 => "r12",
        when L_R13 => "r13",
        when L_R14 => "r14",
        when L_R15 => "r15");

   --  The two base registers, from the SysV argument convention: From
   --  arrives in rdi and To in rsi.
   Out_Base : constant String := "rdi";
   In_Base  : constant String := "rsi";

   --  One instruction's text.  Every displacement comes from Offset_Of and
   --  every register name from Reg_Name, both applied to the instruction's
   --  own location -- so the register and the offset on a line are chosen
   --  by one expression and cannot be made to disagree.  This is the whole
   --  of what "the assembler is written in the high level language" buys.
   procedure Emit
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      I    : Instruction)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Txt.Max_Template
               and then Cur <= Text'Last + 1,
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   procedure Emit
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      I    : Instruction)
   is
      use Txt;
   begin
      case I.Op is
         when Op_Lea_Resume =>
            Expect (Text, Cur, Ok,
                    "leaq 1f(" & Sigil & "rip), " & Sigil & "rax");
         when Op_Store_Rax =>
            Expect (Text, Cur, Ok,
                    "movq " & Sigil & "rax, " & Dec (Offset_Of (I.L))
                    & "(" & Sigil & Out_Base & ")");
         when Op_Store_Reg =>
            Expect (Text, Cur, Ok,
                    "movq " & Sigil & Reg_Name (I.L) & ", "
                    & Dec (Offset_Of (I.L)) & "(" & Sigil & Out_Base & ")");
         when Op_Load_Reg =>
            Expect (Text, Cur, Ok,
                    "movq " & Dec (Offset_Of (I.L)) & "(" & Sigil & In_Base
                    & "), " & Sigil & Reg_Name (I.L));
         when Op_Jump_Ctx =>
            Expect (Text, Cur, Ok,
                    "jmpq *" & Dec (Offset_Of (I.L))
                    & "(" & Sigil & In_Base & ")");
         when Op_Resume_Label =>
            Expect (Text, Cur, Ok, "1:");
         when Op_Ret =>
            Expect (Text, Cur, Ok, "ret");
      end case;
   end Emit;

   --  Every instruction is followed by a newline, the last one included.
   procedure Emit_Snippet
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      Sn   : Snippet)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Txt.Max_Template
               and then Cur <= Text'Last + 1,
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   procedure Emit_Snippet
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      Sn   : Snippet) is
   begin
      for K in 1 .. Sn.N loop
         Emit (Text, Cur, Ok, Sn.Ops (K));
         Txt.Expect (Text, Cur, Ok, Txt.Nl);
         pragma Loop_Invariant (Cur <= Text'Last + 1);
         pragma Loop_Invariant (Cur >= Cur'Loop_Entry);
      end loop;
   end Emit_Snippet;

   procedure Emit_Save
     (Text : String; Cur : in out Positive; Ok : in out Boolean;
      L : Location) is
   begin
      Emit_Snippet (Text, Cur, Ok, Save_Snippet (L));
   end Emit_Save;

   procedure Emit_Load
     (Text : String; Cur : in out Positive; Ok : in out Boolean;
      L : Location) is
   begin
      Emit_Snippet (Text, Cur, Ok, Load_Snippet (L));
   end Emit_Load;

   procedure Emit_Tail
     (Text : String; Cur : in out Positive; Ok : in out Boolean) is
   begin
      Emit_Snippet (Text, Cur, Ok, Tail_Snippet);
   end Emit_Tail;

   ---------------------------------------------------------------------------
   --  The trampoline, and the check as a whole
   ---------------------------------------------------------------------------

   procedure Check_Trampoline_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
   is
      use Txt;
      Cur : Positive := 1;
   begin
      Ok := True;
      --  The argument moves from r13 to the first-argument register, and
      --  the entry point is jumped to from r12.  Prime puts them there.
      Expect (Text, Cur, Ok, "movq " & Sigil & "r13, " & Sigil & "rdi");
      Expect (Text, Cur, Ok, Nl);
      Expect (Text, Cur, Ok, "jmpq *" & Sigil & "r12");
      Expect (Text, Cur, Ok, Nl);
      if Ok and then not Consumed_All (Text, Cur) then
         Ok := False;
      end if;
      At_Char := (if Ok then 0 else Cur);
   end Check_Trampoline_Text;

   function Emitted_Matches_Model return Boolean is
      Switch_Ok, Tramp_Ok : Boolean;
      Ignored             : Natural;
   begin
      --  Both templates are static, so the compiler knows these hold and
      --  says so.  They stay: they are what discharges the checkers'
      --  preconditions, and they would not be dead if a template ever grew
      --  past the bound the walk is proved over.
      pragma Warnings (Off, "range test optimized away");
      pragma Warnings (Off, "value is known to be in range");
      if Switch_Template'First /= 1
        or else Switch_Template'Last not in 0 .. Txt.Max_Template
        or else Trampoline_Template'First /= 1
        or else Trampoline_Template'Last not in 0 .. Txt.Max_Template
      then
         return False;
      end if;
      pragma Warnings (On, "value is known to be in range");
      pragma Warnings (On, "range test optimized away");
      Check_Switch_Text (Switch_Template, Switch_Ok, Ignored);
      Check_Trampoline_Text (Trampoline_Template, Tramp_Ok, Ignored);
      return Switch_Ok and then Tramp_Ok;
   end Emitted_Matches_Model;

end Iour.Ffi.Fiber.Machine;
