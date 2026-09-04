------------------------------------------------------------------------------
--  Iour.Ffi.Uring -- io_uring's kernel ABI, expressed in Ada.
--
--  Almost all of liburing is `static inline` in <liburing.h>: every
--  io_uring_prep_*, io_uring_sqe_set_data, io_uring_cq_advance and friends
--  compile into the caller and export no symbol, so there is nothing for an
--  Ada Import to bind to.  What they manipulate, though, is not liburing's
--  own data -- it is the kernel's UAPI (include/uapi/linux/io_uring.h):
--  struct io_uring_sqe, struct io_uring_cqe and struct io_uring_params are
--  frozen ABI that the kernel can never change, exactly like sockaddr_in.
--
--  So this package mirrors those three structures and binds the two entry
--  points liburing does export as real symbols, io_uring_setup and
--  io_uring_enter.  Everything above -- claiming a submission slot, filling
--  in an operation, publishing the tail, harvesting completions -- is then
--  ordinary Ada in Iour.Reactor, where SPARK can see it.
--
--  Deliberately NOT mirrored: struct io_uring itself.  That one is
--  liburing's private bookkeeping, it is not UAPI, and its layout has
--  changed between releases.  Iour.Reactor maps the rings from the offsets
--  io_uring_setup reports and never needs it.
--
--  The layouts below are asserted against the C headers by
--  tests/abi_check.c, which fails the build if a field ever moves.
------------------------------------------------------------------------------

with Interfaces; use Interfaces;
with System;

package Iour.Ffi.Uring with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  Ring offset descriptors, filled in by io_uring_setup
   ---------------------------------------------------------------------------

   --  Byte offsets, within the mapped submission ring, of each field the
   --  submitter has to touch.  Reading them from the kernel rather than
   --  assuming a layout is what makes the mapping version-proof.
   type Sqring_Offsets is record
      Head         : Unsigned_32 := 0;
      Tail         : Unsigned_32 := 0;
      Ring_Mask    : Unsigned_32 := 0;
      Ring_Entries : Unsigned_32 := 0;
      Flags        : Unsigned_32 := 0;
      Dropped      : Unsigned_32 := 0;
      Array_Offset : Unsigned_32 := 0;
      Resv1        : Unsigned_32 := 0;
      User_Addr    : Unsigned_64 := 0;
   end record
     with Convention => C;

   type Cqring_Offsets is record
      Head         : Unsigned_32 := 0;
      Tail         : Unsigned_32 := 0;
      Ring_Mask    : Unsigned_32 := 0;
      Ring_Entries : Unsigned_32 := 0;
      Overflow     : Unsigned_32 := 0;
      Cqes         : Unsigned_32 := 0;
      Flags        : Unsigned_32 := 0;
      Resv1        : Unsigned_32 := 0;
      User_Addr    : Unsigned_64 := 0;
   end record
     with Convention => C;

   type Reserved_Words is array (0 .. 2) of Unsigned_32
     with Convention => C;

   type Params is record
      Sq_Entries     : Unsigned_32 := 0;
      Cq_Entries     : Unsigned_32 := 0;
      Flags          : Unsigned_32 := 0;
      Sq_Thread_Cpu  : Unsigned_32 := 0;
      Sq_Thread_Idle : Unsigned_32 := 0;
      Features       : Unsigned_32 := 0;
      Wq_Fd          : Unsigned_32 := 0;
      Resv           : Reserved_Words := [others => 0];
      Sq_Off         : Sqring_Offsets := (others => <>);
      Cq_Off         : Cqring_Offsets := (others => <>);
   end record
     with Convention => C;

   ---------------------------------------------------------------------------
   --  Submission and completion entries
   ---------------------------------------------------------------------------

   --  struct io_uring_sqe is a 64-byte record whose middle fields are a
   --  stack of unions, each opcode using them differently.  Rather than
   --  model unions, this mirrors the storage and names each slot after its
   --  dominant use; Iour.Reactor documents which opcode reads which slot.
   type Sqe is record
      Opcode       : Unsigned_8;   --   0  IORING_OP_*
      Flags        : Unsigned_8;   --   1  IOSQE_*
      Ioprio       : Unsigned_16;  --   2
      Fd           : Integer_32;   --   4  file descriptor operated on
      Off          : Unsigned_64;  --   8  file offset, or addr2, or msg data
      Addr         : Unsigned_64;  --  16  buffer, or sockaddr, or timespec
      Len          : Unsigned_32;  --  24  byte count, or msg len
      Op_Flags     : Unsigned_32;  --  28  per-opcode flags (msg_flags, ...)
      User_Data    : Unsigned_64;  --  32  echoed back in the completion
      Buf_Index    : Unsigned_16;  --  40
      Personality  : Unsigned_16;  --  42
      Splice_Fd_In : Integer_32;   --  44  also file_index / msg_ring target
      Addr3        : Unsigned_64;  --  48
      Pad2         : Unsigned_64;  --  56
   end record
     with Convention => C, Size => 64 * 8;

   for Sqe use record
      Opcode       at  0 range 0 ..  7;
      Flags        at  1 range 0 ..  7;
      Ioprio       at  2 range 0 .. 15;
      Fd           at  4 range 0 .. 31;
      Off          at  8 range 0 .. 63;
      Addr         at 16 range 0 .. 63;
      Len          at 24 range 0 .. 31;
      Op_Flags     at 28 range 0 .. 31;
      User_Data    at 32 range 0 .. 63;
      Buf_Index    at 40 range 0 .. 15;
      Personality  at 42 range 0 .. 15;
      Splice_Fd_In at 44 range 0 .. 31;
      Addr3        at 48 range 0 .. 63;
      Pad2         at 56 range 0 .. 63;
   end record;

   type Cqe is record
      User_Data : Unsigned_64;  --  0  the token from the matching Sqe
      Res       : Integer_32;   --  8  >= 0 value, < 0 negated errno
      Flags     : Unsigned_32;  -- 12  IORING_CQE_F_*
   end record
     with Convention => C, Size => 16 * 8;

   for Cqe use record
      User_Data at 0 range 0 .. 63;
      Res       at 8 range 0 .. 31;
      Flags     at 12 range 0 .. 31;
   end record;

   --  Unconstrained overlays used to address the mapped rings.
   type Sqe_Array is array (Unsigned_32 range <>) of Sqe
     with Convention => C;
   type Cqe_Array is array (Unsigned_32 range <>) of Cqe
     with Convention => C;
   type Index_Array is array (Unsigned_32 range <>) of Unsigned_32
     with Convention => C;

   ---------------------------------------------------------------------------
   --  Constants (verified against the headers by tests/abi_check.c)
   ---------------------------------------------------------------------------

   --  Opcodes
   Op_Nop          : constant := 0;
   Op_Timeout      : constant := 11;
   Op_Accept       : constant := 13;
   Op_Connect  : constant := 16;
   Op_Close    : constant := 19;
   Op_Write    : constant := 23;
   Op_Send     : constant := 26;
   Op_Recv     : constant := 27;
   Op_Msg_Ring : constant := 40;

   --  mmap offsets identifying which region to map
   Off_Sq_Ring : constant := 0;
   Off_Cq_Ring : constant := 16#800_0000#;
   Off_Sqes    : constant := 16#1000_0000#;

   --  io_uring_setup flags
   Setup_Sqpoll        : constant := 2;
   Setup_Clamp         : constant := 16;
   Setup_Coop_Taskrun  : constant := 256;
   Setup_Single_Issuer : constant := 4096;
   Setup_Defer_Taskrun : constant := 8192;

   --  io_uring_setup feature reports
   Feat_Single_Mmap : constant := 1;
   Feat_Nodrop      : constant := 2;

   --  io_uring_enter flags
   Enter_Getevents : constant := 1;

   --  Submission ring flags, read from the kernel's side of the ring
   Sq_Need_Wakeup : constant := 1;

   --  Per-Sqe flags
   Sqe_Fixed_File       : constant := 1;
   Sqe_Cqe_Skip_Success : constant := 64;

   --  Sqe.Splice_Fd_In doubles as file_index.  Zero means "not a fixed
   --  slot"; N + 1 names slot N; all ones asks the kernel to pick a free
   --  slot and report it as the result.
   File_Index_Alloc : constant Integer_32 := -1;

   --  Completion flags
   Cqe_F_More : constant := 2;

   --  io_uring_register opcodes
   Register_Files        : constant := 2;
   Register_Files_Update : constant := 6;

   --  Socket-level flag for send: report a dead peer as EPIPE, never SIGPIPE
   Msg_Nosignal : constant := 16#4000#;

   ---------------------------------------------------------------------------
   --  The two liburing entry points that are real symbols
   ---------------------------------------------------------------------------

   --  Create a ring and report its geometry.  Returns the ring descriptor,
   --  or a negative value on failure.
   function Setup (Entries : C_Unsigned; P : System.Address) return C_Int
     with Import, Convention => C, External_Name => "io_uring_setup",
          Global => null;

   --  Hand queued submissions to the kernel and optionally wait for
   --  completions.  This is the only system call on the hot path.
   function Enter
     (Fd           : C_Unsigned;
      To_Submit    : C_Unsigned;
      Min_Complete : C_Unsigned;
      Flags        : C_Unsigned;
      Sig          : System.Address) return C_Int
     with Import, Convention => C, External_Name => "io_uring_enter",
          Global => null;

   --  Register a resource -- a file table, a buffer ring -- with a ring.
   --  Must be called from the ring's issuing thread once SINGLE_ISSUER is
   --  in force, which for this runtime means from the owning shard.
   --
   --  Unlike Setup and Enter above, this one declares its effect on
   --  Kernel.  It has to: a registration is a change to what the kernel
   --  holds on this ring's behalf that outlives the call, and the callers
   --  below are contracted as making it.  Side_Effects is the price --
   --  such a function may only be called as the right-hand side of an
   --  assignment.
   function Register
     (Fd     : C_Unsigned;
      Opcode : C_Unsigned;
      Arg    : System.Address;
      Nr     : C_Unsigned) return C_Int
     with Import, Convention => C, External_Name => "io_uring_register",
          Side_Effects, Global => (In_Out => Kernel), Always_Terminates;

   ---------------------------------------------------------------------------
   --  Registered files
   ---------------------------------------------------------------------------

   --  The table handed to IORING_REGISTER_FILES.  An entry of -1 is a
   --  sparse slot: reserved in the kernel's table, holding nothing yet,
   --  which is what accept-direct fills in.
   type Fd_Table is array (Natural range <>) of Integer_32
     with Convention => C;

   --  struct io_uring_files_update, for IORING_REGISTER_FILES_UPDATE.
   type Files_Update is record
      Offset : Unsigned_32 := 0;   --  first slot to replace
      Resv   : Unsigned_32 := 0;
      Fds    : Unsigned_64 := 0;   --  pointer to the replacement fds
   end record
     with Convention => C, Size => 16 * 8;

   ---------------------------------------------------------------------------
   --  Kernel timespec, for relative timeouts
   ---------------------------------------------------------------------------

   type Kernel_Timespec is record
      Seconds     : Integer_64;
      Nanoseconds : Integer_64;
   end record
     with Convention => C, Size => 16 * 8;

   ---------------------------------------------------------------------------
   --  Layout assertions
   ---------------------------------------------------------------------------

   pragma Compile_Time_Error
     (Sqe'Size /= 64 * 8, "struct io_uring_sqe must be 64 bytes");
   pragma Compile_Time_Error
     (Cqe'Size /= 16 * 8, "struct io_uring_cqe must be 16 bytes");
   pragma Compile_Time_Error
     (Params'Size /= 120 * 8, "struct io_uring_params must be 120 bytes");
   pragma Compile_Time_Error
     (Files_Update'Size /= 16 * 8,
      "struct io_uring_files_update must be 16 bytes");

end Iour.Ffi.Uring;
