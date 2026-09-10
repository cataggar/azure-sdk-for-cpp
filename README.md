# azure_sdk_amqp

AMQP 1.0 integration for Azure SDK clients, backed by the pure Zig
[`azure-uamqp-zig`](https://github.com/cataggar/azure-uamqp-zig) package.

- Package branch: [`sdk/amqp`](https://github.com/cataggar/azure-sdk-for-zig/tree/sdk/amqp)
- External dependency: `uamqp` ([`azure-uamqp-zig`](https://github.com/cataggar/azure-uamqp-zig)), re-exported as `azure_sdk_amqp.uamqp`
- Version: see `build.zig.zon`

`azure-uamqp-zig` supplies the AMQP type system and frame layout but owns no
sockets and encodes no performatives. This package adds both, so a client can
actually reach an Event Hubs namespace.

## Transports

`transport.zig` defines a small `Transport` interface — `read`, `write`,
`flush`, `close` — with three implementations:

| Transport         | Use                                                 |
| ----------------- | --------------------------------------------------- |
| `TlsTransport`    | `amqps` on port 5671, the normal path               |
| `TcpTransport`    | plaintext on port 5672, for the Event Hubs emulator |
| `MemoryTransport` | a scripted in-memory duplex, for tests              |

`Endpoint` separates where the driver dials from the identity it validates, so
a namespace can be fronted by a local proxy:

```zig
const endpoint = amqp.Endpoint
    .forNamespace("myns.servicebus.windows.net")
    .viaCustomEndpoint("proxy.internal", 8443);

const socket = try amqp.connect(allocator, io, endpoint, .{});
defer socket.deinit();
```

## Performative codec

`performative.zig` encodes and decodes `open`, `begin`, `end`, `close`, and the
SASL performatives as described lists.

Encoding was originally written here rather than delegated to `uamqp.encoder`
because that encoder wrote array elements of variable-width types without their
length prefix, which no peer accepts. **uamqp v0.3.0 fixed that** — it now
emits a shared element constructor and per-element lengths, and rejects arrays
it cannot describe (`MixedArrayElements`, `UnsupportedArrayElement`). The
duplication is therefore no longer necessary and this codec could be folded
into `uamqp.encoder`; that consolidation has not been done yet.

## Connection driver

`connection.zig` runs the handshake and the connection state machine:

- protocol header exchange, anonymous SASL, then the post-SASL header exchange
- `open` with the negotiated `max-frame-size`, `channel-max`, and
  `idle-time-out`
- the connection properties Azure records (product, version, platform,
  user-agent) and the `com.microsoft:georeplication` desired capability
- `begin` and `end` for sessions, and `close` for the connection
- empty-frame keep-alives at half the peer's advertised idle timeout
- per-channel frame routing through `registerChannel`

Anonymous SASL is used because Event Hubs carries the real credential over CBS,
matching the Go and Rust clients.

Every call that can wait takes a deadline in milliseconds, so a stalled peer
surfaces `error.Timeout` rather than hanging. `Clock` is a seam: production code
uses `IoClock`, and tests use `ManualClock` to drive idle-timeout behaviour
without sleeping.

```zig
var clock = amqp.IoClock.init(io);
var driver = try amqp.Driver.init(allocator, socket.transport(), clock.clock(), .{
    .container_id = container_id,
    .hostname = "myns.servicebus.windows.net",
    .desired_capabilities = &.{amqp.georeplication_capability},
    .properties = properties,
});
defer driver.deinit();

try driver.open(deadline_ms);
const remote_channel = try driver.beginSession(0, .{}, deadline_ms);
```

## Message codec

`message.zig` encodes and decodes the AMQP message sections — header, delivery
and message annotations, properties, application properties, body, and footer.
The body is a `data`, `sequence`, or `value` section.

```zig
const bytes = try amqp.encodeMessageAlloc(allocator, .{
    .properties = .{ .message_id = .{ .string = id } },
    .application_properties = props,
    .body = .{ .data = &.{payload} },
});
defer allocator.free(bytes);
```

## Sessions and links

`link.zig` builds sessions, senders, and receivers on top of the driver:

- attach and detach, matched to the peer's echoed attach by link name
- flow control, including credit rebasing onto our delivery count (§2.6.7) and
  draining, which waits for the sender to consume the outstanding credit
- multi-frame transfers, split to the negotiated `max-frame-size` on send and
  reassembled on receive. A delivery that arrives whole in one frame — nearly
  all of them — skips reassembly entirely, and `receive` hands out the buffer
  the delivery already owns rather than copying it into scratch storage, so a
  received body is copied once rather than three times
- frames are read into a buffer the driver keeps and grows to the largest frame
  it has actually seen, rather than allocating and freeing a body per frame,
  and a transfer's payload is split off using the length the performative
  decode already reported instead of decoding the performative a second time.
  Together those take a received delivery from six allocations to four, each of
  which ends up in something the caller reads. The body is valid until the next
  `receiveFrame`, as before; decoded performatives copy into their own arena,
  so they outlive it
- settlement: accepted, rejected, and released outcomes, with a rejection
  surfacing the peer's error condition, one delivery at a time or a whole
  contiguous run in a single disposition
- pipelined sends: a configurable number of deliveries may be unsettled at
  once, so a link is not limited to one message per round trip
- session flow control: transfer ids advance per frame, the peer's
  `incoming-window` is seeded from its `begin`, rebased on every flow and
  waited on rather than overrun, and this endpoint's own window slides with
  what it receives instead of running down
- the Event Hubs link properties the Go and Rust clients send —
  `com.microsoft:receiver-name`, `com.microsoft:epoch`, and the
  `apache.org:selector-filter:string` filter used to pick a starting offset

```zig
var session = try amqp.Session.begin(allocator, &driver, 0, .{}, deadline_ms);
defer session.deinit();

const filters = [_]amqp.performative.Filter{
    .selector("amqp.annotation.x-opt-offset > '@latest'"),
};
const receiver = try amqp.openReceiver(&session, .{
    .name = link_name,
    .source_address = "myhub/ConsumerGroups/$Default/Partitions/0",
    .filters = &filters,
    .prefetch = 300,
}, deadline_ms);

const delivery = try receiver.receive(deadline_ms);
try receiver.accept(delivery);
```

If a peer rejects `openSender` or `openReceiver` with the protocol-defined
null target/source Attach followed by Detach, the call keeps pumping through
the Detach and still returns `error.LinkDetached`. The session retains the
peer's service-defined AMQP condition, description, and info map after the
temporary link is removed:

```zig
const receiver = amqp.openReceiver(&session, options, deadline_ms) catch |err| {
    if (err == error.LinkDetached) {
        if (session.failedLinkOpen()) |diagnostic| {
            std.log.err("link rejected: {s}", .{diagnostic.condition()});
        }
    }
    return err;
};
```

`failedLinkOpen` borrows session-owned diagnostics. They remain valid until the
next sender/receiver open attempt, `takeFailedLinkOpen`, or session
deinitialization. `takeFailedLinkOpen` instead transfers an owned value that
the caller must `deinit`; taking also clears the session slot. Every open
attempt clears the prior value before doing any allocation, and a successful
open leaves it empty, so diagnostics cannot leak across retries or link names.
Sessions and their diagnostic access are caller serialized, like the rest of
the synchronous link API: keep an open and its diagnostic inspection or take
in the same serialized operation. Independent sessions do not share diagnostic
slots; this does not make simultaneous operations on one session or driver
thread safe. A taken diagnostic survives session/driver destruction, provided
the session allocator remains valid until the diagnostic is deinitialized.
Do not copy an owned diagnostic and deinitialize both copies. Conditions are
deliberately not interpreted by this package; service clients may map
conditions they understand.

`delivery` stays valid until the next `receive` returns, so copy anything you
need to keep. Prefetched deliveries queue up and are drained with a cursor
rather than by shifting the queue, which keeps a deep prefetch window linear.

A receiver accepts messages up to `max_message_size`, 128 MiB by default. That
clears the largest message Azure will hand us with room to spare — Event Hubs
allows 1 MB, or up to 20 MB on Dedicated, and Service Bus 256 KB standard /
100 MB premium, and a broker adds annotations on delivery, so a limit of
exactly 100 MiB would have no room for them.

The limit is declared in our `attach` *and* enforced during reassembly, and it
needs both halves: declaring it lets a conformant sender fail the message on
its own side, while §2.7.3 makes respecting the field the sender's obligation,
so only local enforcement makes it a bound. A message past it detaches the link
with `amqp:link:message-size-exceeded`.

```zig
const receiver = try amqp.openReceiver(&session, .{
    .name = link_name,
    .source_address = "myhub/ConsumerGroups/$Default/Partitions/0",
    .max_message_size = 4 * 1024 * 1024,
    .max_buffered_bytes = 256 * 1024 * 1024,
}, deadline_ms);
```

Only your limit is enforced. A peer's own declared `max-message-size` is
recorded but not applied: it is a threshold the peer picks, with no room for
the annotations a broker adds on delivery, and going over detaches the link.
Applying it would buy a tighter ceiling but not a qualitatively different one,
since unbounded growth is already closed by your limit — and that tightening
does not pay for tearing links down on a number the peer chose.

Setting `max_message_size` to null or zero restores unlimited per-message
reassembly only when `max_buffered_bytes` is also null. With a finite aggregate
budget, that budget is advertised and enforced as the effective
`max-message-size`, so a conforming peer is never granted credit for a legal
message this receiver would have to reject.

`max_buffered_bytes` separately bounds the aggregate payload retained in the
ready queue and the delivery currently being reassembled. The default is a
finite 256 MiB (`default_max_buffered_bytes`); null explicitly opts out and
makes the caller responsible for bounding retention above this layer. With a
finite budget, credit is capped conservatively and a multi-frame delivery
reserves its full legal size: ready bytes plus that reservation plus all
outstanding credit can never exceed the aggregate budget. The default 128 MiB
message limit therefore grants at most two deliveries at once. Service clients
that know a smaller protocol maximum should set both limits explicitly to gain
a deeper safe window. A sender that ignores the capped credit is detached with
`amqp:resource-limit-exceeded` before the crossing chunk is retained.

`issueCredit(count)` requests `count` additional completed application
deliveries. In manual mode (`prefetch = 0`), if an authorized initial or
continued transfer is aborted, it does not satisfy the request: exactly that
consumed slot returns to deferred demand, and `receive` emits bounded
replacement credit from inside its pump before waiting for the next transfer.
Repeated aborts therefore keep live plus deferred demand constant. If a custom
byte or settlement-slot budget cannot safely put the whole request on the
wire, the remainder is held and issued automatically as capacity returns, so
callers need not loop just to restate the same requested count. Prefetch links
continue to replenish only through their automatic window and do not also
restore manual abort demand.

Credit issuance is transactional with its `Flow` frame. The prospective
credit, deferred request, and overrun debt are committed only after the whole
frame is encoded, written, and flushed. An encode allocation failure therefore
leaves the request retryable without a phantom local grant or double count; a
write or flush failure leaves the local counters uncommitted and terminalizes
the dirty connection instead. Drain intent follows the same rule and becomes
active only after its `Flow` is emitted. A compliant drain response may omit
`link-credit`; the remaining credit is then derived with serial arithmetic
from the prior delivery limit and the reported `delivery-count`. Once a drain
Flow is emitted, an acknowledgement timeout terminally detaches that receiver:
silently clearing the flag would race a peer that may still process the drain,
and stale drain state would suppress later manual abort-demand replacement.

Only a locally emitted `Flow` advances that delivery limit. A sender's incoming
`Flow` may reconcile its view and reduce remaining credit, but `link-credit`
from the sender can never create receiver authorization or pay down overrun
debt.

The delivery already returned to the caller is outside the aggregate budget
and remains valid until the next successful `receive`; it is still bounded by
`max_message_size`. Callers that know a service's smaller message limit should
set it explicitly, which permits proportionally more of the requested prefetch
window under the aggregate ceiling.

`max_unsettled_deliveries` independently bounds delivery-id bookkeeping, with
a default of 1024. Credit reserves both payload bytes and unsettled slots, so a
mode-second peer withholding settlement acknowledgments cannot make the
session maps or per-link scans grow without bound after payloads leave the
ready queue. Acknowledgments and mode-first local settlement release slots and
replenish withheld credit.

Credit and delivery count are charged on the initial transfer, exactly once.
A continuation may omit `delivery-id` or repeat the initial value without
being charged again. Settlement is cumulative across the transfer sequence:
`settled = true` on any continuation remains true when later frames omit it,
releases the active delivery id, and is reported on the completed delivery. An
already sender-settled delivery ignores `rcv-settle-mode`, including on the
frame that first makes cumulative settlement true; unsettled deliveries still
enforce the locally negotiated mode. An aborted multi-frame delivery, including
one that repeats the id, releases its
partial bytes without entering the ready queue, while a different delivery id
arriving before the current delivery ends is a protocol error that terminally
detaches the receiver. Any allocation
failure after a transfer has been consumed does the same: the missing frame
cannot be replayed, so keeping its old prefix for a later continuation would
surface truncated data.

Any write or flush failure while emitting a frame terminally closes the
connection transport. A header or body may already be buffered, so allowing a
later send to reuse that byte stream could flush a corrupt partial frame.
Protocol-header and heartbeat writes follow the same rule. Likewise, an error
after any inbound frame header byte is consumed closes the connection; an
unread body can no longer be parsed from a known boundary. EOF and terminal
transport read failures also close the driver and every session link when they
arrive before any frame byte; only a zero-byte deadline remains retryable.

An acknowledgement timeout after a successfully emitted SASL or AMQP protocol
header, Open, Begin, or End is terminal at the corresponding connection/session
scope. Open encoding/allocation failure after the AMQP header exchange is
terminal too: the peer is already waiting for Open, so returning to the start
would duplicate the header. Attach uses the same invariant: if its response
does not arrive, the session and transport are invalidated before the
half-attached object is destroyed, so a delayed response cannot bind a
same-name replacement.

Every initial transfer, including aborted and pre-settled transfers, is checked
against unsettled delivery ids active across every receiver on the session. An
unsettled id remains active through completion and is released only by terminal
settlement, abort, detach, error, or deinitialization. Repeating it while its
own multi-frame delivery is still in progress remains a valid continuation.
If a consumed disposition range cannot allocate rejection detail, every
matching outbound delivery is still marked terminal before the connection is
invalidated, so none can remain silently reusable or wait forever.

Consumed SASL, Open, Begin, End, Close, and connection-pump controls are guarded
the same way: decode or apply failure invalidates the driver and closes the
transport before retry is possible. A valid remote End terminalizes its session
and links and emits the End response; a valid remote Close responds, then
terminalizes the connection and transport. Close is recognized globally before
channel routing, on any negotiated channel. Locally emitted Close, End, and
closing Detach enter terminal output state immediately; acknowledgement timeout
cannot leave the connection, session, or link writable, and teardown retry does
not emit a duplicate terminal frame. Later sender and receiver operations fail
without emission. Remote Detach is acknowledged with `closed = true` and
terminally poisons only the named link, even when the peer requested suspension
with `closed = false`; resumable link state is not retained.

Receiver settlement preserves the mode selected by the local receiver's
Attach; the remote sender's Attach preference does not replace it. An initial
Transfer may override a mode-second link to `first` for that delivery.
`settleRange` records each effective mode and splits a mixed range into
correctly settled runs. Mode first carries `settled = true` and releases ids
immediately. Mode second carries `settled = false`; ids remain active until a
sender-role disposition acknowledges only previously dispositioned ids with
`settled = true`.

On the outbound side, the remote receiver's Attach selects the sender's actual
receiver-settle-mode. When mode second returns a receiver-role disposition with
`settled = false`, the sender emits the corresponding sender-role
`settled = true` acknowledgment before the delivery can be retired. Duplicate
dispositions do not duplicate acknowledgments, and acknowledgment emission
failure terminalizes the consumed-frame session.

Settling one delivery at a time costs a frame per message, which at a 300-deep
prefetch is 300 frames of bookkeeping. A disposition can name a `first`..`last`
range instead, and `SettleBatch` builds those runs safely — delivery ids belong
to the session rather than to the link, so anything else sharing the session
leaves gaps that a range must not span:

```zig
var settling = amqp.SettleBatch.init(receiver, .accepted);
var i: usize = 0;
while (i < 300) : (i += 1) {
    try settling.add(try receiver.receive(deadline_ms));
}
try settling.flush();
```

Nothing reaches the wire until `flush`, so abandoning a batch leaves its
deliveries unsettled and the peer redelivers them.

### Keeping deliveries in flight

`send` and `sendBytes` wait for the peer to settle each delivery, so a link
sends at most one message per round trip no matter how small the messages are.
Against a broker 30 ms away that caps a sender near 33 deliveries a second,
which is a network limit rather than a CPU one and so survives any amount of
encoding work.

`max_in_flight` lifts the cap. `sendBytesAsync` writes the transfer frames and
returns a `DeliveryToken` instead of waiting, and `awaitSettlement` retires the
oldest delivery and reports the peer's verdict against the token that names it:

```zig
const sender = try amqp.openSender(&session, .{
    .name = link_name,
    .target_address = "myhub",
    .max_in_flight = 8,
}, deadline_ms);

for (payloads) |payload| {
    _ = sender.sendBytesAsync(payload, .{}, deadline_ms) catch |err| switch (err) {
        error.InFlightWindowFull => {
            _ = try sender.awaitSettlement(deadline_ms);
            _ = try sender.sendBytesAsync(payload, .{}, deadline_ms);
        },
        else => return err,
    };
}
while (sender.inFlight() > 0) {
    const settlement = try sender.awaitSettlement(deadline_ms);
    if (settlement.outcome != .accepted) return error.SendFailed;
}
```

A full window is an error rather than a wait: only the caller can retire a
delivery, so blocking inside `sendBytesAsync` until one was retired would wait
on something only the blocked caller could do.

A refused delivery comes back as `Settlement.outcome`, not as an error, because
a pipelining caller needs to know *which* delivery the broker turned down —
`sendBytes` keeps mapping the outcome onto `error.SendRejected` for callers that
send one at a time. `Outcome` deliberately carries no payload: the peer's own
`DeliveryState` holds slices decoded into the frame's arena, which is released
before `pump` returns, so handing that union back would hand back freed memory.
The condition behind a rejection is copied into `Settlement.rejection`, owned by
the sender and valid until its next `awaitSettlement`.

The default `max_in_flight` is 1, so a sender behaves exactly as it always has
until it is asked for more. `sendBytes` waits for the oldest delivery, which is
only its own when nothing else is outstanding, so it reports
`error.DeliveriesInFlight` rather than mixing with `sendBytesAsync` and
attributing one delivery's verdict to another. A send that never reaches a
verdict retires its own entry. In receiver-settle-mode first that leaves the
sender reusable; in mode second the sender terminally detaches before
discarding an undecided id, because a late first-phase disposition would
otherwise require an acknowledgment the sender could no longer correlate.

`SenderOptions.snd_settle_mode` is the sender's authoritative settlement mode
and is honored on Attach and Transfer. The remote receiver's Attach field is a
desired preference only: omission, `mixed`, or an opposite fixed preference
cannot replace the actual mode selected by this locally initiated sender. In
sender-settled mode every transfer carries `settled = true`; synchronous and
asynchronous sends complete after emission without retaining an in-flight
entry or waiting for a disposition.

Deliveries settle in the order they were sent, and the ring holding them is
allocated once at attach, so a silent peer costs a fixed amount of memory rather
than a growing one.

If a multi-frame send fails after its opening transfer reached the wire, the
link is poisoned and detached best-effort. Cleanup is idempotent and
scope-aware: a remote Detach is answered once, and a remote End is never
followed by a link-level Detach. The peer is already holding an unterminated
delivery, so starting another delivery on that link would instead continue the
failed bytes and corrupt the protocol stream. Recovery must open a new sender.
The poisoned object is terminal and must first be removed with
`Session.closeSender`; late attach or flow frames cannot reactivate it or bind
to a replacement with the same name. Link credit and delivery count are
consumed when the first frame succeeds, while no settlement entry is created
for the incomplete delivery.

`abandonInFlight` is the way out of a pipeline that failed partway. Waiting is
what just failed, so the caller cannot wait the remaining deliveries out, and a
sender still holding unsettled ones refuses every later blocking send — without
it a single timed-out pipeline would wedge the link for good. In settlement
mode second, abandoning any undecided delivery closes the bounded link state
before its ids are discarded. In other modes a later disposition is ignored,
so resending an abandoned delivery the broker went on to accept publishes it
twice.

Some of those verdicts may already be in hand, though. A disposition is recorded
on whichever delivery the peer names, wherever it sits in the window, while
`awaitSettlement` retires in send order and blocks on the oldest — so a peer that
answers out of order strands decided deliveries behind an undecided one, which is
exactly the state a caller is in when it gives up and abandons.
`abandonInFlightInto` abandons the window and writes those verdicts out first, in
send order, returning how many were held. That may exceed the buffer length, so a
short buffer does not read as "that was all of them"; sizing it to `inFlight()`
before the call is always enough.

```zig
var decided: [8]amqp.DecidedDelivery = undefined;
const n = sender.abandonInFlightInto(&decided);
for (decided[0..@min(n, decided.len)]) |d| {
    if (d.outcome == .accepted) markSent(d.token);
}
```

`DecidedDelivery` carries no rejection detail: a `Rejection` is heap-owned and
the sender holds one slot for it, so there is nowhere to put a windowful. The
outcome is what decides whether a message has to be sent again.

### Session flow control

Session ids count transfer *frames*, not deliveries (§2.5.6). Every frame of a
multi-frame delivery consumes one, even though only the first frame carries the
delivery id, so a message split across seventeen frames advances the session by
seventeen and the next delivery's id follows from there. Numbering by delivery
instead leaves every later id short of the peer's count, and the peer's
dispositions then name ids the sender never issued — its verdicts match nothing
and the send waits out its deadline.

The peer's `begin` and every `flow` state how many frames it can still absorb.
That capacity is rebased onto what has already gone out:

```
remote-incoming-window = next-incoming-id(flow) + incoming-window(flow) - next-outgoing-id
```

which is `incoming-window` less the frames sent since the id the peer named.
The subtraction is the point. `incoming-window` describes the peer's room as of
that id, so taking it at face value re-credits every frame sent since and lets a
sender run past the window. A flow may omit `next-incoming-id` until the peer has
seen a transfer, in which case the spec substitutes the session's first outgoing
id.

Only the distance already sent is treated as a serial number (RFC 1982), never
the window itself. The window is a peer-supplied `uint` spanning the whole
range — these sessions advertise `maxInt(u32)` — so testing *it* against a
serial bound reads the most open window possible as a shut one. The distance is
bounded by the frames in flight, so a value in the top half means the peer named
an id beyond anything that was sent, which is nonsense rather than an overrun.

A sender waits for the peer to reopen a closed window before writing the next
frame, including partway through a multi-frame delivery. Unlike a full in-flight
ring, this is something waiting can actually resolve: the peer alone reopens it,
and it does so with a flow the sender picks up while pumping.

In the other direction, this endpoint's own `incoming-window` is capacity rather
than a countdown. Every transfer is accepted — the receiver buffers the delivery,
and link credit is what bounds a peer — so the room offered from
`next-incoming-id` is the same after each frame as before it. Spending it per
frame without replenishing would pin `next-incoming-id + incoming-window`, the
limit a peer derives its own capacity from, at its opening value: a
once-per-session budget wearing the shape of a window.

A handle in an inbound frame is scoped to the peer that sent it, so links are
looked up by the handle the peer chose, never by our own. A session holding both
a CBS link and an events link would otherwise cross its deliveries.

## Request/response links

`rpc.zig` pairs a sender with a receiver attached to a private reply address,
correlating each reply to its request by message id. Both `$cbs` and
`$management` are built on it, as they are in the Go client.

A reply's status rides in application properties rather than in the delivery
outcome, so a refused request still arrives as an accepted transfer. Both
spellings brokers use — `status-code` and `statusCode` — are accepted, as is
any integral encoding of the code.

## CBS authentication

Event Hubs carries no credential in the SASL exchange, so every entity is
authorised separately by putting a token to `$cbs` before a link on that path
attaches. `cbs.zig` sends the `operation`, `type`, `name`, and `expiration`
application properties with the token as the message value, matching Go's
layout exactly, and maps a 401 to `error.Unauthorized` so callers do not retry
a refused credential.

```zig
const client = try amqp.Cbs.open(&session, .{ .link_id = id }, deadline_ms);
defer client.deinit();

try client.authorize(audience, credential.tokenProvider(), now_ms, deadline_ms);
```

Tokens are cached per audience and refreshed six minutes before expiry with up
to five seconds of jitter, backing off thirty seconds after a failure — the
same policy as the Rust client. A pre-formed SAS from a connection string is
marked non-refreshable and schedules nothing, since renewing it returns the
same expiry; the broker still enforces it, and `invalidateAll` re-authorises
every path after a connection is recovered.

Acquiring the token is the credential's job. `TokenProvider` is a
function-pointer struct, so this module does not depend on the credential type,
and it is only consulted when a round-trip is actually needed.

## Management

`management.zig` drives the `$management` endpoint. A request carries the
`operation` (`READ` for every metadata read), the entity `type`, the `name`,
and the caller's `security_token`, with caller-supplied properties merged after
them. The path has to be authorised over CBS before this link attaches.

```zig
const client = try amqp.Management.open(&session, .{ .link_id = id }, deadline_ms);
defer client.deinit();

var response = try client.call(.{
    .entity_type = "com.microsoft:eventhub",
    .name = hub_name,
    .security_token = token,
}, deadline_ms);
defer response.deinit();
```

A non-2xx reply fails the call. Zig errors carry no payload, so the broker's
status and description are recorded on `last_error`, the same way the
connection driver records a remote error. `callRaw` returns the reply whatever
its status, for callers that treat some codes as expected.

`begin` and `awaitReply` are separate so several requests can be in flight at
once; each is matched to its own reply however the broker orders them, and a
reply that arrives before its caller asks for it is held rather than dropped. A
detach fails everything outstanding instead of leaving a caller blocked until
its deadline.

## Tests

`test_peer.zig` drives the far end of a `MemoryTransport`, writing the frames a
broker would send and parsing back what the driver emitted. The link, RPC, and
CBS tests share it, since they all need the same open/begin/attach preamble
before the behaviour under test starts.

Run the package's independent tests from this directory:

```bash
zig build test --summary all
```
