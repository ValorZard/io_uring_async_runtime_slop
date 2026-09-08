------------------------------------------------------------------------------
--  echo_client -- drives the server with many simultaneous conversations.
--
--    ./bin/echo_client [host] [port] [connections] [rounds]
--
--  Every connection is one fiber.  With the defaults that is 1000
--  conversations in flight at once, all of them running on Shard_Count
--  operating system threads -- which is the point of the exercise.
--
--  Timing uses Ada.Real_Time; Jorvik forbids Ada.Calendar outright.
------------------------------------------------------------------------------

with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Real_Time;     use Ada.Real_Time;
with Ada.Text_IO;       use Ada.Text_IO;
with Iour;              use Iour;
with Iour.Ffi.Sys;
with Iour.Fibers;
with Iour.Net;
with Iour.Scheduler;
with Iour.Shards;
with Iour.Trace;
with Ada.Environment_Variables;
with Echo_Client_App;

procedure Echo_Client with SPARK_Mode => On, CPU => 1 is

   --  Every path here ends in Exit_Process, which is No_Return, so
   --  gnatprove reports that this procedure never returns normally.  That
   --  is the design and not a defect: a Jorvik partition never ends on its
   --  own, because the environment task would block forever waiting on
   --  tasks that No_Task_Termination forbids to terminate.  Exiting the
   --  process is how such a program stops, and the README says so.
   pragma Annotate
     (GNATprove, Intentional,
      "all paths",
      "A Jorvik partition ends by calling Exit_Process; returning from the "
      & "main subprogram would hang on tasks that may not terminate.");

   --  Nothing on this command line is a large number, and bounding them
   --  is what keeps the arithmetic below provable.
   Max_Argument : constant := 1_000_000;

   --  How long the run took, in milliseconds.
   --
   --  The body is SPARK_Mode => Off and this is the only thing in these
   --  examples that is.  Nothing in the language relates two arbitrary
   --  Ada.Real_Time.Time values, so "To - From" carries a range check that
   --  cannot be discharged -- and a guard written in terms of that same
   --  difference carries it too, so there is no way to write around it.
   --  One Off body with the reason on it is the shape the runtime itself
   --  uses wherever the language cannot express what a body means; see the
   --  README's *SPARK status*.
   function Elapsed_Milliseconds (From, To : Time) return Integer
     with Global => null;

   function Elapsed_Milliseconds (From, To : Time) return Integer
     with SPARK_Mode => Off is
   begin
      if To <= From then
         return 0;
      end if;
      return (To - From) / Milliseconds (1);
   end Elapsed_Milliseconds;

   --  Hand-rolled rather than Integer'Value, and hand-rolled the same way
   --  in both example mains.  Integer'Value carries a precondition SPARK
   --  cannot discharge for an arbitrary command-line string, and the
   --  exception handler that used to catch its Constraint_Error is not
   --  something SPARK reasons about either.  Digits and a bound, and the
   --  whole thing is provable and total.
   function Argument_Or (Index : Positive; Default : Natural) return Natural is
      Value : Natural := 0;
   begin
      if Argument_Count < Index then
         return Default;
      end if;
      declare
         Text : constant String := Argument (Index);
      begin
         if Text'Length = 0 then
            return Default;
         end if;
         for I in Text'Range loop
            pragma Loop_Invariant (Value <= Max_Argument);
            if Text (I) not in '0' .. '9' then
               return Default;
            end if;
            if Value > (Max_Argument - (Character'Pos (Text (I))
                                        - Character'Pos ('0'))) / 10
            then
               return Default;   --  too large to be meant
            end if;
            Value := Value * 10
                     + (Character'Pos (Text (I)) - Character'Pos ('0'));
         end loop;
         return Value;
      end;
   end Argument_Or;

   --  Bounded, because the argument is unbounded and is concatenated into
   --  a report line below: without a bound SPARK cannot show the
   --  concatenation stays inside Natural, and a very long argument really
   --  would be a problem rather than a hypothetical one.  Echo_Client_App
   --  truncates to the same length when it stores it.
   Max_Host_Arg : constant := 46;

   function Host_Argument return String is
     (if Argument_Count = 0 then "127.0.0.1"
      elsif Argument (1)'Length = 0 then "127.0.0.1"
      elsif Argument (1)'Length > Max_Host_Arg
      then Argument (1) (Argument (1)'First
                         .. Argument (1)'First + Max_Host_Arg - 1)
      else Argument (1));

   Host        : constant String  := Host_Argument;
   Port        : constant Natural := Argument_Or (2, 9099);
   Connections : constant Natural := Argument_Or (3, 1000);
   Rounds      : constant Natural := Argument_Or (4, 8);

   Handle   : Future_Ref;
   Fd_Limit : Natural;

   Started, Succeeded, Failures, Frames, Mismatched, Concurrent : Natural;
   Live, Peak : Natural;

   Start_Time : Time;
   Stop_Time  : Time;

   --  Milliseconds, as an integer, and never a Duration or a Long_Float.
   --  SPARK supports neither conversion between fixed-point and
   --  floating-point types nor a proof that To_Duration's result fits in
   --  Duration, and neither is needed: Ada.Real_Time defines division of
   --  one Time_Span by another as an Integer count, which is the elapsed
   --  time in units of the divisor and exactly what a rate wants.
   Elapsed_Ms : Integer;
begin
   if Ada.Environment_Variables.Exists ("IOUR_TRACE") then
      Trace.Enable;
   end if;
   Net.Ignore_Broken_Pipes;
   Fd_Limit := Ffi.Sys.Raise_Descriptor_Limit;

   Echo_Client_App.Configure (Host, Port, Connections, Rounds);

   Shards.Activate;
   Scheduler.Wait_Until_Ready;

   Put_Line ("echo_client: " & Host & " port" & Port'Image
             & ", " & Connections'Image & " connections"
             & "," & Rounds'Image & " rounds each");
   Put_Line ("echo_client: " & Shard_Count'Image & " shards"
             & ", descriptor limit" & Fd_Limit'Image);

   Start_Time := Clock;

   Echo_Client_App.Start_Driver (Handle);
   if Handle = No_Future then
      Put_Line ("echo_client: could not start the driver");
      Ffi.Sys.Exit_Process (1);
   end if;

   Scheduler.Wait_For_Shutdown;

   --  Clock is a volatile function, and SPARK RM 7.1.3(9) allows a call to
   --  one only as the whole right-hand side of an assignment -- not as an
   --  actual, and not inside a larger expression.  Hence the extra
   --  variable rather than "To_Duration (Clock - Start_Time)".
   Stop_Time := Clock;

   Elapsed_Ms := Elapsed_Milliseconds (Start_Time, Stop_Time);

   Echo_Client_App.Snapshot
     (Started, Succeeded, Failures, Frames, Mismatched, Concurrent);
   Fibers.Live_Fibers (Live, Peak);

   New_Line;
   Put_Line ("echo_client: sessions started" & Started'Image
             & ", succeeded" & Succeeded'Image
             & ", failed" & Failures'Image);
   Put_Line ("echo_client: frames exchanged" & Frames'Image
             & ", protocol mismatches" & Mismatched'Image);
   Put_Line ("echo_client: peak concurrent sessions" & Concurrent'Image
             & ", peak fibers" & Peak'Image);
   Put_Line ("echo_client: elapsed" & Elapsed_Ms'Image & " ms");

   if Elapsed_Ms > 0 and then Frames <= Integer'Last / 1000 then
      declare
         --  Each frame is one request and one response, so the round trip
         --  count is the frame count.
         Per_Second : constant Natural := Frames * 1000 / Elapsed_Ms;
      begin
         Put_Line ("echo_client: round trips per second"
                   & Per_Second'Image);
      end;
   end if;

   for S in Active_Shard loop
      declare
         Completions, Resumes, Adopted, Sleeps, Left, Bad : Natural;
      begin
         Scheduler.Report
           (S, Completions, Resumes, Adopted, Sleeps, Left, Bad);
         Put_Line ("  shard" & S'Image
                   & ": completions" & Completions'Image
                   & ", resumes" & Resumes'Image
                   & ", sessions adopted" & Adopted'Image
                   & ", kernel sleeps" & Sleeps'Image
                   & (if Bad > 0 then ", FLUSH ERRORS" & Bad'Image else ""));
      end;
   end loop;

   Fibers.Release_All_Stacks;

   Ffi.Sys.Exit_Process
     (if Succeeded = Connections and then Mismatched = 0 then 0 else 1);
end Echo_Client;
