------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Machine -- the context switch as a typed object, AArch64
--  AAPCS64.
--
--  The third target, and the first one whose assembly is not a naked
--  subprogram, because GCC does not have naked subprograms here.  That is
--  established by experiment rather than read off a document: GCC 12.2 on
--  aarch64-linux-gnu accepts __attribute__((naked)) and answers
--
--     warning: 'naked' attribute directive ignored [-Wattributes]
--
--  having emitted an ordinary prologue and epilogue.  A context switch
--  wrapped in a prologue is not a context switch, so the parent body
--  assembles the whole function out of one Asm block bracketed by
--  .pushsection/.popsection and binds it with Import.  What matters here
--  is that the *template is still an Ada constant of this package*, so
--  everything below -- the model, the render check, the whole argument --
--  works exactly as it does on the two x86 targets.  See the parent body
--  for why that bracketing is safe.
--
--  Everything a switch has in common with every other switch is in the
--  portable half and is not repeated here:
--
--    Iour.Ffi.Fiber.Frames    the abstract machine, over a location set
--    Iour.Ffi.Fiber.Target    the obligation, the exchange theorem and the
--                             text walk -- the interface a target meets
--    Iour.Ffi.Fiber.Text      the assembler-text scanner
--    Iour.Ffi.Fiber.Layout    where a fiber's first frame goes
--
--  What differs from x86-64, beyond the register file:
--
--  *  **No sigil.**  GCC's extended-asm doubling of '%' exists because
--     x86 register names begin with one.  AArch64 register names do not,
--     so Txt.Sigil appears nowhere below and the template is the plain
--     assembler text.
--
--  *  **The link register is a location.**  x86 pushes a return address
--     on the stack and `ret` pops it; AArch64 keeps it in x30 and `ret`
--     branches to it.  So x30 round-trips like any other callee-saved
--     register, and a resumed fiber returns to *its* caller because its
--     own x30 came back with it.  L_Pc is still separate and still first:
--     it is the resume label's address, saved and never restored, and the
--     incoming context's copy is the branch that ends the sequence.
--
--  *  **The stack pointer is not addressable.**  `str sp, [x0, #8]` does
--     not encode -- register 31 reads as the zero register in that
--     position -- so L_Sp goes through the scratch register in both
--     directions, exactly as the Win64 target's TEB fields do.  L_Fpcr is
--     the same shape for the same reason: `mrs`/`msr` name a system
--     register, not memory.
--
--  *  **Only the low half of v8-v15 is callee-saved.**  AAPCS64 obliges a
--     callee to preserve d8-d15, that is bits 0-63 of v8-v15, and nothing
--     above them.  So these are eight-byte locations written with `str d8`
--     rather than sixteen-byte ones, and the context record is smaller
--     than the Win64 one despite covering more registers.
--
--  The two papers behind the arrangement are named in the SysV file and
--  the reasoning is identical here; what follows is this machine.
------------------------------------------------------------------------------

with Iour.Ffi.Fiber.Frames;
with Iour.Ffi.Fiber.Target;
with Iour.Ffi.Fiber.Text;

package Iour.Ffi.Fiber.Machine with SPARK_Mode => On is

   package Txt renames Iour.Ffi.Fiber.Text;

   ---------------------------------------------------------------------------
   --  1.  The register file type
   ---------------------------------------------------------------------------

   --  Every machine location an AAPCS64 context switch is responsible for,
   --  in ascending offset order -- which is also the order the switch
   --  saves them in, so the enumeration is the layout, the save schedule
   --  and the coverage argument at once.
   --
   --  L_Pc first, which the portable half relies on: Restorable is derived
   --  as everything after Location'First, and Save_Obligation special-cases
   --  Location'First as the one that receives the resume address.
   --
   --  The set is AAPCS64's callee-saved registers: x19-x28 general, x29 the
   --  frame pointer, x30 the link register, d8-d15 the low halves of the
   --  vector registers, plus the stack pointer and the floating-point
   --  control register.  It is trusted input that this list is the ABI's;
   --  nothing here can check that, and the SysV file's "What the model does
   --  not catch" applies word for word.
   type Location is
     (L_Pc, L_Sp,
      L_X19, L_X20, L_X21, L_X22, L_X23, L_X24, L_X25, L_X26, L_X27, L_X28,
      L_X29, L_X30,
      L_Fpcr,
      L_D8, L_D9, L_D10, L_D11, L_D12, L_D13, L_D14, L_D15);

   subtype Restorable is Location range L_Sp .. L_D15;

   package Fr is new Iour.Ffi.Fiber.Frames (Location);

   --  A generic instance's operations are not directly visible, and both
   --  the contracts below and the Target instantiation need equality.
   use type Fr.Frame;
   use type Fr.Word;
   use type Fr.State;

   --  What kind of thing a location is, which decides the instruction pair
   --  that moves it.  Unlike Win64 it does not also decide a width: every
   --  location here is eight bytes.
   type Location_Class is
     (Class_Pc,        --  the resume address: computed, never restored
      Class_Sp,        --  the stack pointer, via the scratch register
      Class_General,   --  x19-x30, addressable directly
      Class_Fpcr,      --  a system register, via the scratch register
      Class_Vector);   --  d8-d15, the callee-saved low halves

   function Class_Of (L : Location) return Location_Class with Global => null;

   ---------------------------------------------------------------------------
   --  2.  Layout
   ---------------------------------------------------------------------------

   --  The byte offsets of the context record.  These named numbers are the
   --  single source of truth: the record's representation clause in the
   --  parent body uses them, Offset_Of uses them, and every emitted
   --  displacement comes from Offset_Of.
   Off_Pc   : constant := 0;
   Off_Sp   : constant := 8;
   Off_X19  : constant := 16;
   Off_X20  : constant := 24;
   Off_X21  : constant := 32;
   Off_X22  : constant := 40;
   Off_X23  : constant := 48;
   Off_X24  : constant := 56;
   Off_X25  : constant := 64;
   Off_X26  : constant := 72;
   Off_X27  : constant := 80;
   Off_X28  : constant := 88;
   Off_X29  : constant := 96;
   Off_X30  : constant := 104;
   Off_Fpcr : constant := 112;
   Off_D8   : constant := 120;

   --  d8 through d15 are consecutive from Off_D8; Offset_Of derives the
   --  rest rather than naming them, the way the Win64 file does for xmm.
   Vec_Bytes : constant := 8;
   First_Vec : constant := 8;

   Context_Bytes : constant := 184;

   --  Every location here is one 64-bit word.  Keeping the function on all
   --  three targets means the files stay readable against each other; the
   --  Win64 one is the only one where it is not constant.
   function Size_Of (L : Location) return Positive
     with Global => null, Post => Size_Of'Result = 8;

   function Vec_Number (L : Location) return Natural
     with Global => null,
          Pre  => Class_Of (L) = Class_Vector,
          Post => Vec_Number'Result in First_Vec .. First_Vec + 7;

   function Offset_Of (L : Location) return Natural
     with Global => null,
          Post => Offset_Of'Result + Size_Of (L) <= Context_Bytes
                  and then Offset_Of'Result mod Size_Of (L) = 0;

   --  Two locations never share a byte.
   function Disjoint (A, B : Location) return Boolean is
     (Offset_Of (A) + Size_Of (A) <= Offset_Of (B)
      or else Offset_Of (B) + Size_Of (B) <= Offset_Of (A))
     with Ghost, Global => null;

   --  The layout theorem, as a lemma: a ghost procedure with an empty body
   --  whose postcondition gnatprove has to establish out of nothing.  A
   --  library-level pragma Assert calling Offset_Of would be rejected by
   --  the compiler under SPARK RM 7.7(3) even though gnatprove accepts it.
   procedure Layout_Is_Disjoint
     with Ghost, Global => null, Always_Terminates,
          Post => (for all A in Location =>
                     (for all B in Location =>
                        (if A /= B then Disjoint (A, B))));

   --  Disjointness does not say the locations *cover* the context, and
   --  that omission is not academic: on the SysV target, deleting a
   --  register together with its offset, its template lines and its record
   --  field once compiled, proved clean and passed the start-up check
   --  while the switch silently stopped preserving it.  Requiring the
   --  offsets to be a chain -- first at zero, each starting where its
   --  predecessor ended, last ending exactly at Context_Bytes -- is
   --  strictly stronger, and linear rather than quadratic.
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

   --  The switch is made of these forms and nothing else.  Each carries the
   --  location it acts on, and both consumers -- the abstract machine and
   --  the text walk -- take the displacement and the register name from
   --  that one field, so a register cannot be emitted at its neighbour's
   --  offset.
   type Opcode is
     (Op_Adr_Resume,    --  adr x16, 1f
      Op_Read_Sp,       --  mov x16, sp
      Op_Read_Fpcr,     --  mrs x16, fpcr
      Op_Store_Scratch, --  str x16, [x0, #off]        outgoing context
      Op_Store_Reg,     --  str xN, [x0, #off]         outgoing context
      Op_Store_Vec,     --  str dN, [x0, #off]         outgoing context
      Op_Load_Scratch,  --  ldr x16, [x1, #off]        incoming context
      Op_Write_Sp,      --  mov sp, x16
      Op_Write_Fpcr,    --  msr fpcr, x16
      Op_Load_Reg,      --  ldr xN, [x1, #off]         incoming context
      Op_Load_Vec,      --  ldr dN, [x1, #off]         incoming context
      Op_Br_Scratch,    --  br x16
      Op_Resume_Label,  --  1:
      Op_Ret);          --  ret

   type Instruction is record
      Op : Opcode;
      L  : Location;
   end record;

   --  A location expands to at most two instructions; the tail is four,
   --  because AArch64 has no branch through memory and the jump has to
   --  load the target first.  That is one more than either x86 target.
   Max_Ops : constant := 4;
   subtype Op_Index is Positive range 1 .. Max_Ops;
   type Op_Array is array (Op_Index) of Instruction;

   type Snippet is record
      Ops : Op_Array;
      N   : Natural;
   end record
     with Predicate => Snippet.N in 1 .. Max_Ops;

   function Save_Snippet (L : Location) return Snippet with Global => null;

   function Load_Snippet (L : Restorable) return Snippet with Global => null;

   --  Load the incoming context's resume address, branch to it, the label a
   --  resumed context lands on, and the return that hands it back to
   --  whoever called the switch on it.
   function Tail_Snippet return Snippet with Global => null;

   ---------------------------------------------------------------------------
   --  4.  What the sequence means
   ---------------------------------------------------------------------------

   --  Stands for the address of the resume label, which this model has no
   --  way to compute and no need to.  Not Ghost: it is the actual for a
   --  generic formal object, and a ghost entity may not be passed to a
   --  non-ghost formal.  A constant emits nothing either way.
   Resume_Address : constant Fr.Word := 16#5245_5355_4D45_0001#;

   --  One instruction.  Fr.State's scratch field is named Rax for the
   --  target that was written first; here it is x16, the ABI's first
   --  intra-procedure-call scratch register, which a callee owes nobody.
   procedure Apply (S : in out Fr.State; I : Instruction)
     with Ghost, Global => null, Always_Terminates,
       Post =>
         (case I.Op is
            when Op_Adr_Resume =>
              S = (S'Old with delta Rax => Resume_Address),
            when Op_Read_Sp | Op_Read_Fpcr =>
              S = (S'Old with delta Rax => S'Old.Live (I.L)),
            when Op_Store_Scratch =>
              S = (S'Old with delta
                     Out_Ctx => (S'Old.Out_Ctx with delta I.L => S'Old.Rax)),
            when Op_Store_Reg | Op_Store_Vec =>
              S = (S'Old with delta
                     Out_Ctx =>
                       (S'Old.Out_Ctx with delta I.L => S'Old.Live (I.L))),
            when Op_Load_Scratch =>
              S = (S'Old with delta Rax => S'Old.In_Ctx (I.L)),
            when Op_Write_Sp | Op_Write_Fpcr =>
              S = (S'Old with delta
                     Live => (S'Old.Live with delta I.L => S'Old.Rax)),
            when Op_Load_Reg | Op_Load_Vec =>
              S = (S'Old with delta
                     Live =>
                       (S'Old.Live with delta I.L => S'Old.In_Ctx (I.L))),
            when Op_Br_Scratch | Op_Resume_Label | Op_Ret => S = S'Old);

   --  Saving one location leaves every other slot of the outgoing context,
   --  and the whole of the live and incoming frames, exactly as they were.
   --  That is the non-interference half of the theorem, and it is where a
   --  duplicated offset would be caught.  Nothing is said about the scratch
   --  register, which the two-instruction forms necessarily clobber.
   --
   --  These two are what Iour.Ffi.Fiber.Target's formals bind to, and their
   --  postconditions have to imply that package's Save_Obligation and
   --  Load_Obligation.  They are written out rather than deferred to those
   --  predicates because this is also where this target's body is checked
   --  against them, and a target reads better with its obligation in front
   --  of it.
   procedure Save_One (S : in out Fr.State; L : Location)
     with Ghost, Global => null, Always_Terminates,
       Post => S.Live = S.Live'Old
               and then S.In_Ctx = S.In_Ctx'Old
               and then S.Out_Ctx =
                 (S.Out_Ctx'Old with delta
                    L => (if L = L_Pc then Resume_Address
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
   --  meet Target's obligations the failure would be reported here, naming
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
   --
   --  x0 holds the outgoing context and x1 the incoming one, which is
   --  AAPCS64's first two argument registers and so is what Swap's C
   --  profile delivers.  x16 is the scratch.
   Switch_Template : constant String :=
     "adr x16, 1f"              & Txt.Nl &
     "str x16, [x0, #0]"        & Txt.Nl &
     "mov x16, sp"              & Txt.Nl &
     "str x16, [x0, #8]"        & Txt.Nl &
     "str x19, [x0, #16]"       & Txt.Nl &
     "str x20, [x0, #24]"       & Txt.Nl &
     "str x21, [x0, #32]"       & Txt.Nl &
     "str x22, [x0, #40]"       & Txt.Nl &
     "str x23, [x0, #48]"       & Txt.Nl &
     "str x24, [x0, #56]"       & Txt.Nl &
     "str x25, [x0, #64]"       & Txt.Nl &
     "str x26, [x0, #72]"       & Txt.Nl &
     "str x27, [x0, #80]"       & Txt.Nl &
     "str x28, [x0, #88]"       & Txt.Nl &
     "str x29, [x0, #96]"       & Txt.Nl &
     "str x30, [x0, #104]"      & Txt.Nl &
     "mrs x16, fpcr"            & Txt.Nl &
     "str x16, [x0, #112]"      & Txt.Nl &
     "str d8, [x0, #120]"       & Txt.Nl &
     "str d9, [x0, #128]"       & Txt.Nl &
     "str d10, [x0, #136]"      & Txt.Nl &
     "str d11, [x0, #144]"      & Txt.Nl &
     "str d12, [x0, #152]"      & Txt.Nl &
     "str d13, [x0, #160]"      & Txt.Nl &
     "str d14, [x0, #168]"      & Txt.Nl &
     "str d15, [x0, #176]"      & Txt.Nl &
     "ldr d15, [x1, #176]"      & Txt.Nl &
     "ldr d14, [x1, #168]"      & Txt.Nl &
     "ldr d13, [x1, #160]"      & Txt.Nl &
     "ldr d12, [x1, #152]"      & Txt.Nl &
     "ldr d11, [x1, #144]"      & Txt.Nl &
     "ldr d10, [x1, #136]"      & Txt.Nl &
     "ldr d9, [x1, #128]"       & Txt.Nl &
     "ldr d8, [x1, #120]"       & Txt.Nl &
     "ldr x16, [x1, #112]"      & Txt.Nl &
     "msr fpcr, x16"            & Txt.Nl &
     "ldr x30, [x1, #104]"      & Txt.Nl &
     "ldr x29, [x1, #96]"       & Txt.Nl &
     "ldr x28, [x1, #88]"       & Txt.Nl &
     "ldr x27, [x1, #80]"       & Txt.Nl &
     "ldr x26, [x1, #72]"       & Txt.Nl &
     "ldr x25, [x1, #64]"       & Txt.Nl &
     "ldr x24, [x1, #56]"       & Txt.Nl &
     "ldr x23, [x1, #48]"       & Txt.Nl &
     "ldr x22, [x1, #40]"       & Txt.Nl &
     "ldr x21, [x1, #32]"       & Txt.Nl &
     "ldr x20, [x1, #24]"       & Txt.Nl &
     "ldr x19, [x1, #16]"       & Txt.Nl &
     "ldr x16, [x1, #8]"        & Txt.Nl &
     "mov sp, x16"              & Txt.Nl &
     "ldr x16, [x1, #0]"        & Txt.Nl &
     "br x16"                   & Txt.Nl &
     "1:"                       & Txt.Nl &
     "ret"                      & Txt.Nl;

   --  The trampoline a freshly primed context starts on: the entry point is
   --  in x19 and its argument in x20, both restored by the switch that
   --  lands here, and AAPCS64's first argument register is x0.  A branch
   --  rather than a call, so the entry point sees the stack exactly as
   --  Prime laid it out.
   Trampoline_Template : constant String :=
     "mov x0, x20"              & Txt.Nl &
     "br x19"                   & Txt.Nl;

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

   --  AAPCS64 defines no red zone: a leaf function may not write below the
   --  stack pointer at all.  So nothing has to be left above the entry
   --  frame, where SysV reserves 128 bytes and Win64 a 32-byte shadow
   --  store.
   --
   --  The other half of the difference is in Iour.Ffi.Fiber.Layout.  Both
   --  x86 targets want the entry frame at 8 modulo 16, because a `call`
   --  has pushed a return address and the ABI's 16-byte guarantee is
   --  measured before that push.  AArch64 puts the return address in x30
   --  and requires the stack pointer to be 16-byte aligned at all times --
   --  the hardware can be configured to fault otherwise -- so this target
   --  uses Layout.Entry_Sp_Offset, whose postcondition is `mod 16 = 0`,
   --  rather than Return_Slot_Offset.
   Entry_Reserve : constant := 0;

end Iour.Ffi.Fiber.Machine;
