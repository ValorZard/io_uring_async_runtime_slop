------------------------------------------------------------------------------
--  Iour.Ffi.Identity body -- SPARK_Mode => Off.
--
--  One variable, and the only thing about it that is not ordinary Ada:
--  every thread has its own copy.  GNAT's Thread_Local_Storage pragma is
--  the same on both systems this runtime targets, so unlike the binding
--  next door in Iour.Ffi.Sys, identity needs no per-platform body at all.
------------------------------------------------------------------------------

package body Iour.Ffi.Identity with SPARK_Mode => Off is

   --  Initialised to the "not a shard" sentinel, which is what every
   --  thread the runtime did not start keeps for its whole life.
   Slot : Shard_Ref := No_Shard;
   pragma Thread_Local_Storage (Slot);

   procedure Claim (Index : Shard_Id) is
   begin
      Slot := Index;
   end Claim;

   function Current return Shard_Ref is (Slot);

end Iour.Ffi.Identity;
