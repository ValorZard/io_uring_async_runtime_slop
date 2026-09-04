------------------------------------------------------------------------------
--  Iour.Run_Queue -- the one globally accessible queue of pending work.
--
--  Every future created by Iour.Fibers.Spawn lands here, and every shard
--  running an event loop pops from it.  That is the whole load-balancing
--  story: a shard that finishes its work helps itself to the next item, so
--  a burst of connections spreads across cores without anybody measuring
--  load or stealing from a neighbour.
--
--  Only newly spawned work travels through here.  Once a shard adopts a
--  fiber, that fiber stays put, because its in-flight operations live in
--  that shard's ring and its completions can be reaped nowhere else.
------------------------------------------------------------------------------

package Iour.Run_Queue with
  SPARK_Mode     => On,
  Abstract_State => (Queue with Synchronous, External),
  Initializes    => Queue
is

   --  Publish a task future.  Accepted is False only if the queue is full,
   --  which the caller must surface rather than block on.
   procedure Push (Handle : Future_Id; Accepted : out Boolean)
     with Global => (In_Out => Queue);

   --  Claim the oldest waiting item, or No_Future if there is none.
   procedure Pop (Handle : out Future_Ref)
     with Global => (In_Out => Queue);

   --  Items waiting.  A shard consults this before deciding to sleep.
   procedure Depth (Count : out Natural)
     with Global => (In_Out => Queue);

   --  Total items ever published, for reporting.
   procedure Total_Pushed (Count : out Natural)
     with Global => (In_Out => Queue);

end Iour.Run_Queue;
