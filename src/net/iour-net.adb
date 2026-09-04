with Interfaces; use Interfaces;
with Iour.Async;
with Iour.Ffi.Net;
with Iour.Ffi.Sys;

package body Iour.Net with SPARK_Mode => On is

   package Raw renames Iour.Ffi.Net;

   ---------------------------------------------------------------------------
   --  Setup
   ---------------------------------------------------------------------------

   function Listen
     (Port      : Natural;
      Backlog   : Natural := 4096;
      Reuseport : Boolean := False) return Io_Result
   is
      Result : Io_Result;
   begin
      if Port > 65_535 then
         return -E_Invalid;
      end if;
      --  A Side_Effects function may only be called as an assignment.
      Result := Raw.Tcp_Listener
        (Host      => Raw.Any_Address,
         Port      => Unsigned_16 (Port),
         Backlog   => Backlog,
         Reuseport => Reuseport);
      return Result;
   end Listen;

   function New_Socket return Io_Result is
      Result : Io_Result;
   begin
      Result := Raw.Tcp_Socket;
      return Result;
   end New_Socket;

   function Port_Of (S : Socket) return Io_Result is (Raw.Local_Port (S));

   function Close_Now (S : Socket) return Io_Result is
      Result : Io_Result;
   begin
      Result := Raw.Close (S);
      return Result;
   end Close_Now;

   function Shutdown_Now (S : Socket; How : Natural) return Io_Result is
      Result : Io_Result;
   begin
      Result := Raw.Shutdown (S, How);
      return Result;
   end Shutdown_Now;

   procedure Ignore_Broken_Pipes is
   begin
      Ffi.Sys.Ignore_Sigpipe;
   end Ignore_Broken_Pipes;

   ---------------------------------------------------------------------------
   --  Operations
   ---------------------------------------------------------------------------

   procedure Accept_Connection (Listener : Socket; Result : out Io_Result) is
   begin
      Async.Perform (Reactor.Op_Accept (Listener, 0), Result);
   end Accept_Connection;

   procedure Receive
     (S : Socket; Buffer : out Byte_Array; Result : out Io_Result) is
   begin
      if Buffer'Length = 0 then
         Result := 0;
         return;
      end if;
      --  Buffer belongs to the caller's frame, which is on the fiber's own
      --  stack and therefore stays put for as long as the fiber is
      --  suspended -- exactly as long as the kernel needs it.
      Async.Perform
        (Reactor.Op_Recv (S, Buffer'Address, Buffer'Length, 0), Result);
   end Receive;

   procedure Send
     (S : Socket; Buffer : Byte_Array; Result : out Io_Result) is
   begin
      if Buffer'Length = 0 then
         Result := 0;
         return;
      end if;
      Async.Perform
        (Reactor.Op_Send (S, Buffer'Address, Buffer'Length, 0), Result);
   end Send;

   procedure Receive_Exact
     (S : Socket; Buffer : out Byte_Array; Result : out Io_Result)
   is
      Got  : Natural := 0;
      Step : Io_Result;
   begin
      if Buffer'Length = 0 then
         Result := 0;
         return;
      end if;

      while Got < Buffer'Length loop
         declare
            Rest : Byte_Array renames
              Buffer (Buffer'First + Got .. Buffer'Last);
         begin
            Async.Perform
              (Reactor.Op_Recv (S, Rest'Address, Rest'Length, 0), Step);
         end;

         if Step < 0 then
            Result := Step;
            return;
         elsif Step = 0 then
            --  Peer closed mid-message.  Report a clean end of stream
            --  rather than a partial frame the caller cannot use.
            Result := 0;
            return;
         end if;

         Got := Got + Natural (Step);
      end loop;

      Result := Io_Result (Buffer'Length);
   end Receive_Exact;

   procedure Send_All
     (S : Socket; Buffer : Byte_Array; Result : out Io_Result)
   is
      Sent  : Natural := 0;
      Step  : Io_Result;
   begin
      if Buffer'Length = 0 then
         Result := 0;
         return;
      end if;

      --  A stream socket may accept only part of a write; keep going until
      --  it is all gone or the peer stops listening.
      while Sent < Buffer'Length loop
         declare
            Chunk : Byte_Array renames
              Buffer (Buffer'First + Sent .. Buffer'Last);
         begin
            Async.Perform
              (Reactor.Op_Send (S, Chunk'Address, Chunk'Length, 0), Step);
         end;

         if Step < 0 then
            Result := Step;
            return;
         elsif Step = 0 then
            --  Nothing moved and no error: the peer is gone.
            Result := -E_Pipe;
            return;
         end if;

         Sent := Sent + Natural (Step);
      end loop;

      Result := Io_Result (Sent);
   end Send_All;

   procedure Write_All
     (Fd : Descriptor; Buffer : Byte_Array; Result : out Io_Result)
   is
      Sent : Natural := 0;
      Step : Io_Result;
   begin
      if Buffer'Length = 0 then
         Result := 0;
         return;
      end if;

      while Sent < Buffer'Length loop
         declare
            Chunk : Byte_Array renames
              Buffer (Buffer'First + Sent .. Buffer'Last);
         begin
            Async.Perform
              (Reactor.Op_Write (Fd, Chunk'Address, Chunk'Length, 0), Step);
         end;

         if Step < 0 then
            Result := Step;
            return;
         elsif Step = 0 then
            Result := -E_Pipe;
            return;
         end if;

         Sent := Sent + Natural (Step);
      end loop;

      Result := Io_Result (Sent);
   end Write_All;

   procedure Connect
     (S      : Socket;
      Host   : String;
      Port   : Natural;
      Result : out Io_Result)
   is
      --  Local, so it lives on the fiber's stack for the whole of the
      --  operation.  The kernel reads it after this call has suspended.
      Endpoint : aliased Raw.Sockaddr_In;
      Host_Ip  : Unsigned_32;
      Valid    : Boolean;
   begin
      if Port > 65_535 then
         Result := -E_Invalid;
         return;
      end if;

      Raw.Parse_Ipv4 (Host, Host_Ip, Valid);
      if not Valid then
         Result := -E_Invalid;
         return;
      end if;

      Endpoint := Raw.Make_Address (Host_Ip, Unsigned_16 (Port));

      Async.Perform
        (Reactor.Op_Connect
           (S, Endpoint'Address, Raw.Sockaddr_In'Size / 8, 0),
         Result);
   end Connect;

   procedure Close (S : Socket; Result : out Io_Result) is
   begin
      Async.Perform (Reactor.Op_Close (S, 0), Result);
   end Close;

end Iour.Net;
