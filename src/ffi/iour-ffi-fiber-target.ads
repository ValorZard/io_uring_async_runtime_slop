------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Target -- what a context switch is, once, for every
--  target.
--
--  This is the interface an assembly target implements.  A target supplies
--  its location set, the effect of saving and restoring one location, and
--  the text of the instructions that do it; this package supplies the two
--  things that do not vary -- the exchange theorem and the walk that
--  checks the emitted text against it -- and states, as Save_Obligation
--  and Load_Obligation below, what it needs of the target for those to
--  hold.
--
--  Be precise about how much of that Ada enforces, because it is less than
--  it looks.  The formal subprograms carry no contracts (they cannot; see
--  below), so **instantiation alone checks only profiles**.  What makes
--  this an interface rather than a shared body of code is that
--  Model_Switch's body asserts Save_Obligation and Load_Obligation after
--  every call and is proved from them.  So:
--
--    *  the obligation is written here, once, where a new target's author
--       reads it, rather than having to be reverse-engineered from
--       Model_Switch's postcondition;
--    *  every target is held to the *same* obligation, not merely to one
--       strong enough for its own instance;
--    *  a target that misses it fails at its instantiation, naming the
--       predicate it broke.
--
--  That last is checked, not asserted.  A stand-in target whose Save_One
--  treats the instruction pointer like any other register -- and whose own
--  postcondition says so, so that it is internally consistent -- fails
--  with "assertion might fail ... Save_Obligation", at the instantiation.
--
--  Two things about SPARK and generics were established by experiment
--  here, both of them the opposite of the obvious guess:
--
--  *  **Do not put contracts on the formal subprograms.**  It is the
--     obvious way to state the obligation, it compiles under gprbuild, and
--     gnatprove's frontend then rejects every instantiation with a type
--     mismatch between the formal Location and the actual.  That is why
--     the obligation is a predicate asserted at the point of use instead.
--     gnatprove analyses instances rather than templates, so the assertion
--     is discharged per target, against that target's own postcondition.
--
--  *  A formal package's operations are not directly visible and a generic
--     formal part cannot carry a use clause, so the equalities the
--     contracts need are imported as formals with defaults.
--
--  The ordering convention every target shares, and the reason coverage is
--  never a proof obligation: Location is declared in ascending offset
--  order with the instruction pointer first, saves run over the whole type
--  and restores over Restorable in reverse.  Both phases are loops over a
--  type, so "did we remember xmm11" cannot be got wrong; what is left to
--  prove is non-interference, which is where a duplicated offset dies.
------------------------------------------------------------------------------

with Iour.Ffi.Fiber.Frames;
with Iour.Ffi.Fiber.Text;

generic
   --  The target's machine locations, in ascending offset order, with the
   --  instruction pointer first.
   type Location is (<>);

   with package F is new Iour.Ffi.Fiber.Frames (Location);

   with function "=" (L, R : F.Frame) return Boolean is <>;
   with function "=" (L, R : F.Word) return Boolean is <>;

   --  Stands for the address of the resume label, which the model has no
   --  way to compute and no need to.  What matters is that it is what the
   --  outgoing context's rip slot receives.
   Resume_Address : F.Word;

   --  Saving one location leaves every other slot of the outgoing context,
   --  and the whole of the live and incoming frames, exactly as they were.
   --  The target proves this of its own instruction sequence.
   with procedure Save_One (S : in out F.State; L : Location) with Ghost;
   with procedure Load_One (S : in out F.State; L : Location) with Ghost;

   --  The text of what those do, one location at a time, and the tail that
   --  ends the sequence: the jump through the incoming context's saved
   --  rip, the label a resumed context lands on, and the return.
   with procedure Emit_Save
     (Text : String; Cur : in out Positive; Ok : in out Boolean;
      L : Location);
   with procedure Emit_Load
     (Text : String; Cur : in out Positive; Ok : in out Boolean;
      L : Location);
   with procedure Emit_Tail
     (Text : String; Cur : in out Positive; Ok : in out Boolean);

package Iour.Ffi.Fiber.Target with SPARK_Mode => On is

   use type F.Frame;
   use type F.Word;

   --  Everything but the instruction pointer, which is saved -- as the
   --  resume label's address -- and never restored into a register,
   --  because the incoming context's copy is the jump that ends the
   --  sequence.
   subtype Restorable is Location
     range Location'Succ (Location'First) .. Location'Last;

   ---------------------------------------------------------------------------
   --  The obligation
   ---------------------------------------------------------------------------

   --  What a target's Save_One and Load_One must achieve.  These are the
   --  interface: everything else here is derived from them.
   --
   --  They are stated as predicates rather than as postconditions on the
   --  formal subprograms because gnatprove rejects the instantiation if the
   --  formals are contracted -- see the header.  Model_Switch's body asserts
   --  them after every call, so a target whose Save_One does something else
   --  fails on *this* predicate, named here, rather than on some downstream
   --  consequence of it; and Model_Switch is proved from these rather than
   --  from whatever the actual happened to promise, so every target is held
   --  to the same obligation rather than merely to a sufficient one.
   --
   --  Saving location L writes L's slot of the outgoing context -- the
   --  resume address for the instruction pointer, the live value for
   --  anything else -- and disturbs nothing else at all.  The "nothing
   --  else" is the half that matters: it is what a duplicated offset
   --  breaks.
   function Save_Obligation
     (Before, After : F.State; L : Location) return Boolean
   is
     (After.Live = Before.Live
      and then After.In_Ctx = Before.In_Ctx
      and then After.Out_Ctx =
        (Before.Out_Ctx with delta
           L => (if L = Location'First then Resume_Address
                 else Before.Live (L))))
     with Ghost;

   --  Restoring location L writes L's live location from the incoming
   --  context and disturbs nothing else.
   function Load_Obligation
     (Before, After : F.State; L : Location) return Boolean
   is
     (After.Out_Ctx = Before.Out_Ctx
      and then After.In_Ctx = Before.In_Ctx
      and then After.Live =
        (Before.Live with delta L => Before.In_Ctx (L)))
     with Ghost;

   --  The theorem.  The outgoing context ends up holding the entry value
   --  of every location, every restorable location ends up holding what
   --  the incoming context held, and the incoming context is untouched.
   --
   --  This is the callee-saved obligation of a typed assembly language
   --  stated as one predicate.  A dropped register, a duplicated offset, a
   --  load from the wrong slot and a save that never happens all break it.
   procedure Model_Switch (S : in out F.State)
     with Ghost, Global => null, Always_Terminates,
       Post =>
         (for all L in Location =>
            S.Out_Ctx (L) =
              (if L = Location'First then Resume_Address
               else S.Live'Old (L)))
         and then (for all L in Restorable => S.Live (L) = S.In_Ctx'Old (L))
         and then S.In_Ctx = S.In_Ctx'Old;

   --  Render the instruction sequence and compare it, character for
   --  character, with Text.  Ok is False and At_Char is the position where
   --  they first disagree -- or Text'Last + 1 if the text ran out.
   --
   --  The walk is the same shape as Model_Switch, deliberately: a location
   --  the meaning covers is a location the text covers.
   procedure Check_Switch_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
     with Global => null, Always_Terminates,
          Pre  => Text'First = 1
                  and then Text'Last in 0 .. Iour.Ffi.Fiber.Text.Max_Template,
          Post => (if Ok then At_Char = 0);

end Iour.Ffi.Fiber.Target;
