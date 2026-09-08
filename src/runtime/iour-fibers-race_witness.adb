package body Iour.Fibers.Race_Witness with SPARK_Mode => On is

   --  Never set, and that is the point; the warning saying so is the one
   --  thing here to silence rather than fix.  It is the second of the two
   --  reasons Work cannot run -- the first is that the tasks below block
   --  before they reach the call at all -- and it is the one gnatprove
   --  reads: Async_Writers says an outside agent might write it, so the
   --  branch is not folded and the call stays in the call graph.  Nothing
   --  outside this body can name it.
   pragma Warnings (Off, "*""Run"" is not modified*");
   Run : Boolean := False
     with Atomic, Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;
   pragma Warnings (On, "*""Run"" is not modified*");

   --  Where a witness task spends the life of the process.  Jorvik forbids
   --  a task body from running off its end, so it has to block rather than
   --  return -- and block rather than spin, which is what
   --  "loop null; end loop;" would do.
   protected Never_Opens
     with Priority => Runtime_Priority
   is
      entry Park;
   private
      Released : Boolean := False;
   end Never_Opens;

   pragma Warnings
     (GNATprove, Off, "statement has no effect",
      Reason => "Barrier-only entry: the wait is the point.");
   protected body Never_Opens is
      entry Park when Released is
      begin
         null;
      end Park;
   end Never_Opens;
   pragma Warnings (GNATprove, On, "statement has no effect");

   --  The call that puts Work into a task's call graph, and the branch
   --  that keeps it out of the program.  Nothing reaches this: both tasks
   --  block for ever before the call to it.  Measured -- an
   --  Exit_Process at the top of it, in a scratch build, is reached on
   --  every run when the call comes before the wait and on no run when it
   --  comes after.
   procedure Never_Runs;

   procedure Never_Runs is
      Go : Boolean;
   begin
      --  Read into a local first: a volatile object may appear only as the
      --  whole right-hand side of an assignment, SPARK RM 7.1.3(9).
      Go := Run;
      if Go then
         Work (0);
      end if;
   end Never_Runs;

   --  Two of them, because the data-race rule needs two tasks referencing
   --  the same object before it says anything.  One would leave a job that
   --  shares state with itself across shards -- the commonest way to get
   --  this wrong -- reported as safe.  Measured: with Witness_B deleted,
   --  a plain unsynchronized Echo_Server_App.Next_Core is reported by
   --  nothing.
   --
   --  They cannot be Ghost and so cannot be compiled out.  GNAT rejects it
   --  twice over -- "aspect ""Ghost"" cannot apply to a task type" and
   --  "ghost object ... cannot be synchronized" -- and the deeper reason
   --  is that ghost code may not write non-ghost state, which is precisely
   --  what a fiber body does.  Nor can the objects be dropped in favour of
   --  a task type alone: a task type with no objects, and a task type with
   --  one, are both silent.  Two real task objects per job is the floor.
   task Witness_A with Priority => Runtime_Priority;
   task Witness_B with Priority => Runtime_Priority;

   task body Witness_A is
   begin
      --  Blocks here for the life of the process.  Park is an entry whose
      --  barrier is False and which nothing ever opens, so this call does
      --  not return and nothing below it is ever reached -- which is the
      --  first and stronger of the two reasons a fiber body cannot run on
      --  a thread that is not a shard.  gnatprove cannot fold an entry
      --  call, so what follows stays in the call graph, which is the whole
      --  point of the task.
      Never_Opens.Park;

      --  Not reached, twice over: Park never returned, and Run is False.
      Never_Runs;

      --  Jorvik forbids a task body from running off its end, so there has
      --  to be something here that cannot be left.
      loop
         Never_Opens.Park;
      end loop;
   end Witness_A;

   --  The same, and the duplication is the point: see Witness_A.
   task body Witness_B is
   begin
      Never_Opens.Park;
      Never_Runs;
      loop
         Never_Opens.Park;
      end loop;
   end Witness_B;

end Iour.Fibers.Race_Witness;
