package body Iour.Http.Buffer with SPARK_Mode => On is

   procedure Consume (B : in out Buffer; Count : Natural) is
   begin
      B.First := B.First + Count;
   end Consume;

   procedure Compact (B : in out Buffer) is
      Count : constant Natural := Available (B);
   begin
      if B.First = 1 then
         return;
      end if;
      if Count > 0 then
         for Index in 0 .. Count - 1 loop
            B.Data (1 + Index) := B.Data (B.First + Index);
         end loop;
      end if;
      B.First := 1;
      B.Last := Count + 1;
   end Compact;

   procedure Append
     (B      : in out Buffer;
      Source : Iour.Byte_Array;
      Count  : Natural)
   is
   begin
      if Count > 0 then
         for Index in 0 .. Count - 1 loop
            B.Data (B.Last + Index) := Source (Source'First + Index);
         end loop;
      end if;
      B.Last := B.Last + Count;
   end Append;

end Iour.Http.Buffer;