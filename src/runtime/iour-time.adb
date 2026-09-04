with Interfaces;
with Iour.Async;
with Iour.Ffi.Uring;
with Iour.Reactor;

package body Iour.Time with SPARK_Mode => On is

   Nanos_Per_Second : constant := 1_000_000_000;

   procedure Sleep (Nanoseconds : Natural) is
      --  Local, so it sits on the fiber's own stack and stays valid for as
      --  long as the fiber is suspended -- which is exactly as long as the
      --  kernel needs to read it.
      Deadline : aliased Ffi.Uring.Kernel_Timespec;
      Result   : Io_Result;
   begin
      if Nanoseconds = 0 then
         return;
      end if;

      Deadline :=
        (Seconds     => Interfaces.Integer_64 (Nanoseconds / Nanos_Per_Second),
         Nanoseconds => Interfaces.Integer_64 (Nanoseconds mod Nanos_Per_Second));

      --  A timeout reports -ETIME when it expires normally, which is the
      --  expected outcome, not a failure.
      Async.Perform (Reactor.Op_Timeout (Deadline'Address, 0), Result);
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
