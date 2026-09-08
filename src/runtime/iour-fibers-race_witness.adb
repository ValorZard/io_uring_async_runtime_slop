package body Iour.Fibers.Race_Witness with SPARK_Mode => On is

   --  Never set, and that is the point; the warning saying so is the one
   --  thing here to silence rather than fix.
   pragma Warnings (Off, "*""Run"" is not modified*");
   Run : Boolean := False
     with Atomic, Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;
   pragma Warnings (On, "*""Run"" is not modified*");

   --  Where the witness task spends the life of the process.  Jorvik
   --  forbids a task body from running off its end, so it has to block
   --  rather than return -- and block rather than spin, which is what
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

   procedure Never_Runs is
      Go : Boolean;
   begin
      --  Read into a local first: a volatile object may appear only as the
      --  whole right-hand side of an assignment, SPARK RM 7.1.3(9).
      Go := Run;
      if Go then
         All_Fiber_Bodies;
      end if;
   end Never_Runs;

   task Witness with Priority => Runtime_Priority;

   task body Witness is
   begin
      Never_Runs;
      loop
         Never_Opens.Park;
      end loop;
   end Witness;

end Iour.Fibers.Race_Witness;
