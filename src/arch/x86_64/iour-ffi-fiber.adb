------------------------------------------------------------------------------
--  Iour.Ffi.Fiber body, x86-64 SysV.
--
--  The one SPARK_Mode => Off body in the runtime.  Two things here are
--  outside SPARK by nature: taking the address of a context slot to hand it
--  to the switch, and writing the dummy return address through a computed
--  stack address.  Everything else about fibers -- who runs, when, on which
--  shard -- is decided in Iour.Fibers, which is proved.
--
--  Structure follows minicoro's x86-64 backend closely enough to be checked
--  against it side by side: _mco_ctxbuf is Context, _mco_switch is Swap,
--  _mco_wrap_main is Trampoline, _mco_makectx is Prime.
------------------------------------------------------------------------------

with System.Machine_Code;    use System.Machine_Code;
with System.Storage_Elements; use System.Storage_Elements;
with Interfaces;
with Iour.Ffi.Sys;

package body Iour.Ffi.Fiber with SPARK_Mode => Off is

   use type System.Address;
   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Interfaces.C.size_t;

   LF : constant String := "" & ASCII.LF;

   ---------------------------------------------------------------------------
   --  Context: minicoro's _mco_ctxbuf, field for field
   ---------------------------------------------------------------------------

   --  The byte offsets in Swap depend on this order.  Rip first because the
   --  switch ends with an indirect jump through it.
   type Context is record
      Rip : System.Address := System.Null_Address;   --   0
      Rsp : System.Address := System.Null_Address;   --   8
      Rbp : System.Address := System.Null_Address;   --  16
      Rbx : System.Address := System.Null_Address;   --  24
      R12 : System.Address := System.Null_Address;   --  32
      R13 : System.Address := System.Null_Address;   --  40
      R14 : System.Address := System.Null_Address;   --  48
      R15 : System.Address := System.Null_Address;   --  56
   end record
     with Convention => C, Size => 64 * 8;

   for Context use record
      Rip at  0 range 0 .. 63;
      Rsp at  8 range 0 .. 63;
      Rbp at 16 range 0 .. 63;
      Rbx at 24 range 0 .. 63;
      R12 at 32 range 0 .. 63;
      R13 at 40 range 0 .. 63;
      R14 at 48 range 0 .. 63;
      R15 at 56 range 0 .. 63;
   end record;

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

   --  Naked: GCC emits no prologue or epilogue, so the Asm below is the
   --  entire function and the stack pointer is exactly what the caller left.
   --  From arrives in rdi and To in rsi, per the C convention.
   --
   --  Save the resume address (the label after the jump), then the stack
   --  pointer and the six callee-saved registers, into From.  Load the same
   --  eight from To, and jump through To's saved rip.  The `ret` at the
   --  label is what a context resumes into, and it returns to whoever
   --  called Swap on that context, exactly as if Swap had just returned.
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
      Asm ("leaq 1f(%%rip), %%rax"    & LF &
           "movq %%rax,  0(%%rdi)"    & LF &
           "movq %%rsp,  8(%%rdi)"    & LF &
           "movq %%rbp, 16(%%rdi)"    & LF &
           "movq %%rbx, 24(%%rdi)"    & LF &
           "movq %%r12, 32(%%rdi)"    & LF &
           "movq %%r13, 40(%%rdi)"    & LF &
           "movq %%r14, 48(%%rdi)"    & LF &
           "movq %%r15, 56(%%rdi)"    & LF &
           "movq 56(%%rsi), %%r15"    & LF &
           "movq 48(%%rsi), %%r14"    & LF &
           "movq 40(%%rsi), %%r13"    & LF &
           "movq 32(%%rsi), %%r12"    & LF &
           "movq 24(%%rsi), %%rbx"    & LF &
           "movq 16(%%rsi), %%rbp"    & LF &
           "movq  8(%%rsi), %%rsp"    & LF &
           "jmpq *0(%%rsi)"           & LF &
           "1:"                       & LF &
           "ret",
           Volatile => True);
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
      Asm ("movq %%r13, %%rdi" & LF &
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
      P : constant C_Int := Sys.Getpagesize;
   begin
      return (if P > 0 then Storage_Count (P) else 4096);
   end Page_Size;

   function Guard_Size return C_Size is (C_Size (Page_Size));

   function Round_Up (Bytes : Storage_Count; To : Storage_Count)
     return Storage_Count
   is ((Bytes + To - 1) / To * To);

   function Stack_Alloc (Size : C_Size) return System.Address is
      Page   : constant Storage_Count := Page_Size;
      Usable : constant Storage_Count := Round_Up (Storage_Count (Size), Page);
      Base   : System.Address;
      Status : C_Int;
   begin
      if Storage_Count (Size) < 4 * Page then
         return System.Null_Address;
      end if;

      --  Usable bytes plus one guard page below them.  minicoro's VMEM
      --  allocator maps the region the same way; the guard is our addition,
      --  so a fiber that overruns its stack takes SIGSEGV instead of
      --  silently trampling the neighbouring mapping.
      Base := Sys.Mmap
        (Addr   => System.Null_Address,
         Length => C_Size (Usable + Page),
         Prot   => Sys.Prot_Read + Sys.Prot_Write,
         Flags  => Sys.Map_Private + Sys.Map_Anonymous,
         Fd     => -1,
         Offset => 0);
      if Base = Sys.Map_Failed then
         return System.Null_Address;
      end if;

      Status := Sys.Mprotect (Base, C_Size (Page), Sys.Prot_None);
      if Status /= 0 then
         Status := Sys.Munmap (Base, C_Size (Usable + Page));
         return System.Null_Address;
      end if;
      return Base;
   end Stack_Alloc;

   procedure Stack_Free (Base : System.Address; Size : C_Size) is
      Page    : constant Storage_Count := Page_Size;
      Usable  : constant Storage_Count := Round_Up (Storage_Count (Size), Page);
      Ignored : C_Int;
   begin
      if Base = System.Null_Address then
         return;
      end if;
      Ignored := Sys.Munmap (Base, C_Size (Usable + Page));
   end Stack_Free;

   ---------------------------------------------------------------------------
   --  Prime: minicoro's _mco_makectx
   ---------------------------------------------------------------------------

   --  SysV reserves 128 bytes above the stack pointer as a red zone that a
   --  leaf function may use without adjusting rsp.  Leave it, as minicoro
   --  does, so the first frame never runs off the top of the mapping.
   Red_Zone : constant Storage_Count := 128;

   procedure Prime
     (Slot : C_Long;
      Base : System.Address;
      Size : C_Size;
      Arg  : C_Long)
   is
      Page   : constant Storage_Count := Page_Size;
      Usable : constant Storage_Count := Round_Up (Storage_Count (Size), Page);
      Top    : System.Address;
      Slot_Address : System.Address;
   begin
      if Base = System.Null_Address or else not In_Range (Slot) then
         return;
      end if;

      --  Usable region starts one guard page above the mapping base.  Align
      --  its top to 16, step back over the red zone, and place the dummy
      --  return address in the 8 bytes below that.  With rsp pointing at
      --  it, the entry sees rsp = 8 mod 16, which is what a call leaves.
      Top := Base + Page + Usable;
      Top := To_Address (To_Integer (Top) and not 15);
      Top := Top - Red_Zone;
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
        (Rip => Trampoline'Address,
         Rsp => Slot_Address,
         R12 => Fiber_Main'Address,
         R13 => To_Address (Integer_Address (Arg)),
         Rbp | Rbx | R14 | R15 => System.Null_Address);
   end Prime;

end Iour.Ffi.Fiber;
