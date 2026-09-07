------------------------------------------------------------------------------
--  Iour.Ffi.Fiber body, x86-64 Windows.
--
--  The same shape as the SysV body next door, against the same spec, and
--  different in the three ways the Win64 ABI is different.
--
--    More registers are callee-saved.  RDI and RSI are scratch on Linux and
--    preserved here, and XMM6 through XMM15 are preserved as well -- a
--    hundred and sixty bytes of them.  A switch that dropped those would
--    corrupt any fiber that was in the middle of floating-point or
--    vectorised code, which on a modern compiler includes memcpy.
--
--    The thread has stack bounds recorded in its TEB, and things consult
--    them: stack-probe sequences the compiler inserts for large frames,
--    and the unwinder if an exception is ever raised.  A fiber runs on a
--    stack the thread's TEB knows nothing about, so the switch moves those
--    three fields across with the registers.  This is what boost.context
--    does on the same platform, and for the same reason.
--
--    There is no red zone, and there is a shadow store.  A Win64 function
--    may write thirty-two bytes above its return address without asking,
--    to spill the four register arguments, so Prime leaves that room.
--
--  Everything else follows minicoro exactly as the SysV body does:
--  registers go in a context buffer rather than on the stack, a
--  two-instruction trampoline receives the entry point in r12 and its
--  argument in r13, and the initial stack carries a dummy return address so
--  the entry sees the alignment a call would have left.
--
--  Still a SPARK_Mode => Off body, for the same irreducible reasons as the
--  SysV one.  What is no longer here is everything that could be said in
--  SPARK about this switch: the twenty-five machine locations it owns,
--  their offsets, the instruction sequence as data, the register-file
--  exchange the sequence performs, and the arithmetic that places a
--  fiber's first frame inside its mapping and clear of its guard page have
--  all moved into Iour.Ffi.Fiber.Machine, which is proved.  The
--  representation clause below takes its offsets from there, Swap and
--  Trampoline hand it their templates, and Machine.Emitted_Matches_Model
--  -- which Iour.Fibers runs before it lets a shard start -- proves those
--  templates are the rendering of the proved instruction sequence.  Read
--  that package's header for why.
------------------------------------------------------------------------------

with System.Machine_Code;    use System.Machine_Code;
with System.Storage_Elements; use System.Storage_Elements;
with Interfaces;
with Iour.Ffi.Sys;
with Iour.Ffi.Win32;
with Iour.Ffi.Fiber.Machine;
with Iour.Ffi.Fiber.Layout;

package body Iour.Ffi.Fiber with SPARK_Mode => Off is

   package Win  renames Iour.Ffi.Win32;
   package Mach renames Iour.Ffi.Fiber.Machine;
   package Lay  renames Iour.Ffi.Fiber.Layout;

   use type System.Address;
   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Interfaces.C.size_t;
   use type Interfaces.Unsigned_32;

   ---------------------------------------------------------------------------
   --  Context
   ---------------------------------------------------------------------------

   --  The byte offsets in Swap depend on this order.  Rip first because the
   --  switch ends with an indirect jump through it; the vector registers
   --  last because they are sixteen bytes each and want the alignment.
   type Xmm_Register is array (0 .. Mach.Xmm_Bytes - 1) of
     Interfaces.Unsigned_8
     with Alignment => 16, Size => Mach.Xmm_Bytes * 8;

   --  XMM6 through XMM15, the ten the Win64 ABI makes callee-saved.
   type Xmm_File is array (Mach.First_Xmm .. Mach.Last_Xmm) of Xmm_Register
     with Convention => C;

   --  The offsets are Machine's named numbers, not literals: the same
   --  numbers Machine.Offset_Of returns, and therefore the same numbers
   --  that appear in the emitted instructions.  Pad is the two bytes that
   --  carry the x87 control word up to the vector registers' sixteen-byte
   --  alignment; Machine's layout lemma is what says it is in no
   --  location's range.
   type Context is record
      Rip           : System.Address := System.Null_Address;
      Rsp           : System.Address := System.Null_Address;
      Rbp           : System.Address := System.Null_Address;
      Rbx           : System.Address := System.Null_Address;
      R12           : System.Address := System.Null_Address;
      R13           : System.Address := System.Null_Address;
      R14           : System.Address := System.Null_Address;
      R15           : System.Address := System.Null_Address;
      Rdi           : System.Address := System.Null_Address;
      Rsi           : System.Address := System.Null_Address;

      --  TEB: StackBase, StackLimit, DeallocationStack.
      Stack_Base    : System.Address := System.Null_Address;
      Stack_Limit   : System.Address := System.Null_Address;
      Dealloc_Stack : System.Address := System.Null_Address;

      Mxcsr         : Interfaces.Unsigned_32 := 16#0000_1F80#;
      Fpu_Cw        : Interfaces.Unsigned_16 := 16#0000_027F#;
      Pad           : Interfaces.Unsigned_16 := 0;

      Xmm           : Xmm_File := [others => [others => 0]];
   end record
     with Convention => C, Alignment => 16;

   for Context use record
      Rip           at Mach.Off_Rip           range 0 .. 63;
      Rsp           at Mach.Off_Rsp           range 0 .. 63;
      Rbp           at Mach.Off_Rbp           range 0 .. 63;
      Rbx           at Mach.Off_Rbx           range 0 .. 63;
      R12           at Mach.Off_R12           range 0 .. 63;
      R13           at Mach.Off_R13           range 0 .. 63;
      R14           at Mach.Off_R14           range 0 .. 63;
      R15           at Mach.Off_R15           range 0 .. 63;
      Rdi           at Mach.Off_Rdi           range 0 .. 63;
      Rsi           at Mach.Off_Rsi           range 0 .. 63;
      Stack_Base    at Mach.Off_Stack_Base    range 0 .. 63;
      Stack_Limit   at Mach.Off_Stack_Limit   range 0 .. 63;
      Dealloc_Stack at Mach.Off_Dealloc_Stack range 0 .. 63;
      Mxcsr         at Mach.Off_Mxcsr         range 0 .. 31;
      Fpu_Cw        at Mach.Off_Fpu_Cw        range 0 .. 15;
      Pad           at Mach.Off_Pad           range 0 .. 15;
      Xmm           at Mach.Off_Xmm
        range 0 .. (Mach.Last_Xmm - Mach.First_Xmm + 1)
                   * Mach.Xmm_Bytes * 8 - 1;
   end record;

   pragma Compile_Time_Error
     (Context'Size /= Mach.Context_Bytes * 8,
      "the Win64 fiber context must be Machine.Context_Bytes bytes");

   ---------------------------------------------------------------------------
   --  The slot table: one context per fiber, one per shard scheduler
   ---------------------------------------------------------------------------

   Slot_Capacity : constant := Max_Fibers + Max_Shards;
   type Slot_Index is range 0 .. Slot_Capacity - 1;
   type Context_Table is array (Slot_Index) of aliased Context
     with Convention => C;

   --  Static, so there is nothing to allocate and nothing that can fail at
   --  run time.  About 2 MB at the default sizes -- more than the SysV
   --  table, because the vector registers are most of a context here.
   Table : Context_Table;

   function In_Range (Slot : C_Long) return Boolean is
     (Slot >= 0 and then Slot <= C_Long (Slot_Index'Last));

   function Reserve (Slots : C_Long) return C_Int is
     (if Slots > 0 and then Slots <= C_Long (Slot_Capacity) then 0 else -1);

   function Slot_Count return C_Long is (C_Long (Slot_Capacity));

   ---------------------------------------------------------------------------
   --  Swap
   ---------------------------------------------------------------------------

   --  Naked: GCC emits no prologue or epilogue, so the template below is
   --  the entire function and the stack pointer is exactly what the caller
   --  left.  From arrives in rcx and To in rdx, per the Win64 convention,
   --  which is what Machine renders its displacements against.
   --
   --  The template is Machine.Switch_Template because GNAT requires an Asm
   --  template to be a static string and a rendered one would not be.  That
   --  is the one place where the emitted code is a written-out string
   --  rather than a computed one, and Machine.Emitted_Matches_Model is what
   --  closes it: it walks the proved instruction sequence -- fifty-nine
   --  instructions here, against the SysV switch's nineteen -- and compares
   --  the rendering with this constant, character for character.
   procedure Swap (From : System.Address; To : System.Address)
     with Convention => C;
   pragma Machine_Attribute (Swap, "naked");

   procedure Swap (From : System.Address; To : System.Address) is
      pragma Unreferenced (From, To);
   begin
      Asm (Mach.Switch_Template, Volatile => True);
   end Swap;

   ---------------------------------------------------------------------------
   --  Trampoline
   ---------------------------------------------------------------------------

   --  A freshly primed context has this as its rip, the entry point in r12
   --  and the argument in r13.  Move the argument into the first-parameter
   --  register -- rcx here, where SysV uses rdi -- and jump.  A jump rather
   --  than a call, so the entry sees the stack exactly as Prime laid it
   --  out: return slot on top, shadow store above it, which is the ABI's
   --  post-call state.
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

   function Page_Size return Lay.Page_Bytes is
      P : constant Natural := Ffi.Sys.Page_Size;
   begin
      if P in Lay.Page_Bytes then
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
      Page    : constant Lay.Page_Bytes := Page_Size;
      Usable  : Natural;
      Base     : System.Address;
      Previous : aliased Win.Dword := 0;
      Ok       : Win.Bool;
      Ignored  : Win.Bool;
   begin
      if not Usable_Size (Size, Page, Usable) then
         return System.Null_Address;
      end if;

      --  Usable bytes plus one guard page below them.  VirtualAlloc
      --  reserves on the 64 KiB granularity and commits on the page, and
      --  Windows only backs a committed page when it is first touched, so
      --  this is the same lazy mapping the SysV body gets from mmap.
      Base := Win.Virtual_Alloc
        (Address => System.Null_Address,
         Size    => C_Size (Usable + Page),
         Kind    => Win.Mem_Reserve + Win.Mem_Commit,
         Protect => Win.Page_Readwrite);
      if Base = System.Null_Address then
         return System.Null_Address;
      end if;

      --  The guard.  PAGE_NOACCESS rather than PAGE_GUARD: a guard page
      --  arms once and then becomes ordinary memory, which would let the
      --  second overrun through silently.  This one faults every time.
      Ok := Win.Virtual_Protect
        (Address  => Base,
         Size     => C_Size (Page),
         Protect  => Win.Page_Noaccess,
         Previous => Previous'Access);
      if Ok = 0 then
         Ignored := Win.Virtual_Free (Base, 0, Win.Mem_Release);
         return System.Null_Address;
      end if;
      return Base;
   end Stack_Alloc;

   procedure Stack_Free (Base : System.Address; Size : C_Size) is
      pragma Unreferenced (Size);
      Ignored : Win.Bool;
   begin
      if Base = System.Null_Address then
         return;
      end if;
      --  MEM_RELEASE frees the whole reservation, which is why the size
      --  has to be zero and the address has to be the one VirtualAlloc
      --  returned.
      Ignored := Win.Virtual_Free (Base, 0, Win.Mem_Release);
   end Stack_Free;

   ---------------------------------------------------------------------------
   --  Prime
   ---------------------------------------------------------------------------

   procedure Prime
     (Slot : C_Long;
      Base : System.Address;
      Size : C_Size;
      Arg  : C_Long)
   is
      Page   : constant Lay.Page_Bytes := Page_Size;
      Usable : Natural;
      Limit  : System.Address;
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
      --  aligning the address only if the base is itself 16-aligned.
      --  VirtualAlloc reserves on the 64 KiB granularity, so it always is;
      --  refuse rather than build a misaligned frame if that ever stops
      --  being true.
      if To_Integer (Base) mod 16 /= 0 then
         return;
      end if;

      --  Usable region starts one guard page above the mapping base.
      Limit := Base + Storage_Offset (Page);

      --  Proved of the result: it is 8 modulo 16, which is the alignment a
      --  call leaves and the entry point is entitled to; it is above the
      --  guard page, so this write cannot touch it; and the shadow store
      --  above it -- the thirty-two bytes a Win64 function may use to
      --  spill its four register arguments without allocating them -- is
      --  inside the mapping.
      Slot_Address :=
        Base + Storage_Offset
                 (Lay.Return_Slot_Offset (Page, Usable, Mach.Entry_Reserve));

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
        (Rip           => Trampoline'Address,
         Rsp           => Slot_Address,
         R12           => Fiber_Main'Address,
         R13           => To_Address (Integer_Address (Arg)),
         Rbp | Rbx | R14 | R15 | Rdi | Rsi => System.Null_Address,

         --  The bounds the TEB will carry while this fiber is on the core.
         --  Base is where the whole reservation starts, which is what
         --  DeallocationStack means; Limit is the lowest byte the fiber may
         --  touch, which is the first page above the guard.
         Stack_Base    => Limit + Storage_Offset (Usable),
         Stack_Limit   => Limit,
         Dealloc_Stack => Base,

         --  The ABI's initial control words.  A fiber starts with round to
         --  nearest, all exceptions masked, and extended precision -- the
         --  state the C runtime sets up for a thread.
         Mxcsr         => 16#0000_1F80#,
         Fpu_Cw        => 16#0000_027F#,
         Pad           => 0,
         Xmm           => [others => [others => 0]]);
   end Prime;

end Iour.Ffi.Fiber;
