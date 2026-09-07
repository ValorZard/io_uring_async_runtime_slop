------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Machine body, x86-64 Windows.
--
--  Laid out to be read side by side with the SysV body: the instructions,
--  then what they mean, then what they look like, and the two consumers
--  walk the same snippets in the same order.  What is different is that a
--  location here has a class, and the class decides both the instruction
--  pair that moves it and the width of its slot.
------------------------------------------------------------------------------

package body Iour.Ffi.Fiber.Machine with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  Layout
   ---------------------------------------------------------------------------

   function Class_Of (L : Location) return Location_Class is
     (case L is
        when L_Rip | L_Rsp | L_Rbp | L_Rbx | L_R12 | L_R13 | L_R14 | L_R15
           | L_Rdi | L_Rsi                        => Class_General,
        when L_Stack_Base | L_Stack_Limit
           | L_Dealloc_Stack                      => Class_Teb,
        when L_Mxcsr                              => Class_Mxcsr,
        when L_Fpu_Cw                             => Class_Fpu_Cw,
        when L_Xmm6 .. L_Xmm15                    => Class_Xmm);

   function Size_Of (L : Location) return Positive is
     (case Class_Of (L) is
        when Class_General | Class_Teb => 8,
        when Class_Mxcsr               => 4,
        when Class_Fpu_Cw              => 2,
        when Class_Xmm                 => Xmm_Bytes);

   function Xmm_Number (L : Location) return Natural is
     (First_Xmm + Location'Pos (L) - Location'Pos (L_Xmm6));

   function Offset_Of (L : Location) return Natural is
     (case L is
        when L_Rip           => Off_Rip,
        when L_Rsp           => Off_Rsp,
        when L_Rbp           => Off_Rbp,
        when L_Rbx           => Off_Rbx,
        when L_R12           => Off_R12,
        when L_R13           => Off_R13,
        when L_R14           => Off_R14,
        when L_R15           => Off_R15,
        when L_Rdi           => Off_Rdi,
        when L_Rsi           => Off_Rsi,
        when L_Stack_Base    => Off_Stack_Base,
        when L_Stack_Limit   => Off_Stack_Limit,
        when L_Dealloc_Stack => Off_Dealloc_Stack,
        when L_Mxcsr         => Off_Mxcsr,
        when L_Fpu_Cw        => Off_Fpu_Cw,
        when L_Xmm6 .. L_Xmm15 =>
          Off_Xmm + Xmm_Bytes * (Xmm_Number (L) - First_Xmm));

   --  Nothing to do: the postcondition is a fact about constants, and
   --  gnatprove has to establish it out of nothing.
   procedure Layout_Is_Disjoint is
   begin
      null;
   end Layout_Is_Disjoint;

   ---------------------------------------------------------------------------
   --  The instruction sequence
   ---------------------------------------------------------------------------

   --  N says how many of Ops are the snippet; Pad fills the rest and is
   --  never read, in either consumer.
   Pad_Op : constant Instruction := (Op => Op_Ret, L => L_Rip);

   function Save_Snippet (L : Location) return Snippet is
     (if L = L_Rip then
        --  rip is not read from a register: the outgoing context receives
        --  the address of the resume label.
        (Ops => [(Op_Lea_Resume, L_Rip), (Op_Store_Rax, L_Rip), Pad_Op],
         N   => 2)
      else
        (case Class_Of (L) is
           when Class_General =>
             (Ops => [(Op_Store_Reg, L), Pad_Op, Pad_Op], N => 1),
           --  gs-relative to memory is not a move the machine has, so the
           --  TEB fields go through rax.  Win64 makes rax caller-saved, so
           --  the switch owes nobody its value.
           when Class_Teb =>
             (Ops => [(Op_Read_Teb, L), (Op_Store_Rax, L), Pad_Op], N => 2),
           when Class_Mxcsr =>
             (Ops => [(Op_Store_Mxcsr, L), Pad_Op, Pad_Op], N => 1),
           when Class_Fpu_Cw =>
             (Ops => [(Op_Store_Fpu_Cw, L), Pad_Op, Pad_Op], N => 1),
           when Class_Xmm =>
             (Ops => [(Op_Store_Xmm, L), Pad_Op, Pad_Op], N => 1)));

   function Load_Snippet (L : Restorable) return Snippet is
     (case Class_Of (L) is
        when Class_General =>
          (Ops => [(Op_Load_Reg, L), Pad_Op, Pad_Op], N => 1),
        when Class_Teb =>
          (Ops => [(Op_Load_Rax, L), (Op_Write_Teb, L), Pad_Op], N => 2),
        when Class_Mxcsr =>
          (Ops => [(Op_Load_Mxcsr, L), Pad_Op, Pad_Op], N => 1),
        when Class_Fpu_Cw =>
          (Ops => [(Op_Load_Fpu_Cw, L), Pad_Op, Pad_Op], N => 1),
        when Class_Xmm =>
          (Ops => [(Op_Load_Xmm, L), Pad_Op, Pad_Op], N => 1));

   function Tail_Snippet return Snippet is
     ((Ops => [(Op_Jump_Ctx, L_Rip),
               (Op_Resume_Label, L_Rip),
               (Op_Ret, L_Rip)],
       N => 3));

   ---------------------------------------------------------------------------
   --  What the sequence means
   ---------------------------------------------------------------------------

   procedure Apply (S : in out State; I : Instruction) is
   begin
      case I.Op is
         when Op_Lea_Resume =>
            S.Rax := Resume_Address;
         when Op_Read_Teb =>
            S.Rax := S.Live (I.L);
         when Op_Load_Rax =>
            S.Rax := S.In_Ctx (I.L);
         when Op_Store_Rax =>
            S.Out_Ctx (I.L) := S.Rax;
         when Op_Store_Reg | Op_Store_Mxcsr | Op_Store_Fpu_Cw
            | Op_Store_Xmm =>
            S.Out_Ctx (I.L) := S.Live (I.L);
         when Op_Write_Teb =>
            S.Live (I.L) := S.Rax;
         when Op_Load_Reg | Op_Load_Mxcsr | Op_Load_Fpu_Cw | Op_Load_Xmm =>
            S.Live (I.L) := S.In_Ctx (I.L);
         when Op_Jump_Ctx | Op_Resume_Label | Op_Ret =>
            null;
      end case;
   end Apply;

   --  Saving one location leaves every other slot of the outgoing context,
   --  and the whole of the live and incoming frames, exactly as they were.
   --  Two locations sharing a slot would make this false for the second.
   procedure Save_One (S : in out State; L : Location)
     with Ghost, Global => null, Always_Terminates,
       Post => S.Live = S.Live'Old
               and then S.In_Ctx = S.In_Ctx'Old
               and then S.Out_Ctx =
                 (S.Out_Ctx'Old with delta
                    L => (if L = L_Rip then Resume_Address
                          else S.Live'Old (L)));

   procedure Save_One (S : in out State; L : Location) is
      Sn : constant Snippet := Save_Snippet (L);
   begin
      if L = L_Rip or else Class_Of (L) = Class_Teb then
         Apply (S, Sn.Ops (1));
         Apply (S, Sn.Ops (2));
      else
         Apply (S, Sn.Ops (1));
      end if;
   end Save_One;

   procedure Load_One (S : in out State; L : Restorable)
     with Ghost, Global => null, Always_Terminates,
       Post => S.Out_Ctx = S.Out_Ctx'Old
               and then S.In_Ctx = S.In_Ctx'Old
               and then S.Live =
                 (S.Live'Old with delta L => S.In_Ctx'Old (L));

   procedure Load_One (S : in out State; L : Restorable) is
      Sn : constant Snippet := Load_Snippet (L);
   begin
      if Class_Of (L) = Class_Teb then
         Apply (S, Sn.Ops (1));
         Apply (S, Sn.Ops (2));
      else
         Apply (S, Sn.Ops (1));
      end if;
   end Load_One;

   procedure Model_Switch (S : in out State) is
      Entry_Live : constant Frame := S.Live;
      Entry_In   : constant Frame := S.In_Ctx;
   begin
      --  Save phase: every location, in ascending offset order.  Coverage
      --  is by construction -- this is a loop over the type -- so there is
      --  no "did we remember xmm11" obligation to discharge, only the
      --  non-interference one Save_One carries.
      for L in Location loop
         Save_One (S, L);
         pragma Loop_Invariant (S.Live = Entry_Live);
         pragma Loop_Invariant (S.In_Ctx = Entry_In);
         pragma Loop_Invariant
           (for all M in Location'First .. L =>
              S.Out_Ctx (M) =
                (if M = L_Rip then Resume_Address else Entry_Live (M)));
      end loop;

      pragma Assert
        (for all M in Location =>
           S.Out_Ctx (M) =
             (if M = L_Rip then Resume_Address else Entry_Live (M)));

      --  Restore phase: every restorable location, in descending order.
      --  The order is the assembly's, and it is free: rdx holds the
      --  incoming context throughout and is not a location, so no load can
      --  destroy the base the next load needs.  That would not be true if
      --  the switch had been written with the context in rdi or rsi, which
      --  this ABI does make callee-saved.
      for L in reverse Restorable loop
         Load_One (S, L);
         pragma Loop_Invariant (S.In_Ctx = Entry_In);
         pragma Loop_Invariant
           (for all M in Location =>
              S.Out_Ctx (M) =
                (if M = L_Rip then Resume_Address else Entry_Live (M)));
         pragma Loop_Invariant
           (for all M in L .. Restorable'Last => S.Live (M) = Entry_In (M));
      end loop;
   end Model_Switch;

   ---------------------------------------------------------------------------
   --  What the sequence looks like
   ---------------------------------------------------------------------------

   subtype Reg_Text is String (1 .. 3);

   function Reg_Name (L : Location) return Reg_Text
     with Pre => Class_Of (L) = Class_General;

   function Reg_Name (L : Location) return Reg_Text is
     (case L is
        when L_Rip  => "rip",
        when L_Rsp  => "rsp",
        when L_Rbp  => "rbp",
        when L_Rbx  => "rbx",
        when L_R12  => "r12",
        when L_R13  => "r13",
        when L_R14  => "r14",
        when L_R15  => "r15",
        when L_Rdi  => "rdi",
        when L_Rsi  => "rsi",
        when others => "???");

   function Teb_Offset (L : Location) return String
     with Pre  => Class_Of (L) = Class_Teb,
          Post => Teb_Offset'Result'First = 1
                  and then Teb_Offset'Result'Length in 4 .. 6;

   function Teb_Offset (L : Location) return String is
     (case L is
        when L_Stack_Base    => Teb_Stack_Base,
        when L_Stack_Limit   => Teb_Stack_Limit,
        when L_Dealloc_Stack => Teb_Dealloc_Stack,
        when others          => "0x00");

   --  The two base registers, from the Win64 argument convention: From
   --  arrives in rcx and To in rdx.
   Out_Base : constant String := "rcx";
   In_Base  : constant String := "rdx";

   subtype Small is Natural range 0 .. 999;

   function Digit (N : Natural) return Character is
     (Character'Val (Character'Pos ('0') + N))
     with Pre => N <= 9;

   function Dec (N : Small) return String is
     (if N < 10 then [1 => Digit (N)]
      elsif N < 100 then [Digit (N / 10), Digit (N mod 10)]
      else [Digit (N / 100), Digit ((N / 10) mod 10), Digit (N mod 10)])
     with Post => Dec'Result'First = 1
                  and then Dec'Result'Length in 1 .. 3;

   --  Consume S from Text at Cur, or give up.  Once Ok is False nothing
   --  advances, so At_Char reports where the divergence began rather than
   --  where the walk happened to stop.
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

   procedure Expect
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      S    : String) is
   begin
      if not Ok or else S'Length = 0 then
         return;
      end if;
      if S'Length > Text'Last - Cur + 1 then
         Ok := False;
         return;
      end if;
      if Text (Cur .. Cur + S'Length - 1) /= S then
         Ok := False;
      else
         Cur := Cur + S'Length;
      end if;
   end Expect;

   --  One instruction's text.  Every displacement comes from Offset_Of and
   --  every register name from Reg_Name or Xmm_Number, all applied to the
   --  instruction's own location -- so the register and the offset on a
   --  line are chosen by one expression and cannot be made to disagree.
   procedure Emit
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      I    : Instruction)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Max_Template
               and then Cur <= Text'Last + 1
               and then (case I.Op is
                           when Op_Store_Reg | Op_Load_Reg =>
                             Class_Of (I.L) = Class_General,
                           when Op_Read_Teb | Op_Write_Teb =>
                             Class_Of (I.L) = Class_Teb,
                           when Op_Store_Xmm | Op_Load_Xmm =>
                             Class_Of (I.L) = Class_Xmm,
                           when others => True),
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   procedure Emit
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      I    : Instruction) is
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
         when Op_Read_Teb =>
            Expect (Text, Cur, Ok,
                    "movq " & Sigil & "gs:" & Teb_Offset (I.L)
                    & ", " & Sigil & "rax");
         when Op_Write_Teb =>
            Expect (Text, Cur, Ok,
                    "movq " & Sigil & "rax, " & Sigil & "gs:"
                    & Teb_Offset (I.L));
         when Op_Load_Rax =>
            Expect (Text, Cur, Ok,
                    "movq " & Dec (Offset_Of (I.L)) & "(" & Sigil & In_Base
                    & "), " & Sigil & "rax");
         when Op_Load_Reg =>
            Expect (Text, Cur, Ok,
                    "movq " & Dec (Offset_Of (I.L)) & "(" & Sigil & In_Base
                    & "), " & Sigil & Reg_Name (I.L));
         when Op_Store_Mxcsr =>
            Expect (Text, Cur, Ok,
                    "stmxcsr " & Dec (Offset_Of (I.L))
                    & "(" & Sigil & Out_Base & ")");
         when Op_Load_Mxcsr =>
            Expect (Text, Cur, Ok,
                    "ldmxcsr " & Dec (Offset_Of (I.L))
                    & "(" & Sigil & In_Base & ")");
         when Op_Store_Fpu_Cw =>
            Expect (Text, Cur, Ok,
                    "fnstcw " & Dec (Offset_Of (I.L))
                    & "(" & Sigil & Out_Base & ")");
         when Op_Load_Fpu_Cw =>
            Expect (Text, Cur, Ok,
                    "fldcw " & Dec (Offset_Of (I.L))
                    & "(" & Sigil & In_Base & ")");
         when Op_Store_Xmm =>
            Expect (Text, Cur, Ok,
                    "movaps " & Sigil & "xmm" & Dec (Xmm_Number (I.L))
                    & ", " & Dec (Offset_Of (I.L))
                    & "(" & Sigil & Out_Base & ")");
         when Op_Load_Xmm =>
            Expect (Text, Cur, Ok,
                    "movaps " & Dec (Offset_Of (I.L))
                    & "(" & Sigil & In_Base & "), " & Sigil & "xmm"
                    & Dec (Xmm_Number (I.L)));
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
   procedure Emit_Line
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      I    : Instruction)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Max_Template
               and then Cur <= Text'Last + 1
               and then (case I.Op is
                           when Op_Store_Reg | Op_Load_Reg =>
                             Class_Of (I.L) = Class_General,
                           when Op_Read_Teb | Op_Write_Teb =>
                             Class_Of (I.L) = Class_Teb,
                           when Op_Store_Xmm | Op_Load_Xmm =>
                             Class_Of (I.L) = Class_Xmm,
                           when others => True),
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   procedure Emit_Line
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      I    : Instruction) is
   begin
      Emit (Text, Cur, Ok, I);
      Expect (Text, Cur, Ok, Nl);
   end Emit_Line;

   procedure Emit_Snippet
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      Sn   : Snippet)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Max_Template
               and then Cur <= Text'Last + 1
               and then (for all K in Op_Index =>
                           (if K <= Sn.N then
                              (case Sn.Ops (K).Op is
                                 when Op_Store_Reg | Op_Load_Reg =>
                                   Class_Of (Sn.Ops (K).L) = Class_General,
                                 when Op_Read_Teb | Op_Write_Teb =>
                                   Class_Of (Sn.Ops (K).L) = Class_Teb,
                                 when Op_Store_Xmm | Op_Load_Xmm =>
                                   Class_Of (Sn.Ops (K).L) = Class_Xmm,
                                 when others => True))),
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   procedure Emit_Snippet
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      Sn   : Snippet) is
   begin
      for K in 1 .. Sn.N loop
         Emit_Line (Text, Cur, Ok, Sn.Ops (K));
         pragma Loop_Invariant (Cur <= Text'Last + 1);
         pragma Loop_Invariant (Cur >= Cur'Loop_Entry);
      end loop;
   end Emit_Snippet;

   procedure Check_Switch_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
   is
      Cur : Positive := 1;
   begin
      Ok := True;

      for L in Location loop
         Emit_Snippet (Text, Cur, Ok, Save_Snippet (L));
         pragma Loop_Invariant (Cur <= Text'Last + 1);
      end loop;

      for L in reverse Restorable loop
         Emit_Snippet (Text, Cur, Ok, Load_Snippet (L));
         pragma Loop_Invariant (Cur <= Text'Last + 1);
      end loop;

      Emit_Snippet (Text, Cur, Ok, Tail_Snippet);

      --  Text that merely begins with the right instructions is not the
      --  right instructions: anything trailing would be assembled too.
      if Ok and then Cur /= Text'Last + 1 then
         Ok := False;
      end if;
      At_Char := (if Ok then 0 else Cur);
   end Check_Switch_Text;

   procedure Check_Trampoline_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
   is
      Cur : Positive := 1;
   begin
      Ok := True;
      --  The argument moves from r13 to the first-argument register, which
      --  is rcx here, and the entry point is jumped to from r12.  Prime
      --  puts them there.
      Expect (Text, Cur, Ok, "movq " & Sigil & "r13, " & Sigil & "rcx");
      Expect (Text, Cur, Ok, Nl);
      Expect (Text, Cur, Ok, "jmpq *" & Sigil & "r12");
      Expect (Text, Cur, Ok, Nl);
      if Ok and then Cur /= Text'Last + 1 then
         Ok := False;
      end if;
      At_Char := (if Ok then 0 else Cur);
   end Check_Trampoline_Text;

   function Emitted_Matches_Model return Boolean is
      Switch_Ok, Tramp_Ok : Boolean;
      Ignored             : Natural;
   begin
      --  Both templates are static, so the compiler knows these hold and
      --  says so.  They stay: they are what discharges Check_*_Text's
      --  precondition, and they would not be dead if a template ever grew
      --  past the bound the checker is proved over.
      pragma Warnings (Off, "range test optimized away");
      pragma Warnings (Off, "value is known to be in range");
      if Switch_Template'First /= 1
        or else Switch_Template'Last not in 0 .. Max_Template
        or else Trampoline_Template'First /= 1
        or else Trampoline_Template'Last not in 0 .. Max_Template
      then
         return False;
      end if;
      pragma Warnings (On, "value is known to be in range");
      pragma Warnings (On, "range test optimized away");
      Check_Switch_Text (Switch_Template, Switch_Ok, Ignored);
      Check_Trampoline_Text (Trampoline_Template, Tramp_Ok, Ignored);
      return Switch_Ok and then Tramp_Ok;
   end Emitted_Matches_Model;

   ---------------------------------------------------------------------------
   --  The stack a fiber starts on
   ---------------------------------------------------------------------------

   function Round_Up_Pages (Bytes : Stack_Bytes; Page : Page_Bytes)
     return Natural
   is ((Bytes + Page - 1) / Page * Page);

   --  The assembly's `and $-16` on the top of the stack, as arithmetic.
   --  Modelling the mask rather than deriving 16-alignment from the page
   --  size keeps this in linear arithmetic, and keeps the model the same
   --  shape as the code.
   function Align_Down_16 (X : Natural) return Natural is (X - X mod 16)
     with Post => Align_Down_16'Result mod 16 = 0
                  and then Align_Down_16'Result <= X
                  and then X - Align_Down_16'Result < 16;

   function Return_Slot_Offset (Guard : Page_Bytes; Usable : Natural)
     return Natural
   is (Align_Down_16 (Guard + Usable) - Entry_Reserve - 8);

end Iour.Ffi.Fiber.Machine;
