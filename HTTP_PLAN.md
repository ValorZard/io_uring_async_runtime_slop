# Adding an HTTP/1.1 client and server, and WebSockets

A plan, not an implementation. It says where the code goes, what shape it
takes, which parts of [aht](https://github.com/ovenpasta/aht) come across
and which cannot, what it costs in stack and memory, and the three things
the runtime is missing that this work needs.

The short answer: **all of it sits above `Iour.Net` and none of it touches
the platform seam.** Two new portable source directories, no change to
`Iour.Reactor`, no new `Op_Kind`, and no new `SPARK_Mode => Off` body --
with three exceptions, all listed under *What the runtime is missing*, only
one of which blocks anything.

The longer answer is that aht is a *synchronous, heap-based,
exception-raising client library*, and every one of those three traits is
load-bearing in its design and forbidden here. What transfers is its
accumulated correctness -- the framing rules, the decoder's error
conditions, the WebSocket sequencing table -- not its code.

---

## What aht is, and what of it survives

aht is Ada 2022: a synchronous HTTP/1.1 client and a task-based WebSocket
client, over TCP or TLS, with `Ada.Containers`, `Unbounded_String`,
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

That is not a workaround for the SPARK rule; it is strictly better, and it
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

Three things. Only the first blocks anything, and none of them is needed
for a server that speaks HTTP to clients on an already-connected socket.

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

## Order of work

Each step is useful on its own, and the first four depend on nothing the
runtime is missing.

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
6. **Then the gaps, in value order**: bounded receive, then DNS, then the
   RNG for a WebSocket client.

Rough size, in this repository's register, where comments are about half of
every file:

| part | lines |
|---|---|
| HTTP core: vocabulary, buffer, headers, parse, wire | 2000 -- 2500 |
| server generic | 300 |
| client | 300 |
| WebSockets including SHA-1, Base64 and UTF-8 | 800 |
| examples and tests | 500 |

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
