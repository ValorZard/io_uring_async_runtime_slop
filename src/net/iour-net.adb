with Interfaces; use Interfaces;
with System;
with Iour.Async;
with Iour.Ffi.Memory;
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
         --  Nothing to fill.  The aggregate is a no-op on an empty array
         --  but is what lets SPARK see the out parameter as initialised.
         Buffer := [others => 0];
         Result := 0;
         return;
      end if;
      --  Buffer belongs to the caller's frame, which is on the fiber's own
      --  stack and therefore stays put for as long as the fiber is
      --  suspended -- exactly as long as the kernel needs it.
      declare
         Target : System.Address;
      begin
         Target := Ffi.Memory.Of_Output (Buffer);
         Async.Perform
           (Reactor.Op_Recv (S, Target, Buffer'Length, 0), Result);
      end;
   end Receive;

   procedure Send
     (S : Socket; Buffer : Byte_Array; Result : out Io_Result) is
   begin
      if Buffer'Length = 0 then
         Result := 0;
         return;
      end if;
      Async.Perform
        (Reactor.Op_Send
           (S, Ffi.Memory.Of_Bytes (Buffer), Buffer'Length, 0),
         Result);
   end Send;

   procedure Receive_Exact
     (S : Socket; Buffer : out Byte_Array; Result : out Io_Result)
   is
      Got    : Natural := 0;
      Step   : Io_Result;
      Target : System.Address;
   begin
      if Buffer'Length = 0 then
         Buffer := [others => 0];
         Result := 0;
         return;
      end if;

      --  One address for the whole buffer; each round reads into the part
      --  not yet filled, found by advancing it.
      Target := Ffi.Memory.Of_Output (Buffer);

      while Got < Buffer'Length loop
         pragma Loop_Invariant (Got < Buffer'Length);
         pragma Loop_Variant (Increases => Got);
         Async.Perform
           (Reactor.Op_Recv
              (S, Ffi.Memory.Advance (Target, Got), Buffer'Length - Got, 0),
            Step);

         if Step < 0 then
            Result := Step;
            return;
         elsif Step = 0 then
            --  Peer closed mid-message.  Report a clean end of stream
            --  rather than a partial frame the caller cannot use.
            Result := 0;
            return;
         elsif Step > Io_Result (Buffer'Length - Got) then
            --  The kernel never returns more than was asked for.  Refuse
            --  to believe it if it ever did, rather than run off the end.
            Result := -E_Invalid;
            return;
         end if;

         Got := Got + Natural (Step);
      end loop;

      Result := Io_Result (Buffer'Length);
   end Receive_Exact;

   procedure Send_All
     (S : Socket; Buffer : Byte_Array; Result : out Io_Result)
   is
      Sent   : Natural := 0;
      Step   : Io_Result;
      Source : System.Address;
   begin
      if Buffer'Length = 0 then
         Result := 0;
         return;
      end if;
      Source := Ffi.Memory.Of_Bytes (Buffer);

      --  A stream socket may accept only part of a write; keep going until
      --  it is all gone or the peer stops listening.
      while Sent < Buffer'Length loop
         pragma Loop_Invariant (Sent < Buffer'Length);
         pragma Loop_Variant (Increases => Sent);
         Async.Perform
           (Reactor.Op_Send
              (S, Ffi.Memory.Advance (Source, Sent), Buffer'Length - Sent, 0),
            Step);

         if Step < 0 then
            Result := Step;
            return;
         elsif Step = 0 then
            --  Nothing moved and no error: the peer is gone.
            Result := -E_Pipe;
            return;
         elsif Step > Io_Result (Buffer'Length - Sent) then
            Result := -E_Invalid;   --  more than offered: not possible
            return;
         end if;

         Sent := Sent + Natural (Step);
      end loop;

      Result := Io_Result (Sent);
   end Send_All;

   procedure Write_All
     (Fd : Descriptor; Buffer : Byte_Array; Result : out Io_Result)
   is
      Sent   : Natural := 0;
      Step   : Io_Result;
      Source : System.Address;
   begin
      if Buffer'Length = 0 then
         Result := 0;
         return;
      end if;
      Source := Ffi.Memory.Of_Bytes (Buffer);

      while Sent < Buffer'Length loop
         pragma Loop_Invariant (Sent < Buffer'Length);
         pragma Loop_Variant (Increases => Sent);
         Async.Perform
           (Reactor.Op_Write
              (Fd, Ffi.Memory.Advance (Source, Sent), Buffer'Length - Sent, 0),
            Step);

         if Step < 0 then
            Result := Step;
            return;
         elsif Step = 0 then
            Result := -E_Pipe;
            return;
         elsif Step > Io_Result (Buffer'Length - Sent) then
            Result := -E_Invalid;
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
           (S, Ffi.Memory.Of_Sockaddr (Endpoint), Raw.Sockaddr_In'Size / 8, 0),
         Result);
   end Connect;

   procedure Close (S : Socket; Result : out Io_Result) is
   begin
      Async.Perform (Reactor.Op_Close (S, 0), Result);
   end Close;

end Iour.Net;
