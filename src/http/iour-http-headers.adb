package body Iour.Http.Headers with SPARK_Mode => On is

   function Lower (Value : Iour.Byte) return Iour.Byte is
   begin
      if Value in Iour.Byte (Character'Pos ('A')) ..
                  Iour.Byte (Character'Pos ('Z'))
      then
         return Value + Iour.Byte (Character'Pos ('a') - Character'Pos ('A'));
      end if;
      return Value;
   end Lower;

   procedure Clear (Headers : in out Header_Table) is
   begin
      Headers.Entries := [others => (others => 0)];
      Headers.Used := 0;
   end Clear;

   procedure Add
     (Headers     : in out Header_Table;
      Name_First  : Head_Index;
      Name_Last   : Head_Index;
      Value_First : Head_Index;
      Value_Last  : Head_Index;
      Status      : out Parse_Status)
   is
   begin
      if Headers.Used = Max_Headers then
         Status := Too_Large;
         return;
      end if;
      Headers.Used := Headers.Used + 1;
      Headers.Entries (Headers.Used) :=
        (Name_First, Name_Last, Value_First, Value_Last);
      Status := Complete;
   end Add;

   function Count (Headers : Header_Table) return Natural is (Headers.Used);

   procedure Find
     (Headers : Header_Table;
      Data    : Iour.Byte_Array;
      Name    : String;
      Found   : out Boolean;
      Value   : out Header_Slice)
   is
      Match : Boolean;
   begin
      Found := False;
      Value := (others => 0);
      for Index in 1 .. Headers.Used loop
         --  Both ends of the slice have to lie inside Data, not just the
         --  far one: Data may be any window the caller has, including an
         --  empty one, whose 'First is then above its 'Last.
         if Headers.Entries (Index).Name_Last - Headers.Entries (Index).Name_First
              + 1 = Name'Length
           and then Headers.Entries (Index).Name_First >= Data'First
           and then Headers.Entries (Index).Name_Last <= Data'Last
         then
            Match := True;
            if Name'Length > 0 then
               for Offset in 0 .. Name'Length - 1 loop
                  if Lower (Data (Headers.Entries (Index).Name_First + Offset)) /=
                       Byte (Character'Pos (Name (Name'First + Offset)))
                  then
                     Match := False;
                  end if;
               end loop;
            end if;
            if Match then
               Found := True;
               Value := Headers.Entries (Index);
               return;
            end if;
         end if;
      end loop;
   end Find;

end Iour.Http.Headers;