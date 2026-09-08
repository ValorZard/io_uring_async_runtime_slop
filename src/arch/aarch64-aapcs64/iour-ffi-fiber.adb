------------------------------------------------------------------------------
--  Iour.Ffi.Fiber body, AArch64 AAPCS64.
--
--  A SPARK_Mode => Off body for the same irreducible reasons as the two x86
--  ones: inline Asm is not analysable code, and the switch needs the
--  address of a context slot.  Everything that could be said in SPARK about
--  this switch is in Iour.Ffi.Fiber.Machine, which is proved.
--
--  What is different here, and it is the whole reason this file does not
--  simply mirror the SysV one:
--
--  **GCC has no naked subprograms on AArch64.**  Established by experiment
--  on the target rather than read off a document -- GCC 12.2
--  aarch64-linux-gnu accepts the attribute and answers
--
--     warning: 'naked' attribute directive ignored [-Wattributes]
--
--  having emitted an ordinary prologue and epilogue.  Both x86 bodies rely
--  on `pragma Machine_Attribute (Swap, "naked")` to make the Asm template
--  the entire function; that is not available, and a context switch with a
--  compiler prologue around it is not a context switch.  It would save x29
--  and x30 onto the outgoing fiber's stack and then try to restore them
--  from the incoming fiber's.
--
--  So the two functions are assembled *whole*, from one Asm block wrapped
--  in .pushsection .text / .popsection, and reached through Import.  The
--  bracketing is what makes it safe: everything between them goes into
--  .text as its own symbol, and the enclosing subprogram's own instruction
--  stream is not touched, so it does not matter what GCC emits around it
--  or whether it is ever called.
--
--  Verified on the target before this file was written.  A function
--  defined this way and consisting of `add x0, x0, #7; ret` returns its
--  argument plus seven -- which a compiler prologue would have disturbed
--  -- and the next symbol begins exactly eight bytes later, so the two
--  instructions are the entire function.
--
--  The important consequence is that **the template is still an Ada
--  constant of Machine**, exactly as on x86.  Emitted_Matches_Model still
--  walks the proved instruction sequence and compares it with the string
--  handed to Asm, character for character, so nothing about the
--  verification argument is weakened by the change of mechanism.  Only the
--  wrapper directives are outside the check, and they contain no
--  instructions.
--
--  One escaping rule bites here and is easy to miss: GCC reads '%' in an
--  Asm template as introducing an operand number, so the `%function` a
--  .type directive needs must be written '%%'.  Getting it wrong is a
--  compile error -- "operand number missing after %-letter" -- not silent
--  damage.  Machine's Switch_Template contains no '%' at all, AArch64
--  register names having no sigil.
------------------------------------------------------------------------------

with System.Machine_Code;     use System.Machine_Code;
with System.Storage_Elements; use System.Storage_Elements;
with Interfaces;
with Iour.Ffi.Posix;
with Iour.Ffi.Fiber.Machine;
with Iour.Ffi.Fiber.Layout;

package body Iour.Ffi.Fiber with SPARK_Mode => Off is

   package Posix renames Iour.Ffi.Posix;
   package Mach renames Iour.Ffi.Fiber.Machine;
   package Lay  renames Iour.Ffi.Fiber.Layout;

   use type System.Address;
   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Interfaces.C.size_t;

   ---------------------------------------------------------------------------
   --  Context
   ---------------------------------------------------------------------------

   --  Pc first because the switch ends with a branch through it.  The
   --  offsets are Machine's named numbers, not literals: the same numbers
   --  Machine.Offset_Of returns, and therefore the same numbers that appear
   --  in the emitted instructions.
   --
   --  x19-x30 and the stack pointer are addresses; the FPCR and the vector
   --  slots are not, and are typed as words so that nothing reads them as
   --  pointers in a debugger.
   type Context is record
      Pc   : System.Address := System.Null_Address;
      Sp   : System.Address := System.Null_Address;
      X19  : System.Address := System.Null_Address;
      X20  : System.Address := System.Null_Address;
      X21  : System.Address := System.Null_Address;
      X22  : System.Address := System.Null_Address;
      X23  : System.Address := System.Null_Address;
      X24  : System.Address := System.Null_Address;
      X25  : System.Address := System.Null_Address;
      X26  : System.Address := System.Null_Address;
      X27  : System.Address := System.Null_Address;
      X28  : System.Address := System.Null_Address;
      X29  : System.Address := System.Null_Address;
      X30  : System.Address := System.Null_Address;
      Fpcr : Interfaces.Unsigned_64 := 0;
      D8   : Interfaces.Unsigned_64 := 0;
      D9   : Interfaces.Unsigned_64 := 0;
      D10  : Interfaces.Unsigned_64 := 0;
      D11  : Interfaces.Unsigned_64 := 0;
      D12  : Interfaces.Unsigned_64 := 0;
      D13  : Interfaces.Unsigned_64 := 0;
      D14  : Interfaces.Unsigned_64 := 0;
      D15  : Interfaces.Unsigned_64 := 0;
   end record
     with Convention => C;

   --  The vector slots are consecutive from Off_D8, which is how
   --  Machine.Offset_Of derives them; writing the multiplication here
   --  rather than eight more named numbers keeps the two derivations the
   --  same shape.
   for Context use record
      Pc   at Mach.Off_Pc   range 0 .. 63;
      Sp   at Mach.Off_Sp   range 0 .. 63;
      X19  at Mach.Off_X19  range 0 .. 63;
      X20  at Mach.Off_X20  range 0 .. 63;
      X21  at Mach.Off_X21  range 0 .. 63;
      X22  at Mach.Off_X22  range 0 .. 63;
      X23  at Mach.Off_X23  range 0 .. 63;
      X24  at Mach.Off_X24  range 0 .. 63;
      X25  at Mach.Off_X25  range 0 .. 63;
      X26  at Mach.Off_X26  range 0 .. 63;
      X27  at Mach.Off_X27  range 0 .. 63;
      X28  at Mach.Off_X28  range 0 .. 63;
      X29  at Mach.Off_X29  range 0 .. 63;
      X30  at Mach.Off_X30  range 0 .. 63;
      Fpcr at Mach.Off_Fpcr range 0 .. 63;
      D8   at Mach.Off_D8 + 0 * Mach.Vec_Bytes range 0 .. 63;
      D9   at Mach.Off_D8 + 1 * Mach.Vec_Bytes range 0 .. 63;
      D10  at Mach.Off_D8 + 2 * Mach.Vec_Bytes range 0 .. 63;
      D11  at Mach.Off_D8 + 3 * Mach.Vec_Bytes range 0 .. 63;
      D12  at Mach.Off_D8 + 4 * Mach.Vec_Bytes range 0 .. 63;
      D13  at Mach.Off_D8 + 5 * Mach.Vec_Bytes range 0 .. 63;
      D14  at Mach.Off_D8 + 6 * Mach.Vec_Bytes range 0 .. 63;
      D15  at Mach.Off_D8 + 7 * Mach.Vec_Bytes range 0 .. 63;
   end record;

   pragma Compile_Time_Error
     (Context'Size /= Mach.Context_Bytes * 8,
      "the AArch64 fiber context must be Machine.Context_Bytes bytes");

   ---------------------------------------------------------------------------
   --  The slot table: one context per fiber, one per shard scheduler
   ---------------------------------------------------------------------------

   Slot_Capacity : constant := Max_Fibers + Max_Shards;
   type Slot_Index is range 0 .. Slot_Capacity - 1;
   type Context_Table is array (Slot_Index) of aliased Context
     with Convention => C;

   --  Static, so there is nothing to allocate and nothing that can fail at
   --  run time.  About 750 KB at the default sizes.
   Table : Context_Table;

   function In_Range (Slot : C_Long) return Boolean is
     (Slot >= 0 and then Slot <= C_Long (Slot_Index'Last));

   function Reserve (Slots : C_Long) return C_Int is
     (if Slots > 0 and then Slots <= C_Long (Slot_Capacity) then 0 else -1);

   function Slot_Count return C_Long is (C_Long (Slot_Capacity));

   ---------------------------------------------------------------------------
   --  The two functions, assembled whole
   ---------------------------------------------------------------------------

   Nl  : constant String := "" & ASCII.LF;

   --  GCC reads a single '%' in an Asm template as introducing an operand
   --  number, so the .type directive's %function is written doubled.  This
   --  is the same escape Iour.Ffi.Fiber.Text.Sigil provides for the x86
   --  register names, needed here for a different reason.
   Pct : constant String := "%%";

   Swap_Symbol  : constant String := "iour_aarch64_swap";
   Tramp_Symbol : constant String := "iour_aarch64_trampoline";

   --  Written out per symbol rather than built by a function taking the
   --  name, because **a function call is never static** -- RM 4.9(6,18) --
   --  and GNAT requires an Asm template to be a static string.  A `Head
   --  (Swap_Symbol) & ...` template is rejected with "asm template argument
   --  is not static", which is the same rule that puts Machine's
   --  Switch_Template in a constant rather than in a renderer.
   --  Concatenation of string literals and of constant Strings is static
   --  and folds, so these four do work.
   --
   --  .balign 4 because every AArch64 instruction is four bytes and the
   --  assembler will not otherwise guarantee the alignment of a symbol
   --  planted mid-section.
   Swap_Head : constant String :=
     ".pushsection .text"                             & Nl &
     ".balign 4"                                      & Nl &
     ".globl " & Swap_Symbol                          & Nl &
     ".type " & Swap_Symbol & ", " & Pct & "function" & Nl &
     Swap_Symbol & ":"                                & Nl;

   Swap_Foot : constant String :=
     ".size " & Swap_Symbol & ", .-" & Swap_Symbol & Nl &
     ".popsection"                                 & Nl;

   Tramp_Head : constant String :=
     ".pushsection .text"                              & Nl &
     ".balign 4"                                       & Nl &
     ".globl " & Tramp_Symbol                          & Nl &
     ".type " & Tramp_Symbol & ", " & Pct & "function" & Nl &
     Tramp_Symbol & ":"                                & Nl;

   Tramp_Foot : constant String :=
     ".size " & Tramp_Symbol & ", .-" & Tramp_Symbol & Nl &
     ".popsection"                                   & Nl;

   --  Never called.  It exists so that its Asm block is emitted, and it is
   --  exported rather than called because an exported subprogram cannot be
   --  dropped as unreferenced, where a local one could.  Nothing of the
   --  block lands in this subprogram's own instruction stream: it is all
   --  between .pushsection and .popsection.
   --
   --  GNAT requires an Asm template to be a static string.  Concatenation
   --  of string literals and of constant Strings -- including
   --  Machine.Switch_Template, declared in another unit -- folds to one,
   --  which is what lets the instructions live in the package the proof is
   --  about rather than here.
   procedure Emit_Switch_Code
     with Convention => C, Export,
          External_Name => "iour_aarch64_emit_switch_code";

   procedure Emit_Switch_Code is
   begin
      Asm (Swap_Head
           & Mach.Switch_Template
           & Swap_Foot
           & Tramp_Head
           & Mach.Trampoline_Template
           & Tramp_Foot,
           Volatile => True);
   end Emit_Switch_Code;

   --  Save the running context into From and resume To.  From arrives in x0
   --  and To in x1, per AAPCS64, which is what Machine renders its
   --  displacements against.
   procedure Swap (From : System.Address; To : System.Address)
     with Import, Convention => C, External_Name => Swap_Symbol;

   --  A freshly primed context has this as its Pc, the entry point in x19
   --  and the argument in x20.  Move the argument into the first-parameter
   --  register and branch.  A branch rather than a call, so the entry point
   --  sees the stack exactly as Prime laid it out and x30 still holds the
   --  sentinel Prime put there.
   procedure Trampoline
     with Import, Convention => C, External_Name => Tramp_Symbol;

   --  Every fiber starts in this Ada procedure, exported by Iour.Fibers.
   --  Bound here by name: this package sits below Iour.Fibers, so the
   --  reference resolves at link time rather than through a with clause.
   procedure Fiber_Main (Arg : C_Long)
     with Import, Convention => C, External_Name => "iour_fiber_main";

   ---------------------------------------------------------------------------
   --  Switch
   ---------------------------------------------------------------------------

   procedure Switch (From : C_Long; To : C_Long) is
   begin
      --  Refuse rather than corrupt.  Iour.Fibers never generates an
      --  out-of-range or self-directed slot; if one ever appeared, stalling
      --  that fiber is recoverable and scribbling on a register file is not.
      if From = To or else not In_Range (From) or else not In_Range (To) then
         return;
      end if;
      Swap (Table (Slot_Index (From))'Address,
            Table (Slot_Index (To))'Address);
   end Switch;

   ---------------------------------------------------------------------------
   --  Stacks
   ---------------------------------------------------------------------------

   --  The largest stack this backend will map.  Machine's arithmetic is
   --  proved over a bounded range, and this body is not proved, so it
   --  enforces the bounds itself rather than assuming its callers do.
   --  Fiber_Stack_Bytes is 64 KiB; 128 MB is room to spare.
   Max_Stack : constant := 2 ** 27;

   function Page_Size return Lay.Page_Bytes is
      P : constant C_Int := Posix.Getpagesize;
   begin
      if P >= C_Int (Lay.Page_Bytes'First)
        and then P <= C_Int (Lay.Page_Bytes'Last)
      then
         return Lay.Page_Bytes (P);
      else
         return Lay.Page_Bytes'First;
      end if;
   end Page_Size;

   function Guard_Size return C_Size is (C_Size (Page_Size));

   --  Whether Size is a stack this backend will handle at all, given Page.
   --  Below four pages there is not enough room for a guard page and a
   --  first frame; above Max_Stack the offset arithmetic leaves the range
   --  Machine proves over.
   function Usable_Size
     (Size : C_Size; Page : Lay.Page_Bytes; Bytes : out Natural)
      return Boolean
   is
   begin
      Bytes := 0;
      if Size < C_Size (4 * Page) or else Size > C_Size (Max_Stack) then
         return False;
      end if;
      Bytes := Lay.Round_Up_Pages (Natural (Size), Page);
      return True;
   end Usable_Size;

   function Stack_Alloc (Size : C_Size) return System.Address is
      Page   : constant Lay.Page_Bytes := Page_Size;
      Usable : Natural;
      Base   : System.Address;
      Status : C_Int;
   begin
      if not Usable_Size (Size, Page, Usable) then
         return System.Null_Address;
      end if;

      --  Usable bytes plus one guard page below them, so a fiber that
      --  overruns its stack takes SIGSEGV instead of silently trampling
      --  the neighbouring mapping.
      Base := Posix.Mmap
        (Addr   => System.Null_Address,
         Length => C_Size (Usable + Page),
         Prot   => Posix.Prot_Read + Posix.Prot_Write,
         Flags  => Posix.Map_Private + Posix.Map_Anonymous,
         Fd     => -1,
         Offset => 0);
      if Base = Posix.Map_Failed then
         return System.Null_Address;
      end if;

      Status := Posix.Mprotect (Base, C_Size (Page), Posix.Prot_None);
      if Status /= 0 then
         Status := Posix.Munmap (Base, C_Size (Usable + Page));
         return System.Null_Address;
      end if;
      return Base;
   end Stack_Alloc;

   procedure Stack_Free (Base : System.Address; Size : C_Size) is
      Page    : constant Lay.Page_Bytes := Page_Size;
      Usable  : Natural;
      Ignored : C_Int;
   begin
      --  A size Stack_Alloc would have refused cannot have come from it,
      --  so there is no mapping of that shape to unmap.  Leaving it alone
      --  leaks address space; unmapping a range computed from a nonsense
      --  size would unmap something else.
      if Base = System.Null_Address
        or else not Usable_Size (Size, Page, Usable)
      then
         return;
      end if;
      Ignored := Posix.Munmap (Base, C_Size (Usable + Page));
   end Stack_Free;

   ---------------------------------------------------------------------------
   --  Prime
   ---------------------------------------------------------------------------

   --  Nothing ever returns through a fiber's entry x30 -- Fiber_Main ends
   --  by switching away, never by returning -- so a branch to this means an
   --  invariant broke, and the value makes that obvious in a debugger.
   --
   --  Where the x86 targets write their sentinel into a return slot on the
   --  stack, this one goes in the context's x30 field: AAPCS64 returns
   --  through the link register, so that is the same place.  It also means
   --  Prime writes nothing to the stack at all.
   Never_Returns : constant Integer_Address := 16#DEAD_DEAD_DEAD_DEAD#;

   procedure Prime
     (Slot : C_Long;
      Base : System.Address;
      Size : C_Size;
      Arg  : C_Long)
   is
      Page       : constant Lay.Page_Bytes := Page_Size;
      Usable     : Natural;
      Sp_Address : System.Address;
   begin
      if Base = System.Null_Address or else not In_Range (Slot) then
         return;
      end if;
      if not Usable_Size (Size, Page, Usable) then
         return;
      end if;

      --  Layout.Entry_Sp_Offset works in offsets from the mapping base and
      --  does its own 16-alignment there, which is the same answer as
      --  aligning the address only if the base is itself 16-aligned.  mmap
      --  returns page-aligned mappings, so it always is; refuse rather than
      --  build a misaligned stack pointer if that ever stops being true.
      --  AArch64 is less forgiving about this than x86: with SCTLR_EL1.SA
      --  set, using a misaligned SP to reach memory faults.
      if To_Integer (Base) mod 16 /= 0 then
         return;
      end if;

      --  Proved of the result: it is 0 modulo 16, which is what AAPCS64
      --  requires of the stack pointer whenever it is used to address
      --  memory; it is above the guard page; and the ABI's reserve above
      --  it -- nil here, AAPCS64 having no red zone -- is inside the
      --  mapping.
      Sp_Address :=
        Base + Storage_Offset
                 (Lay.Entry_Sp_Offset (Page, Usable, Mach.Entry_Reserve));

      Table (Slot_Index (Slot)) :=
        (Pc  => Trampoline'Address,
         Sp  => Sp_Address,
         X19 => Fiber_Main'Address,
         X20 => To_Address (Integer_Address (Arg)),
         X30 => To_Address (Never_Returns),
         X21 | X22 | X23 | X24 | X25 | X26 | X27 | X28 | X29 =>
           System.Null_Address,
         Fpcr => 0,
         D8 | D9 | D10 | D11 | D12 | D13 | D14 | D15 => 0);
   end Prime;

end Iour.Ffi.Fiber;
