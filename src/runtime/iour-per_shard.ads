------------------------------------------------------------------------------
--  Iour.Per_Shard -- one value per shard, with no lock in front of it.
--
--  Most of a shard's scheduling state is only ever touched by the shard
--  itself: which fiber is on its core, why the last one gave the core back,
--  whether anything has been left in its inbox.  Putting that behind a
--  protected object buys nothing -- the lock is never contended -- and costs
--  a mutex round trip per access, which on the hot path adds up to more
--  than the work being protected.
--
--  SPARK has one lock-free way to share a variable between tasks: an
--  Atomic scalar.  Not an array of them -- an array with Atomic_Components
--  is not itself a synchronized object -- so this package holds Max_Shards
--  separate atomic scalars and dispatches on the shard index, the same way
--  Iour.Shards holds Max_Shards separate task declarations.  A generic, so
--  the dispatch is written once.
--
--  Reads and writes are single machine-word loads and stores, ordered as
--  atomics.  That is all a shard needs for its own state.  Anything two
--  shards genuinely contend for -- a ready queue, a future -- still lives
--  in a protected object.
------------------------------------------------------------------------------

generic
   type Item is (<>);
   Initial : Item;
package Iour.Per_Shard with
  SPARK_Mode     => On,
  Abstract_State => (Cells with Synchronous, External),
  Initializes    => Cells
is

   procedure Set (Shard : Shard_Id; Value : Item)
     with Global => (In_Out => Cells);

   procedure Get (Shard : Shard_Id; Value : out Item)
     with Global => (Input => Cells);

end Iour.Per_Shard;
