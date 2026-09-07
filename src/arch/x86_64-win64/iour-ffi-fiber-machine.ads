------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Machine -- the context switch as a typed object, x86-64
--  Windows.
--
--  The same package as the SysV one next door, against the same idea, and
--  bigger for the reason the Win64 switch is bigger: this ABI makes rdi and
--  rsi callee-saved, makes xmm6 through xmm15 callee-saved, and keeps the
--  running thread's stack bounds in its TEB where the compiler's stack
--  probes and the unwinder go looking for them.  Twenty-five locations
--  rather than eight, in four sizes rather than one.
--
--  Read the SysV header for what the two papers behind this contribute and
--  for what is proved against what is checked.  In one line each: the
--  instructions are values rather than characters, so a register and its
--  offset are chosen by one expression and cannot disagree (Rutter 1981);
--  and the switch's obligation is stated as the register-file exchange a
--  typed assembly language would demand of it, and proved (Crary 2003, and
--  Morrisett, Crary and Glew's stack-based TAL behind it).
--
--  Everything a switch has in common with every other switch is in the
--  portable half -- Iour.Ffi.Fiber.Frames, .Target, .Text and .Layout --
--  and instantiating Iour.Ffi.Fiber.Target with what is here is what
--  obliges this target to be right.
--
--  The size of the location set is exactly why this is worth doing here.
--  Dropping xmm11 from a hand-written thirty-instruction save-and-restore
--  is an easy mistake and a nearly undebuggable one -- it corrupts only
--  fibers that were suspended inside vectorised code, which on a modern
--  compiler means inside memcpy.  Model_Switch's postcondition is
--  quantified over the whole location set, so a location the sequence
--  misses is a proof that fails.
------------------------------------------------------------------------------

with Iour.Ffi.Fiber.Frames;
with Iour.Ffi.Fiber.Target;
with Iour.Ffi.Fiber.Text;

package Iour.Ffi.Fiber.Machine with SPARK_Mode => On is

   package Txt renames Iour.Ffi.Fiber.Text;

   ---------------------------------------------------------------------------
   --  1.  The register file type
   ---------------------------------------------------------------------------

   --  Every machine location a Win64 context switch is responsible for, in
   --  ascending offset order, which is also the order the switch saves them
   --  in.  L_Rip is saved -- as the address of the resume label -- and
   --  never restored into a register: the incoming context's copy is the
   --  jump that ends the sequence.
   type Location is
     (L_Rip, L_Rsp, L_Rbp, L_Rbx, L_R12, L_R13, L_R14, L_R15,
      L_Rdi, L_Rsi,
      L_Stack_Base, L_Stack_Limit, L_Dealloc_Stack,
      L_Mxcsr, L_Fpu_Cw,
      L_Xmm6, L_Xmm7, L_Xmm8, L_Xmm9, L_Xmm10,
      L_Xmm11, L_Xmm12, L_Xmm13, L_Xmm14, L_Xmm15);

   subtype Restorable is Location range L_Rsp .. L_Xmm15;

   package Fr is new Iour.Ffi.Fiber.Frames (Location);

   --  A generic instance's operations are not directly visible, and both
   --  the contracts below and the Target instantiation need equality.
   use type Fr.Frame;
   use type Fr.Word;
   use type Fr.State;

   --  What kind of machine location it is, which decides both the
   --  instruction that moves it and how wide its slot is.
   type Location_Class is
     (Class_General,   --  a 64-bit integer register
      Class_Teb,       --  a field of the thread environment block, at gs:
      Class_Mxcsr,     --  the SSE control and status word
      Class_Fpu_Cw,    --  the x87 control word
      Class_Xmm);      --  a 128-bit vector register

   function Class_Of (L : Location) return Location_Class with Global => null;

   ---------------------------------------------------------------------------
   --  2.  Layout
   ---------------------------------------------------------------------------

   --  The single source of truth for the context record's layout: the
   --  representation clause in the parent body uses these named numbers,
   --  and so does every displacement in the emitted instructions.
   Off_Rip           : constant := 0;
   Off_Rsp           : constant := 8;
   Off_Rbp           : constant := 16;
   Off_Rbx           : constant := 24;
   Off_R12           : constant := 32;
   Off_R13           : constant := 40;
   Off_R14           : constant := 48;
   Off_R15           : constant := 56;
   Off_Rdi           : constant := 64;
   Off_Rsi           : constant := 72;
   Off_Stack_Base    : constant := 80;
   Off_Stack_Limit   : constant := 88;
   Off_Dealloc_Stack : constant := 96;
   Off_Mxcsr         : constant := 104;
   Off_Fpu_Cw        : constant := 108;
   Off_Pad           : constant := 110;
   Off_Xmm           : constant := 112;

   --  Ten vector registers of sixteen bytes, xmm6 through xmm15.
   First_Xmm : constant := 6;
   Last_Xmm  : constant := 15;
   Xmm_Bytes : constant := 16;

   Context_Bytes : constant := 272;

   function Size_Of (L : Location) return Positive
     with Global => null,
          Post => Size_Of'Result in 2 | 4 | 8 | 16;

   function Offset_Of (L : Location) return Natural
     with Global => null,
          Post => Offset_Of'Result + Size_Of (L) <= Context_Bytes
                  and then Offset_Of'Result mod Size_Of (L) = 0;

   --  Two locations never share a byte.  Proved for every pair by the
   --  lemma below.
   function Disjoint (A, B : Location) return Boolean is
     (Offset_Of (A) + Size_Of (A) <= Offset_Of (B)
      or else Offset_Of (B) + Size_Of (B) <= Offset_Of (A))
     with Ghost, Global => null;

   --  The layout theorem, as a lemma: a ghost procedure with an empty body
   --  whose postcondition gnatprove has to establish out of nothing.  A
   --  library-level pragma Assert calling Offset_Of would be rejected by
   --  the compiler under SPARK RM 7.7(3), even though gnatprove accepts it.
   --
   --  Over twenty-five locations in four widths this is the check that
   --  would notice a vector slot laid on top of the control words -- the
   --  two bytes at Off_Pad are deliberately in no location's range, and are
   --  what pads the x87 control word out to the vector registers'
   --  sixteen-byte alignment.
   procedure Layout_Is_Disjoint
     with Ghost, Global => null, Always_Terminates,
          Post => (for all A in Location =>
                     (for all B in Location =>
                        (if A /= B then Disjoint (A, B))))
                  and then Off_Fpu_Cw + 2 = Off_Pad
                  and then Off_Pad + 2 = Off_Xmm;

   --  Bytes between the x87 control word and the first vector register:
   --  what carries Fpu_Cw up to the sixteen-byte alignment movaps needs.
   Pad_Bytes : constant := Off_Xmm - Off_Pad;

   --  Disjointness says no two locations overlap.  It does not say they
   --  cover the context, and that omission is not academic: with only the
   --  lemma above, deleting a register from the middle of Location --
   --  together with its offset, its two template lines and its field of the
   --  record -- compiles, proves clean and passes the start-up check, while
   --  the switch silently stops preserving it.  That was measured, on the
   --  SysV side's r14, before this lemma existed.  Context'Size does not
   --  catch it either, because removing a middle field leaves a hole and
   --  the record's size is unchanged.
   --
   --  So the offsets are required to be a *chain*: the first at zero, each
   --  one starting where its predecessor ended -- plus the padding, at the
   --  one place there is any -- and the last ending exactly at
   --  Context_Bytes.  That is strictly stronger than disjointness, and it
   --  is linear rather than quadratic in the number of locations, which
   --  with twenty-five of them is worth having.
   procedure Layout_Tiles_Context
     with Ghost, Global => null, Always_Terminates,
          Post => Offset_Of (Location'First) = 0
                  and then
                    (for all L in Location =>
                       (if L /= Location'First then
                          Offset_Of (L) =
                            Offset_Of (Location'Pred (L))
                            + Size_Of (Location'Pred (L))
                            + (if L = L_Xmm6 then Pad_Bytes else 0)))
                  and then Offset_Of (Location'Last)
                           + Size_Of (Location'Last) = Context_Bytes;

   --  Which vector register L is, for the instruction that moves it.
   function Xmm_Number (L : Location) return Natural
     with Global => null,
          Pre  => Class_Of (L) = Class_Xmm,
          Post => Xmm_Number'Result in First_Xmm .. Last_Xmm;

   ---------------------------------------------------------------------------
   --  3.  The instruction sequence, as data
   ---------------------------------------------------------------------------

   --  Four kinds of location need four pairs of move instructions, and the
   --  TEB fields need two instructions each way because there is no
   --  memory-to-memory move: they go through rax, which Win64 makes
   --  caller-saved and the switch therefore owes nobody.
   type Opcode is
     (Op_Lea_Resume,    --  leaq 1f(%rip), %rax
      Op_Store_Rax,     --  movq %rax, off(%rcx)
      Op_Store_Reg,     --  movq %reg, off(%rcx)
      Op_Read_Teb,      --  movq %gs:teb, %rax
      Op_Write_Teb,     --  movq %rax, %gs:teb
      Op_Load_Rax,      --  movq off(%rdx), %rax
      Op_Load_Reg,      --  movq off(%rdx), %reg
      Op_Store_Mxcsr,   --  stmxcsr off(%rcx)
      Op_Load_Mxcsr,    --  ldmxcsr off(%rdx)
      Op_Store_Fpu_Cw,  --  fnstcw off(%rcx)
      Op_Load_Fpu_Cw,   --  fldcw off(%rdx)
      Op_Store_Xmm,     --  movaps %xmmN, off(%rcx)
      Op_Load_Xmm,      --  movaps off(%rdx), %xmmN
      Op_Jump_Ctx,      --  jmpq *off(%rdx)
      Op_Resume_Label,  --  1:
      Op_Ret);          --  ret

   type Instruction is record
      Op : Opcode;
      L  : Location;
   end record;

   Max_Ops : constant := 3;
   subtype Op_Index is Positive range 1 .. Max_Ops;
   type Op_Array is array (Op_Index) of Instruction;

   type Snippet is record
      Ops : Op_Array;
      N   : Natural;
   end record
     with Predicate => Snippet.N in 1 .. Max_Ops;

   function Save_Snippet (L : Location) return Snippet with Global => null;

   function Load_Snippet (L : Restorable) return Snippet with Global => null;

   function Tail_Snippet return Snippet with Global => null;

   ---------------------------------------------------------------------------
   --  4.  The abstract machine, and what the sequence means on it
   ---------------------------------------------------------------------------

   --  The model is about which location's contents end up where, not about
   --  their encoding: width is a layout question and is settled by the
   --  disjointness lemma above.  Fr.Frame is one value per location
   --  whatever its width.
   --
   --  Resume_Address is not Ghost: it is the actual for a generic formal
   --  object, and a ghost entity may not be passed to a non-ghost formal.
   --  A constant emits nothing either way.
   Resume_Address : constant Fr.Word := 16#5245_5355_4D45_0001#;

   procedure Apply (S : in out Fr.State; I : Instruction)
     with Ghost, Global => null, Always_Terminates,
       Post =>
         (case I.Op is
            when Op_Lea_Resume =>
              S = (S'Old with delta Rax => Resume_Address),
            when Op_Read_Teb =>
              S = (S'Old with delta Rax => S'Old.Live (I.L)),
            when Op_Load_Rax =>
              S = (S'Old with delta Rax => S'Old.In_Ctx (I.L)),
            when Op_Store_Rax =>
              S = (S'Old with delta
                     Out_Ctx => (S'Old.Out_Ctx with delta I.L => S'Old.Rax)),
            when Op_Store_Reg | Op_Store_Mxcsr | Op_Store_Fpu_Cw
               | Op_Store_Xmm =>
              S = (S'Old with delta
                     Out_Ctx =>
                       (S'Old.Out_Ctx with delta I.L => S'Old.Live (I.L))),
            when Op_Write_Teb =>
              S = (S'Old with delta
                     Live => (S'Old.Live with delta I.L => S'Old.Rax)),
            when Op_Load_Reg | Op_Load_Mxcsr | Op_Load_Fpu_Cw | Op_Load_Xmm =>
              S = (S'Old with delta
                     Live =>
                       (S'Old.Live with delta I.L => S'Old.In_Ctx (I.L))),
            when Op_Jump_Ctx | Op_Resume_Label | Op_Ret => S = S'Old);

   --  Saving one location leaves every other slot of the outgoing context,
   --  and the whole of the live and incoming frames, exactly as they were.
   --  Two locations sharing a slot would make this false for the second.
   --
   --  These two are what Iour.Ffi.Fiber.Target's formals bind to, so their
   --  postconditions are this target's side of the interface.
   procedure Save_One (S : in out Fr.State; L : Location)
     with Ghost, Global => null, Always_Terminates,
       Post => S.Live = S.Live'Old
               and then S.In_Ctx = S.In_Ctx'Old
               and then S.Out_Ctx =
                 (S.Out_Ctx'Old with delta
                    L => (if L = L_Rip then Resume_Address
                          else S.Live'Old (L)));

   procedure Load_One (S : in out Fr.State; L : Location)
     with Ghost, Global => null, Always_Terminates,
       Pre  => L in Restorable,
       Post => S.Out_Ctx = S.Out_Ctx'Old
               and then S.In_Ctx = S.In_Ctx'Old
               and then S.Live =
                 (S.Live'Old with delta L => S.In_Ctx'Old (L));

   ---------------------------------------------------------------------------
   --  5.  What the sequence looks like
   ---------------------------------------------------------------------------

   --  The text of one location's save, one location's restore, and the
   --  tail.  The other half of this target's side of the interface.
   procedure Emit_Save
     (Text : String; Cur : in out Positive; Ok : in out Boolean;
      L : Location)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Txt.Max_Template
               and then Cur <= Text'Last + 1,
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   procedure Emit_Load
     (Text : String; Cur : in out Positive; Ok : in out Boolean;
      L : Location)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Txt.Max_Template
               and then Cur <= Text'Last + 1
               and then L in Restorable,
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   procedure Emit_Tail
     (Text : String; Cur : in out Positive; Ok : in out Boolean)
     with Global => null, Always_Terminates,
       Pre  => Text'First = 1
               and then Text'Last in 0 .. Txt.Max_Template
               and then Cur <= Text'Last + 1,
       Post => Cur >= Cur'Old and then Cur <= Text'Last + 1;

   ---------------------------------------------------------------------------
   --  6.  The interface, instantiated
   ---------------------------------------------------------------------------

   --  This is where this target's obligations are discharged.  Model_Switch
   --  and Check_Switch_Text come out of it; if any of the six actuals above
   --  were wrong, the failure would be reported here.  With twenty-five
   --  locations in four widths that is worth more here than next door.
   package Switch is new Iour.Ffi.Fiber.Target
     (Location       => Location,
      F              => Fr,
      Resume_Address => Resume_Address,
      Save_One       => Save_One,
      Load_One       => Load_One,
      Emit_Save      => Emit_Save,
      Emit_Load      => Emit_Load,
      Emit_Tail      => Emit_Tail);

   procedure Check_Switch_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
     renames Switch.Check_Switch_Text;

   ---------------------------------------------------------------------------
   --  7.  The text GCC assembles
   ---------------------------------------------------------------------------

   --  NT_TIB.StackBase, NT_TIB.StackLimit and TEB.DeallocationStack, at the
   --  offsets Windows has used on x86-64 since the platform existed.  They
   --  are reached through gs, which is where the TEB lives in 64-bit user
   --  mode.  Textual because that is how they appear in an instruction;
   --  they index nothing this package computes with.
   Teb_Stack_Base    : constant String := "0x08";
   Teb_Stack_Limit   : constant String := "0x10";
   Teb_Dealloc_Stack : constant String := "0x1478";

   --  The template GCC assembles.  Check_Switch_Text proves it is the
   --  rendering of the instruction sequence above, character for
   --  character; it is written out only because GNAT requires an Asm
   --  template to be a static string.
   Switch_Template : constant String :=
     "leaq 1f(" & Txt.Sigil & "rip), " & Txt.Sigil & "rax"          & Txt.Nl &
     "movq " & Txt.Sigil & "rax, 0(" & Txt.Sigil & "rcx)"           & Txt.Nl &
     "movq " & Txt.Sigil & "rsp, 8(" & Txt.Sigil & "rcx)"           & Txt.Nl &
     "movq " & Txt.Sigil & "rbp, 16(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "rbx, 24(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "r12, 32(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "r13, 40(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "r14, 48(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "r15, 56(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "rdi, 64(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "rsi, 72(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "gs:" & Teb_Stack_Base
            & ", " & Txt.Sigil & "rax"                          & Txt.Nl &
     "movq " & Txt.Sigil & "rax, 80(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "gs:" & Teb_Stack_Limit
            & ", " & Txt.Sigil & "rax"                          & Txt.Nl &
     "movq " & Txt.Sigil & "rax, 88(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "movq " & Txt.Sigil & "gs:" & Teb_Dealloc_Stack
            & ", " & Txt.Sigil & "rax"                          & Txt.Nl &
     "movq " & Txt.Sigil & "rax, 96(" & Txt.Sigil & "rcx)"          & Txt.Nl &
     "stmxcsr 104(" & Txt.Sigil & "rcx)"                        & Txt.Nl &
     "fnstcw 108(" & Txt.Sigil & "rcx)"                         & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm6, 112(" & Txt.Sigil & "rcx)"      & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm7, 128(" & Txt.Sigil & "rcx)"      & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm8, 144(" & Txt.Sigil & "rcx)"      & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm9, 160(" & Txt.Sigil & "rcx)"      & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm10, 176(" & Txt.Sigil & "rcx)"     & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm11, 192(" & Txt.Sigil & "rcx)"     & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm12, 208(" & Txt.Sigil & "rcx)"     & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm13, 224(" & Txt.Sigil & "rcx)"     & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm14, 240(" & Txt.Sigil & "rcx)"     & Txt.Nl &
     "movaps " & Txt.Sigil & "xmm15, 256(" & Txt.Sigil & "rcx)"     & Txt.Nl &
     "movaps 256(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm15"     & Txt.Nl &
     "movaps 240(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm14"     & Txt.Nl &
     "movaps 224(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm13"     & Txt.Nl &
     "movaps 208(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm12"     & Txt.Nl &
     "movaps 192(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm11"     & Txt.Nl &
     "movaps 176(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm10"     & Txt.Nl &
     "movaps 160(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm9"      & Txt.Nl &
     "movaps 144(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm8"      & Txt.Nl &
     "movaps 128(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm7"      & Txt.Nl &
     "movaps 112(" & Txt.Sigil & "rdx), " & Txt.Sigil & "xmm6"      & Txt.Nl &
     "fldcw 108(" & Txt.Sigil & "rdx)"                          & Txt.Nl &
     "ldmxcsr 104(" & Txt.Sigil & "rdx)"                        & Txt.Nl &
     "movq 96(" & Txt.Sigil & "rdx), " & Txt.Sigil & "rax"          & Txt.Nl &
     "movq " & Txt.Sigil & "rax, " & Txt.Sigil & "gs:"
            & Teb_Dealloc_Stack                             & Txt.Nl &
     "movq 88(" & Txt.Sigil & "rdx), " & Txt.Sigil & "rax"          & Txt.Nl &
     "movq " & Txt.Sigil & "rax, " & Txt.Sigil & "gs:"
            & Teb_Stack_Limit                               & Txt.Nl &
     "movq 80(" & Txt.Sigil & "rdx), " & Txt.Sigil & "rax"          & Txt.Nl &
     "movq " & Txt.Sigil & "rax, " & Txt.Sigil & "gs:"
            & Teb_Stack_Base                                & Txt.Nl &
     "movq 72(" & Txt.Sigil & "rdx), " & Txt.Sigil & "rsi"          & Txt.Nl &
     "movq 64(" & Txt.Sigil & "rdx), " & Txt.Sigil & "rdi"          & Txt.Nl &
     "movq 56(" & Txt.Sigil & "rdx), " & Txt.Sigil & "r15"          & Txt.Nl &
     "movq 48(" & Txt.Sigil & "rdx), " & Txt.Sigil & "r14"          & Txt.Nl &
     "movq 40(" & Txt.Sigil & "rdx), " & Txt.Sigil & "r13"          & Txt.Nl &
     "movq 32(" & Txt.Sigil & "rdx), " & Txt.Sigil & "r12"          & Txt.Nl &
     "movq 24(" & Txt.Sigil & "rdx), " & Txt.Sigil & "rbx"          & Txt.Nl &
     "movq 16(" & Txt.Sigil & "rdx), " & Txt.Sigil & "rbp"          & Txt.Nl &
     "movq 8(" & Txt.Sigil & "rdx), " & Txt.Sigil & "rsp"           & Txt.Nl &
     "jmpq *0(" & Txt.Sigil & "rdx)"                            & Txt.Nl &
     "1:"                                                   & Txt.Nl &
     "ret"                                                  & Txt.Nl;

   --  The trampoline a freshly primed context starts on.  Win64's first
   --  argument register is rcx, where SysV uses rdi; everything else about
   --  it is the same.
   Trampoline_Template : constant String :=
     "movq " & Txt.Sigil & "r13, " & Txt.Sigil & "rcx"              & Txt.Nl &
     "jmpq *" & Txt.Sigil & "r12"                               & Txt.Nl;

   procedure Check_Trampoline_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
     with Global => null, Always_Terminates,
          Pre  => Text'First = 1
                  and then Text'Last in 0 .. Txt.Max_Template,
          Post => (if Ok then At_Char = 0);

   function Emitted_Matches_Model return Boolean
     with Global => null;

   ---------------------------------------------------------------------------
   --  8.  The stack a fiber starts on
   ---------------------------------------------------------------------------

   --  Win64 has no red zone, but a function may write the thirty-two bytes
   --  above its return address to spill its four register arguments,
   --  without allocating them.  The entry point is entitled to that, so the
   --  first frame is placed low enough to leave it inside the mapping.  The
   --  SysV model reserves 128 bytes of red zone in the same place, and the
   --  arithmetic is otherwise identical.
   Entry_Reserve : constant := 32;

end Iour.Ffi.Fiber.Machine;
