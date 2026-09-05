with Interfaces; use Interfaces;
with Iour.Async;

package body Iour.Time with SPARK_Mode => On is

   procedure Sleep (Nanoseconds : Natural) is
      Result : Io_Result;
   begin
      if Nanoseconds = 0 then
         return;
      end if;

      --  The interval travels by value, so nothing has to stay alive for
      --  the length of the wait.  It used to be a timespec on the fiber's
      --  own stack, which io_uring needs and Windows has no use for; the
      --  Linux backend now stages one of its own next to the submission.
      --
      --  A timeout reports -ETIME when it expires normally, which is the
      --  expected outcome, not a failure; there is nothing to do with it.
      pragma Warnings
        (GNATprove, Off, "*""Result"" is set by ""Perform"" but not used*",
         Reason => "A timer's only result is that it expired.");
      Async.Perform
        (Reactor.Op_Timeout (Unsigned_64 (Nanoseconds), 0), Result);
      pragma Warnings
        (GNATprove, On, "*""Result"" is set by ""Perform"" but not used*");
   end Sleep;

   procedure Sleep_Milliseconds (Milliseconds : Natural) is
   begin
      if Milliseconds > Natural'Last / 1_000_000 then
         Sleep (Natural'Last);
      else
         Sleep (Milliseconds * 1_000_000);
      end if;
   end Sleep_Milliseconds;

end Iour.Time;
