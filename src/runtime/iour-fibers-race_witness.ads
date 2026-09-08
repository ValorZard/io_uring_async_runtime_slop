------------------------------------------------------------------------------
--  Iour.Fibers.Race_Witness -- makes SPARK check a program's fiber bodies
--  for data races.  Without one they are checked for nothing at all.
--
--  SPARK's data-race rule fires when an unsynchronized object is reachable
--  from two tasks.  A fiber is entered through the context switch's
--  assembly trampoline, so gnatprove analyses Iour.Fibers.Fiber_Main as a
--  subprogram nobody calls: no fiber body is in any task's call graph, and
--  the rule never gets the chance to look.  State a program shares between
--  its fibers is therefore unchecked by default, silently.
--
--  This states the truth the trampoline hides -- these bodies run on
--  shards, and there is more than one shard -- by putting them in two
--  tasks' call graphs.  Instantiate it once per program with a procedure
--  that calls every fiber body, and call Never_Runs once from the main
--  subprogram:
--
--     procedure All_Bodies is
--     begin
--        Serve (0);
--        Acceptor (0);
--     end All_Bodies;
--
--     package Races is new Iour.Fibers.Race_Witness (All_Bodies);
--
--  Nothing is executed.  Never_Runs reads one atomic flag that nothing
--  ever sets and takes a branch that is never taken; the actual is reached
--  only through it.
--
--  **A fiber body left out of the actual is a fiber body checked for
--  nothing, and nothing will say so.**  That is the one thing to get right
--  here, and it is why the actual is a single procedure listing them all
--  rather than something per job: a list is reviewable, and a missing
--  entry is visible next to the ones that are there.
--
--  Four things about the shape, each established by experiment.  Do not
--  re-derive them; three are the opposite of the obvious guess.
--
--    * The guard must be one gnatprove cannot fold.  A statically False
--      one is pruned -- "this statement is never reached" -- and the race
--      check stays silent.  Run is Atomic and nothing sets it, so the call
--      stays in the call graph and out of the program.
--
--    * One task here, not two.  The rule needs two callers and the second
--      is the environment task, which is why the main subprogram has to
--      call Never_Runs.  Without that call there is one task and nothing
--      is reported.
--
--    * The witness must be in the partition's closure.  Put in a unit
--      nothing withs -- a separate source directory selected by a scenario
--      variable, say -- it is not analysed and reports nothing, even under
--      -U.  That is why this is compiled into the program rather than
--      being a proof-only artefact, and it has the happy consequence that
--      the proved program and the shipped program are the same program.
--
--    * It has to run at Runtime_Priority.  At any other priority every
--      protected object it reaches reports a possible ceiling violation
--      instead of the thing you are looking for.
--
--  The cost is one thread that starts, makes no call, and parks for good.
--  Parks, not spins: Jorvik forbids a task body from running off its end,
--  so it waits on a barrier that never opens, exactly as Iour.Shards does
--  for shards past Shard_Count.
--
--  What this does not model is the scheduling.  SPARK cannot tell two
--  fibers on one shard, which cannot preempt each other, from two on
--  different shards, which race -- so it treats both as racing.  That is
--  conservative, which is the right way for a check to be wrong, and it is
--  why Echo_Server_App's Next_Core had to become Atomic rather than be
--  justified by the shard-confinement argument it used to carry.
------------------------------------------------------------------------------

generic
   --  Calls every fiber body this program registers with Iour.Fibers.Job.
   with procedure All_Fiber_Bodies;

package Iour.Fibers.Race_Witness with SPARK_Mode => On is

   pragma Elaborate_Body;

   --  Does nothing: one atomic read and a branch that is never taken.
   --  The main subprogram calls it once, which is what puts the fiber
   --  bodies into the environment task's call graph as well as the witness
   --  task's -- and two tasks is what the data-race rule needs.
   procedure Never_Runs;

end Iour.Fibers.Race_Witness;
