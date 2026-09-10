------------------------------------------------------------------------------
--  Iour.Http.Buffer -- a bounded byte window for one HTTP connection.
--
--  Compact invalidates every slice into Data.  Callers retaining header
--  slices therefore keep the head buffer unchanged until the request ends.
------------------------------------------------------------------------------

package Iour.Http.Buffer with SPARK_Mode => On is

   --  The predicate below allows the one-past-the-end position, so the
   --  capacity has to stay far enough below Positive'Last that Capacity + 1
   --  cannot overflow.  A megabyte is orders of magnitude more than one
   --  connection's window ever needs.
   Max_Capacity : constant := 1_048_576;

   subtype Capacity_Range is Positive range 1 .. Max_Capacity;

   type Buffer (Capacity : Capacity_Range) is record
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

   --  "Count bytes are available from Source'First" is stated in index
   --  arithmetic rather than as Count <= Source'Length, because Byte_Array
   --  is indexed by Natural: an array running to Natural'Last has a length
   --  of Natural'Last + 1, so Source'Length is not itself a Natural and
   --  comparing Count against it carries a range check nothing can
   --  discharge.
   procedure Append
     (B      : in out Buffer;
      Source : Iour.Byte_Array;
      Count  : Natural)
     with Pre => Count <= Free (B)
                 and then (Count = 0
                           or else (Source'First <= Source'Last
                                    and then Count - 1 <=
                                               Source'Last - Source'First));

end Iour.Http.Buffer;