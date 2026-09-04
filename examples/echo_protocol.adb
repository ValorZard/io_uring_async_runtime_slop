package body Echo_Protocol with SPARK_Mode => On is

   subtype Tag_Text is String (1 .. 4);
   type Tag_Table is array (Message_Kind) of Tag_Text;

   Tags : constant Tag_Table :=
     [Ping      => "PING",
      Pong      => "PONG",
      Farewell  => "BYE ",
      Malformed => "????"];

   Space : constant Byte := Byte (Character'Pos (' '));
   Zero  : constant Byte := Byte (Character'Pos ('0'));

   function Tag_Of (Kind : Message_Kind) return String is (Tags (Kind));

   ---------------------------------------------------------------------------

   procedure Build
     (Kind : Message_Kind; Sequence : Natural; Into : out Frame)
   is
      Tag  : constant Tag_Text := Tags (Kind);
      Rest : Natural := (if Sequence > Max_Sequence then Max_Sequence
                         else Sequence);
   begin
      Into := [others => Space];

      for I in 0 .. 3 loop
         Into (I) := Byte (Character'Pos (Tag (Tag'First + I)));
      end loop;

      --  Least significant digit last, so the field reads normally.
      for I in reverse Digits_First .. Digits_Last loop
         Into (I) := Zero + Byte (Rest mod 10);
         Rest := Rest / 10;
      end loop;
   end Build;

   ---------------------------------------------------------------------------

   procedure Parse
     (From : Frame; Kind : out Message_Kind; Sequence : out Natural)
   is
      Tag   : Tag_Text := "    ";
      Value : Natural := 0;
      Digit : Byte;
   begin
      Kind := Malformed;
      Sequence := 0;

      for I in 0 .. 3 loop
         Tag (Tag'First + I) := Character'Val (Natural (From (I)));
      end loop;

      for K in Message_Kind loop
         if K /= Malformed and then Tags (K) = Tag then
            Kind := K;
         end if;
      end loop;

      if Kind = Malformed then
         return;
      end if;

      for I in Digits_First .. Digits_Last loop
         Digit := From (I);
         if Digit < Zero or else Digit > Zero + 9 then
            Kind := Malformed;
            Sequence := 0;
            return;
         end if;
         Value := Value * 10 + Natural (Digit - Zero);
      end loop;

      Sequence := Value;
   end Parse;

end Echo_Protocol;
