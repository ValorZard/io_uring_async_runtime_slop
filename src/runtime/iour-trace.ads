------------------------------------------------------------------------------
--  Iour.Trace -- see what the runtime is doing while it runs.
--
--  Off by default and cheap when off: each event is one atomic load and a
--  return.  When on, every event is one blocking write(2) to stderr from
--  whatever context raised it.  Blocking is deliberate.  A trace is for
--  watching the scheduler, and a trace that suspended the fiber it was
--  reporting on would change what it was reporting.
--
--  Enable it with IOUR_TRACE=1 in the environment of any of the example
--  programs, or by calling Enable before the shards start.
------------------------------------------------------------------------------

package Iour.Trace with
  SPARK_Mode     => On,
  Abstract_State => (Switch with External => (Async_Writers => True)),
  Initializes    => Switch
is

   procedure Enable
     with Global => (Output => Switch);

   procedure Disable
     with Global => (Output => Switch);

   --  Labels longer than this are an error in the caller, not a runtime
   --  condition; the bound is what lets the line assembly be proved.
   Max_Label : constant := 96;

   --  "[iour] shard N: <label>" -- or "[iour] main: ..." off-shard.
   procedure Event (Shard : Shard_Ref; Label : String)
     with Pre => Label'Length <= Max_Label;

   --  "[iour] shard N: <label> <value>".
   procedure Event (Shard : Shard_Ref; Label : String; Value : Integer)
     with Pre => Label'Length <= Max_Label;

end Iour.Trace;
