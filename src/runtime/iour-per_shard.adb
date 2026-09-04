package body Iour.Per_Shard with
  SPARK_Mode    => On,
  Refined_State => (Cells => (C0, C1, C2, C3, C4, C5, C6, C7))
is

   --  Effective_Reads and Effective_Writes are off: a read here has no side
   --  effect and a write only ever replaces the previous value, which is
   --  what lets SPARK treat a Get as a plain input and a Set as a plain
   --  output rather than as I/O.
   C0, C1, C2, C3, C4, C5, C6, C7 : Item := Initial
     with Atomic, Async_Readers, Async_Writers,
          Effective_Reads => False, Effective_Writes => False;

   pragma Compile_Time_Error
     (Max_Shards /= 8,
      "Iour.Per_Shard holds exactly eight cells; add or remove some to"
      & " match Max_Shards");

   procedure Set (Shard : Shard_Id; Value : Item) is
   begin
      case Shard is
         when 0 => C0 := Value;
         when 1 => C1 := Value;
         when 2 => C2 := Value;
         when 3 => C3 := Value;
         when 4 => C4 := Value;
         when 5 => C5 := Value;
         when 6 => C6 := Value;
         when 7 => C7 := Value;
      end case;
   end Set;

   procedure Get (Shard : Shard_Id; Value : out Item) is
   begin
      case Shard is
         when 0 => Value := C0;
         when 1 => Value := C1;
         when 2 => Value := C2;
         when 3 => Value := C3;
         when 4 => Value := C4;
         when 5 => Value := C5;
         when 6 => Value := C6;
         when 7 => Value := C7;
      end case;
   end Get;

end Iour.Per_Shard;
