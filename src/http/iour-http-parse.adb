package body Iour.Http.Parse with SPARK_Mode => On is

   Cr : constant Iour.Byte := 13;
   Lf : constant Iour.Byte := 10;
   Sp : constant Iour.Byte := 32;

   function Is_Byte (Actual : Iour.Byte; Expected : Character) return Boolean is
     (Actual = Iour.Byte (Character'Pos (Expected)));

    function Digit (Value : Iour.Byte) return Natural is
       (Natural (Value - Iour.Byte (Character'Pos ('0'))))
       with Pre => Value in Iour.Byte (Character'Pos ('0')) ..
                                  Iour.Byte (Character'Pos ('9'));

   function Is_Version
       (Data : Head_Buffer; First : Natural; Last : Natural) return Boolean
          with Pre => First <= Max_Header_Bytes - 8
                            and then First + 7 <= Last and then Last <= Data'Last
   is
   begin
      return Last - First = 7
        and then Is_Byte (Data (First), 'H')
        and then Is_Byte (Data (First + 1), 'T')
        and then Is_Byte (Data (First + 2), 'T')
        and then Is_Byte (Data (First + 3), 'P')
        and then Is_Byte (Data (First + 4), '/')
        and then (Is_Byte (Data (First + 5), '1'))
        and then Is_Byte (Data (First + 6), '.')
        and then (Is_Byte (Data (First + 7), '0')
                  or else Is_Byte (Data (First + 7), '1'));
   end Is_Version;

   procedure Find_Head_End
   (Data      : Head_Buffer;
      Available : Natural;
      Status    : out Parse_Status;
      End_At    : out Natural)
   is
   begin
      End_At := 0;
      if Available > Max_Header_Bytes then
         Status := Too_Large;
         return;
      end if;
      if Available < 4 then
         Status := Incomplete;
         return;
      end if;

      for Index in Data'First .. Data'First + Available - 4 loop
         if Data (Index) = Cr and then Data (Index + 1) = Lf
           and then Data (Index + 2) = Cr and then Data (Index + 3) = Lf
         then
            End_At := Index + 3;
            Status := Complete;
            return;
         end if;
      end loop;
      Status := Incomplete;
   end Find_Head_End;

   procedure Request_Line
   (Data           : Head_Buffer;
      First          : Natural;
      Last           : Natural;
      Parsed_Method  : out Method;
      Target_First   : out Natural;
      Target_Last    : out Natural;
      Parsed_Version : out Version;
      Status         : out Parse_Status)
   is
      First_Space  : Natural := Last;
      Second_Space : Natural := Last;
   begin
      Parsed_Method := Get;
      Target_First := First;
      Target_Last := First;
      Parsed_Version := Http_11;

      for Index in First .. Last loop
         pragma Loop_Invariant (First_Space <= Last);
         pragma Loop_Invariant (Second_Space <= Last);
         if Data (Index) = Cr or else Data (Index) = Lf then
            Status := Malformed;
            return;
         elsif Data (Index) = Sp then
            if First_Space = Last then
               First_Space := Index;
            elsif Second_Space = Last then
               Second_Space := Index;
            else
               Status := Malformed;
               return;
            end if;
         end if;
      end loop;

         if First_Space = Last or else Second_Space = Last then
            Status := Malformed;
            return;
         end if;
         if First_Space = First or else First_Space + 1 = Second_Space
           or else Last - Second_Space /= 8
      then
         Status := Malformed;
         return;
      end if;

      if Is_Version (Data, Second_Space + 1, Last) then
         if Is_Byte (Data (Last), '0') then
            Parsed_Version := Http_10;
         end if;
      else
         Status := Malformed;
         return;
      end if;

      if First_Space - First = 3
        and then Is_Byte (Data (First), 'G')
        and then Is_Byte (Data (First + 1), 'E')
        and then Is_Byte (Data (First + 2), 'T')
      then
         Parsed_Method := Get;
      elsif First_Space - First = 4
        and then Is_Byte (Data (First), 'H')
        and then Is_Byte (Data (First + 1), 'E')
        and then Is_Byte (Data (First + 2), 'A')
        and then Is_Byte (Data (First + 3), 'D')
      then
         Parsed_Method := Head;
      elsif First_Space - First = 4
        and then Is_Byte (Data (First), 'P')
        and then Is_Byte (Data (First + 1), 'O')
        and then Is_Byte (Data (First + 2), 'S')
        and then Is_Byte (Data (First + 3), 'T')
      then
         Parsed_Method := Post;
      else
         Status := Malformed;
         return;
      end if;

      if Second_Space = 0 then
         Status := Malformed;
         return;
      end if;

      Target_First := First_Space + 1;
      Target_Last := Second_Space - 1;
      Status := Complete;
   end Request_Line;

   procedure Status_Line
   (Data           : Head_Buffer;
      First          : Natural;
      Last           : Natural;
      Parsed_Version : out Version;
      Code           : out Status_Code;
      Status         : out Parse_Status)
   is
      Value : Natural;
   begin
      Parsed_Version := Http_11;
      Code := 500;
      if Last - First < 11 or else Data (First + 8) /= Sp
        or else not Is_Version (Data, First, First + 7)
      then
         Status := Malformed;
         return;
      end if;
      if Is_Byte (Data (First + 7), '0') then
         Parsed_Version := Http_10;
      end if;
      if Data (First + 9) not in Iour.Byte (Character'Pos ('0')) ..
                               Iour.Byte (Character'Pos ('9'))
        or else Data (First + 10) not in Iour.Byte (Character'Pos ('0')) ..
                                        Iour.Byte (Character'Pos ('9'))
        or else Data (First + 11) not in Iour.Byte (Character'Pos ('0')) ..
                                        Iour.Byte (Character'Pos ('9'))
      then
         Status := Malformed;
         return;
      end if;
      Value := 100 * Digit (Data (First + 9))
        + 10 * Digit (Data (First + 10)) + Digit (Data (First + 11));
      if Value not in Natural (Status_Code'First) .. Natural (Status_Code'Last) then
         Status := Malformed;
         return;
      end if;
      Code := Status_Code (Value);
      Status := Complete;
   end Status_Line;

end Iour.Http.Parse;