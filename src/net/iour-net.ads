------------------------------------------------------------------------------
--  Iour.Net -- asynchronous sockets that read like synchronous ones.
--
--  Every operation below submits to the calling shard's reactor, suspends
--  the fiber, and returns when the completion arrives.  Written out, a
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
--  Every operation reports the runtime's result convention: at or above
--  zero is the value (bytes moved, accepted descriptor), below zero is the
--  negated error code.  See Iour.Io_Result.
------------------------------------------------------------------------------

with Iour.Ffi;
with Iour.Fibers;
with Iour.Reactor;

--  A suspending operation touches the ring (Reactor.Engines), the fiber
--  table it suspends through (Fibers.Registry), and the kernel.  It does
--  not touch the future table: an ordinary operation is awaited by the
--  fiber that submitted it, and the shard that reaps the completion hands
--  the result straight back (Iour.Reactor.Tag_Fiber_Io).  Only the stream
--  operations at the end need a future.  None of these carries
--  Always_Terminates, and that is deliberate: a Receive on a socket whose
--  peer never sends does not return, and a contract that said otherwise
--  would be false.
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

   --  Whether Listen with Reuseport can really give every core a listener
   --  of its own on one port.
   --
   --  True on Linux, where SO_REUSEPORT makes the kernel hash arriving
   --  connections across the listeners.  False on Windows, which has no
   --  equivalent: its SO_REUSEADDR lets a second bind take the port over
   --  rather than share it, so a server that assumed otherwise would run
   --  on one core and look like it was running on all of them.
   --
   --  A server asks this rather than assuming, and puts a single acceptor
   --  on one core when the answer is no.
   function Port_Sharing_Available return Boolean with Global => null;

   function Port_Of (S : Socket) return Io_Result
     with Global => null;

   --  Close without suspending: for sockets created before the runtime
   --  starts, and for a fixed file whose owning shard needs it gone at
   --  once -- which only that shard's own thread can do.
   function Close_Now (S : Socket) return Io_Result
     with Side_Effects, Global => (In_Out => (Ffi.Kernel, Reactor.Engines));

   Shut_Read  : constant := 0;
   Shut_Write : constant := 1;
   Shut_Both  : constant := 2;

   --  Half-close.  Applied to a listening socket this makes a pending
   --  Accept_Connection complete with an error, which is how a server stops
   --  accepting without waiting for one more client to turn up.
   function Shutdown_Now (S : Socket; How : Natural) return Io_Result
     with Side_Effects, Global => (In_Out => Ffi.Kernel);

   --  Keep a vanished peer from raising SIGPIPE; call once at startup.
   procedure Ignore_Broken_Pipes
     with Global => (In_Out => Ffi.Kernel);

   ---------------------------------------------------------------------------
   --  Suspending operations (must be called from a fiber)
   ---------------------------------------------------------------------------

   --  Accept one connection, yielding the new descriptor as the result.
   --  On a shard whose ring registered a file table the socket goes
   --  straight into that table and the result is a fixed-file descriptor
   --  (Iour.Fixed_File): usable by this shard's fibers exactly like an fd,
   --  but cheaper per operation, and meaningless on any other core.
   procedure Accept_Connection (Listener : Socket; Result : out Io_Result)
     with Global => (In_Out => (Reactor.Engines, Fibers.Registry,
                                Ffi.Kernel));

   --  Read once.  A result of zero means the peer closed cleanly.
   procedure Receive
     (S : Socket; Buffer : out Byte_Array; Result : out Io_Result)
     with Pre    => Buffer'Length <= Max_Transfer,
          Global => (In_Out => (Reactor.Engines, Fibers.Registry,
                                Ffi.Kernel));

   --  Write once; may transfer fewer bytes than offered.
   procedure Send
     (S : Socket; Buffer : Byte_Array; Result : out Io_Result)
     with Pre    => Buffer'Length <= Max_Transfer,
          Global => (In_Out => (Reactor.Engines, Fibers.Registry,
                                Ffi.Kernel));

   --  Read until Buffer is full, resubmitting for short reads.  Result is
   --  Buffer'Length, zero if the peer closed before sending it all, or the
   --  first error.  This is the framing primitive for a fixed-size
   --  protocol: a stream socket splits messages wherever it likes.
   procedure Receive_Exact
     (S : Socket; Buffer : out Byte_Array; Result : out Io_Result)
     with Pre    => Buffer'Length <= Max_Transfer,
          Global => (In_Out => (Reactor.Engines, Fibers.Registry,
                                Ffi.Kernel));

   --  Write everything, resubmitting until it is all gone.  Result is the
   --  number of bytes written, or the first error.
   procedure Send_All
     (S : Socket; Buffer : Byte_Array; Result : out Io_Result)
     with Pre    => Buffer'Length <= Max_Transfer,
          Global => (In_Out => (Reactor.Engines, Fibers.Registry,
                                Ffi.Kernel));

   --  Write everything to a non-socket descriptor: stdout, stderr, a file.
   --  Iour.Text is built on this.
   procedure Write_All
     (Fd : Descriptor; Buffer : Byte_Array; Result : out Io_Result)
     with Pre    => Buffer'Length <= Max_Transfer,
          Global => (In_Out => (Reactor.Engines, Fibers.Registry,
                                Ffi.Kernel));

   procedure Connect
     (S      : Socket;
      Host   : String;
      Port   : Natural;
      Result : out Io_Result)
     with Global => (In_Out => (Reactor.Engines, Fibers.Registry,
                                Ffi.Kernel));

   procedure Close (S : Socket; Result : out Io_Result)
     with Global => (In_Out => (Reactor.Engines, Fibers.Registry,
                                Ffi.Kernel));

end Iour.Net;
