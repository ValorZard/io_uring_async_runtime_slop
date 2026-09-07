------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Text body.
------------------------------------------------------------------------------

package body Iour.Ffi.Fiber.Text with SPARK_Mode => On is

   function Digit (N : Natural) return Character is
     (Character'Val (Character'Pos ('0') + N))
     with Pre => N <= 9;

   function Dec (N : Small) return String is
     (if N < 10 then [1 => Digit (N)]
      elsif N < 100 then [Digit (N / 10), Digit (N mod 10)]
      else [Digit (N / 100), Digit ((N / 10) mod 10), Digit (N mod 10)]);

   procedure Expect
     (Text : String;
      Cur  : in out Positive;
      Ok   : in out Boolean;
      S    : String) is
   begin
      if not Ok or else S'Length = 0 then
         return;
      end if;
      if S'Length > Text'Last - Cur + 1 then
         Ok := False;
         return;
      end if;
      if Text (Cur .. Cur + S'Length - 1) /= S then
         Ok := False;
      else
         Cur := Cur + S'Length;
      end if;
   end Expect;

end Iour.Ffi.Fiber.Text;
