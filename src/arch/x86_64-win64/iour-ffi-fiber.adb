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
------------------------------------------------------------------------------

with System.Machine_Code;    use System.Machine_Code;
with System.Storage_Elements; use System.Storage_Elements;
with Interfaces;
with Iour.Ffi.Sys;
with Iour.Ffi.Win32;

package body Iour.Ffi.Fiber with SPARK_Mode => Off is

   package Win renames Iour.Ffi.Win32;

   use type System.Address;
   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Interfaces.C.size_t;
   use type Interfaces.Unsigned_32;

   LF : constant String := "" & ASCII.LF;

   ---------------------------------------------------------------------------
   --  Context
   ---------------------------------------------------------------------------

   --  The byte offsets in Swap depend on this order.  Rip first because the
   --  switch ends with an indirect jump through it; the vector registers
   --  last because they are sixteen bytes each and want the alignment.
   type Xmm_Register is array (0 .. 15) of Interfaces.Unsigned_8
     with Alignment => 16, Size => 128;

   --  XMM6 through XMM15, the ten the Win64 ABI makes callee-saved.
   type Xmm_File is array (6 .. 15) of Xmm_Register
     with Convention => C;

   type Context is record
      Rip           : System.Address := System.Null_Address;   --   0
      Rsp           : System.Address := System.Null_Address;   --   8
      Rbp           : System.Address := System.Null_Address;   --  16
      Rbx           : System.Address := System.Null_Address;   --  24
      R12           : System.Address := System.Null_Address;   --  32
      R13           : System.Address := System.Null_Address;   --  40
      R14           : System.Address := System.Null_Address;   --  48
      R15           : System.Address := System.Null_Address;   --  56
      Rdi           : System.Address := System.Null_Address;   --  64
      Rsi           : System.Address := System.Null_Address;   --  72

      --  TEB: StackBase, StackLimit, DeallocationStack.
      Stack_Base    : System.Address := System.Null_Address;   --  80
      Stack_Limit   : System.Address := System.Null_Address;   --  88
      Dealloc_Stack : System.Address := System.Null_Address;   --  96

      Mxcsr         : Interfaces.Unsigned_32 := 16#0000_1F80#; -- 104
      Fpu_Cw        : Interfaces.Unsigned_16 := 16#0000_027F#; -- 108
      Pad           : Interfaces.Unsigned_16 := 0;             -- 110

      Xmm           : Xmm_File := [others => [others => 0]];    -- 112
   end record
     with Convention => C, Alignment => 16;

   for Context use record
      Rip           at   0 range 0 .. 63;
      Rsp           at   8 range 0 .. 63;
      Rbp           at  16 range 0 .. 63;
      Rbx           at  24 range 0 .. 63;
      R12           at  32 range 0 .. 63;
      R13           at  40 range 0 .. 63;
      R14           at  48 range 0 .. 63;
      R15           at  56 range 0 .. 63;
      Rdi           at  64 range 0 .. 63;
      Rsi           at  72 range 0 .. 63;
      Stack_Base    at  80 range 0 .. 63;
      Stack_Limit   at  88 range 0 .. 63;
      Dealloc_Stack at  96 range 0 .. 63;
      Mxcsr         at 104 range 0 .. 31;
      Fpu_Cw        at 108 range 0 .. 15;
      Pad           at 110 range 0 .. 15;
      Xmm           at 112 range 0 .. 10 * 128 - 1;
   end record;

   Context_Bytes : constant := 272;

   pragma Compile_Time_Error
     (Context'Size /= Context_Bytes * 8,
      "the Win64 fiber context must be 272 bytes");

   ---------------------------------------------------------------------------
   --  TEB offsets
   ---------------------------------------------------------------------------

   --  NT_TIB.StackBase, NT_TIB.StackLimit and TEB.DeallocationStack, at the
   --  offsets Windows has used on x86-64 since the platform existed.  They
   --  are reached through gs, which is where the TEB lives in 64-bit user
   --  mode.
   Teb_Stack_Base    : constant String := "0x08";
   Teb_Stack_Limit   : constant String := "0x10";
   Teb_Dealloc_Stack : constant String := "0x1478";

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

   --  Naked: GCC emits no prologue or epilogue, so the Asm below is the
   --  entire function and the stack pointer is exactly what the caller
   --  left.  From arrives in rcx and To in rdx, per the Win64 convention.
   --
   --  Save the resume address (the label after the jump), then the stack
   --  pointer, the callee-saved registers, the TEB stack bounds and the
   --  two control words, into From.  Load the same from To, and jump
   --  through To's saved rip.  The `ret` at the label is what a context
   --  resumes into, and it returns to whoever called Swap on that context,
   --  exactly as if Swap had just returned.
   procedure Swap (From : System.Address; To : System.Address)
     with Convention => C;
   pragma Machine_Attribute (Swap, "naked");

   procedure Swap (From : System.Address; To : System.Address) is
      pragma Unreferenced (From, To);
   begin
      Asm
        (--  Outgoing context -> (%rcx)
         "leaq 1f(%%rip), %%rax"                        & LF &
         "movq %%rax,   0(%%rcx)"                       & LF &
         "movq %%rsp,   8(%%rcx)"                       & LF &
         "movq %%rbp,  16(%%rcx)"                       & LF &
         "movq %%rbx,  24(%%rcx)"                       & LF &
         "movq %%r12,  32(%%rcx)"                       & LF &
         "movq %%r13,  40(%%rcx)"                       & LF &
         "movq %%r14,  48(%%rcx)"                       & LF &
         "movq %%r15,  56(%%rcx)"                       & LF &
         "movq %%rdi,  64(%%rcx)"                       & LF &
         "movq %%rsi,  72(%%rcx)"                       & LF &
         "movq %%gs:" & Teb_Stack_Base & ", %%rax"      & LF &
         "movq %%rax,  80(%%rcx)"                       & LF &
         "movq %%gs:" & Teb_Stack_Limit & ", %%rax"     & LF &
         "movq %%rax,  88(%%rcx)"                       & LF &
         "movq %%gs:" & Teb_Dealloc_Stack & ", %%rax"   & LF &
         "movq %%rax,  96(%%rcx)"                       & LF &
         "stmxcsr     104(%%rcx)"                       & LF &
         "fnstcw      108(%%rcx)"                       & LF &
         "movaps %%xmm6,  112(%%rcx)"                   & LF &
         "movaps %%xmm7,  128(%%rcx)"                   & LF &
         "movaps %%xmm8,  144(%%rcx)"                   & LF &
         "movaps %%xmm9,  160(%%rcx)"                   & LF &
         "movaps %%xmm10, 176(%%rcx)"                   & LF &
         "movaps %%xmm11, 192(%%rcx)"                   & LF &
         "movaps %%xmm12, 208(%%rcx)"                   & LF &
         "movaps %%xmm13, 224(%%rcx)"                   & LF &
         "movaps %%xmm14, 240(%%rcx)"                   & LF &
         "movaps %%xmm15, 256(%%rcx)"                   & LF &

         --  Incoming context <- (%rdx)
         "movaps 256(%%rdx), %%xmm15"                   & LF &
         "movaps 240(%%rdx), %%xmm14"                   & LF &
         "movaps 224(%%rdx), %%xmm13"                   & LF &
         "movaps 208(%%rdx), %%xmm12"                   & LF &
         "movaps 192(%%rdx), %%xmm11"                   & LF &
         "movaps 176(%%rdx), %%xmm10"                   & LF &
         "movaps 160(%%rdx), %%xmm9"                    & LF &
         "movaps 144(%%rdx), %%xmm8"                    & LF &
         "movaps 128(%%rdx), %%xmm7"                    & LF &
         "movaps 112(%%rdx), %%xmm6"                    & LF &
         "fldcw       108(%%rdx)"                       & LF &
         "ldmxcsr     104(%%rdx)"                       & LF &
         "movq  96(%%rdx), %%rax"                       & LF &
         "movq %%rax, %%gs:" & Teb_Dealloc_Stack        & LF &
         "movq  88(%%rdx), %%rax"                       & LF &
         "movq %%rax, %%gs:" & Teb_Stack_Limit          & LF &
         "movq  80(%%rdx), %%rax"                       & LF &
         "movq %%rax, %%gs:" & Teb_Stack_Base           & LF &
         "movq  72(%%rdx), %%rsi"                       & LF &
         "movq  64(%%rdx), %%rdi"                       & LF &
         "movq  56(%%rdx), %%r15"                       & LF &
         "movq  48(%%rdx), %%r14"                       & LF &
         "movq  40(%%rdx), %%r13"                       & LF &
         "movq  32(%%rdx), %%r12"                       & LF &
         "movq  24(%%rdx), %%rbx"                       & LF &
         "movq  16(%%rdx), %%rbp"                       & LF &
         "movq   8(%%rdx), %%rsp"                       & LF &
         "jmpq *0(%%rdx)"                               & LF &
         "1:"                                           & LF &
         "ret",
         Volatile => True);
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
      Asm ("movq %%r13, %%rcx" & LF &
           "jmpq *%%r12",
           Volatile => True);
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

   function Page_Size return Storage_Count is
     (Storage_Count (Ffi.Sys.Page_Size));

   function Guard_Size return C_Size is (C_Size (Page_Size));

   function Round_Up (Bytes : Storage_Count; To : Storage_Count)
     return Storage_Count
   is ((Bytes + To - 1) / To * To);

   function Stack_Alloc (Size : C_Size) return System.Address is
      Page    : constant Storage_Count := Page_Size;
      Usable  : constant Storage_Count :=
        Round_Up (Storage_Count (Size), Page);
      Base     : System.Address;
      Previous : aliased Win.Dword := 0;
      Ok       : Win.Bool;
      Ignored  : Win.Bool;
   begin
      if Storage_Count (Size) < 4 * Page then
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

   --  Win64 has no red zone, but it does have a shadow store: a function
   --  may write the thirty-two bytes above its return address to spill its
   --  four register arguments, without allocating them.  The entry point
   --  is entitled to that, so leave it.
   Shadow_Store : constant Storage_Count := 32;

   procedure Prime
     (Slot : C_Long;
      Base : System.Address;
      Size : C_Size;
      Arg  : C_Long)
   is
      Page   : constant Storage_Count := Page_Size;
      Usable : constant Storage_Count := Round_Up (Storage_Count (Size), Page);
      Top    : System.Address;
      Limit  : System.Address;
      Slot_Address : System.Address;
   begin
      if Base = System.Null_Address or else not In_Range (Slot) then
         return;
      end if;

      --  Usable region starts one guard page above the mapping base.
      Limit := Base + Page;
      Top   := Limit + Usable;
      Top   := To_Address (To_Integer (Top) and not 15);

      --  Shadow store, then the dummy return address in the eight bytes
      --  below it.  With rsp pointing at that, the entry sees rsp = 8 mod
      --  16 and thirty-two bytes of scratch above it, which is exactly
      --  what a call would have left.
      Top := Top - Shadow_Store;
      Slot_Address := Top - 8;

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
         Stack_Base    => Limit + Usable,
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
