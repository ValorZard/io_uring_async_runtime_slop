------------------------------------------------------------------------------
--  Iour_Config -- the one tunable the build sets rather than the source.
--
--  Shard_Count has to be a static constant: Jorvik requires each shard
--  task's CPU aspect to be static, Active_Shard is a subtype bounded by
--  it, and Compile_Time_Error checks it against Max_Shards.  A GPR
--  external cannot reach an Ada constant, so the project file selects one
--  of the src/config/shards-<n> directories instead, and each declares
--  this same package with a different value:
--
--     gprbuild -P io_uring_async_runtime.gpr -XIOUR_SHARDS=6
--
--  Nothing else belongs here.  The remaining tunables live in Iour, next
--  to the comments that explain what they cost.
------------------------------------------------------------------------------

package Iour_Config with SPARK_Mode => On, Pure is

   Shard_Count : constant := 6;

end Iour_Config;
