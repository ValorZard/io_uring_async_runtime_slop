------------------------------------------------------------------------------
--  Iour.Ffi.Net -- the synchronous half of sockets.
--
--  Creating a socket, binding it, listening, asking what port the system
--  chose, closing, half-closing: everything that happens once, at start-up
--  or at teardown, and that no fiber ever waits on.  Every byte of traffic
--  afterwards moves through Iour.Reactor.
--
--  The spec is portable and the body is not.  Underneath, Linux calls
--  socket/bind/listen/setsockopt/getsockname/close and Windows calls the
--  Winsock spellings of the same six, with WSA_FLAG_OVERLAPPED on the
--  socket because an overlapped handle is what the completion port
--  requires.  Neither of those vocabularies appears here.
--
--  All of these follow the runtime's reporting convention rather than
--  either system's, so a caller never has to switch between "-1 plus
--  errno" and "SOCKET_ERROR plus WSAGetLastError": at or above zero is the
--  value, below zero is the negated error code.
--
--  Side_Effects (Ada 2022 / SPARK) is what lets a function both return a
--  value and be honest about changing kernel state.  The price is that
--  such a function may only be called as the right-hand side of an
--  assignment, which is how every caller already uses these.
------------------------------------------------------------------------------

with Interfaces; use Interfaces;

package Iour.Ffi.Net with SPARK_Mode => On is

   --  Prepare the system's networking layer.  A no-op on Linux; on Windows
   --  it is WSAStartup, which must happen before any socket call in the
   --  process.  Idempotent, and called from the environment task before any
   --  shard is up.
   pragma Warnings
     (GNATprove, Off, "*is not modified, could be INPUT*",
      Reason => "The Windows body writes Kernel; the Linux one does not. The contract is the union, and narrowing it would be wrong for the other backend.");
   procedure Initialize
     with Global => (In_Out => Kernel), Always_Terminates;
   pragma Warnings
     (GNATprove, On, "*is not modified, could be INPUT*");

   --  A TCP socket with TCP_NODELAY set.  Latency beats coalescing for the
   --  request/response traffic this runtime is built for.
   function Tcp_Socket return Io_Result
     with Side_Effects, Global => (In_Out => Kernel);

   --  A bound, listening socket.  Address reuse always, so a restarted
   --  server does not trip over its own lingering sockets; port sharing
   --  when asked, which lets several shards hold a listener on one port.
   --
   --  Port sharing is SO_REUSEPORT on Linux, where the kernel hashes
   --  connections across the listeners.  Windows has no equivalent that
   --  behaves this way -- SO_REUSEADDR there lets a second bind steal the
   --  port outright rather than share it -- so the Windows body declines
   --  the request and the caller falls back to one listener.
   function Tcp_Listener
     (Host      : Unsigned_32;
      Port      : Unsigned_16;
      Backlog   : Natural := 4096;
      Reuseport : Boolean := False) return Io_Result
     with Side_Effects, Global => (In_Out => Kernel);

   --  Whether Tcp_Listener can actually give every shard its own listener
   --  on one port.  A server asks this rather than assuming, and puts one
   --  acceptor on one core when the answer is no.
   function Port_Sharing_Available return Boolean with Global => null;

   --  The port a socket ended up bound to, which matters when binding to
   --  port 0 and letting the system choose.
   function Local_Port (Fd : Descriptor) return Io_Result;

   function Close (Fd : Descriptor) return Io_Result
     with Side_Effects, Global => (In_Out => Kernel);

   --  The same call for the paths where the result carries nothing anyone
   --  acts on: an error unwind, or a ring being torn down.
   procedure Close_Quietly (Fd : Descriptor)
     with Global => (In_Out => Kernel), Always_Terminates;

   Shut_Read  : constant := 0;
   Shut_Write : constant := 1;
   Shut_Both  : constant := 2;

   --  Half-close a socket.  On a listening socket this is what makes a
   --  pending accept give up, which is how a server stops accepting
   --  without waiting for one more client to arrive.
   function Shutdown (Fd : Descriptor; How : Natural) return Io_Result
     with Side_Effects, Global => (In_Out => Kernel);

end Iour.Ffi.Net;
