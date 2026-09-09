------------------------------------------------------------------------------
--  Iour.Http.Buffer -- a bounded byte window for one HTTP connection.
--
--  Compact invalidates every slice into Data.  Callers retaining header
--  slices therefore keep the head buffer unchanged until the request ends.
------------------------------------------------------------------------------

package Iour.Http.Buffer with SPARK_Mode => On is

   type Buffer (Capacity : Positive) is record
    Data  : Byte_Array (1 .. Capacity) := [others => 0];
    First : Natural := 1;
    Last  : Natural := 1;
   end record
    with Predicate => First in 1 .. Capacity + 1
                and then Last in 1 .. Capacity + 1
                and then First <= Last;

   function Available (B : Buffer) return Natural is (B.Last - B.First);
  function Free (B : Buffer) return Natural is (B.Capacity - B.Last + 1);

   procedure Consume (B : in out Buffer; Count : Natural)
     with Pre => Count <= Available (B);

   procedure Compact (B : in out Buffer);

   procedure Append
     (B      : in out Buffer;
      Source : Iour.Byte_Array;
      Count  : Natural)
     with Pre => Count <= Source'Length and then Count <= Free (B);

end Iour.Http.Buffer;