------------------------------------------------------------------------------
--  Iour.Ffi.Fiber body, x86-64 SysV.
--
--  Still a SPARK_Mode => Off body, and for the same irreducible reasons:
--  inline Asm in naked subprograms is not analysable code, the switch needs
--  the address of a context slot, and priming a stack writes through a
--  computed address.  What changed is how little else is left here.
--
--  Everything that could be said in SPARK about this switch has moved into
--  Iour.Ffi.Fiber.Machine, which is proved: the set of machine locations
--  the switch owns, their offsets, the instruction sequence as data, the
--  register-file exchange the sequence performs, and the arithmetic that
--  places a fiber's first frame inside its mapping and clear of its guard
--  page.  Read that package's header for why it is shaped the way it is;
--  the two papers behind it are Rutter 1981 and Crary 2003.
--
--  So the three constants this body used to own outright are gone:
--
--    the offsets    the representation clause below takes them from
--                   Machine, which is also where the emitted displacements
--                   come from, so a slot cannot move in one and not the
--                   other;
--    the assembly   Swap and Trampoline hand Machine's templates to Asm
--                   rather than spelling instructions out here, and
--                   Machine.Emitted_Matches_Model proves those templates
--                   are the rendering of the proved instruction sequence.
--                   Iour.Fibers runs that check during elaboration and
--                   refuses to start a shard if it fails;
--    the stack sums the alignment, the red zone and the guard-page
--                   clearance are Machine.Return_Slot_Offset's
--                   postcondition rather than three lines of pointer
--                   arithmetic and a comment.
--
--  Structure still follows minicoro's x86-64 backend closely enough to be
--  checked against it side by side: _mco_ctxbuf is Context, _mco_switch is
--  Swap, _mco_wrap_main is Trampoline, _mco_makectx is Prime.
------------------------------------------------------------------------------

with System.Machine_Code;    use System.Machine_Code;
with System.Storage_Elements; use System.Storage_Elements;
with Interfaces;
with Iour.Ffi.Posix;
with Iour.Ffi.Fiber.Machine;

package body Iour.Ffi.Fiber with SPARK_Mode => Off is

   package Posix renames Iour.Ffi.Posix;
   package Mach renames Iour.Ffi.Fiber.Machine;

   use type System.Address;
   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Interfaces.C.size_t;

   ---------------------------------------------------------------------------
   --  Context: minicoro's _mco_ctxbuf, field for field
   ---------------------------------------------------------------------------

   --  Rip first because the switch ends with an indirect jump through it.
   --  The offsets are Machine's named numbers, not literals: the same
   --  numbers Machine.Offset_Of returns, and therefore the same numbers
   --  that appear in the emitted instructions.
   type Context is record
      Rip : System.Address := System.Null_Address;
      Rsp : System.Address := System.Null_Address;
      Rbp : System.Address := System.Null_Address;
      Rbx : System.Address := System.Null_Address;
      R12 : System.Address := System.Null_Address;
      R13 : System.Address := System.Null_Address;
      R14 : System.Address := System.Null_Address;
      R15 : System.Address := System.Null_Address;
   end record
     with Convention => C;

   for Context use record
      Rip at Mach.Off_Rip range 0 .. 63;
      Rsp at Mach.Off_Rsp range 0 .. 63;
      Rbp at Mach.Off_Rbp range 0 .. 63;
      Rbx at Mach.Off_Rbx range 0 .. 63;
      R12 at Mach.Off_R12 range 0 .. 63;
      R13 at Mach.Off_R13 range 0 .. 63;
      R14 at Mach.Off_R14 range 0 .. 63;
      R15 at Mach.Off_R15 range 0 .. 63;
   end record;

   pragma Compile_Time_Error
     (Context'Size /= Mach.Context_Bytes * 8,
      "the SysV fiber context must be Machine.Context_Bytes bytes");

   ---------------------------------------------------------------------------
   --  The slot table: one context per fiber, one per shard scheduler
   ---------------------------------------------------------------------------

   Slot_Capacity : constant := Max_Fibers + Max_Shards;
   type Slot_Index is range 0 .. Slot_Capacity - 1;
   type Context_Table is array (Slot_Index) of aliased Context
     with Convention => C;

   --  Static, so there is nothing to allocate and nothing that can fail at
   --  run time.  About 256 KB at the default sizes.
   Table : Context_Table;

   function In_Range (Slot : C_Long) return Boolean is
     (Slot >= 0 and then Slot <= C_Long (Slot_Index'Last));

   function Reserve (Slots : C_Long) return C_Int is
     (if Slots > 0 and then Slots <= C_Long (Slot_Capacity) then 0 else -1);

   function Slot_Count return C_Long is (C_Long (Slot_Capacity));

   ---------------------------------------------------------------------------
   --  Swap: minicoro's _mco_switch
   ---------------------------------------------------------------------------

   --  Naked: GCC emits no prologue or epilogue, so the template below is
   --  the entire function and the stack pointer is exactly what the caller
   --  left.  From arrives in rdi and To in rsi, per the C convention, which
   --  is what Machine renders its displacements against.
   --
   --  The template is Machine.Switch_Template because GNAT requires an Asm
   --  template to be a static string and a rendered one would not be.  That
   --  is the one place where the emitted code is a written-out string
   --  rather than a computed one, and Machine.Emitted_Matches_Model is what
   --  closes it: it walks the proved instruction sequence and compares the
   --  rendering with this constant, character for character.
   --
   --  minicoro computes the resume address as `leaq 0x3d(%rip)`, a
   --  hand-counted offset; a local label says the same thing without the
   --  arithmetic.
   procedure Swap (From : System.Address; To : System.Address)
     with Convention => C;
   pragma Machine_Attribute (Swap, "naked");

   procedure Swap (From : System.Address; To : System.Address) is
      pragma Unreferenced (From, To);
   begin
      Asm (Mach.Switch_Template, Volatile => True);
   end Swap;

   ---------------------------------------------------------------------------
   --  Trampoline: minicoro's _mco_wrap_main
   ---------------------------------------------------------------------------

   --  A freshly primed context has this as its rip, the entry point in r12
   --  and the argument in r13.  Move the argument into the first-parameter
   --  register and jump.  A jump rather than a call, so the entry sees the
   --  stack exactly as Prime laid it out: return slot on top, 16-byte
   --  aligned just above it, which is the ABI's post-call state.
   procedure Trampoline
     with Convention => C;
   pragma Machine_Attribute (Trampoline, "naked");

   procedure Trampoline is
   begin
      Asm (Mach.Trampoline_Template, Volatile => True);
   end Trampoline;

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

   function Page_Size return Mach.Page_Bytes is
      P : constant C_Int := Posix.Getpagesize;
   begin
      if P >= C_Int (Mach.Page_Bytes'First)
        and then P <= C_Int (Mach.Page_Bytes'Last)
      then
         return Mach.Page_Bytes (P);
      else
         return Mach.Page_Bytes'First;
      end if;
   end Page_Size;

   function Guard_Size return C_Size is (C_Size (Page_Size));

   --  Whether Size is a stack this backend will handle at all, given Page.
   --  Below four pages there is not enough room for a guard page and a
   --  first frame; above Max_Stack the offset arithmetic leaves the range
   --  Machine proves over.
   function Usable_Size
     (Size : C_Size; Page : Mach.Page_Bytes; Bytes : out Natural)
      return Boolean
   is
   begin
      Bytes := 0;
      if Size < C_Size (4 * Page) or else Size > C_Size (Max_Stack) then
         return False;
      end if;
      Bytes := Mach.Round_Up_Pages (Natural (Size), Page);
      return True;
   end Usable_Size;

   function Stack_Alloc (Size : C_Size) return System.Address is
      Page   : constant Mach.Page_Bytes := Page_Size;
      Usable : Natural;
      Base   : System.Address;
      Status : C_Int;
   begin
      if not Usable_Size (Size, Page, Usable) then
         return System.Null_Address;
      end if;

      --  Usable bytes plus one guard page below them.  minicoro's VMEM
      --  allocator maps the region the same way; the guard is our addition,
      --  so a fiber that overruns its stack takes SIGSEGV instead of
      --  silently trampling the neighbouring mapping.
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
      Page    : constant Mach.Page_Bytes := Page_Size;
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
   --  Prime: minicoro's _mco_makectx
   ---------------------------------------------------------------------------

   procedure Prime
     (Slot : C_Long;
      Base : System.Address;
      Size : C_Size;
      Arg  : C_Long)
   is
      Page   : constant Mach.Page_Bytes := Page_Size;
      Usable : Natural;
      Slot_Address : System.Address;
   begin
      if Base = System.Null_Address or else not In_Range (Slot) then
         return;
      end if;
      if not Usable_Size (Size, Page, Usable) then
         return;
      end if;

      --  Machine.Return_Slot_Offset works in offsets from the mapping base
      --  and does its own 16-alignment there, which is the same answer as
      --  aligning the address only if the base is itself 16-aligned.  mmap
      --  returns page-aligned mappings, so it always is; refuse rather
      --  than build a misaligned frame if that ever stops being true.
      if To_Integer (Base) mod 16 /= 0 then
         return;
      end if;

      --  Proved of the result: it is 8 modulo 16, which is the alignment a
      --  call leaves and the entry point is entitled to; it is above the
      --  guard page, so this write cannot touch it; and the red zone above
      --  it is inside the mapping.
      Slot_Address :=
        Base + Storage_Offset (Mach.Return_Slot_Offset (Page, Usable));

      declare
         --  Written through a computed address; this is one of the two
         --  reasons this body is not in SPARK.
         Return_Slot : Interfaces.Unsigned_64
           with Import, Address => Slot_Address;
      begin
         --  minicoro's sentinel.  Nothing ever returns to it -- Fiber_Main
         --  ends by switching away, never by returning -- so a jump here
         --  means an invariant broke, and this value makes that obvious in
         --  a debugger.
         Return_Slot := 16#DEAD_DEAD_DEAD_DEAD#;
      end;

      Table (Slot_Index (Slot)) :=
        (Rip => Trampoline'Address,
         Rsp => Slot_Address,
         R12 => Fiber_Main'Address,
         R13 => To_Address (Integer_Address (Arg)),
         Rbp | Rbx | R14 | R15 => System.Null_Address);
   end Prime;

end Iour.Ffi.Fiber;
