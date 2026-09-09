------------------------------------------------------------------------------
--  Iour.Http.Headers -- bounded, zero-copy slices into an HTTP head buffer.
------------------------------------------------------------------------------

package Iour.Http.Headers with SPARK_Mode => On is

   type Header_Slice is record
      Name_First  : Natural := 0;
      Name_Last   : Natural := 0;
      Value_First : Natural := 0;
      Value_Last  : Natural := 0;
   end record;

   type Header_Table is private;

   procedure Clear (Headers : in out Header_Table);

   procedure Add
     (Headers     : in out Header_Table;
      Name_First  : Natural;
      Name_Last   : Natural;
      Value_First : Natural;
      Value_Last  : Natural;
      Status      : out Parse_Status)
     with Pre => Name_First <= Name_Last and then Value_First <= Value_Last;

   function Count (Headers : Header_Table) return Natural;

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