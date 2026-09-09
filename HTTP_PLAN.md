# Adding an HTTP/1.1 client and server, and WebSockets

A plan, not an implementation. It says where the code goes, what shape it
takes, which parts of [aht](https://github.com/ovenpasta/aht) come across
and which cannot, what it costs in stack and memory, and the three things
the runtime is missing that this work needs.

The short answer: **all of it sits above `Iour.Net` and none of it touches
the platform seam.** Two new portable source directories, no change to
`Iour.Reactor`, no new `Op_Kind`, and no new `SPARK_Mode => Off` body --
with four exceptions, all listed under *What the runtime is missing*. One
of them blocks the client, one is a latent defect in the Linux accept path
that HTTP would be the first thing to notice, and two are optional.

The longer answer is that aht is a *synchronous, heap-based,
exception-raising client library*, and every one of those three traits is
load-bearing in its design and forbidden here. What transfers is its
accumulated correctness -- the framing rules, the decoder's error
conditions, the WebSocket sequencing table -- not its code.

---

## What aht is, and what of it survives
controlled heap buffers, access-to-subprogram callbacks and exceptions. TLS
is out of scope here by instruction, and dropping it removes the only
reason its transport layer is class-wide.

Five rewrites, each forced by a rule this codebase already documents:

| aht | why it cannot come | what replaces it |
|---|---|---|
| `AHT.Bytes.Buffer`, `Ada.Finalization.Controlled` over an access to `Byte_Array` | no heap, no access types | a fixed-capacity record on the fiber's own stack |
| `AHT.HTTP.Headers.Map`, `Indefinite_Vectors` of `Unbounded_String` | heap, containers | a table of index quads into the read buffer, copying nothing |
| a `Sink` parameter of access-to-procedure type | SPARK refuses access-to-subprogram with global effects, the rule that made `Iour.Fibers.Job` exist | a pull loop the fiber writes itself |
| `raise AHT.HTTP.Protocol_Error` | the partition does not propagate exceptions | an `out` status enumeration, beside `Io_Result` for transport failures |
| `AHT.Transport.Transport_Type'Class` dispatch | one transport, once TLS is gone | call `Iour.Net` directly |

### The callback row is the interesting one

aht streams a body through a callback because a synchronous parser has
nowhere to suspend in the middle of one. A stackful fiber does. So the
whole streaming surface inverts:

```ada
   --  aht: push.  The parser owns the loop, the caller owns a callback.
   Response.Read_Streaming (R, T, Sink => Print'Access);

   --  here: pull.  The caller owns the loop, and it is ordinary code.
   loop
      Http.Read_Body_Chunk (C, Chunk, Last, Status);
      exit when Status /= Http.More;
      ...
   end loop;
```
is the one place where this runtime makes the problem *smaller* than aht
found it. Three of aht's packages exist only to manage the consequences of
push-mode delivery in a task-based client, and have no counterpart here:

* `aht-websocket-handoffs`, moving a connection between tasks;
* `aht-websocket-send_guards`, serialising sends against a receive running
  in another task;
* `aht-websocket-budgets`, bounding what a callback may consume.

A fiber owns its socket for the connection's whole life. There is nothing
to hand off, nothing to guard, and the budget is the fiber's stack.

### What does come across, close to verbatim

The logic, which is the part with the bugs in it and the part SPARK proves
best. Copy it deliberately rather than re-deriving it:

* **The body-framing decision table** from `aht-http-response.ads`. 1xx,
  204, 205, 304, or a HEAD request, means no body whatever the framing
  headers say -- so a 101's following bytes stay on the socket for the
  WebSocket layer, and a 204 on a `Connection: close` stream does not wait
  for EOF. Else `Transfer-Encoding: chunked`. Else `Content-Length`. Else
  read until the peer closes.
* **The chunked decoder's error conditions** from `aht-http-io.ads`: a
  non-hex size, a size overflowing the length type, chunk data not followed
  by a bare CRLF, trailers drained and discarded.
* **The whole of `aht-websocket-frames.ads`.** Reserved opcodes, RSV bits
  set, control frames with FIN clear or over 125 bytes, non-minimal length
  encodings, a 64-bit length with the top bit set, fragment sequencing, and
  the mapping of a bad frame to 1002, bad UTF-8 to 1007 and an oversized
  message to 1009. Its ordering rule matters and is easy to get wrong:
  sequencing is checked *before* size, so a misplaced frame is 1002 rather
  than 1009.
* **Base64 per RFC 4648 section 4**, standard alphabet with `=` padding,
  for the handshake key.

---

## Where the code goes

Two directories, both portable, added to `Portable_Dirs` in
[io_uring_async_runtime.gpr](io_uring_async_runtime.gpr). Nothing else in
the build changes: `examples.gpr` and `tests.gpr` both `with` the library
project and inherit its sources.

```
   Portable_Dirs := ("src", "src/ffi", "src/runtime", "src/net",
                     "src/http", "src/ws")
                    & Config_Dir;
```

### `src/http/`

| unit | holds |
|---|---|
| `Iour.Http` | vocabulary: methods, status codes, parse status, the limits |
| `Iour.Http.Buffer` | fixed-capacity byte buffer with compaction |
| `Iour.Http.Headers` | the slice table and case-insensitive lookup |
| `Iour.Http.Parse` | pure parsers. No I/O, `Global => null` |
| `Iour.Http.Wire` | fill, read head, read body, write head, write body |
| `Iour.Http.Client` | one request over a socket the caller connected |
| `Iour.Http.Server` | the generic. Instantiates `Iour.Fibers.Job` |
| `Iour.Http.Url` | scheme, host, port, path, and percent-encoding |

**Split parsing from I/O hard.** `Iour.Http.Parse` should be pure functions
over `Byte_Array` that can be proved and tested with no socket anywhere
near them, and `Iour.Http.Wire` should be the only unit in the directory
that calls `Iour.Net`. That split is what lets `make prove` cover the part
where protocol bugs live, and it is what makes a corpus test possible
without a running server. It is the same arrangement as
`Iour.Ffi.Fiber.Machine` beside its `Off` body: the meaning lifted out to
somewhere it can be reasoned about.

### `src/ws/`

| unit | holds |
|---|---|
| `Iour.Ws` | opcodes, close codes, limits |
| `Iour.Ws.Frames` | header encode and decode, masking |
| `Iour.Ws.Utf8` | the validator for text payloads and close reasons |
| `Iour.Ws.Sha1` | RFC 3174, needed only by the handshake |
| `Iour.Ws.Base64` | encode, and decode for a client verifying the accept |
| `Iour.Ws.Conn` | message and frame level send and receive |

SHA-1 and Base64 are about 200 lines together, pure, fixed-size and
provable. RFC 6455 mandates SHA-1 for the handshake and there is no way
around it; it is not used as a security primitive.

---

## The data structures

### The header table is the keystone

Do not copy header names and values out of the read buffer. Store index
pairs into it:

```ada
   type Header_Slice is record
      Name_First, Name_Last   : Natural := 0;
      Value_First, Value_Last : Natural := 0;
   end record;

   type Header_Table is array (1 .. Max_Headers) of Header_Slice;
```

Thirty-two entries is 512 bytes, against roughly 10 KiB for the same
headers copied into fixed-width fields, which on a 64 KiB fiber stack is
the difference between comfortable and not. Lookup is a case-insensitive
compare over a slice of the buffer. It is also exactly the shape the rest
of this runtime already has: *handles are small integers into a table*, and
here the table is the bytes that arrived.

The consequence to design around: **a header slice is only valid while the
read buffer still holds that request's head.** So the buffer must not be
compacted or refilled underneath a live request, which means the head and
the body cannot share one buffer region carelessly. Either keep the head at
the front and read the body into a separate window, or copy the few header
values the handler asks to retain. State the invariant in the spec and give
the request type a predicate that reflects it.

### The buffer

```ada
   type Buffer (Capacity : Positive) is record
      Data  : Byte_Array (0 .. Capacity - 1) := [others => 0];
      First : Natural := 0;   --  unread data is Data (First .. Last)
      Last  : Natural := 0;
   end record;
```

Discriminated rather than generic, so one type serves the 8 KiB read buffer
and the 2 KiB head buffer without two instantiations. Compaction moves the
unread span down to zero when a read needs room, which is the one operation
that invalidates header slices.

---

## The server

A generic taking the handler as a formal subprogram. That is not a style
choice: it is the only shape SPARK permits, for exactly the reason
`Iour.Fibers.Job` exists.

```ada
   --  in the application, at library level
   procedure Handle
     (Req : Iour.Http.Server_Request; Resp : in out Iour.Http.Responder);

   package My_Server is new Iour.Http.Server (Handle => Handle);
   ...
   My_Server.Start_Acceptor (Shard, Listener, Started);
```

Inside, `Iour.Http.Server` declares its own connection procedure and
instantiates `Iour.Fibers.Job` on it. Two things follow that are worth
being explicit about, because a consumer gets them without asking:

* **The handler is race-checked.** `Job` instantiates
  `Iour.Fibers.Race_Witness` from its visible part, so registering the
  connection body puts the handler and everything it reaches under SPARK's
  data-race rule. A handler sharing a plain variable between connections is
  reported as a possible data race, named at the instance. There is no list
  to keep in step and nothing for the application to remember.
* **The cost is two parked threads per `Server` instantiation**, plus two
  more for its acceptor job. `Max_Jobs` is 64, so a program may have at
  most that many kinds of fiber in total.

### Connection lifetime

One fiber per connection, for the connection's whole life, looping over
keep-alive requests. Identical to `Echo_Server_App`'s handler and for the
same reasons. `Max_Fibers` is 8192, so that is the ceiling on simultaneous
connections.

Acceptors follow the existing pattern exactly, including
`Concurrent_Acceptors` at 32 and the `Port_Sharing_Available` split between
one listener per shard on Linux and one acceptor dealing round the cores on
Windows. There is nothing HTTP-specific about any of it, so
`Iour.Http.Server` should offer the same `Configure` and `Start_Acceptor`
surface rather than inventing another.

### The responder wants a state field

Setting a header after the head has gone out is the classic HTTP server bug
and it is a silent one. Make it a proof obligation:

```ada
   type Phase is (Fresh, Head_Sent, Streaming, Done);

   type Responder is limited record
      Sock  : Iour.Net.Socket;
      State : Phase := Fresh;
      Head  : Buffer (Head_Capacity);
   end record;

   procedure Set_Status (R : in out Responder; Code : Status_Code)
     with Pre => R.State = Fresh;
```

SPARK will discharge these, and the result is that a misordered response
fails to prove rather than reaching a client. aht cannot write these
contracts because its equivalent state is implicit in the transport.

### Limits belong in the spec

All of them static constants in `Iour.Http`, all enforced by the wire layer
rather than by the handler: maximum request line, maximum header block,
maximum header count, maximum chunk size line. Exceeding one is a 431 or a
414 and a closed connection, not an unbounded read. The runtime has no
heap, so an unbounded read is not merely a denial of service; it is
impossible to write in the first place, which is the property to keep.

---

## The client

```ada
   Sock := Iour.Net.New_Socket;
   Iour.Net.Connect (Sock, "93.184.216.34", 80, R);
   Iour.Http.Client.Request (Sock, Get, "/", Headers, Resp, R);
```

The client does not own the socket and does not resolve names. Both are
deliberate. Connection reuse, pooling and redirect-following are the
caller's, because a pool would need a table and a policy and neither
belongs in a first version.

**It takes IPv4 literals only**, because `Iour.Net.Connect` does. See the
gaps below.

---

## WebSockets

Server-side upgrade, in the same fiber, with no handoff:

```ada
   procedure Handle (Req : Server_Request; Resp : in out Responder) is
      Conn : Iour.Ws.Conn.Session;
   begin
      if Iour.Ws.Is_Upgrade (Req) then
         Iour.Ws.Accept_Upgrade (Req, Resp, Conn, Status);
         --  Resp has written the 101.  This fiber now runs the
         --  WebSocket loop for as long as the connection lives.
         loop
            Iour.Ws.Conn.Receive (Conn, Msg, Kind, Last, Status);
            exit when Status /= Ok;
            ...
         end loop;
      end if;
   end Handle;
```

The 101 response is where the HTTP framing table earns its keep: the bytes
after the blank line belong to the WebSocket layer and must not be consumed
as a body. Hand the read buffer's unread remainder to the session rather
than dropping it.

Provide **two receive surfaces**, where aht provides one:

* `Receive`, which reassembles a fragmented message into a caller-supplied
  buffer bounded by a maximum message size and fails with 1009 above it;
* `Receive_Frame`, which delivers each fragment as it arrives.

The second is what makes a large message possible without a large buffer,
and it is free given the pull-mode design. Reassembly is the convenience,
not the primitive.

Ping, pong and the close handshake are handled inside `Receive`, which is
where they belong when one fiber owns the socket. Auto-ping on an interval
is *not* possible yet; see gap 2.

Masking is a client obligation only. A server-only build needs no
randomness at all, which is worth knowing because the RNG is the one FFI
addition in this whole plan.

---

## Stack and memory budget

Everything per connection lives on that connection's fiber stack, which is
`Fiber_Stack_Bytes`, 64 KiB, with a guard page below. The project files
carry `-Wframe-larger-than=16384`, a quarter of that, and it fires on
nothing today.

| item | bytes |
|---|---|
| read buffer, which bounds the request head | 8192 |
| head write buffer | 2048 |
| header slice table, 32 entries | 512 |
| connection and responder records | ~400 |

That is roughly 11 KiB, which fits under the frame flag but not with much
to spare. **Put the connection state in the fiber body's own frame and keep
the parse and wire subprograms' frames small**, rather than letting a
single frame carry all of it. Everything currently reached from a fiber is
under 320 bytes, so this is a real change to that column and should be
measured with `-fstack-usage` on Windows the way the existing numbers were.

Two consequences:

* **Bodies stream and are never buffered whole.** A `Content-Length` of ten
  megabytes is read 8 KiB at a time in the handler's loop. This is the same
  discipline aht's streaming path has, made mandatory by the absence of a
  heap rather than chosen.
* **Resident memory rises on Linux.** A fiber stack is mapped lazily and an
  echo fiber touches one page of it. An HTTP fiber touches three or four.
  The Linux figure of 5.5 to 7.1 MB at 500 connections should be expected
  to roughly triple; the Windows figure of 25 to 32 MB should not move,
  because `VirtualAlloc` plus the guard page already pays up front. Measure
  it rather than trusting this paragraph.

---

## What the runtime is missing

Four things. The first blocks the client. The fourth is a latent defect
rather than a missing feature, and it is the one to fix before taking any
measurement at all.

### 1. No DNS, so the client takes IP literals

`Iour.Net.Connect` calls `Iour.Ffi.Inet.Parse_Ipv4` and returns `-EINVAL`
for anything that is not a dotted quad. aht has `aht-dns`, which binds
`getaddrinfo`; that is a blocking call and would pin a shard's core for the
length of a lookup, which is the one thing this runtime exists not to do.

Three options, in order of preference:

1. **Ship without it.** Document that the client takes addresses, and let
   the application resolve however it likes before it calls. This is what a
   first version should do.
2. **A pure-Ada UDP resolver over the reactor.** A DNS A-record query is a
   small fixed packet and the response parser is bounded; it would be
   `SPARK_Mode => On` throughout and would suspend like any other
   operation. It needs `Iour.Net.New_Socket` to be able to make a datagram
   socket, which it currently cannot, and it needs a resolver address from
   somewhere. Perhaps 300 lines. This is the right answer eventually.
3. `getaddrinfo` on a thread. There is no thread pool on the Linux side and
   introducing one for this would be a poor trade.

### 2. No bounded receive, and no cancel

`Iour.Net.Receive` on a peer that never sends does not return, and the spec
says so deliberately. That is fine for echo and not fine for a server
facing the open internet: idle timeouts, request-head deadlines and
WebSocket ping intervals all need a receive that gives up.

It cannot be built from what is there. `Iour.Async.Perform` submits one
operation and suspends; `Iour.Futures` says plainly that a future has at
most one waiter and a fiber awaits one thing at a time, so there is no
select. `Iour.Reactor`'s operation set has `Kind_Timeout` but no cancel, so
a second fiber cannot interrupt the first.

**Both platforms already have the mechanism and neither exposes it.**
io_uring has `IORING_OP_LINK_TIMEOUT` and `IORING_OP_ASYNC_CANCEL`. Windows
has `CancelIoEx`, which this backend already calls on the shutdown path
when `shutdown` refuses a listening socket. So the work is a new `Op_Kind`
and a body in each reactor, which is the documented way to add an
operation, plus a `Receive_Before` or a `Cancel` in `Iour.Net`.

This is the single most valuable runtime change in this plan, and it is
useful well beyond HTTP.

### 3. No randomness, for WebSocket client masking

RFC 6455 requires a client to mask every frame with a fresh 32-bit key.
That needs `getrandom(2)` on Linux and `BCryptGenRandom` on Windows, behind
a new `Iour.Ffi.Sys` entry with two bodies. It is the same shape as
`Bind_To_Cpu`: a portable spec whose bodies do different amounts, and if
they differ in effects the spec takes the union and the weaker body carries
an `Intentional` justification.

Small, and only a WebSocket *client* needs it.

### 4. Accepted sockets do not get TCP_NODELAY on Linux

`Iour.Ffi.Net.Tcp_Socket` sets `TCP_NODELAY`, and it is the only place in
the runtime that sets it. That covers every socket the runtime *creates*:
`Iour.Net.New_Socket` on both systems, and on Windows the sockets the
reactor makes in advance for `AcceptEx`. It does not cover a socket
returned by `IORING_OP_ACCEPT`, and **Linux does not inherit the option
from the listener**. So on Linux today every accepted connection has Nagle
enabled and every accepted connection on Windows does not.

Echo does not expose this. One 32-byte write per turn is rarely two small
segments in flight at once, which is the condition Nagle actually delays
on. HTTP exposes it immediately: a response head and a body written as two
sends are exactly that condition, and the second send waits on the peer's
delayed ACK for up to 40 ms. Against Go and axum, which have the option on
by default, that is not a small regression; it is the whole measurement.

Two fixes, and they are worth doing in both directions:

1. **Write the head and the body in one send.** Correct regardless, and it
   is one fewer submission per response. It is the reason the head buffer
   exists in the budget above, and a small body should be copied into it
   rather than sent separately.
2. **Set the option on accepted sockets.** Awkward, and that is presumably
   why it is not there: with direct accept the socket is a slot in the
   ring's registered file table and there is no descriptor to hand to
   `setsockopt`. It would have to happen on the non-direct path only, or
   through `IORING_OP_SETSOCKOPT` where the kernel is new enough.

The first alone is enough for a well-behaved HTTP server. The second is
what stops a *badly* behaved one, or a WebSocket sending small frames, from
hitting the same wall. Confirm the diagnosis with a capture before changing
anything: a 40 ms gap between the head and the body on the wire is
unmistakable.

---

## SPARK

**All of this can be `SPARK_Mode => On`, and none of it should add a
trusted body.** That is not optimism: an HTTP parser is index arithmetic
over a fixed array with no addresses, no access types and no inline
assembly, which is the best case SPARK ever gets. The rule in `CLAUDE.md`
is that `Off` is a claim the language cannot express what a body does, and
nothing here qualifies.

Obligations to expect, so they are not a surprise:

* **Index bounds** everywhere in the parsers. Mostly free if slices are
  passed as `Byte_Array` with their own bounds rather than as base plus
  offset.
* **`Content-Length` accumulation must saturate or reject**, never wrap. An
  unbounded `Natural` accumulator over attacker-supplied digits is an
  overflow check that cannot be discharged. Use the `Bump` idiom
  `Iour.Scheduler` already has, or reject above a configured maximum, which
  is better because it is also correct.
* **`Natural` subtraction** in every buffer-length computation. Prefer
  first-and-last index pairs over lengths for this reason.
* **The responder's phase predicate**, which is the point of having it.
* **Null slices.** A zero-length header value is legal HTTP, and the trap
  where a null `String` has its last index one below its first, which bit
  the context-switch renderer, applies here identically. Write
  preconditions over an explicit range rather than an upper bound alone.

Two existing traps apply directly. A volatile object may appear only as the
whole right-hand side of an assignment, so any statistics counter the
server keeps is read into a local before it is tested. And an `Atomic`
variable's external properties get spelled out, `Async_Writers` alone for
the write-once-read-many case.

`make prove-consumers` grows to cover the handler, which is the point of
that target existing.

---

## Testing

* **The parsers stand alone.** A test main over a corpus of request and
  response heads, good and malformed, needs no runtime, no socket and no
  shard. Put it in `tests/` and in `for Main use` so `-U` reaches it, per
  the trap in `CLAUDE.md`.
* **RFC 6455 section 5.7 has frame test vectors.** They are half a page and
  they cover masking, fragmentation and the 16-bit and 64-bit length forms.
  Encode and decode each one and compare bytes.
* **A `smoke`-shaped self-test**: bind a listener, spawn the server, drive
  it with the client over loopback, check the round trip, exit non-zero on
  failure. The existing `smoke` is the model, including checking the switch
  text before anything starts.
* **Chunked decoding deserves its own corpus.** Trailers, a chunk split
  across reads, a size line split across reads, an oversized size, and a
  missing CRLF after chunk data. The split-across-reads cases are the ones
  that a buffer with compaction gets wrong.
* Autobahn would be the real WebSocket answer and is not reachable from
  here; the vectors plus the close-code classification are what is
  affordable.

---

## Benchmarking against Go and axum

**Use `scripts/bench_http.sh`; do not extend `scripts/bench_tcp.sh`.** HTTP
needs its own harness, result directory and CI workflow. It may use the same
process lifecycle and CSV conventions as the TCP harness, but it owns its
own `run_pair`, summaries and protocol-specific workloads.

Everything under *Measurement traps* in `CLAUDE.md` applies unchanged and
none of it is restated here. What follows is only what HTTP adds.

### The contract the new binaries have to meet

The HTTP harness's `run_pair` appends arguments and greps output. Both halves
are fixed:

| | gets appended | must print |
|---|---|---|
| server | `<port> <conns>` | a line containing `listening on port` |
| client | `127.0.0.1 <port> <conns> <rounds>` | `elapsed <n> ms` or `s`, `round trips per second <n>`, `frames exchanged <n>`, `failed <n>` |

The elapsed line's unit is read rather than assumed, so milliseconds are
fine and the Ada client's integer rendering is fine. A new client that
drops the unit from the text breaks that, silently and by three orders of
magnitude; the harness comment at `run_pair` says why.

Six programs now exist: an Ada server/client pair, a Go `net/http`
server/client pair, and an Axum/Reqwest server/client pair. The independent
HTTP harness runs all nine server-client pairings. It currently has a matrix
with randomized pairing order and server CPU/RSS accounting; scaling and
latency stages remain future work.

### Keep the cross pairings, because HTTP needs them more

Six of eighteen rows in the first Linux run measured the load generator
rather than the server. An HTTP client parses responses, so it is
substantially more expensive than the echo client, so the risk is *higher*
here, not lower. The tell is unchanged: if the other two servers do not
separate on that row either, the client is the ceiling.

Keep Go and Rust clients in the matrix as independent load generators. The
Ada client is pinned to its own shards because that is what this runtime is,
so its rows are necessary coverage but can be client-bound; compare server
rows under the same non-Ada client before drawing throughput conclusions.

### What has to be held equal, and did not before

Echo made this free: both ends agreed on 32 bytes and there was nothing
else to agree about. HTTP has plenty.

| what | why it bites |
|---|---|
| the response bytes | Go adds `Date` and sniffs `Content-Type`; hyper adds `date`. Fix the header set and diff the three responses byte for byte before any number counts |
| the `Date` header | Go and hyper both cache it and refresh once a second. A handler that formats it per response is doing strictly more work, and will look slower for a reason that is not the runtime |
| keep-alive | verify it, do not assume it. Count accepts on the server side. Go's `http.Client` stops reusing a connection if the response body is not drained and closed, silently, and every request then measures a TCP handshake |
| framing | fix everything on `Content-Length`. Chunked against non-chunked is not a comparison |
| the router | Axum is a framework over Hyper, Go has `ServeMux`, and the Ada server has neither. A raw Hyper row is future work, needed to make the framework layer a visible number rather than a hidden asymmetry |

`srv us/rt` remains the honest column and becomes microseconds of server
CPU per request, for the reason the script's header gives at length: the
Ada server is on `Shard_Count` cores and the other two are on the whole
machine, so wall-clock throughput is not a like-for-like measure.

### Three workloads

* a small fixed body, for the ceiling;
* a POST with a body, which is the only thing that exercises the body
  reader and the compaction path;
* a 64 KiB response, for the write path.

Skip JSON in a first pass. A JSON row compares serializers, and the Ada
side would have to grow one first.

### Add a tail-latency number

The existing latency stage drives one connection with sequential round
trips and reports a mean. **A mean hides exactly the effect this runtime
exists to demonstrate.** Thread-per-core against work-stealing shows up in
the tail, where a cross-core wakeup onto a cold cache costs, and the Windows
run's own numbers say so: unpinned Go and Tokio burn two to four times the
CPU per round trip while their medians stay close.

A fixed-bucket histogram in the client is bounded, needs no heap and stays
inside SPARK, so p99 is affordable. Report it beside the mean rather than
instead of it.

### Fix the Nagle defect first

Gap 4 above. On Linux an accepted socket has `TCP_NODELAY` unset, and an
HTTP response written as head then body is the precise case Nagle delays.
Any Linux number taken before that is fixed is measuring a 40 ms stall, not
a runtime. Windows is unaffected, which would make it look like a backend
difference.

---

## Implementation status, 2026-09-08

The HTTP implementation is now a bounded, portable first slice above
`Iour.Net`. It is not the complete HTTP/1.1 and WebSocket design described
elsewhere in this document. The distinction matters when changing it or
reading a benchmark result.

### Implemented HTTP surface

* `src/http/` is in `Portable_Dirs`. `Iour.Http` supplies bounded HTTP
   vocabulary, methods, versions, parse states, an 8 KiB `Head_Buffer`, and
   the pure no-body/chunked/content-length/until-close framing decision.
* `Iour.Http.Parse` finds the head terminator and parses request/status
   lines. It currently recognizes GET, HEAD and POST request lines.
   `tests/http_parse_test.adb` is a standalone parser test; its focused proof
   completed 1,145 checks.
* `Iour.Http.Buffer` and `Iour.Http.Headers` exist as bounded foundations,
   but neither is yet the public request/response body surface. `Wire.Read_Head`
   returns both bytes received and the head boundary because one receive may
   contain bytes after CRLF CRLF; callers do not yet consume that remainder.
* `Iour.Http.Server` is a generic with a handler and completion callback.
   One accepted connection is served by one fiber: read head, parse request
   line, invoke the handler, write fixed-length `200 OK`, close. There is no
   header dispatch, request-body read, response status control, response
   headers, chunked encoding, or keep-alive.
* `Iour.Http.Client.Request` sends a GET or empty POST over a socket supplied
   by its caller and parses the response status line/head. It has no body API.
   It accepts dotted-quad IPv4 literals through `Iour.Net`; DNS remains absent.
* `examples/http_server` and `examples/http_client` are the executable
   fixture. Their GET response body is exactly
   `0123456789abcdef0123456789abcdef` (32 ASCII bytes), with `Content-Length`
   and `Connection: close`. POST is still an example handler response, not a
   benchmarked body-reader path.

### Common benchmark CLI

The Ada fixture now conforms to the same command contract as the Go and Rust
peers:

```
http_server [port] [request-goal]
http_client [host] [port] [connections] [rounds]
```

`request-goal` is a request count, not a connection count. The client opens a
new connection for every round because the fixture deliberately emits
`Connection: close`; a run with $C$ connections and $R$ rounds asks its server
to complete $C \times R$ requests. The client starts one fiber per connection,
counts completed sessions and successful requests, prints elapsed milliseconds
and an integer requests-per-second rate, then requests scheduler shutdown. Its
elapsed window opens immediately before the driver spawns sessions and ends at
the last session completion, excluding runtime shutdown and ring drain.
The server's completion callback closes the listener and requests shutdown at
the goal. A zero goal serves until killed.

The old no-argument path is retained: `make demo-http` starts the server and
drives the default one-connection, one-round client through loopback.

### Independent HTTP harness and peers

HTTP intentionally has a separate harness: `scripts/bench_http.sh`.
`scripts/bench_tcp.sh` remains the echo/TCP harness and must not gain HTTP
stages. Both shell scripts are executable (`100755`) in Git so Linux Actions
can invoke them directly; on Windows the Makefile chooses Git Bash rather than
WSL Bash because the Windows Alire installation is not available to WSL.

`bench_http.sh` builds and runs these peers:

| implementation | server | client |
|---|---|---|
| Ada | `bin/http_server` | `bin/http_client` |
| Go | `bench/go_http/go_http_server` | `bench/go_http/go_http_client` |
| Rust | `bench/axum_http/target/release/axum_http_server` | `bench/axum_http/target/release/axum_http_client` |

The Go peer uses `net/http`; the Rust server uses Axum and its client uses
Reqwest. All accept the common CLI, validate status 200 plus the exact 32-byte
body, disable/reject connection reuse through `Connection: close`, and report
the four lines the harness scrapes. A matrix runs all nine Ada/Go/Axum
server-client pairings. The harness normalizes milliseconds and seconds into
`elapsed_s`, normalizes scientific/integer rates to an integer `rt_per_s`, and
uses TCP's grouped rate and three-decimal elapsed display. A nonzero client
failure makes its CSV row `no` and makes the harness fail after the matrix.

The defaults (`BENCH_HTTP_REPS=3`, `BENCH_HTTP_SCALES="100:100 500:40"`) are
for local measurements. `.github/workflows/http-bench.yml` is independent of
the TCP workflow and supplies its own workload through `BENCH_HTTP_REPS`,
`BENCH_HTTP_SCALES`, `BENCH_HTTP_RUN_TIMEOUT` and `BENCH_HTTP_OUT`; inspect the
workflow rather than inferring CI load from script defaults. Its artifact is
`bench/results/http-ci`.

The harness is a completion/regression tool and not yet a fair full HTTP
comparison. It randomizes pair order per repetition and records server user
CPU, system CPU and peak RSS with `bench/runwait`; its CSV fields are
`srv_user_s`, `srv_sys_s` and `srv_maxrss_kb`. Windows CPU charges in 15.6 ms
ticks, so small workloads cannot support a CPU-cost comparison. TIME_WAIT
drain, listener retry, summary, scaling stage and tail-latency histogram remain
work to port or redesign from the TCP harness. It also compares the Ada fixture
with framework servers that add their own headers, so byte-for-byte on-wire
header equality, keep-alive, a raw Hyper row, POST bodies and a 64 KiB response
are still open.

Validated on this tree: `alr exec -- gprbuild -P examples.gpr -j0`,
`make demo-http`, compact full Ada/Go/Axum matrices, `make check-linux`, and
`make check-aarch64` all passed after the common CLI was added.

---

## Order of work

Each step is useful on its own, and the first four depend on nothing the
runtime is missing. Gap 4, the Nagle defect, is not on this list because it
is not part of this work: it is a defect in the runtime as it stands and
should be fixed on its own, before step 3 produces something worth timing.

1. **`Iour.Http` and `Iour.Http.Parse`.** Pure, provable, testable with no
   socket. Everything else depends on the vocabulary being right.
2. **`Iour.Http.Buffer` and `Iour.Http.Wire`.** The first code that touches
   `Iour.Net`. Get compaction and the header-slice invariant right here.
3. **`Iour.Http.Server`, plus one example.** An echo-shaped HTTP server
   beside `echo_server`, sharing its acceptor arrangement.
4. **`Iour.Http.Client`**, IP literals only.
5. **`Iour.Ws.Frames`, `Sha1`, `Base64`, `Utf8`, and the server-side
   upgrade.** Frames first, against the RFC vectors, before anything talks
   to a socket.
6. **The HTTP benchmark harness**, once step 3 exists and the Nagle fix is
   in. It is separate from the TCP harness and has four binaries, its own
   lifecycle code and its own CI workflow.
7. **Then the remaining gaps, in value order**: bounded receive, then DNS,
   then the RNG for a WebSocket client.

Rough size, in this repository's register, where comments are about half of
every file:

| part | lines |
|---|---|
| HTTP core: vocabulary, buffer, headers, parse, wire | 2000 -- 2500 |
| server generic | 300 |
| client | 300 |
| WebSockets including SHA-1, Base64 and UTF-8 | 800 |
| examples and tests | 500 |
| benchmark servers and load client | 400 |

About the size of `src/net` and the examples together.

---

## Decisions still open

* **Where the head buffer and body window live.** One buffer with a
  compaction rule and a documented invalidation point, or two buffers and
  more stack. The second is simpler to prove and costs perhaps 4 KiB more
  per connection. Measure before choosing.
* **Whether the request type exposes slices or copies.** Slices are free
  and fragile; copies are safe and cost a bounded amount of the handler's
  stack. A hybrid, where slices are the default and a `Copy_Header` exists
  for values the handler wants to keep past the next read, is probably
  right.
* **Whether the client owns a connection pool.** Recommended: no, not in a
  first version.
* **Whether HTTP lives in this repository at all**, or in one beside it
  that depends on the runtime. The argument for a second crate is that the
  runtime's proof numbers stay comparable across changes to a much larger
  body of protocol code. The argument against is that `Portable_Dirs` is
  two strings and the SPARK story is stronger when it is one partition.
