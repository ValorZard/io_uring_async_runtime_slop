------------------------------------------------------------------------------
--  Iour.Net -- asynchronous sockets that read like synchronous ones.
--
--  Every operation below submits to the calling shard's ring, suspends the
--  fiber, and returns when the completion arrives.  Written out, a
--  connection handler looks like this:
--
--     procedure Handle (Conn : Fiber_Argument) is
--        Buffer : Byte_Array (0 .. 1023);
--        N      : Io_Result;
--     begin
--        loop
--           Net.Receive (Socket (Conn), Buffer, N);
--           exit when N <= 0;
--           Net.Send_All (Socket (Conn), Buffer (0 .. Natural (N) - 1), N);
--           exit when N < 0;
--        end loop;
--        Net.Close (Socket (Conn), N);
--     end Handle;
--
--  No callbacks, no continuation, no explicit state.  While that fiber sits
--  inside Receive its core is running other connections.
--
--  One rule matters: any buffer handed to Receive, Send or Connect must
--  outlive the call.  A local variable of the fiber body satisfies this
--  automatically, because the fiber's stack is exactly what stays alive
--  while it is suspended.  A buffer that is not reachable for the whole
--  call -- a slice of something being reused, say -- is not safe, and the
--  kernel will happily write into whatever now occupies that memory.
--
--  Every operation reports io_uring's own result convention: at or above
--  zero is the value (bytes moved, accepted descriptor), below zero is the
--  negated errno.
------------------------------------------------------------------------------

with Iour.Ffi;

package Iour.Net with SPARK_Mode => On is

   subtype Socket is Descriptor;

   ---------------------------------------------------------------------------
   --  Setup (synchronous; startup only)
   ---------------------------------------------------------------------------

   --  Bind and listen.  Port 0 lets the kernel choose; ask Port_Of for the
   --  result.  Reuseport lets several listeners share one port, which is
   --  how a shared-nothing server gives every core its own accept queue.
   --  Side_Effects: these create kernel objects, and SPARK requires a
   --  function that does so to say it.  Call them only as the right-hand
   --  side of an assignment.
   function Listen
     (Port      : Natural;
      Backlog   : Natural := 4096;
      Reuseport : Boolean := False) return Io_Result
     with Side_Effects, Global => (In_Out => Ffi.Kernel);

   function New_Socket return Io_Result
     with Side_Effects, Global => (In_Out => Ffi.Kernel);

   function Port_Of (S : Socket) return Io_Result;

   --  Close outside a fiber, for sockets created before the runtime starts.
   function Close_Now (S : Socket) return Io_Result;

   Shut_Read  : constant := 0;
   Shut_Write : constant := 1;
   Shut_Both  : constant := 2;

   --  Half-close.  Applied to a listening socket this makes a pending
   --  Accept_Connection complete with an error, which is how a server stops
   --  accepting without waiting for one more client to turn up.
   function Shutdown_Now (S : Socket; How : Natural) return Io_Result;

   --  Keep a vanished peer from raising SIGPIPE; call once at startup.
   procedure Ignore_Broken_Pipes;

   ---------------------------------------------------------------------------
   --  Suspending operations (must be called from a fiber)
   ---------------------------------------------------------------------------

   --  Accept one connection, yielding the new descriptor as the result.
   procedure Accept_Connection (Listener : Socket; Result : out Io_Result);

   --  Read once.  A result of zero means the peer closed cleanly.
   procedure Receive
     (S : Socket; Buffer : out Byte_Array; Result : out Io_Result);

   --  Write once; may transfer fewer bytes than offered.
   procedure Send
     (S : Socket; Buffer : Byte_Array; Result : out Io_Result);

   --  Read until Buffer is full, resubmitting for short reads.  Result is
   --  Buffer'Length, zero if the peer closed before sending it all, or the
   --  first error.  This is the framing primitive for a fixed-size
   --  protocol: a stream socket splits messages wherever it likes.
   procedure Receive_Exact
     (S : Socket; Buffer : out Byte_Array; Result : out Io_Result);

   --  Write everything, resubmitting until it is all gone.  Result is the
   --  number of bytes written, or the first error.
   procedure Send_All
     (S : Socket; Buffer : Byte_Array; Result : out Io_Result);

   procedure Connect
     (S      : Socket;
      Host   : String;
      Port   : Natural;
      Result : out Io_Result);

   procedure Close (S : Socket; Result : out Io_Result);

end Iour.Net;
