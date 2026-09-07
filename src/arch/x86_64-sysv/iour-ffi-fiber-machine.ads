------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Machine -- the context switch as a typed object, x86-64
--  SysV.
--
--  The switch itself cannot be written in SPARK: it is inline Asm in a
--  naked subprogram, which is not analysable code at all.  What *can* be
--  written in SPARK is everything the assembly is supposed to be, and that
--  is what this package is.
--
--  It is one of two files that describe a target -- the other is the Win64
--  one next door -- and between them they hold nothing that is not
--  genuinely per-target.  Everything a switch has in common with every
--  other switch lives in the portable half:
--
--    Iour.Ffi.Fiber.Frames    the abstract machine, over a location set
--    Iour.Ffi.Fiber.Target    the obligation, the exchange theorem and the
--                             text walk -- the interface a target meets
--    Iour.Ffi.Fiber.Text      the assembler-text scanner
--    Iour.Ffi.Fiber.Layout    where a fiber's first frame goes
--
--  So what remains here is exactly the description of one machine: which
--  locations the switch owns, where they sit in the context record, what
--  instructions move them, and what those instructions look like.
--  Instantiating Iour.Ffi.Fiber.Target with them is what obliges this
--  target to be right: Save_One and Load_One below have to satisfy that
--  package's Save_Obligation and Load_Obligation, and a target that does
--  something else fails on those, at the instantiation.
--
--  Two papers, and it is worth knowing which idea came from which.
--
--  Rutter, "Using a high level language as a cross assembler" (SIGPLAN
--  Notices 16(2), 1981), is the reason the instructions are values here
--  rather than characters in a string.  An offset and a register name that
--  are chosen together by the same case statement cannot disagree; the
--  classic context-switch bug -- storing r14 at r13's offset -- is not
--  expressible.  Rutter emitted the target's code from the high level
--  language.  This emits it too, in the sense that the Asm template is a
--  constant of this package and the text walk proves it character for
--  character equal to what the instruction sequence renders to.  Nothing
--  above trusts a string a human aligned by hand.
--
--  Crary, "Toward a Foundational Typed Assembly Language" (POPL 2003), and
--  closer still Morrisett, Crary and Glew's stack-based TAL, are the reason
--  there is a machine and a theorem rather than a syntactic checklist.
--  TAL states the callee-saved convention as a type the callee holds
--  abstract and must hand back unchanged; a context switch is that
--  obligation and nothing else.  The theorem is Target.Model_Switch's
--  postcondition, and it is quantified over the whole location set, so a
--  dropped register, a duplicated offset, a load from the wrong slot and a
--  save that never happens all break it.
--
--  What is proved and what is checked, precisely, because the difference
--  matters:
--
--    proved by gnatprove   the layout is disjoint, aligned and inside the
--                          context record; Save_One and Load_One meet the
--                          interface's obligations; the instruction
--                          sequence's meaning on the abstract machine is
--                          the exchange the theorem states; the stack
--                          arithmetic in Prime lands the entry frame
--                          inside the mapping, clear of the guard page, at
--                          the alignment the ABI wants; none of the
--                          rendering can go out of bounds.
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
------------------------------------------------------------------------------

with Iour.Ffi.Fiber.Frames;
with Iour.Ffi.Fiber.Target;
with Iour.Ffi.Fiber.Text;

package Iour.Ffi.Fiber.Machine with SPARK_Mode => On is

   package Txt renames Iour.Ffi.Fiber.Text;

   ---------------------------------------------------------------------------
   --  1.  The register file type
   ---------------------------------------------------------------------------

   --  Every machine location a SysV context switch is responsible for.
   --  Declared in ascending offset order, which is also the order the
   --  switch saves them in; the enumeration is therefore the layout, the
   --  save schedule and the coverage argument at once.
   --
   --  L_Rip is first, which the portable half relies on: it is in the set
   --  but is not a register the switch preserves.  The outgoing context
   --  receives the address of the resume label, and the incoming context's
   --  copy is the jump target that ends the sequence.  So it is saved and
   --  never restored, which is what Restorable says.
   type Location is
     (L_Rip, L_Rsp, L_Rbp, L_Rbx, L_R12, L_R13, L_R14, L_R15);

   subtype Restorable is Location range L_Rsp .. L_R15;

   package Fr is new Iour.Ffi.Fiber.Frames (Location);

   --  A generic instance's operations are not directly visible, and both
   --  the contracts below and the Target instantiation need equality.
   use type Fr.Frame;
   use type Fr.Word;
   use type Fr.State;

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
   --  non-interference half of the exchange theorem rests on.
   procedure Layout_Is_Disjoint
     with Ghost, Global => null, Always_Terminates,
          Post => (for all A in Location =>
                     (for all B in Location =>
                        (if A /= B then Disjoint (A, B))));

   --  Disjointness says no two locations overlap.  It does not say they
   --  cover the context, and that omission is not academic: with only the
   --  lemma above, deleting a register from the middle of Location --
   --  together with its offset, its two template lines and its field of the
   --  record -- compiles, proves clean and passes the start-up check, while
   --  the switch silently stops preserving it.  That was measured, on r14,
   --  before this lemma existed.  Context'Size does not catch it either,
   --  because removing a middle field leaves a hole and the record's size
   --  is unchanged.
   --
   --  So the offsets are required to be a *chain*: the first at zero, each
   --  one starting where its predecessor ended, and the last ending exactly
   --  at Context_Bytes.  That is strictly stronger than disjointness -- it
   --  implies it -- and it is linear rather than quadratic in the number of
   --  locations.  A hole anywhere breaks the successor it precedes.
   procedure Layout_Tiles_Context
     with Ghost, Global => null, Always_Terminates,
          Post => Offset_Of (Location'First) = 0
                  and then
                    (for all L in Location =>
                       (if L /= Location'First then
                          Offset_Of (L) =
                            Offset_Of (Location'Pred (L))
                            + Size_Of (Location'Pred (L))))
                  and then Offset_Of (Location'Last)
                           + Size_Of (Location'Last) = Context_Bytes;

   ---------------------------------------------------------------------------
   --  3.  The instruction sequence, as data
   ---------------------------------------------------------------------------

   --  The switch is made of seven instruction forms and nothing else.  Each
   --  carries the location it acts on, and both consumers -- the abstract
   --  machine below and the text walk -- take the offset and the register
   --  name from that one field.
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

   function Save_Snippet (L : Location) return Snippet with Global => null;

   function Load_Snippet (L : Restorable) return Snippet with Global => null;

   --  The jump through the incoming context's saved rip, the label a
   --  resumed context lands on, and the return that hands it back to
   --  whoever called the switch on it.
   function Tail_Snippet return Snippet with Global => null;

   ---------------------------------------------------------------------------
   --  4.  What the sequence means
   ---------------------------------------------------------------------------

   --  Stands for the address of the resume label, which this model has no
   --  way to compute and no need to.
   --
   --  Not Ghost: it is the actual for a generic formal object, and a ghost
   --  entity may not be passed to a non-ghost formal.  A constant emits
   --  nothing either way.
   Resume_Address : constant Fr.Word := 16#5245_5355_4D45_0001#;

   --  One instruction.
   procedure Apply (S : in out Fr.State; I : Instruction)
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

   --  Saving one location leaves every other slot of the outgoing context,
   --  and the whole of the live and incoming frames, exactly as they were.
   --  That is the non-interference half of the theorem, and it is where a
   --  duplicated offset would be caught: two locations sharing a slot would
   --  make this false for the second one.
   --
   --  These two are what Iour.Ffi.Fiber.Target's formals bind to, and their
   --  postconditions have to imply that package's Save_Obligation and
   --  Load_Obligation.  They are written out here rather than deferred to
   --  those predicates because this is also where the target's own body is
   --  checked against them, and a target reads better with its obligation
   --  in front of it.
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
   --  and Check_Switch_Text come out of it; if Save_One or Load_One did not
   --  meet Target's obligations, the failure would be reported here, naming
   --  the predicate they broke.
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

   --  It has to be a static string -- GNAT requires that of an Asm template
   --  -- so it is written out rather than built, and Check_Switch_Text is
   --  what makes writing it out safe.  Every displacement below is the
   --  Offset_Of the location on its line; the walk is what says so.
   Switch_Template : constant String :=
     "leaq 1f(" & Txt.Sigil & "rip), " & Txt.Sigil & "rax"    & Txt.Nl &
     "movq " & Txt.Sigil & "rax, 0(" & Txt.Sigil & "rdi)"     & Txt.Nl &
     "movq " & Txt.Sigil & "rsp, 8(" & Txt.Sigil & "rdi)"     & Txt.Nl &
     "movq " & Txt.Sigil & "rbp, 16(" & Txt.Sigil & "rdi)"    & Txt.Nl &
     "movq " & Txt.Sigil & "rbx, 24(" & Txt.Sigil & "rdi)"    & Txt.Nl &
     "movq " & Txt.Sigil & "r12, 32(" & Txt.Sigil & "rdi)"    & Txt.Nl &
     "movq " & Txt.Sigil & "r13, 40(" & Txt.Sigil & "rdi)"    & Txt.Nl &
     "movq " & Txt.Sigil & "r14, 48(" & Txt.Sigil & "rdi)"    & Txt.Nl &
     "movq " & Txt.Sigil & "r15, 56(" & Txt.Sigil & "rdi)"    & Txt.Nl &
     "movq 56(" & Txt.Sigil & "rsi), " & Txt.Sigil & "r15"    & Txt.Nl &
     "movq 48(" & Txt.Sigil & "rsi), " & Txt.Sigil & "r14"    & Txt.Nl &
     "movq 40(" & Txt.Sigil & "rsi), " & Txt.Sigil & "r13"    & Txt.Nl &
     "movq 32(" & Txt.Sigil & "rsi), " & Txt.Sigil & "r12"    & Txt.Nl &
     "movq 24(" & Txt.Sigil & "rsi), " & Txt.Sigil & "rbx"    & Txt.Nl &
     "movq 16(" & Txt.Sigil & "rsi), " & Txt.Sigil & "rbp"    & Txt.Nl &
     "movq 8(" & Txt.Sigil & "rsi), " & Txt.Sigil & "rsp"     & Txt.Nl &
     "jmpq *0(" & Txt.Sigil & "rsi)"                          & Txt.Nl &
     "1:"                                                     & Txt.Nl &
     "ret"                                                    & Txt.Nl;

   --  The trampoline a freshly primed context starts on: the entry point
   --  is in r12 and its argument in r13, and SysV's first argument
   --  register is rdi.  A jump rather than a call, so the entry point sees
   --  the stack exactly as Prime laid it out.
   Trampoline_Template : constant String :=
     "movq " & Txt.Sigil & "r13, " & Txt.Sigil & "rdi"        & Txt.Nl &
     "jmpq *" & Txt.Sigil & "r12"                             & Txt.Nl;

   procedure Check_Trampoline_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
     with Global => null, Always_Terminates,
          Pre  => Text'First = 1
                  and then Text'Last in 0 .. Txt.Max_Template,
          Post => (if Ok then At_Char = 0);

   --  Both of the above, against the templates this package actually hands
   --  to Asm.  Iour.Fibers calls it before it lets a shard start.
   function Emitted_Matches_Model return Boolean
     with Global => null;

   ---------------------------------------------------------------------------
   --  8.  The stack a fiber starts on
   ---------------------------------------------------------------------------

   --  SysV reserves the 128 bytes above the stack pointer as a red zone
   --  that a leaf function may use without adjusting rsp.  The entry point
   --  is entitled to it, so the first frame is placed low enough to leave
   --  it inside the mapping.  Win64 has no red zone and a 32-byte shadow
   --  store instead; Iour.Ffi.Fiber.Layout does the arithmetic for both and
   --  this is the only part of it that differs.
   Entry_Reserve : constant := 128;

end Iour.Ffi.Fiber.Machine;
