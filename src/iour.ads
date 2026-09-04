------------------------------------------------------------------------------
--  Iour -- an io_uring async runtime for Ada 2022 / SPARK, on Jorvik.
--
--  Shape of the system, top down:
--
--    * A fixed set of library-level Ada tasks ("shards"), each pinned to one
--      CPU core by a static CPU aspect.  Jorvik forbids dynamic CPU
--      assignment and task hierarchies, so the shards are single task
--      declarations in Iour.Shards, not an array of task objects.
--
--    * Each shard owns one io_uring instance.  Nothing about a ring is
--      shared: only the shard that created a ring ever submits to it or
--      reaps from it, which is what lets the design use
--      IORING_SETUP_SINGLE_ISSUER and avoid submission locking entirely.
--
--    * Work is carried by stackful fibers.  A fiber has its own stack, so
--      Await is an ordinary function call that happens to suspend: when it
--      cannot make progress it switches the CPU to another fiber and
--      returns later, exactly where it left off.  No async colouring, no
--      continuation-passing, no state machines.
--
--    * Futures live in a global, shard-agnostic table.  Any shard can
--      resolve any future, and the shard that owns the waiting fiber is
--      woken through the ring-to-ring message path (IORING_OP_MSG_RING).
--
--    * Newly spawned fibers go onto one globally accessible run queue that
--      every shard pops from, so load spreads across cores on its own.
--
--  All handles in this runtime are small integers indexing statically sized
--  tables.  That is deliberate: it keeps the whole runtime free of access
--  types and dynamic allocation, which is what makes SPARK analysis of a
--  concurrent system like this tractable.
------------------------------------------------------------------------------

with System;

package Iour with SPARK_Mode => On is

   ---------------------------------------------------------------------------
   --  Tunables
   ---------------------------------------------------------------------------

   --  Upper bound on shards.  Iour.Shards declares exactly this many task
   --  declarations, because Jorvik requires each one's CPU to be static.
   Max_Shards : constant := 8;

   --  Shards that actually run the event loop.  The remainder park forever.
   --  Must be in 1 .. Max_Shards.
   Shard_Count : constant := 4;

   --  Ada CPU number (1-based; Linux CPU 0 is Ada CPU 1) that shard 0 is
   --  pinned to.  Shard N takes First_Shard_Cpu + N.  Leaving CPU 1 free
   --  keeps the environment task, which does startup and teardown, off the
   --  shard cores.
   First_Shard_Cpu : constant := 2;

   --  Concurrent fibers.  Each live fiber costs one stack (allocated lazily,
   --  then recycled), so this bounds memory rather than reserving it.
   --
   --  A connection holds one for its whole life, so this is the real cap on
   --  simultaneous connections -- and it has to be read together with how
   --  fast the runtime accepts.  At 5000 offered connections the older,
   --  slower accept path kept fewer than 4096 alive at any instant and so
   --  fitted under half this; accepting straight into a registered file
   --  slot is quick enough that all 5000 are now live together, and a
   --  table of 4096 would turn the surplus away.  Raising the bound costs
   --  address space, not memory: stacks are mapped on first use.
   Max_Fibers : constant := 8192;

   --  Concurrent unresolved futures.  A fiber in the middle of a read holds
   --  one; budget for a few per fiber.
   Max_Futures : constant := 16384;

   --  Usable bytes per fiber stack, on top of a guard page.  This is what
   --  bounds memory once thousands of connections are live: every
   --  concurrent fiber holds one stack, so 2000 connections at 64 KiB cost
   --  128 MB of address space.  Stacks are mapped lazily and never handed
   --  back while the runtime runs, so the real figure is the high-water
   --  mark, not Max_Fibers.  Fiber bodies must keep their locals modest --
   --  this is not a growable stack, though it does have a guard page, so an
   --  overrun faults rather than corrupting a neighbour.
   Fiber_Stack_Bytes : constant := 64 * 1024;

   --  Submission queue depth per ring.
   Ring_Entries : constant := 4096;

   --  Completions copied out of a ring per harvest.
   Reap_Batch : constant := 256;

   --  How long an idle shard sleeps before re-checking the global run queue.
   --  Shard-to-shard handoffs are signalled immediately over MSG_RING; this
   --  bound only covers work published by a thread that owns no ring, such
   --  as the environment task during startup.
   Idle_Poll_Nanos : constant := 1_000_000;  --  1 ms

   --  The one priority in the partition.  Every shard task runs at it, and
   --  every protected object in the runtime declares it as its ceiling.
   --
   --  That equality is not cosmetic.  Jorvik mandates Ceiling_Locking, so a
   --  protected action must run at the object's ceiling priority; GNAT
   --  implements the change with sched_setscheduler, and a protected object
   --  left to its default ceiling of System.Priority'Last therefore costs
   --  two system calls per protected action -- around seventy per network
   --  round trip once the future, the ring cell, the ready queue and the
   --  fiber pool have each been entered and left.  When the ceiling already
   --  equals the caller's active priority there is nothing to change and
   --  the calls disappear.
   --
   --  The constraint this buys the speed with: any task that calls into the
   --  runtime must run at this priority.  A higher-priority caller is a
   --  ceiling violation, which is Program_Error at the call, not a subtle
   --  corruption -- and gnatprove rejects it ahead of that.
   Runtime_Priority : constant System.Priority := System.Default_Priority;

   ---------------------------------------------------------------------------
   --  Handles
   ---------------------------------------------------------------------------

   --  Every handle type is an integer range whose lowest value is a "none"
   --  sentinel, with a subtype covering the valid slots.  Passing the ref
   --  type where a slot is required is then a proof obligation, not a
   --  runtime surprise.

   type Shard_Ref is range -1 .. Max_Shards - 1;
   subtype Shard_Id is Shard_Ref range 0 .. Max_Shards - 1;
   subtype Active_Shard is Shard_Id range 0 .. Shard_Count - 1;
   No_Shard : constant Shard_Ref := -1;

   type Fiber_Ref is range -1 .. Max_Fibers - 1;
   subtype Fiber_Id is Fiber_Ref range 0 .. Max_Fibers - 1;
   No_Fiber : constant Fiber_Ref := -1;

   type Future_Ref is range -1 .. Max_Futures - 1;
   subtype Future_Id is Future_Ref range 0 .. Max_Futures - 1;
   No_Future : constant Future_Ref := -1;

   ---------------------------------------------------------------------------
   --  Descriptors and buffers
   ---------------------------------------------------------------------------

   type Descriptor is range -1 .. 2 ** 31 - 1;
   Invalid_Descriptor : constant Descriptor := -1;

   --  A descriptor is either a process-wide file descriptor or a slot in
   --  one shard's registered file table.  The kernel keeps a registered
   --  file pinned for the life of the slot, so an operation on it skips the
   --  descriptor-table lookup and reference count that an ordinary fd
   --  costs on every submission.  The slot only means something on the
   --  ring that registered it, so the shard is part of the name: a fixed
   --  file is Fixed_File_Base + Shard * Fixed_File_Span + Slot, a range no
   --  real fd reaches.
   Fixed_File_Base : constant := 2 ** 30;
   Fixed_File_Span : constant := 2 ** 20;
   subtype File_Slot is Natural range 0 .. Fixed_File_Span - 1;

   function Is_Fixed_File (D : Descriptor) return Boolean is
     (D >= Fixed_File_Base);

   function Fixed_File (Shard : Shard_Id; Slot : File_Slot) return Descriptor
   is (Descriptor (Fixed_File_Base
                   + Integer (Shard) * Fixed_File_Span + Slot))
     with Post => Is_Fixed_File (Fixed_File'Result);

   function Fixed_File_Shard (D : Descriptor) return Shard_Id is
     (Shard_Id ((Integer (D) - Fixed_File_Base) / Fixed_File_Span))
     with Pre => Is_Fixed_File (D)
                 and then Integer (D) - Fixed_File_Base
                          < Max_Shards * Fixed_File_Span;

   function Fixed_File_Slot (D : Descriptor) return File_Slot is
     ((Integer (D) - Fixed_File_Base) mod Fixed_File_Span)
     with Pre => Is_Fixed_File (D);

   pragma Compile_Time_Error
     (Fixed_File_Base + Max_Shards * Fixed_File_Span > Descriptor'Last,
      "fixed-file descriptors must fit below Descriptor'Last");

   --  Largest buffer one operation accepts.  io_uring carries a 32-bit
   --  length; this stays comfortably inside it and inside Natural, so the
   --  conversions along the way are provable rather than checked.
   Max_Transfer : constant := 2 ** 30;

   type Byte is mod 2 ** 8 with Size => 8;
   type Byte_Array is array (Natural range <>) of Byte
     with Component_Size => 8;

   ---------------------------------------------------------------------------
   --  Operation results
   ---------------------------------------------------------------------------

   --  io_uring reports every completion in one signed integer: at or above
   --  zero it is the operation's value (bytes transferred, accepted
   --  descriptor); below zero it is the negated errno.  The runtime carries
   --  that convention through unchanged rather than inventing a status type,
   --  so nothing is lost in translation.
   subtype Io_Result is Integer;

   function Failed (R : Io_Result) return Boolean is (R < 0);
   function Succeeded (R : Io_Result) return Boolean is (R >= 0);

   --  "No completion result": the one value the kernel never reports (see
   --  Errno below), used where a resumption carries no result of its own --
   --  a wakeup for a future, a yield -- so a fiber that was waiting for a
   --  completion can tell the two apart.
   No_Result : constant Io_Result := Io_Result'First;

   --  The guard on Io_Result'First is not hypothetical bookkeeping: negating
   --  it would overflow.  The kernel never reports it, so the branch is
   --  unreachable in practice, but leaving it out would make this function
   --  partial.
   function Errno (R : Io_Result) return Natural is
     (if R >= 0 then 0
      elsif R = Io_Result'First then Natural'Last
      else -R)
     with Post => (if R >= 0 then Errno'Result = 0);

   --  The handful of errno values the runtime reasons about by name.
   E_Intr        : constant := 4;
   E_Invalid     : constant := 22;
   E_Again       : constant := 11;
   E_Pipe        : constant := 32;
   E_Time        : constant := 62;
   E_Conn_Reset  : constant := 104;
   E_Conn_Aborted : constant := 103;
   E_Canceled    : constant := 125;

   --  A completion that means "the peer went away", which callers normally
   --  treat as an orderly end of conversation rather than a failure.
   function Peer_Gone (R : Io_Result) return Boolean is
     (R = 0
      or else Errno (R) = E_Conn_Reset
      or else Errno (R) = E_Pipe
      or else Errno (R) = E_Conn_Aborted);

   ---------------------------------------------------------------------------
   --  Fiber bodies
   ---------------------------------------------------------------------------

   --  A fiber body is a plain procedure taking one integer.  Keeping the
   --  payload to a scalar avoids closures, and with them the access types
   --  and heap allocation that would put this runtime outside SPARK.
   --  Callers pass a descriptor, or an index into their own table.
   type Fiber_Argument is new Integer;

   type Fiber_Body is access procedure (Arg : Fiber_Argument);

end Iour;
