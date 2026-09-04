with Iour.Ffi;
with Iour.Ffi.Sys;

package body Iour.Trace with
  SPARK_Mode    => On,
  Refined_State => (Switch => Enabled)
is

   Enabled : Boolean := False
     with Atomic, Async_Writers => True, Async_Readers => False,
          Effective_Reads => False, Effective_Writes => False;

   Max_Line : constant := 160;

   procedure Enable is
   begin
      Enabled := True;
   end Enable;

   procedure Disable is
   begin
      Enabled := False;
   end Disable;

   ---------------------------------------------------------------------------

   procedure Emit (Text : String) is
      Line : Byte_Array (0 .. Max_Line) := [others => 0];
      N    : Natural range 0 .. Max_Line + 1 := 0;
   begin
      for I in Text'Range loop
         pragma Loop_Invariant (N <= Max_Line);
         exit when N = Max_Line;   --  leave room for the newline
         Line (N) := Byte (Character'Pos (Text (I)));
         N := N + 1;
      end loop;
      Line (N) := 10;   --  LF
      N := N + 1;
      Ffi.Sys.Write_Blocking (Ffi.Sys.Stderr, Line, Ffi.C_Size (N));
   end Emit;

   function Prefix (Shard : Shard_Ref) return String is
     (if Shard in Shard_Id
      then "[iour] shard" & Shard'Image & ": "
      else "[iour] main: ");

   procedure Event (Shard : Shard_Ref; Label : String) is
      On : constant Boolean := Enabled;
   begin
      if On then
         Emit (Prefix (Shard) & Label);
      end if;
   end Event;

   procedure Event (Shard : Shard_Ref; Label : String; Value : Integer) is
      On : constant Boolean := Enabled;
   begin
      if On then
         Emit (Prefix (Shard) & Label & Value'Image);
      end if;
   end Event;

end Iour.Trace;
