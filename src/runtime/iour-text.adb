with Iour.Ffi;
with Iour.Ffi.Sys;
with Iour.Fibers;
with Iour.Net;

package body Iour.Text with SPARK_Mode => On is

   procedure Emit (Fd : Descriptor; Text : String) is
      --  On the fiber's own stack, so it stays valid for as long as the
      --  fiber is suspended -- exactly as long as the kernel needs it.
      --  Fully initialised so SPARK can see every byte handed to the kernel
      --  was written by us.
      Line   : Byte_Array (0 .. Max_Line) := [others => 0];
      N      : Natural range 0 .. Max_Line + 1 := 0;
      Shard  : constant Shard_Ref := Fibers.Self;
      Me     : Fiber_Ref := No_Fiber;
      Result : Io_Result;
   begin
      for I in Text'Range loop
         pragma Loop_Invariant (N <= Max_Line);
         exit when N = Max_Line;   --  leave room for the newline
         Line (N) := Byte (Character'Pos (Text (I)));
         N := N + 1;
      end loop;
      Line (N) := 10;   --  LF
      N := N + 1;

      if Shard in Active_Shard then
         Fibers.Running_Fiber (Shard, Me);
      end if;

      if Me /= No_Fiber then
         --  On a fiber: through the ring, suspending until it is written.
         --  Should the ring refuse, fall back to a plain write rather than
         --  lose the line: this is the output people read to find out what
         --  went wrong.
         Net.Write_All (Fd, Line (0 .. N - 1), Result);
         if Failed (Result) then
            Ffi.Sys.Write_Blocking (Fd, Line, Ffi.C_Size (N));
         end if;
      else
         --  Environment task or scheduler context: nothing to suspend.
         Ffi.Sys.Write_Blocking (Fd, Line, Ffi.C_Size (N));
      end if;
   end Emit;

   procedure Put_Line (Text : String) is
   begin
      Emit (Ffi.Sys.Standard_Output, Text);
   end Put_Line;

   procedure Put_Line_Error (Text : String) is
   begin
      Emit (Ffi.Sys.Standard_Error, Text);
   end Put_Line_Error;

end Iour.Text;
