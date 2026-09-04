------------------------------------------------------------------------------
--  Smoke_Workload -- the fiber bodies and shared state for the smoke test.
--
--  Two Jorvik rules shape this file, and they shape every application built
--  on this runtime:
--
--    * No_Local_Protected_Objects: shared state lives in a library-level
--      package, never inside a subprogram.
--    * A fiber body is passed as an access-to-subprogram value, so it must
--      be declared at library level too -- a nested procedure is "deeper
--      than the access type" and Ada will not let you take its access.
--
--  So application code is written as library-level packages, with the main
--  subprogram reduced to starting the runtime and reporting.
------------------------------------------------------------------------------

with Iour; use Iour;

package Smoke_Workload with SPARK_Mode => On is

   Worker_Count : constant := 24;

   --  One worker: suspend on a real ring operation, yield, then finish.
   procedure Worker (Arg : Fiber_Argument);

   --  Fans out the workers, waits for them, then stops the runtime.
   procedure Root (Arg : Fiber_Argument);

   --  How many workers finished, and how they were spread over the shards.
   procedure Result
     (Finished : out Natural;
      Spread   : out String;
      Last     : out Natural);

end Smoke_Workload;
