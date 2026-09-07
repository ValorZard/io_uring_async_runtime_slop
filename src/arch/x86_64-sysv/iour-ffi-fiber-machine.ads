------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Machine -- the context switch as a typed object, x86-64
--  SysV.
--
--  The switch itself cannot be written in SPARK: it is inline Asm in a
--  naked subprogram, which is not analysable code at all.  What *can* be
--  written in SPARK is everything the assembly is supposed to be, and that
--  is what this package is.  It holds
--
--    * the set of machine locations the switch owns, as a type;
--    * their byte offsets in the context record, once, for both the
--      record's representation clause and the emitted instructions;
--    * the instruction sequence, as data;
--    * an abstract machine and the switch's meaning on it, with the
--      exchange theorem stated as a postcondition and proved;
--    * the exact assembler text, and a checker that the text is the
--      rendering of that same instruction sequence.
--
--  Two ideas, from two papers.
--
--  Rutter, "Using a high level language as a cross assembler" (SIGPLAN
--  Notices 16(2), 1981), is the reason the instructions are values here
--  rather than characters in a string.  An offset and a register name that
--  are chosen together by the same case statement cannot disagree; the
--  classic context-switch bug -- storing r14 at r13's offset -- is not
--  expressible.  Rutter emitted the target's code from the high level
--  language.  This emits it too, in the sense that the Asm template is a
--  constant of this package and Check_Switch_Text proves it character for
--  character equal to what the instruction sequence renders to.  Nothing
--  above trusts a string a human aligned by hand.
--
--  Crary, "Toward a Foundational Typed Assembly Language" (POPL 2003), and
--  behind it Morrisett, Crary and Glew's stack-based TAL, are the reason
--  there is a machine and a theorem rather than a syntactic checklist.
--  TAL's soundness argument is that a register file has a type and a
--  well-typed instruction sequence preserves it; the callee-saved
--  convention is expressed there as an abstract type a callee must hand
--  back unchanged.  A context switch is that obligation and nothing else,
--  so it is stated here as one: Model_Switch's postcondition says the
--  outgoing context ends up holding exactly the entry value of every
--  location, the live locations end up holding exactly the incoming
--  context's, and the incoming context is not disturbed.  A dropped
--  register, a duplicated offset, a load from the wrong slot and a save
--  that never happens all break it.
--
--  What is proved and what is checked, precisely, because the difference
--  matters:
--
--    proved by gnatprove   the layout is disjoint, aligned and inside the
--                          context record; the instruction sequence's
--                          meaning on the abstract machine is the exchange
--                          above; the stack arithmetic in Prime lands the
--                          entry frame inside the mapping, clear of the
--                          guard page, at the alignment the ABI wants;
--                          none of the rendering can go out of bounds.
--
--    checked at start-up   that the text GCC actually assembled is the
--                          rendering of that instruction sequence.  This
--                          is a run-time check because GNAT requires an
--                          Asm template to be a static string, so the
--                          text cannot be built by the loops that render
--                          it.  Iour.Fibers runs it before any shard is
--                          allowed to start, so a binary whose assembly
--                          and whose proof had drifted apart refuses to
--                          run rather than switching contexts wrongly.
--
--  The parent's body stays SPARK_Mode => Off, and is now nearly empty of
--  anything that was not forced to be there: the Asm calls, the addresses
--  of two slots, and one write through a computed address.
------------------------------------------------------------------------------

package Iour.Ffi.Fiber.Machine with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  1.  The register file type
   ---------------------------------------------------------------------------

   --  Every machine location a SysV context switch is responsible for.
   --  Declared in ascending offset order, which is also the order the
   --  switch saves them in; the enumeration is therefore the layout, the
   --  save schedule and the coverage argument at once.
   --
   --  L_Rip is in the set but is not a register the switch preserves: the
   --  outgoing context receives the address of the resume label, and the
   --  incoming context's copy is the jump target that ends the sequence.
   --  So it is saved and never restored, which is what Restorable says.
   type Location is
     (L_Rip, L_Rsp, L_Rbp, L_Rbx, L_R12, L_R13, L_R14, L_R15);

   subtype Restorable is Location range L_Rsp .. L_R15;

   ---------------------------------------------------------------------------
   --  2.  Layout
   ---------------------------------------------------------------------------

   --  The byte offsets of the context record.  These named numbers are the
   --  single source of truth: the record's representation clause in the
   --  parent body uses them, Offset_Of uses them, and the emitted
   --  instructions get their displacements from Offset_Of.
   Off_Rip : constant := 0;
   Off_Rsp : constant := 8;
   Off_Rbp : constant := 16;
   Off_Rbx : constant := 24;
   Off_R12 : constant := 32;
   Off_R13 : constant := 40;
   Off_R14 : constant := 48;
   Off_R15 : constant := 56;

   Context_Bytes : constant := 64;

   --  Every location here is one 64-bit word.  The Win64 model next door
   --  has four sizes, and keeping the function on both sides means the two
   --  files stay readable against each other.
   function Size_Of (L : Location) return Positive
     with Global => null, Post => Size_Of'Result = 8;

   function Offset_Of (L : Location) return Natural
     with Global => null,
          Post => Offset_Of'Result + Size_Of (L) <= Context_Bytes
                  and then Offset_Of'Result mod Size_Of (L) = 0;

   --  Two locations never share a byte.  Proved for every pair by the
   --  lemma below; it is the property that makes "saved to its own offset"
   --  mean "saved without destroying another location's slot".
   function Disjoint (A, B : Location) return Boolean is
     (Offset_Of (A) + Size_Of (A) <= Offset_Of (B)
      or else Offset_Of (B) + Size_Of (B) <= Offset_Of (A))
     with Ghost, Global => null;

   --  The layout theorem, as a lemma: a ghost procedure with an empty body
   --  whose postcondition gnatprove has to establish out of nothing.  That
   --  is the SPARK way of asserting a fact about constants; a library-level
   --  pragma Assert calling Offset_Of would be rejected by the compiler
   --  under SPARK RM 7.7(3), even though gnatprove accepts it.
   --
   --  It is what licenses "saved to its own offset" to mean "saved without
   --  overwriting another location's slot", and so what the
   --  non-interference half of Model_Switch rests on.
   procedure Layout_Is_Disjoint
     with Ghost, Global => null, Always_Terminates,
          Post => (for all A in Location =>
                     (for all B in Location =>
                        (if A /= B then Disjoint (A, B))));

   ---------------------------------------------------------------------------
   --  3.  The instruction sequence, as data
   ---------------------------------------------------------------------------

   --  The switch is made of seven instruction forms and nothing else.  Each
   --  carries the location it acts on, and both consumers -- the abstract
   --  machine below and the text checker further down -- take the offset
   --  and the register name from that one field.
   type Opcode is
     (Op_Lea_Resume,   --  leaq 1f(%rip), %rax
      Op_Store_Rax,    --  movq %rax, off(%rdi)          outgoing context
      Op_Store_Reg,    --  movq %reg, off(%rdi)          outgoing context
      Op_Load_Reg,     --  movq off(%rsi), %reg          incoming context
      Op_Jump_Ctx,     --  jmpq *off(%rsi)               incoming context
      Op_Resume_Label, --  1:
      Op_Ret);         --  ret

   type Instruction is record
      Op : Opcode;
      L  : Location;
   end record;

   --  A location expands to at most two instructions -- L_Rip's save needs
   --  the leaq as well -- and the tail is three.
   Max_Ops : constant := 3;
   subtype Op_Index is Positive range 1 .. Max_Ops;
   type Op_Array is array (Op_Index) of Instruction;

   type Snippet is record
      Ops : Op_Array;
      N   : Natural;
   end record
     with Predicate => Snippet.N in 1 .. Max_Ops;

   --  What saving L costs, and what restoring it costs.  Coverage of the
   --  register file is not a proof obligation here: the phases below are
   --  loops over Location and over Restorable, so every location is in the
   --  sequence exactly once by construction.
   function Save_Snippet (L : Location) return Snippet with Global => null;

   function Load_Snippet (L : Restorable) return Snippet with Global => null;

   --  The jump through the incoming context's saved rip, the label a
   --  resumed context lands on, and the return that hands it back to
   --  whoever called the switch on it.
   function Tail_Snippet return Snippet with Global => null;

   ---------------------------------------------------------------------------
   --  4.  The abstract machine, and what the sequence means on it
   ---------------------------------------------------------------------------

   type Word is mod 2 ** 64;

   --  A context, live or in memory: one word per location.
   type Frame is array (Location) of Word with Ghost;

   --  Everything the sequence can read or write.  Rax is the one scratch
   --  register it uses, and is not a location: SysV makes it caller-saved,
   --  so the switch owes nobody its value.
   type State is record
      Live    : Frame;   --  the machine's live locations
      Out_Ctx : Frame;   --  memory at (%rdi)
      In_Ctx  : Frame;   --  memory at (%rsi)
      Rax     : Word;
   end record with Ghost;

   --  Stands for the address of the resume label, which is a number this
   --  model has no way to compute and no need to.  What matters is that it
   --  is what the outgoing context's rip slot receives, and that it is
   --  distinguishable from anything else.
   Resume_Address : constant Word := 16#5245_5355_4D45_0001# with Ghost;

   --  One instruction.
   procedure Apply (S : in out State; I : Instruction)
     with Ghost, Global => null, Always_Terminates,
       Post =>
         (case I.Op is
            when Op_Lea_Resume =>
              S = (S'Old with delta Rax => Resume_Address),
            when Op_Store_Rax =>
              S = (S'Old with delta
                     Out_Ctx => (S'Old.Out_Ctx with delta I.L => S'Old.Rax)),
            when Op_Store_Reg =>
              S = (S'Old with delta
                     Out_Ctx =>
                       (S'Old.Out_Ctx with delta I.L => S'Old.Live (I.L))),
            when Op_Load_Reg =>
              S = (S'Old with delta
                     Live =>
                       (S'Old.Live with delta I.L => S'Old.In_Ctx (I.L))),
            when Op_Jump_Ctx | Op_Resume_Label | Op_Ret => S = S'Old);

   --  The theorem.  Running the whole sequence on any starting state
   --  leaves the outgoing context holding the entry value of every
   --  location -- with the resume address in the rip slot, because that is
   --  where the switch will come back -- leaves every restorable location
   --  holding what the incoming context held, and leaves the incoming
   --  context alone.
   --
   --  This is the callee-saved obligation of a typed assembly language
   --  stated as one predicate.  Nothing here is about what a fiber
   --  computes; it is about the switch handing the register file over
   --  whole.
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

   --  A newline, and the doubled percent GCC wants in an extended-asm
   --  template.  Both appear in the emitted constants and in the checker,
   --  so neither can be got right in one place and wrong in the other.
   Nl    : constant String := "" & ASCII.LF;
   Sigil : constant String := "%%";

   --  The template GCC assembles.  It has to be a static string -- GNAT
   --  requires that of an Asm template -- so it is written out rather than
   --  built, and Check_Switch_Text is what makes writing it out safe.
   --  Every displacement below is the Offset_Of the location on its line;
   --  the checker is what says so.
   Switch_Template : constant String :=
     "leaq 1f(" & Sigil & "rip), " & Sigil & "rax"       & Nl &
     "movq " & Sigil & "rax, 0(" & Sigil & "rdi)"        & Nl &
     "movq " & Sigil & "rsp, 8(" & Sigil & "rdi)"        & Nl &
     "movq " & Sigil & "rbp, 16(" & Sigil & "rdi)"       & Nl &
     "movq " & Sigil & "rbx, 24(" & Sigil & "rdi)"       & Nl &
     "movq " & Sigil & "r12, 32(" & Sigil & "rdi)"       & Nl &
     "movq " & Sigil & "r13, 40(" & Sigil & "rdi)"       & Nl &
     "movq " & Sigil & "r14, 48(" & Sigil & "rdi)"       & Nl &
     "movq " & Sigil & "r15, 56(" & Sigil & "rdi)"       & Nl &
     "movq 56(" & Sigil & "rsi), " & Sigil & "r15"       & Nl &
     "movq 48(" & Sigil & "rsi), " & Sigil & "r14"       & Nl &
     "movq 40(" & Sigil & "rsi), " & Sigil & "r13"       & Nl &
     "movq 32(" & Sigil & "rsi), " & Sigil & "r12"       & Nl &
     "movq 24(" & Sigil & "rsi), " & Sigil & "rbx"       & Nl &
     "movq 16(" & Sigil & "rsi), " & Sigil & "rbp"       & Nl &
     "movq 8(" & Sigil & "rsi), " & Sigil & "rsp"        & Nl &
     "jmpq *0(" & Sigil & "rsi)"                         & Nl &
     "1:"                                                & Nl &
     "ret"                                               & Nl;

   --  The trampoline a freshly primed context starts on: the entry point
   --  is in r12 and its argument in r13, and SysV's first argument
   --  register is rdi.  A jump rather than a call, so the entry point sees
   --  the stack exactly as Prime laid it out.
   Trampoline_Template : constant String :=
     "movq " & Sigil & "r13, " & Sigil & "rdi"           & Nl &
     "jmpq *" & Sigil & "r12"                           & Nl;

   --  Longest single rendered instruction, and the largest template this
   --  checker will look at.  Both are bounds for the proof, not budgets.
   Max_Line     : constant := 64;
   Max_Template : constant := 8192;

   --  Render the instruction sequence and compare it, character for
   --  character, with Text.  Ok is False and At_Char is the position where
   --  they first disagree -- or Text'Last + 1 if the text simply ran out.
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

   --  Both of the above, against the templates this package actually hands
   --  to Asm.  Iour.Fibers calls it during elaboration and refuses to start
   --  a shard if it comes back False.
   function Emitted_Matches_Model return Boolean
     with Global => null;

   ---------------------------------------------------------------------------
   --  6.  The stack a fiber starts on
   ---------------------------------------------------------------------------

   --  SysV reserves the 128 bytes above the stack pointer as a red zone
   --  that a leaf function may use without adjusting rsp.  The entry point
   --  is entitled to it, so the first frame is placed low enough to leave
   --  it inside the mapping.  Win64 has no red zone and a 32-byte shadow
   --  store instead; the arithmetic on the other side is the same with a
   --  different constant.
   Entry_Reserve : constant := 128;

   subtype Page_Bytes is Natural range 4_096 .. 2 ** 20;
   subtype Stack_Bytes is Natural range 0 .. 2 ** 28;

   --  Round Bytes up to a whole number of pages.  Bounded so it cannot
   --  overflow, which the version this replaced could for a large enough
   --  request.
   function Round_Up_Pages (Bytes : Stack_Bytes; Page : Page_Bytes)
     return Natural
     with Global => null,
          Pre  => Bytes <= Stack_Bytes'Last - Page,
          Post => Round_Up_Pages'Result mod Page = 0
                  and then Round_Up_Pages'Result >= Bytes
                  and then Round_Up_Pages'Result < Bytes + Page;

   --  Where the dummy return address goes, as a byte offset from the base
   --  of the mapping.  The mapping is one guard page followed by Usable
   --  bytes the fiber may touch; the frame is built down from the top of
   --  that, 16-aligned, with Entry_Reserve left above it.
   --
   --  The postcondition is the whole point:
   --
   --    mod 16 = 8       what a call leaves, so the entry point sees the
   --                     alignment the ABI promises it and SSE spills do
   --                     not fault;
   --    >= Guard         the eight bytes written are above the guard page,
   --                     so priming a fiber never touches it;
   --    within the map   the reserve above the frame is inside the usable
   --                     region, so a leaf using its whole red zone stays
   --                     in the mapping.
   function Return_Slot_Offset (Guard : Page_Bytes; Usable : Natural)
     return Natural
     with Global => null,
          Pre  => Usable mod Guard = 0
                  and then Usable in 4 * Guard .. Stack_Bytes'Last
                  and then Guard <= Stack_Bytes'Last - Usable,
          Post => Return_Slot_Offset'Result mod 16 = 8
                  and then Return_Slot_Offset'Result >= Guard
                  and then Return_Slot_Offset'Result + 8 + Entry_Reserve
                             <= Guard + Usable;

end Iour.Ffi.Fiber.Machine;
