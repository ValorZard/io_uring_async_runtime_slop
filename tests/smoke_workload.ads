with Iour.Fibers.Race_Witness;
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

   --  Every fiber body this program registers.  Never executed: it is
   --  reached only through Races.Never_Runs, which the main subprogram
   --  calls once and which is guarded by a flag nothing ever sets.
   --
   --  A body missing from here is a body checked for nothing, and nothing
   --  will say so.  Keep it in step with the Iour.Fibers.Job instances.
   procedure All_Fiber_Bodies;

   package Races is new Iour.Fibers.Race_Witness (All_Fiber_Bodies);


   --  Start Root as a fiber.  The Iour.Fibers.Job instance it needs must
   --  be at library level, so it lives in this package's body.
   procedure Start_Root (Handle : out Future_Ref);

   --  A promise the environment task fulfils, to prove a wake posted from a
   --  thread with no ring reaches its fiber.  Set by Root before it awaits.
   procedure Handshake (Handle : out Future_Ref);

   --  How many workers finished, and how they were spread over the shards.
   --  Spread'First = 1 rather than any lower bound: the arithmetic below
   --  walks a cursor through it, and a String whose 'First is Natural'First
   --  makes "Spread'First - 1" and "Cursor + Length - 1" unprovable rather
   --  than merely awkward.  Every caller passes a 1-based buffer.
   procedure Result
     (Finished : out Natural;
      Spread   : out String;
      Last     : out Natural)
     with Pre  => Spread'First = 1
                  and then Spread'Last in 1 .. Natural'Last - 1,
          Post => Last <= Spread'Last;

end Smoke_Workload;
