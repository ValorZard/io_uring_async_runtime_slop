with Interfaces.C;
with System.Storage_Elements;
with Iour.Ffi.Memory;
with Iour.Ffi.Sys;
with Iour.Ffi.Net;
with Iour.Per_Shard;

package body Iour.Reactor with
  SPARK_Mode    => On,
  Refined_State =>
    (Rings => (Cells,
               Fds.Cells, Sq_Heads.Cells, Sq_Tails.Cells, Sqe_Arrays.Cells,
               Sq_Sizes.Cells, Cq_Heads.Cells, Cq_Tails.Cells,
               Cqe_Arrays.Cells, Cq_Sizes.Cells, Local_Tails.Cells,
               Unsents.Cells, Live_Ops.Cells))
is

   package Uring renames Iour.Ffi.Uring;
   package Sys renames Iour.Ffi.Sys;
   package Net renames Iour.Ffi.Net;
   package Mem renames Iour.Ffi.Memory;

   use System.Storage_Elements;
   use type System.Address;
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   ---------------------------------------------------------------------------
   --  Ring handle
   ---------------------------------------------------------------------------

   type Ring_Handle is record
      Fd : Ffi.C_Int := -1;

      --  Submission side.  Head is written by the kernel and read by us;
      --  tail is the reverse.
      Sq_Head    : System.Address := System.Null_Address;
      Sq_Tail    : System.Address := System.Null_Address;
      Sq_Flags   : System.Address := System.Null_Address;
      Sq_Indices : System.Address := System.Null_Address;
      Sqes       : System.Address := System.Null_Address;
      Sq_Entries : Unsigned_32 := 0;

      --  Completion side.
      Cq_Head    : System.Address := System.Null_Address;
      Cq_Tail    : System.Address := System.Null_Address;
      Cqes       : System.Address := System.Null_Address;
      Cq_Entries : Unsigned_32 := 0;

      --  Our private copy of the tail.  Operations accumulate here and
      --  become visible to the kernel only when Flush publishes it, so a
      --  burst of submissions costs one release store, not one per entry.
      Local_Tail : Unsigned_32 := 0;

      --  Mappings, kept for teardown.
      Sq_Ring_Base : System.Address := System.Null_Address;
      Cq_Ring_Base : System.Address := System.Null_Address;
      Sqes_Base    : System.Address := System.Null_Address;
      Sq_Ring_Size : Ffi.C_Size := 0;
      Cq_Ring_Size : Ffi.C_Size := 0;
      Sqes_Size    : Ffi.C_Size := 0;
      Shared_Map   : Boolean := False;
   end record;

   ---------------------------------------------------------------------------
   --  Ring_Cell -- one shard's ring
   ---------------------------------------------------------------------------

   --  The mapping, kept for teardown.  This lock is taken twice in a
   --  ring's life -- Install at Open, Take at Shut -- and never on the path
   --  an operation follows.
   protected type Ring_Cell
     with Priority => Runtime_Priority
   is
      procedure Install (Handle : Ring_Handle);
      procedure Take (Handle : out Ring_Handle);
   private
      H : Ring_Handle;
   end Ring_Cell;

   Cells : array (Shard_Id) of Ring_Cell;

   --  Everything Push, Flush and Harvest touch, as one atomic cell per
   --  shard (Iour.Per_Shard).  A ring has exactly one submitter and one
   --  reaper, the shard that owns it, so none of this is ever contended;
   --  it used to sit behind the lock above because SPARK needs state that
   --  more than one task can reach to be synchronised, and atomics are the
   --  other way to satisfy that.  Two protected actions per push and four
   --  per scheduler pass become plain loads and stores.
   --
   --  The mapped addresses are held as Integer_Address because a cell has
   --  to be a discrete scalar; To_Address on the way out costs nothing.
   --  The only cross-shard reader is Ring_Descriptor, which wants the fd of
   --  a sibling's ring to message it, and that is written once at Open.
   package Fds         is new Iour.Per_Shard (Ffi.C_Int, -1);
   package Sq_Heads    is new Iour.Per_Shard (Integer_Address, 0);
   package Sq_Tails    is new Iour.Per_Shard (Integer_Address, 0);
   package Sqe_Arrays  is new Iour.Per_Shard (Integer_Address, 0);
   package Sq_Sizes    is new Iour.Per_Shard (Unsigned_32, 0);
   package Cq_Heads    is new Iour.Per_Shard (Integer_Address, 0);
   package Cq_Tails    is new Iour.Per_Shard (Integer_Address, 0);
   package Cqe_Arrays  is new Iour.Per_Shard (Integer_Address, 0);
   package Cq_Sizes    is new Iour.Per_Shard (Unsigned_32, 0);

   --  Our private copy of the submission tail: operations accumulate here
   --  and become visible to the kernel only when Flush publishes it, so a
   --  burst of submissions costs one release store, not one per entry.
   package Local_Tails is new Iour.Per_Shard (Unsigned_32, 0);

   --  Queued but not yet handed to io_uring_enter.
   package Unsents     is new Iour.Per_Shard (Unsigned_32, 0);

   --  Submitted, completion not yet seen.
   package Live_Ops    is new Iour.Per_Shard (Natural, 0);

   ---------------------------------------------------------------------------
   --  Address arithmetic helpers
   ---------------------------------------------------------------------------

   function Offset (Base : System.Address; By : Unsigned_32)
     return System.Address
   is (Base + Storage_Offset (By));

   function As_U64 (Addr : System.Address) return Unsigned_64 is
     (Unsigned_64 (To_Integer (Addr)));

   ---------------------------------------------------------------------------
   --  Token encoding
   ---------------------------------------------------------------------------

   --  Tag in the top eight bits, payload in the low thirty-two.  The gap in
   --  between is left empty so a token is easy to read in a trace.
   Tag_Shift : constant := 56;

   function Encode (Tag : Token_Tag; Payload : Unsigned_32) return Unsigned_64
   is (Shift_Left (Unsigned_64 (Token_Tag'Pos (Tag) + 1), Tag_Shift)
       or Unsigned_64 (Payload));

   procedure Decode
     (Token   : Unsigned_64;
      Tag     : out Token_Tag;
      Payload : out Unsigned_32)
   is
      Code : constant Unsigned_64 := Shift_Right (Token, Tag_Shift);
   begin
      Payload := Unsigned_32 (Token and 16#FFFF_FFFF#);
      if Code >= 1
        and then Code <= Unsigned_64 (Token_Tag'Pos (Token_Tag'Last))
      then
         Tag := Token_Tag'Val (Natural (Code) - 1);
      else
         Tag := Tag_Unknown;
      end if;
   end Decode;

   ---------------------------------------------------------------------------
   --  Operation constructors
   ---------------------------------------------------------------------------

   --  Each mirrors the corresponding io_uring_prep_* helper.  The comments
   --  record which union slot the kernel reads for that opcode, because the
   --  field names in a flattened SQE cannot say it on their own.

   function Op_Nop (Token : Unsigned_64) return Op_Spec is
     (Opcode => Uring.Op_Nop, Token => Token, others => <>);

   function Op_Accept (Fd : Descriptor; Token : Unsigned_64) return Op_Spec is
     --  addr = sockaddr (none), off = addrlen pointer (none), len unused.
     (Opcode => Uring.Op_Accept,
      Fd     => Integer_32 (Fd),
      Token  => Token,
      others => <>);

   function Op_Connect
     (Fd      : Descriptor;
      Address : System.Address;
      Length  : Natural;
      Token   : Unsigned_64) return Op_Spec
   is
     --  addr = sockaddr, off = the address length BY VALUE, not a pointer.
     (Opcode => Uring.Op_Connect,
      Fd     => Integer_32 (Fd),
      Addr   => As_U64 (Address),
      Off    => Unsigned_64 (Length),
      Token  => Token,
      others => <>);

   function Op_Recv
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
   is
     (Opcode => Uring.Op_Recv,
      Fd     => Integer_32 (Fd),
      Addr   => As_U64 (Buffer),
      Length => Unsigned_32 (Length),
      Token  => Token,
      others => <>);

   function Op_Send
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
   is
     --  MSG_NOSIGNAL so a vanished peer is reported as EPIPE on the
     --  completion rather than raised as a signal.
     (Opcode   => Uring.Op_Send,
      Fd       => Integer_32 (Fd),
      Addr     => As_U64 (Buffer),
      Length   => Unsigned_32 (Length),
      Op_Flags => Uring.Msg_Nosignal,
      Token    => Token,
      others   => <>);

   function Op_Write
     (Fd     : Descriptor;
      Buffer : System.Address;
      Length : Natural;
      Token  : Unsigned_64) return Op_Spec
   is
     --  off = -1 means "the file's current position", which is also what a
     --  pipe or terminal wants.
     (Opcode => Uring.Op_Write,
      Fd     => Integer_32 (Fd),
      Addr   => As_U64 (Buffer),
      Off    => Unsigned_64'Last,
      Length => Unsigned_32 (Length),
      Token  => Token,
      others => <>);

   function Op_Close (Fd : Descriptor; Token : Unsigned_64) return Op_Spec is
     (Opcode => Uring.Op_Close,
      Fd     => Integer_32 (Fd),
      Token  => Token,
      others => <>);

   function Op_Timeout
     (Timespec : System.Address; Token : Unsigned_64) return Op_Spec
   is
     --  fd = -1, addr = timespec, len = 1 (one timespec), off = 0 meaning
     --  "do not also wait for N completions".
     (Opcode => Uring.Op_Timeout,
      Fd     => -1,
      Addr   => As_U64 (Timespec),
      Length => 1,
      Token  => Token,
      others => <>);

   function Op_Msg_Ring
     (Target_Ring  : Descriptor;
      Target_Token : Unsigned_64;
      Token        : Unsigned_64) return Op_Spec
   is
     --  fd = the ring being messaged, off = the user_data the target will
     --  see, len = the res the target will see.
     (Opcode => Uring.Op_Msg_Ring,
      Fd     => Integer_32 (Target_Ring),
      Off    => Target_Token,
      Length => 0,
      Token  => Token,
      others => <>);

   ---------------------------------------------------------------------------
   --  The idle timer's timespec
   ---------------------------------------------------------------------------

   --  One constant timespec per backoff level.  Constants because the
   --  kernel only reads them, which sidesteps any question of one shard's
   --  timer racing another's, and because a timeout's timespec has to stay
   --  put until the operation completes.
   type Backoff_Table is
     array (Natural range 0 .. Max_Backoff) of aliased Uring.Kernel_Timespec;

   function Backoff_Nanos (Level : Natural) return Long_Long_Integer is
     (Long_Long_Integer (Idle_Poll_Nanos) * (2 ** Level))
     with Pre  => Level <= Max_Backoff,
          Post => Backoff_Nanos'Result >= 0
                  and then Backoff_Nanos'Result
                           <= Long_Long_Integer (Idle_Poll_Nanos)
                              * (2 ** Max_Backoff);

   Idle_Timespecs : constant Backoff_Table :=
     [for L in 0 .. Max_Backoff =>
        (Seconds     => Integer_64 (Backoff_Nanos (L) / 1_000_000_000),
         Nanoseconds => Integer_64 (Backoff_Nanos (L) mod 1_000_000_000))];


   ---------------------------------------------------------------------------
   --  Ring_Cell body
   ---------------------------------------------------------------------------

   protected body Ring_Cell is

      procedure Install (Handle : Ring_Handle) is
      begin
         H := Handle;
      end Install;

      procedure Take (Handle : out Ring_Handle) is
      begin
         Handle := H;
         H := Ring_Handle'(others => <>);
      end Take;

   end Ring_Cell;

   ---------------------------------------------------------------------------
   --  Ring creation
   ---------------------------------------------------------------------------

   procedure Map_Ring (H : in out Ring_Handle; P : Uring.Params;
                       Status : out Io_Result);

   procedure Map_Ring (H : in out Ring_Handle; P : Uring.Params;
                       Status : out Io_Result)
   is
      Sq_Bytes : Ffi.C_Size :=
        Ffi.C_Size (P.Sq_Off.Array_Offset) + Ffi.C_Size (P.Sq_Entries) * 4;
      Cq_Bytes : constant Ffi.C_Size :=
        Ffi.C_Size (P.Cq_Off.Cqes)
        + Ffi.C_Size (P.Cq_Entries) * (Uring.Cqe'Size / 8);
      Base : System.Address;
   begin
      Status := 0;

      --  With IORING_FEAT_SINGLE_MMAP the kernel places both rings in one
      --  region, so a single mapping of the larger size covers them.
      H.Shared_Map := (P.Features and Uring.Feat_Single_Mmap) /= 0;
      if H.Shared_Map and then Cq_Bytes > Sq_Bytes then
         Sq_Bytes := Cq_Bytes;
      end if;

      Base := Sys.Mmap
        (Addr   => System.Null_Address,
         Length => Sq_Bytes,
         Prot   => Sys.Prot_Read + Sys.Prot_Write,
         Flags  => Sys.Map_Shared + Sys.Map_Populate,
         Fd     => H.Fd,
         Offset => Uring.Off_Sq_Ring);
      if Base = Sys.Map_Failed then
         Status := Sys.Failure_Code;
         return;
      end if;

      H.Sq_Ring_Base := Base;
      H.Sq_Ring_Size := Sq_Bytes;

      if H.Shared_Map then
         H.Cq_Ring_Base := Base;
         H.Cq_Ring_Size := 0;  --  unmapped together with the SQ region
      else
         H.Cq_Ring_Base := Sys.Mmap
           (Addr   => System.Null_Address,
            Length => Cq_Bytes,
            Prot   => Sys.Prot_Read + Sys.Prot_Write,
            Flags  => Sys.Map_Shared + Sys.Map_Populate,
            Fd     => H.Fd,
            Offset => Uring.Off_Cq_Ring);
         if H.Cq_Ring_Base = Sys.Map_Failed then
            Status := Sys.Failure_Code;
            return;
         end if;
         H.Cq_Ring_Size := Cq_Bytes;
      end if;

      H.Sqes_Size := Ffi.C_Size (P.Sq_Entries) * (Uring.Sqe'Size / 8);
      H.Sqes_Base := Sys.Mmap
        (Addr   => System.Null_Address,
         Length => H.Sqes_Size,
         Prot   => Sys.Prot_Read + Sys.Prot_Write,
         Flags  => Sys.Map_Shared + Sys.Map_Populate,
         Fd     => H.Fd,
         Offset => Uring.Off_Sqes);
      if H.Sqes_Base = Sys.Map_Failed then
         Status := Sys.Failure_Code;
         return;
      end if;

      --  Resolve every index the submitter touches from the offsets the
      --  kernel just reported, rather than assuming a struct layout.
      H.Sq_Head    := Offset (H.Sq_Ring_Base, P.Sq_Off.Head);
      H.Sq_Tail    := Offset (H.Sq_Ring_Base, P.Sq_Off.Tail);
      H.Sq_Flags   := Offset (H.Sq_Ring_Base, P.Sq_Off.Flags);
      H.Sq_Indices := Offset (H.Sq_Ring_Base, P.Sq_Off.Array_Offset);
      H.Sqes       := H.Sqes_Base;
      H.Sq_Entries := P.Sq_Entries;

      H.Cq_Head    := Offset (H.Cq_Ring_Base, P.Cq_Off.Head);
      H.Cq_Tail    := Offset (H.Cq_Ring_Base, P.Cq_Off.Tail);
      H.Cqes       := Offset (H.Cq_Ring_Base, P.Cq_Off.Cqes);
      H.Cq_Entries := P.Cq_Entries;

      --  The ring sizes are powers of two and the kernel's masks are
      --  Entries - 1.  The submitter computes its masks from Entries so
      --  SPARK can see every index is in range; here we check the kernel
      --  agrees, and refuse the ring if it does not.
      declare
         Sq_Mask_Addr : constant System.Address :=
           Offset (H.Sq_Ring_Base, P.Sq_Off.Ring_Mask);
         Cq_Mask_Addr : constant System.Address :=
           Offset (H.Cq_Ring_Base, P.Cq_Off.Ring_Mask);
         Sq_Mask : Unsigned_32;
         Cq_Mask : Unsigned_32;
      begin
         if Sq_Mask_Addr = System.Null_Address
           or else Cq_Mask_Addr = System.Null_Address
           or else H.Sq_Tail = System.Null_Address
           or else H.Sq_Indices = System.Null_Address
           or else P.Sq_Entries = 0
           or else P.Cq_Entries = 0
         then
            Status := -E_Invalid;
            return;
         end if;
         Mem.Load_Word (Sq_Mask_Addr, Sq_Mask);
         Mem.Load_Word (Cq_Mask_Addr, Cq_Mask);
         if Sq_Mask /= P.Sq_Entries - 1 or else Cq_Mask /= P.Cq_Entries - 1
         then
            Status := -E_Invalid;
            return;
         end if;

         Mem.Load_Word (H.Sq_Tail, H.Local_Tail);

         --  The submission ring is indirect: the kernel reads an index
         --  array and then the SQE it points at.  Nothing here ever
         --  reorders submissions, so the mapping is the identity and is
         --  written once.
         Mem.Write_Identity_Map (H.Sq_Indices, P.Sq_Entries);
      end;
   end Map_Ring;

   ---------------------------------------------------------------------------
   --  Open
   ---------------------------------------------------------------------------

   procedure Open (Shard : Shard_Id; Status : out Io_Result) is

      --  SINGLE_ISSUER tells the kernel this ring has exactly one
      --  submitting thread, which is true by construction here and lets it
      --  drop internal locking.  CLAMP asks it to reduce an oversized
      --  request rather than refuse it.  A kernel that does not recognise
      --  them fails setup with EINVAL, so fall back rather than refuse to
      --  start.
      Preferred : constant Unsigned_32 :=
        Uring.Setup_Single_Issuer or Uring.Setup_Clamp;

      procedure Try (Flags : Unsigned_32; H : out Ring_Handle;
                     Result : out Io_Result);

      procedure Try (Flags : Unsigned_32; H : out Ring_Handle;
                     Result : out Io_Result)
      is
         P  : aliased Uring.Params;
         Fd : Ffi.C_Int;
      begin
         H := Ring_Handle'(others => <>);
         P.Flags := Flags;

         --  liburing's exported syscall wrappers report failure as a
         --  negated errno in the result, not as -1 plus errno.
         Fd := Uring.Setup (Ffi.C_Unsigned (Ring_Entries), Mem.Of_Params (P));
         if Fd < 0 then
            Result := Io_Result (Fd);
            return;
         end if;

         H.Fd := Fd;
         Map_Ring (H, P, Result);
      end Try;

      H : Ring_Handle;
   begin
      Try (Preferred, H, Status);

      if Status < 0 then
         --  Retry with no optional flags before giving up.
         Try (0, H, Status);
      end if;

      if Status >= 0 then
         Cells (Shard).Install (H);

         --  Publish what the hot path reads.  The fd goes last: it is the
         --  one field a sibling looks at, and a ring with an fd is a ring
         --  that is ready.
         Sq_Heads.Set    (Shard, To_Integer (H.Sq_Head));
         Sq_Tails.Set    (Shard, To_Integer (H.Sq_Tail));
         Sqe_Arrays.Set  (Shard, To_Integer (H.Sqes));
         Sq_Sizes.Set    (Shard, H.Sq_Entries);
         Cq_Heads.Set    (Shard, To_Integer (H.Cq_Head));
         Cq_Tails.Set    (Shard, To_Integer (H.Cq_Tail));
         Cqe_Arrays.Set  (Shard, To_Integer (H.Cqes));
         Cq_Sizes.Set    (Shard, H.Cq_Entries);
         Local_Tails.Set (Shard, H.Local_Tail);
         Unsents.Set     (Shard, 0);
         Live_Ops.Set    (Shard, 0);
         Fds.Set         (Shard, H.Fd);
      end if;
   end Open;

   ---------------------------------------------------------------------------
   --  Shut
   ---------------------------------------------------------------------------

   procedure Shut (Shard : Shard_Id) is
      H : Ring_Handle;
   begin
      --  Retire the ring before unmapping it: fd first, so a sibling that
      --  looks now sees nothing to message, then the addresses, so a push
      --  or harvest that somehow followed would find no ring rather than a
      --  stale mapping.
      Fds.Set        (Shard, -1);
      Sqe_Arrays.Set (Shard, 0);
      Cqe_Arrays.Set (Shard, 0);
      Sq_Heads.Set   (Shard, 0);
      Sq_Tails.Set   (Shard, 0);
      Cq_Heads.Set   (Shard, 0);
      Cq_Tails.Set   (Shard, 0);
      Sq_Sizes.Set   (Shard, 0);
      Cq_Sizes.Set   (Shard, 0);

      Cells (Shard).Take (H);

      if H.Sqes_Base /= System.Null_Address then
         Sys.Unmap (H.Sqes_Base, H.Sqes_Size);
      end if;
      if H.Cq_Ring_Size > 0 and then H.Cq_Ring_Base /= System.Null_Address then
         Sys.Unmap (H.Cq_Ring_Base, H.Cq_Ring_Size);
      end if;
      if H.Sq_Ring_Base /= System.Null_Address then
         Sys.Unmap (H.Sq_Ring_Base, H.Sq_Ring_Size);
      end if;
      if H.Fd >= 0 then
         Net.Close_Quietly (H.Fd);
      end if;
   end Shut;

   ---------------------------------------------------------------------------
   --  Push / Flush / Harvest
   ---------------------------------------------------------------------------

   procedure Push (Shard : Shard_Id; Spec : Op_Spec; Queued : out Boolean)
   is
      Sqes_I     : Integer_Address;
      Head_I     : Integer_Address;
      Sqes       : System.Address;
      Head_Addr  : System.Address;
      Entries    : Unsigned_32;
      Local_Tail : Unsigned_32;
      Head       : Unsigned_32;
      Mask       : Unsigned_32;
      Index      : Unsigned_32;
      Unsent     : Unsigned_32;
      Live       : Natural;
   begin
      Queued := False;

      Sqe_Arrays.Get  (Shard, Sqes_I);
      Sq_Sizes.Get    (Shard, Entries);
      Sq_Heads.Get    (Shard, Head_I);
      Local_Tails.Get (Shard, Local_Tail);
      Sqes      := To_Address (Sqes_I);
      Head_Addr := To_Address (Head_I);

      if Entries = 0
        or else Sqes = System.Null_Address
        or else Head_Addr = System.Null_Address
      then
         return;  --  no ring
      end if;

      --  How many slots the kernel has not yet taken.  Unsigned
      --  subtraction is what makes this correct across the point where the
      --  32-bit counters wrap.  One shard owns this ring, so nothing else
      --  can be pushing meanwhile.
      Mem.Load_Word (Head_Addr, Head);
      if Local_Tail - Head >= Entries then
         return;  --  queue full; the caller flushes and retries
      end if;

      --  The ring size is a power of two, so the mask is Entries - 1.
      --  Computing it here rather than loading the kernel's copy is what
      --  lets SPARK see that Index is inside the ring; Map_Ring checks the
      --  kernel agrees.
      Mask  := Entries - 1;
      Index := Local_Tail and Mask;
      pragma Assert (Index <= Mask);

      --  Every field is set, including the ones this opcode does not use:
      --  a recycled slot still holds the previous operation's bytes, and
      --  the kernel would read them.
      Mem.Write_Sqe
        (Base  => Sqes,
         Count => Entries,
         Index => Index,
         Item  => (Opcode       => Spec.Opcode,
                   Flags        => Spec.Sqe_Flags,
                   Ioprio       => 0,
                   Fd           => Spec.Fd,
                   Off          => Spec.Off,
                   Addr         => Spec.Addr,
                   Len          => Spec.Length,
                   Op_Flags     => Spec.Op_Flags,
                   User_Data    => Spec.Token,
                   Buf_Index    => 0,
                   Personality  => 0,
                   Splice_Fd_In => 0,
                   Addr3        => 0,
                   Pad2         => 0));

      Local_Tails.Set (Shard, Local_Tail + 1);
      Unsents.Get (Shard, Unsent);
      Unsents.Set (Shard, Unsent + 1);
      Live_Ops.Get (Shard, Live);
      if Live < Natural'Last then
         Live_Ops.Set (Shard, Live + 1);
      end if;
      Queued := True;
   end Push;

   procedure Flush
     (Shard    : Shard_Id;
      Wait_For : Natural;
      Status   : out Io_Result)
   is
      Fd        : Ffi.C_Int;
      To_Submit : Unsigned_32;
      Tail_I    : Integer_Address;
      Tail_Addr : System.Address;
      Tail      : Unsigned_32;
      Flags     : Unsigned_32 := 0;
      Result    : Ffi.C_Int;
      Taken     : Unsigned_32;
   begin
      Fds.Get         (Shard, Fd);
      Unsents.Get     (Shard, To_Submit);
      Sq_Tails.Get    (Shard, Tail_I);
      Local_Tails.Get (Shard, Tail);
      Tail_Addr := To_Address (Tail_I);

      if Tail_Addr /= System.Null_Address then
         --  Release store: everything written into the SQEs must be
         --  visible to the kernel before it sees the new tail.
         Mem.Store_Word (Tail_Addr, Tail);
      end if;

      if Fd < 0 then
         Status := -E_Again;
         return;
      end if;

      if Wait_For > 0 then
         Flags := Flags or Uring.Enter_Getevents;
      elsif To_Submit = 0 then
         Status := 0;
         return;  --  nothing queued and nothing to wait for
      end if;

      --  The one system call on the hot path, and the only place a shard
      --  sleeps.
      Result := Uring.Enter
        (Fd           => Ffi.C_Unsigned (Fd),
         To_Submit    => Ffi.C_Unsigned (To_Submit),
         Min_Complete => Ffi.C_Unsigned (Wait_For),
         Flags        => Ffi.C_Unsigned (Flags),
         Sig          => System.Null_Address);

      if Result > 0 then
         --  Account for what the kernel actually accepted.  A short submit
         --  leaves the remainder queued for next time.
         Taken := Unsigned_32 (Result);
         Unsents.Set (Shard, (if Taken >= To_Submit then 0
                              else To_Submit - Taken));
      end if;

      Status := Io_Result (Result);
   end Flush;

   procedure Flush_Quietly (Shard : Shard_Id) is
      Status : Io_Result;
   begin
      pragma Warnings
        (GNATprove, Off, "*""Status"" is set by ""Flush"" but not used*",
         Reason => "Discarding the status is this procedure's purpose;"
                   & " the shard loop is where flush failures are counted.");
      Flush (Shard, 0, Status);
      pragma Warnings
        (GNATprove, On, "*""Status"" is set by ""Flush"" but not used*");
   end Flush_Quietly;

   procedure Harvest
     (Shard : Shard_Id;
      Batch : out Completion_Batch;
      Count : out Natural)
   is
      Cqes_I    : Integer_Address;
      Head_I    : Integer_Address;
      Tail_I    : Integer_Address;
      Cqes      : System.Address;
      Entries   : Unsigned_32;
      Head_Addr : System.Address;
      Tail_Addr : System.Address;
      Head      : Unsigned_32;
      Tail      : Unsigned_32;
      Mask      : Unsigned_32;
      N         : Natural range 0 .. Reap_Batch := 0;
      E         : Uring.Cqe;
      Live      : Natural;
   begin
      Batch := [others => (others => <>)];
      Count := 0;

      Cqe_Arrays.Get (Shard, Cqes_I);
      Cq_Sizes.Get   (Shard, Entries);
      Cq_Heads.Get   (Shard, Head_I);
      Cq_Tails.Get   (Shard, Tail_I);
      Cqes      := To_Address (Cqes_I);
      Head_Addr := To_Address (Head_I);
      Tail_Addr := To_Address (Tail_I);

      if Entries = 0
        or else Cqes = System.Null_Address
        or else Head_Addr = System.Null_Address
        or else Tail_Addr = System.Null_Address
      then
         return;  --  no ring
      end if;

      Mem.Load_Word (Head_Addr, Head);
      --  Acquire load: the entries the kernel wrote must be visible before
      --  we read them.
      Mem.Load_Word (Tail_Addr, Tail);
      Mask := Entries - 1;

      while Head /= Tail and then N < Reap_Batch loop
         pragma Loop_Variant (Increases => N);
         pragma Assert ((Head and Mask) <= Mask);
         Mem.Read_Cqe
           (Base  => Cqes,
            Count => Entries,
            Index => Head and Mask,
            Item  => E);
         Batch (N) := (Token => E.User_Data,
                       Res   => Io_Result (E.Res),
                       Flags => E.Flags);
         Head := Head + 1;
         N := N + 1;
      end loop;

      if N > 0 then
         --  Release the slots in one store rather than one per entry.
         Mem.Store_Word (Head_Addr, Head);
         Live_Ops.Get (Shard, Live);
         Live_Ops.Set (Shard, (if Live > N then Live - N else 0));
      end if;

      Count := N;
   end Harvest;

   procedure In_Flight (Shard : Shard_Id; Count : out Natural) is
   begin
      Live_Ops.Get (Shard, Count);
   end In_Flight;

   procedure Ring_Descriptor (Shard : Shard_Id; Fd : out Descriptor) is
      Raw : Ffi.C_Int;
   begin
      Fds.Get (Shard, Raw);
      Fd := (if Raw < 0 then Invalid_Descriptor else Descriptor (Raw));
   end Ring_Descriptor;

   ---------------------------------------------------------------------------
   --  Arm_Idle_Timer
   ---------------------------------------------------------------------------

   procedure Arm_Idle_Timer
     (Shard : Shard_Id; Level : Natural := 0)
   is
      Step   : constant Natural :=
        (if Level > Max_Backoff then Max_Backoff else Level);
      Queued : Boolean;
   begin
      pragma Warnings
        (GNATprove, Off, "*""Queued"" is set by ""Push"" but not used*",
         Reason => "If the queue is full, submissions are pending, and"
                   & " their completions will wake the shard instead.");
      Push (Shard,
            Op_Timeout (Mem.Of_Timespec (Idle_Timespecs (Step)),
                        Encode (Tag_Timer, Unsigned_32 (Step))),
            Queued);
      pragma Warnings
        (GNATprove, On, "*""Queued"" is set by ""Push"" but not used*");
   end Arm_Idle_Timer;

end Iour.Reactor;
