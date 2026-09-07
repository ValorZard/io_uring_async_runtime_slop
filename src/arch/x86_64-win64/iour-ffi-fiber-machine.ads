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
--  Read the SysV header for what the two papers behind this contribute.  In
--  one line each: the instructions are values rather than characters, so a
--  register and its offset are chosen by one expression and cannot
--  disagree (Rutter 1981); and the switch's obligation is stated as the
--  register-file exchange a typed assembly language would demand of it,
--  and proved (Crary 2003, and Morrisett, Crary and Glew's stack-based
--  TAL behind it).
--
--  The size of the location set is exactly why this is worth doing here.
--  Dropping xmm11 from a hand-written thirty-instruction save-and-restore
--  is an easy mistake and a nearly undebuggable one -- it corrupts only
--  fibers that were suspended inside vectorised code, which on a modern
--  compiler means inside memcpy.  Model_Switch's postcondition is
--  quantified over the whole location set, so a location the sequence
--  misses is a proof that fails.
------------------------------------------------------------------------------

package Iour.Ffi.Fiber.Machine with SPARK_Mode => On is

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

   --  One value per location, whatever its width: this model is about
   --  which location's contents end up where, not about their encoding.
   --  Width is a layout question and is settled by Disjoint above.
   type Word is mod 2 ** 64;

   type Frame is array (Location) of Word with Ghost;

   type State is record
      Live    : Frame;   --  the live locations, registers and TEB alike
      Out_Ctx : Frame;   --  memory at (%rcx)
      In_Ctx  : Frame;   --  memory at (%rdx)
      Rax     : Word;
   end record with Ghost;

   Resume_Address : constant Word := 16#5245_5355_4D45_0001# with Ghost;

   procedure Apply (S : in out State; I : Instruction)
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

   --  The theorem, identical in shape to the SysV one and quantified over
   --  a location set three times the size: the outgoing context ends up
   --  holding the entry value of every location, every restorable location
   --  ends up holding what the incoming context held, and the incoming
   --  context is untouched.
   procedure Model_Switch (S : in out State)
     with Ghost, Global => null, Always_Terminates,
       Post =>
         (for all L in Location =>
            S.Out_Ctx (L) =
              (if L = L_Rip then Resume_Address else S.Live'Old (L)))
         and then (for all L in Restorable => S.Live (L) = S.In_Ctx'Old (L))
         and then S.In_Ctx = S.In_Ctx'Old;

   ---------------------------------------------------------------------------
   --  5.  The text
   ---------------------------------------------------------------------------

   Nl    : constant String := "" & ASCII.LF;
   Sigil : constant String := "%%";

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
     "leaq 1f(" & Sigil & "rip), " & Sigil & "rax"          & Nl &
     "movq " & Sigil & "rax, 0(" & Sigil & "rcx)"           & Nl &
     "movq " & Sigil & "rsp, 8(" & Sigil & "rcx)"           & Nl &
     "movq " & Sigil & "rbp, 16(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "rbx, 24(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "r12, 32(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "r13, 40(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "r14, 48(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "r15, 56(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "rdi, 64(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "rsi, 72(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "gs:" & Teb_Stack_Base
            & ", " & Sigil & "rax"                          & Nl &
     "movq " & Sigil & "rax, 80(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "gs:" & Teb_Stack_Limit
            & ", " & Sigil & "rax"                          & Nl &
     "movq " & Sigil & "rax, 88(" & Sigil & "rcx)"          & Nl &
     "movq " & Sigil & "gs:" & Teb_Dealloc_Stack
            & ", " & Sigil & "rax"                          & Nl &
     "movq " & Sigil & "rax, 96(" & Sigil & "rcx)"          & Nl &
     "stmxcsr 104(" & Sigil & "rcx)"                        & Nl &
     "fnstcw 108(" & Sigil & "rcx)"                         & Nl &
     "movaps " & Sigil & "xmm6, 112(" & Sigil & "rcx)"      & Nl &
     "movaps " & Sigil & "xmm7, 128(" & Sigil & "rcx)"      & Nl &
     "movaps " & Sigil & "xmm8, 144(" & Sigil & "rcx)"      & Nl &
     "movaps " & Sigil & "xmm9, 160(" & Sigil & "rcx)"      & Nl &
     "movaps " & Sigil & "xmm10, 176(" & Sigil & "rcx)"     & Nl &
     "movaps " & Sigil & "xmm11, 192(" & Sigil & "rcx)"     & Nl &
     "movaps " & Sigil & "xmm12, 208(" & Sigil & "rcx)"     & Nl &
     "movaps " & Sigil & "xmm13, 224(" & Sigil & "rcx)"     & Nl &
     "movaps " & Sigil & "xmm14, 240(" & Sigil & "rcx)"     & Nl &
     "movaps " & Sigil & "xmm15, 256(" & Sigil & "rcx)"     & Nl &
     "movaps 256(" & Sigil & "rdx), " & Sigil & "xmm15"     & Nl &
     "movaps 240(" & Sigil & "rdx), " & Sigil & "xmm14"     & Nl &
     "movaps 224(" & Sigil & "rdx), " & Sigil & "xmm13"     & Nl &
     "movaps 208(" & Sigil & "rdx), " & Sigil & "xmm12"     & Nl &
     "movaps 192(" & Sigil & "rdx), " & Sigil & "xmm11"     & Nl &
     "movaps 176(" & Sigil & "rdx), " & Sigil & "xmm10"     & Nl &
     "movaps 160(" & Sigil & "rdx), " & Sigil & "xmm9"      & Nl &
     "movaps 144(" & Sigil & "rdx), " & Sigil & "xmm8"      & Nl &
     "movaps 128(" & Sigil & "rdx), " & Sigil & "xmm7"      & Nl &
     "movaps 112(" & Sigil & "rdx), " & Sigil & "xmm6"      & Nl &
     "fldcw 108(" & Sigil & "rdx)"                          & Nl &
     "ldmxcsr 104(" & Sigil & "rdx)"                        & Nl &
     "movq 96(" & Sigil & "rdx), " & Sigil & "rax"          & Nl &
     "movq " & Sigil & "rax, " & Sigil & "gs:"
            & Teb_Dealloc_Stack                             & Nl &
     "movq 88(" & Sigil & "rdx), " & Sigil & "rax"          & Nl &
     "movq " & Sigil & "rax, " & Sigil & "gs:"
            & Teb_Stack_Limit                               & Nl &
     "movq 80(" & Sigil & "rdx), " & Sigil & "rax"          & Nl &
     "movq " & Sigil & "rax, " & Sigil & "gs:"
            & Teb_Stack_Base                                & Nl &
     "movq 72(" & Sigil & "rdx), " & Sigil & "rsi"          & Nl &
     "movq 64(" & Sigil & "rdx), " & Sigil & "rdi"          & Nl &
     "movq 56(" & Sigil & "rdx), " & Sigil & "r15"          & Nl &
     "movq 48(" & Sigil & "rdx), " & Sigil & "r14"          & Nl &
     "movq 40(" & Sigil & "rdx), " & Sigil & "r13"          & Nl &
     "movq 32(" & Sigil & "rdx), " & Sigil & "r12"          & Nl &
     "movq 24(" & Sigil & "rdx), " & Sigil & "rbx"          & Nl &
     "movq 16(" & Sigil & "rdx), " & Sigil & "rbp"          & Nl &
     "movq 8(" & Sigil & "rdx), " & Sigil & "rsp"           & Nl &
     "jmpq *0(" & Sigil & "rdx)"                            & Nl &
     "1:"                                                   & Nl &
     "ret"                                                  & Nl;

   --  The trampoline a freshly primed context starts on.  Win64's first
   --  argument register is rcx, where SysV uses rdi; everything else about
   --  it is the same.
   Trampoline_Template : constant String :=
     "movq " & Sigil & "r13, " & Sigil & "rcx"              & Nl &
     "jmpq *" & Sigil & "r12"                               & Nl;

   Max_Line     : constant := 64;
   Max_Template : constant := 8192;

   procedure Check_Switch_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
     with Global => null, Always_Terminates,
          Pre  => Text'First = 1
                  and then Text'Last in 0 .. Max_Template,
          Post => (if Ok then At_Char = 0);

   procedure Check_Trampoline_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
     with Global => null, Always_Terminates,
          Pre  => Text'First = 1
                  and then Text'Last in 0 .. Max_Template,
          Post => (if Ok then At_Char = 0);

   function Emitted_Matches_Model return Boolean
     with Global => null;

   ---------------------------------------------------------------------------
   --  6.  The stack a fiber starts on
   ---------------------------------------------------------------------------

   --  Win64 has no red zone, but a function may write the thirty-two bytes
   --  above its return address to spill its four register arguments,
   --  without allocating them.  The entry point is entitled to that, so the
   --  first frame is placed low enough to leave it inside the mapping.  The
   --  SysV model reserves 128 bytes of red zone in the same place, and the
   --  arithmetic is otherwise identical.
   Entry_Reserve : constant := 32;

   subtype Page_Bytes is Natural range 4_096 .. 2 ** 20;
   subtype Stack_Bytes is Natural range 0 .. 2 ** 28;

   function Round_Up_Pages (Bytes : Stack_Bytes; Page : Page_Bytes)
     return Natural
     with Global => null,
          Pre  => Bytes <= Stack_Bytes'Last - Page,
          Post => Round_Up_Pages'Result mod Page = 0
                  and then Round_Up_Pages'Result >= Bytes
                  and then Round_Up_Pages'Result < Bytes + Page;

   --  Where the dummy return address goes, as a byte offset from the base
   --  of the mapping: one guard page, then Usable bytes the fiber may
   --  touch, and the entry frame built down from the top of those.
   --
   --    mod 16 = 8       what a call leaves, which is the alignment the
   --                     entry point is entitled to assume;
   --    >= Guard         above the guard page, so priming never writes to
   --                     it;
   --    within the map   the shadow store above the frame is inside the
   --                     usable region.
   function Return_Slot_Offset (Guard : Page_Bytes; Usable : Natural)
     return Natural
     with Global => null,
          Pre  => Usable in 4 * Guard .. Stack_Bytes'Last
                  and then Guard <= Stack_Bytes'Last - Usable,
          Post => Return_Slot_Offset'Result mod 16 = 8
                  and then Return_Slot_Offset'Result >= Guard
                  and then Return_Slot_Offset'Result + 8 + Entry_Reserve
                             <= Guard + Usable;

end Iour.Ffi.Fiber.Machine;
