package body Iour.Http with SPARK_Mode => On is

   function Body_Framing
     (Request_Method      : Method;
      Response_Status     : Status_Code;
      Has_Chunked         : Boolean;
      Has_Content_Length  : Boolean) return Body_Kind
   is
   begin
      if Request_Method = Head
        or else Response_Status in 100 .. 199
        or else Response_Status = 204
        or else Response_Status = 205
        or else Response_Status = 304
      then
         return No_Body;
      elsif Has_Chunked then
         return Chunked;
      elsif Has_Content_Length then
         return Fixed_Length;
      else
         return Until_Close;
      end if;
   end Body_Framing;

end Iour.Http;