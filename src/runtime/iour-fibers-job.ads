------------------------------------------------------------------------------
--  Iour.Fibers.Job -- one kind of fiber, named by instantiating this.
--
--  This is how a fiber body reaches the runtime, and the only way that
--  works from SPARK.  Instantiate it with an ordinary procedure and spawn
--  through the instance:
--
--     procedure Handler (Arg : Fiber_Argument);
--     package Handler_Job is new Iour.Fibers.Job (Work => Handler);
--     ...
--     Handler_Job.Spawn_Here (Fiber_Argument (Conn), Started);
--
--  No subprogram pointer appears in the consumer's code, so SPARK's rule
--  against 'Access of a subprogram with global effects -- which every
--  fiber body has, since doing I/O is the point -- never applies to it.
--  The single 'Access is in this package's private part, which is
--  SPARK_Mode => Off for that one line and nothing else.
--
--  Two Ada rules shape the arrangement, and both give errors that name
--  the fix:
--
--    * RM 6.3.1(17/3): 'Access of a generic formal subprogram is not
--      subtype conformant.  Hence Trampoline, which is an ordinary
--      procedure that calls the formal.
--
--    * RM 3.10.2(32): 'Access in a generic BODY is illegal when the access
--      type is declared outside the generic -- which Fiber_Body is, in
--      Iour.Fibers's private part.  The private part of the generic SPEC
--      is where it is allowed, which is where Ref is.
--
--  Registration happens when the instance elaborates.  Under this
--  partition's Sequential elaboration policy every library unit is
--  elaborated before any task is activated, so the job table is complete
--  and unchanging by the time the first shard runs -- which is what makes
--  reading it from every shard afterwards a read of settled state.
--
--  An instance must be at library level: it registers from its own
--  elaboration, and a job that came and went with a stack frame would
--  leave a dangling entry behind.
--
--  Registering also puts the body under SPARK's data-race rule, which it
--  is otherwise outside of: a fiber is entered through the context
--  switch's assembly, so nothing connects a fiber body to a task and the
--  rule never looks.  Witness below is what connects it, and it is here
--  rather than in the consumer so that there is no list to keep in step
--  with these instantiations and nothing to forget.  See
--  Iour.Fibers.Race_Witness, which explains the whole mechanism and why
--  it cannot live in this package's own body.
------------------------------------------------------------------------------

with Iour.Fibers.Race_Witness;

generic
   --  The fiber body.  An ordinary procedure with whatever effects it
   --  likes; nothing here constrains it, and nothing needs to.
   with procedure Work (Arg : Fiber_Argument);

package Iour.Fibers.Job with SPARK_Mode => On is

   --  This job's number, or No_Job if registration failed -- which means
   --  the program has more than Max_Jobs kinds of fiber and is a fact
   --  about the program, not a runtime condition.  The three Spawn
   --  wrappers below check it, so most callers never need to.
   procedure Number (Id : out Job_Ref)
     with Global => (Input => Registry);

   --  The three ways to start one, each the same as Iour.Fibers's
   --  procedure of that name with the job already chosen.  Every one of
   --  them reports failure rather than raising: a full fiber table is a
   --  load condition, and a runtime that blocked to wait for a slot would
   --  stall the core that could free one.

   --  Onto whichever shard picks it up off the global run queue, with a
   --  future that resolves when the fiber finishes.
   procedure Spawn (Arg : Fiber_Argument; Handle : out Future_Ref)
     with Global => (In_Out => Registry);

   --  Onto the calling shard, detached.  The path a connection handler
   --  takes: the fiber runs on the core that accepted it, which is the
   --  core whose ring already carries its socket.
   procedure Spawn_Here (Arg : Fiber_Argument; Started : out Boolean)
     with Global => (In_Out => Registry);

   --  Onto a named shard, detached, and callable from the environment
   --  task -- which is how a server puts one acceptor on every core
   --  before the load arrives.
   procedure Spawn_On
     (Shard : Active_Shard; Arg : Fiber_Argument; Started : out Boolean)
     with Global => (In_Out => Registry);

   --  Puts Work into two tasks' call graphs, so that state it shares with
   --  another fiber is seen by SPARK's data-race rule.  Nothing in it ever
   --  runs; it costs two threads that park for good, per kind of fiber.
   --
   --  It is instantiated here, in the visible part, and not in the body:
   --  the private part below is SPARK_Mode => Off, an Off private part
   --  forces an Off body, and a task body in an Off body is analysed for
   --  nothing.
   package Witness is new Iour.Fibers.Race_Witness (Work);

private
   pragma SPARK_Mode (Off);

   --  RM 6.3.1(17/3): the formal itself cannot have 'Access taken.
   procedure Trampoline (Arg : Fiber_Argument);

   --  The one 'Access in the runtime, and the whole reason this package's
   --  private part is outside SPARK.  RM 3.10.2(32) puts it here rather
   --  than in the body.
   Ref : constant Fiber_Body := Trampoline'Access;

end Iour.Fibers.Job;
