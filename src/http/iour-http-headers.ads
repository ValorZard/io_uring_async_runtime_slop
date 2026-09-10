------------------------------------------------------------------------------
--  Iour.Http.Headers -- bounded, zero-copy slices into an HTTP head buffer.
------------------------------------------------------------------------------

package Iour.Http.Headers with SPARK_Mode => On is

   --  Head_Index rather than Natural: these are positions in a head
   --  buffer, and saying so is what bounds Name_Last - Name_First + 1
   --  below Natural'Last in Find.
   type Header_Slice is record
      Name_First  : Head_Index := 0;
      Name_Last   : Head_Index := 0;
      Value_First : Head_Index := 0;
      Value_Last  : Head_Index := 0;
   end record;

   type Header_Table is private;

   procedure Clear (Headers : in out Header_Table);

   procedure Add
     (Headers     : in out Header_Table;
      Name_First  : Head_Index;
      Name_Last   : Head_Index;
      Value_First : Head_Index;
      Value_Last  : Head_Index;
      Status      : out Parse_Status)
     with Pre => Name_First <= Name_Last and then Value_First <= Value_Last;

   function Count (Headers : Header_Table) return Natural;

   --  Data is the head buffer the slices point into.  A slice that does
   --  not lie wholly inside it is skipped rather than trusted, which is
   --  what lets this be called with any window of the connection's bytes.
   procedure Find
     (Headers : Header_Table;
      Data    : Iour.Byte_Array;
      Name    : String;
      Found   : out Boolean;
      Value   : out Header_Slice)
     with Global => null;

private

   type Header_Array is array (Positive range 1 .. Max_Headers) of Header_Slice;

   type Header_Table is record
      Entries : Header_Array := [others => (others => 0)];
      Used    : Natural range 0 .. Max_Headers := 0;
   end record;

end Iour.Http.Headers;