with Ada.Command_Line; use Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;
with Iour;        use Iour;
with Iour.Ffi.Sys;
with Iour.Net;
with Iour.Scheduler;
with Iour.Shards;
with Http_Server_App;

procedure Http_Server with SPARK_Mode => On, CPU => 1 is

   --  Every path here ends in Exit_Process, which is No_Return, so
   --  gnatprove reports that this procedure never returns normally.  That
   --  is the design and not a defect; echo_server says the same at length.
   pragma Annotate
     (GNATprove, Intentional,
      "all paths",
      "A Jorvik partition ends by calling Exit_Process; returning from the "
      & "main subprogram would hang on tasks that may not terminate.");

   --  Nothing on this command line is a large number, and bounding them
   --  is what keeps the arithmetic below provable.
   Max_Argument : constant := 1_000_000;

   --  Hand-rolled the same way as in the other three example mains.
   --  Natural'Value carries a precondition SPARK cannot discharge for an
   --  arbitrary command-line string, and the Constraint_Error handler
   --  that used to stand in for it is not something SPARK reasons about
   --  either.  Digits and a bound, and the whole thing is provable and
   --  total.
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
         for Character_At in Text'Range loop
            pragma Loop_Invariant (Value <= Max_Argument);
            if Text (Character_At) not in '0' .. '9' then
               return Default;
            end if;
            if Value > (Max_Argument - (Character'Pos (Text (Character_At))
                                        - Character'Pos ('0'))) / 10
            then
               return Default;   --  too large to be meant
            end if;
            Value := Value * 10
              + (Character'Pos (Text (Character_At)) - Character'Pos ('0'));
         end loop;
         return Value;
      end;
   end Argument_Or;

   Listener : Io_Result;
   Bound    : Io_Result;
   Started  : Boolean;
begin
   Net.Ignore_Broken_Pipes;
   Listener := Net.Listen (Argument_Or (1, 8080));
   if Failed (Listener) then
      Put_Line ("http_server: cannot listen");
      Ffi.Sys.Exit_Process (1);
   end if;
   Bound := Net.Port_Of (Descriptor (Listener));
   Shards.Activate;
   Scheduler.Wait_Until_Ready;
    Http_Server_App.Configure
       (Descriptor (Listener), Argument_Or (2, 0));
    Http_Server_App.Start
       (Active_Shard'First, Descriptor (Listener), Started);
   if not Started then
      Put_Line ("http_server: cannot start acceptor");
      Ffi.Sys.Exit_Process (1);
   end if;
   Put_Line ("http_server: listening on port" & Bound'Image
             & " with" & Shard_Count'Image & " shards");
   Scheduler.Wait_For_Shutdown;
   Ffi.Sys.Exit_Process (0);
end Http_Server;