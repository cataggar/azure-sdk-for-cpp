//! AMQP 1.0 sessions and links.
//!
//! `uamqp.protocol.link` and `uamqp.protocol.session` are stubs that never
//! encode anything, so this module drives attach, credit, transfer, and
//! settlement over the connection `Driver`.
//!
//! Everything here is synchronous and deadline-driven, like the driver: a call
//! that can wait takes a deadline in milliseconds on the driver's clock.

const std = @import("std");
const uamqp = @import("uamqp");
const perf = @import("performative.zig");
const message = @import("message.zig");
const connection = @import("connection.zig");

const Allocator = std.mem.Allocator;
const Driver = connection.Driver;
const frame = uamqp.frame;
const FrameType = uamqp.frame.FrameType;

pub const LinkError = connection.ConnectionError || error{
    /// The peer detached the link; inspect `remoteError`.
    LinkDetached,
    /// The peer rejected the delivery; inspect `rejection`.
    SendRejected,
    /// The peer released or modified the delivery rather than accepting it.
    SendNotAccepted,
    /// A message exceeded the peer's advertised `max-message-size`.
    MessageTooLarge,
    /// A transfer arrived for a handle no link owns.
    UnknownHandle,
    /// The peer sent a transfer without the credit to do so.
    CreditExceeded,
    /// Buffered deliveries reached `ReceiverOptions.max_buffered_bytes`.
    BufferLimitExceeded,
    /// `max_in_flight` deliveries are already unsettled; retire one with
    /// `awaitSettlement` before sending again.
    InFlightWindowFull,
    /// `awaitSettlement` was called with nothing on the wire to wait for.
    NoDeliveryInFlight,
    /// A blocking `send` was attempted while pipelined deliveries were still
    /// outstanding. Retire them with `awaitSettlement` first.
    DeliveriesInFlight,
    /// Another live or poisoned link already owns this name.
    LinkNameInUse,
    /// Receiver limits cannot be represented safely on the wire.
    InvalidReceiverOptions,
    /// An unsettled delivery id was reused before its terminal disposition.
    DuplicateDeliveryId,
    /// Unsettled deliveries reached `ReceiverOptions.max_unsettled_deliveries`.
    SettlementLimitExceeded,
};

/// Set on a receiver so Event Hubs can name the owner in its error text.
pub const receiver_name_property = "com.microsoft:receiver-name";

/// Set on a receiver to claim exclusive ownership of a partition.
pub const epoch_property = "com.microsoft:epoch";

/// What the peer said about a delivery it would not accept.
pub const Rejection = struct {
    condition: []const u8,
    description: ?[]const u8 = null,

    pub fn deinit(self: Rejection, allocator: Allocator) void {
        allocator.free(self.condition);
        if (self.description) |d| allocator.free(d);
    }
};

// ─────────────────────── Session ───────────────────────

/// Structured remote diagnostics retained when a link-open attempt fails.
///
/// A value returned by `Session.takeFailedLinkOpen` belongs to the caller and
/// survives session and driver destruction. Its allocator must remain valid
/// until `deinit` is called; copying the value does not duplicate ownership.
/// Diagnostics are service agnostic; callers interpret the peer-defined
/// condition and info fields.
pub const FailedLinkOpen = struct {
    allocator: Allocator,
    remote_error: connection.RemoteError,

    pub fn condition(self: FailedLinkOpen) []const u8 {
        return self.remote_error.condition;
    }

    pub fn description(self: FailedLinkOpen) ?[]const u8 {
        return self.remote_error.description;
    }

    pub fn info(self: FailedLinkOpen) ?perf.Fields {
        return self.remote_error.info;
    }

    pub fn deinit(self: *FailedLinkOpen) void {
        self.remote_error.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const SessionOptions = struct {
    /// Window sizes. Rust opens sessions with very large windows so the
    /// service is never the one throttling.
    incoming_window: u32 = std.math.maxInt(u32),
    outgoing_window: u32 = std.math.maxInt(u32),
    handle_max: u32 = std.math.maxInt(u32),
};

/// A session, owning the links attached to one channel.
/// Drop `link` from `list` and free it. A link that is not in the list was
/// already dropped, so freeing it here would be a double free.
fn removeLink(comptime T: type, list: *std.ArrayList(*T), link: *T) void {
    for (list.items, 0..) |item, i| {
        if (item != link) continue;
        _ = list.orderedRemove(i);
        link.deinit();
        return;
    }
}

/// Remaining serial-number distance from `count` to `limit`. A value in the
/// undefined/backwards half of RFC 1982 cannot authorize deliveries.
fn remainingToDeliveryLimit(limit: u32, count: u32) u32 {
    const remaining: i32 = @bitCast(limit -% count);
    return if (remaining > 0) @intCast(remaining) else 0;
}

pub const Session = struct {
    allocator: Allocator,
    driver: *Driver,
    channel: u16,
    remote_channel: u16,

    next_outgoing_id: u32 = 0,
    next_incoming_id: u32 = 0,
    /// How many transfer frames this endpoint can take from `next_incoming_id`.
    /// Capacity rather than a countdown: every transfer is accepted, so the
    /// room on offer slides forward with the id instead of running down.
    incoming_window: u32,
    outgoing_window: u32,
    ended: bool = false,
    /// Our first transfer id. §2.5.6 falls back to this when a peer's flow
    /// omits `next-incoming-id`, which it may until it has seen a transfer.
    initial_outgoing_id: u32 = 0,
    /// How many more transfer frames the peer can absorb. Seeded from its
    /// `begin`, recomputed from every `flow`, and spent one per frame sent.
    remote_incoming_window: u32 = 0,

    next_handle: u32 = 0,
    senders: std.ArrayList(*Sender) = .empty,
    receivers: std.ArrayList(*Receiver) = .empty,
    incoming_deliveries: std.AutoHashMapUnmanaged(u32, *Receiver) = .empty,
    failed_link_open: ?FailedLinkOpen = null,

    /// Begin a session on `channel`.
    pub fn begin(
        allocator: Allocator,
        driver: *Driver,
        channel: u16,
        options: SessionOptions,
        deadline_ms: i64,
    ) LinkError!Session {
        // The id our first transfer will carry. §2.5.6 needs it a second time,
        // as the fallback when a peer's flow omits `next-incoming-id`, so the
        // two uses are tied together here rather than restated apart.
        const initial_outgoing_id: u32 = 0;

        const remote = try driver.beginSession(channel, .{
            .next_outgoing_id = initial_outgoing_id,
            .incoming_window = options.incoming_window,
            .outgoing_window = options.outgoing_window,
            .handle_max = options.handle_max,
        }, deadline_ms);

        var session: Session = .{
            .allocator = allocator,
            .driver = driver,
            .channel = channel,
            .remote_channel = remote.channel,
            .incoming_window = options.incoming_window,
            .outgoing_window = options.outgoing_window,
            .next_outgoing_id = initial_outgoing_id,
            .initial_outgoing_id = initial_outgoing_id,
            .next_incoming_id = remote.next_outgoing_id,
        };
        // Through the same helper the flows use, so a window cannot be read
        // one way at begin and another way a frame later.
        session.remote_incoming_window = session.windowFrom(null, remote.incoming_window);
        return session;
    }

    pub fn deinit(self: *Session) void {
        for (self.senders.items) |s| s.deinit();
        for (self.receivers.items) |r| r.deinit();
        self.senders.deinit(self.allocator);
        self.receivers.deinit(self.allocator);
        self.incoming_deliveries.deinit(self.allocator);
        self.clearFailedLinkOpen();
        self.* = undefined;
    }

    /// Borrow diagnostics from the most recent failed sender or receiver open.
    ///
    /// The returned pointer remains valid until the next link-open attempt,
    /// `takeFailedLinkOpen`, or session deinitialization. Session operations
    /// are caller serialized: keep an open and its diagnostic inspection or
    /// ownership transfer in the same serialized operation.
    pub fn failedLinkOpen(self: *const Session) ?*const FailedLinkOpen {
        return if (self.failed_link_open) |*diagnostic| diagnostic else null;
    }

    /// Transfer ownership of the most recent failed-link-open diagnostics.
    ///
    /// The caller must invoke `FailedLinkOpen.deinit` on the returned value.
    pub fn takeFailedLinkOpen(self: *Session) ?FailedLinkOpen {
        const diagnostic = self.failed_link_open;
        self.failed_link_open = null;
        return diagnostic;
    }

    fn clearFailedLinkOpen(self: *Session) void {
        if (self.failed_link_open) |*diagnostic| diagnostic.deinit();
        self.failed_link_open = null;
    }

    fn preserveFailedLinkOpen(
        self: *Session,
        remote_error: *?connection.RemoteError,
    ) void {
        const owned = remote_error.* orelse return;
        self.clearFailedLinkOpen();
        remote_error.* = null;
        self.failed_link_open = .{
            .allocator = self.allocator,
            .remote_error = owned,
        };
    }

    /// End the session on the wire.
    pub fn end(self: *Session, deadline_ms: i64) LinkError!void {
        if (self.ended) return error.LinkDetached;
        self.terminate();
        try self.driver.endSession(self.channel, deadline_ms);
    }

    /// Detach one sender and drop it from the session.
    ///
    /// Detaching without dropping would leave the session pumping frames into
    /// a link nobody can reach, and `deinit` would free it a second time. The
    /// detach is best effort: a link being recovered has usually already been
    /// detached by the peer, and failing here would strand the link instead.
    pub fn closeSender(self: *Session, sender: *Sender, deadline_ms: i64) void {
        if (sender.attached) sender.detach(deadline_ms) catch {};
        removeLink(Sender, &self.senders, sender);
    }

    /// Detach one receiver and drop it from the session.
    pub fn closeReceiver(self: *Session, receiver: *Receiver, deadline_ms: i64) void {
        if (receiver.attached) receiver.detach(deadline_ms) catch {};
        removeLink(Receiver, &self.receivers, receiver);
    }

    fn allocateHandle(self: *Session) u32 {
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }

    /// Read one frame and apply it to the session and its links.
    ///
    /// Returns true when the frame was consumed. A frame for another channel
    /// is ignored, which keeps a single-session connection simple.
    pub fn pump(self: *Session, deadline_ms: i64) LinkError!bool {
        if (self.ended) return error.LinkDetached;
        const inbound = self.driver.receiveFrame(deadline_ms) catch |err| {
            if (self.driver.state == .err) self.terminate();
            return err;
        };
        if (perf.peekDescriptor(inbound.body) == perf.descriptor.close) {
            const decoded = self.driver.decodeBodyReusing(inbound.body) catch |err|
                return self.failConsumedFrame(err);
            const c = decoded.performative.close;
            self.driver.recordRemoteError(c.err) catch |err| return self.failConsumedFrame(err);
            self.terminate();
            self.driver.sendPerformative(.amqp, 0, .{ .close = .{} }) catch |err|
                return self.failConsumedFrame(err);
            self.driver.terminate();
            return error.RemoteClosed;
        }
        if (inbound.header.channel != self.remote_channel) return false;

        const decoded = self.driver.decodeBodyReusing(inbound.body) catch |err| {
            // The frame has already been consumed and cannot be replayed.
            self.driver.invalidate();
            self.terminate();
            return err;
        };

        // The decode above already measured the performative, so the payload
        // is the remainder. `bytes_consumed` is what the decoder read out of
        // `body`, so it cannot exceed it, but a corrupt length would slice out
        // of bounds rather than fail cleanly.
        if (decoded.bytes_consumed > inbound.body.len) {
            return self.failConsumedFrame(error.MalformedFrame);
        }
        const payload = inbound.body[decoded.bytes_consumed..];
        switch (decoded.performative) {
            .flow => |f| self.applyFlow(f) catch |err| return self.failConsumedFrame(err),
            .disposition => |d| self.applyDisposition(d) catch |err| return self.failConsumedFrame(err),
            .transfer => |t| self.applyTransfer(t, payload) catch |err| {
                if (err == error.OutOfMemory) return self.failConsumedFrame(err);
                return err;
            },
            .attach => |a| self.applyAttach(a) catch |err| return self.failConsumedFrame(err),
            .detach => |d| self.applyDetach(d) catch |err| return self.failConsumedFrame(err),
            .end => |e| {
                self.driver.recordRemoteError(e.err) catch |err| return self.failConsumedFrame(err);
                self.terminate();
                self.driver.sendPerformative(.amqp, self.channel, .{ .end = .{} }) catch |err|
                    return self.failConsumedFrame(err);
                return error.RemoteClosed;
            },
            .close => |c| {
                self.driver.recordRemoteError(c.err) catch |err| return self.failConsumedFrame(err);
                self.terminate();
                self.driver.sendPerformative(.amqp, 0, .{ .close = .{} }) catch |err|
                    return self.failConsumedFrame(err);
                self.driver.terminate();
                return error.RemoteClosed;
            },
            else => return false,
        }
        return true;
    }

    fn failConsumedFrame(self: *Session, err: LinkError) LinkError {
        self.driver.invalidate();
        self.terminate();
        return err;
    }

    fn invalidateLinks(self: *Session) void {
        for (self.senders.items) |sender| {
            sender.attached = false;
            sender.awaiting_attach = false;
            sender.poisoned = true;
        }
        for (self.receivers.items) |receiver| {
            receiver.attached = false;
            receiver.awaiting_attach = false;
            receiver.poisoned = true;
            receiver.clearPartialAndFree();
            self.releaseReceiverDeliveries(receiver);
        }
    }

    fn terminate(self: *Session) void {
        self.ended = true;
        self.invalidateLinks();
    }

    fn reserveIncomingDelivery(
        self: *Session,
        receiver: *Receiver,
        id: u32,
        settle_mode: perf.ReceiverSettleMode,
    ) LinkError!void {
        if (self.incoming_deliveries.contains(id)) return error.DuplicateDeliveryId;
        try receiver.unsettled_ids.ensureTotalCapacityPrecise(
            self.allocator,
            receiver.unsettled_ids.items.len + 1,
        );
        receiver.unsettled_ids.appendAssumeCapacity(.{
            .id = id,
            .settle_mode = settle_mode,
        });
        errdefer _ = receiver.unsettled_ids.pop();
        try self.incoming_deliveries.put(self.allocator, id, receiver);
    }

    fn releaseIncomingDelivery(self: *Session, receiver: *Receiver, id: u32) void {
        if (self.incoming_deliveries.get(id) != receiver) return;
        _ = self.incoming_deliveries.remove(id);
        for (receiver.unsettled_ids.items, 0..) |active, i| {
            if (active.id != id) continue;
            _ = receiver.unsettled_ids.swapRemove(i);
            return;
        }
    }

    fn releaseReceiverDeliveries(self: *Session, receiver: *Receiver) void {
        for (receiver.unsettled_ids.items) |active| {
            if (self.incoming_deliveries.get(active.id) == receiver) {
                _ = self.incoming_deliveries.remove(active.id);
            }
        }
        receiver.unsettled_ids.clearRetainingCapacity();
    }

    fn releaseIncomingRange(self: *Session, receiver: *Receiver, first: u32, last: u32) void {
        const span = last -% first;
        if (span >= 1 << 31) return;
        var i = receiver.unsettled_ids.items.len;
        while (i > 0) {
            i -= 1;
            const id = receiver.unsettled_ids.items[i].id;
            if (id -% first > span) continue;
            _ = self.incoming_deliveries.remove(id);
            _ = receiver.unsettled_ids.swapRemove(i);
        }
    }

    // A handle in an inbound frame is scoped to the peer that sent it
    // (§2.6.2), so it is matched against `remote_handle` only. Matching our
    // own handle too would collide whenever a session holds both a sender and
    // a receiver, which is the shape CBS and $management use.
    fn senderFor(self: *Session, handle: u32) ?*Sender {
        for (self.senders.items) |s| {
            if (s.attached and s.remote_handle == handle) return s;
        }
        return null;
    }

    fn receiverFor(self: *Session, handle: u32) ?*Receiver {
        for (self.receivers.items) |r| {
            if (r.attached and r.remote_handle == handle) return r;
        }
        return null;
    }

    fn senderForDetach(self: *Session, handle: u32) ?*Sender {
        for (self.senders.items) |s| {
            if ((s.attached or (s.awaiting_attach and s.attach_refused)) and
                s.remote_handle == handle)
            {
                return s;
            }
        }
        return null;
    }

    fn receiverForDetach(self: *Session, handle: u32) ?*Receiver {
        for (self.receivers.items) |r| {
            if ((r.attached or (r.awaiting_attach and r.attach_refused)) and
                r.remote_handle == handle)
            {
                return r;
            }
        }
        return null;
    }

    /// A receiver this endpoint has detached but the peer may not have.
    fn detachedReceiverFor(self: *Session, handle: u32) ?*Receiver {
        for (self.receivers.items) |r| {
            if (!r.attached and r.remote_handle == handle) return r;
        }
        return null;
    }

    fn applyFlow(self: *Session, f: perf.Flow) LinkError!void {
        self.next_incoming_id = f.next_outgoing_id;
        self.remote_incoming_window = self.windowFrom(f.next_incoming_id, f.incoming_window);

        const handle = f.handle orelse return;
        if (self.senderFor(handle)) |s| {
            if (f.link_credit) |credit| {
                // The peer states credit relative to its view of our delivery
                // count, so rebase onto ours (§2.6.7).
                const their_count = f.delivery_count orelse s.delivery_count;
                const consumed = s.delivery_count -% their_count;
                s.credit = credit -| consumed;
            }
            s.drain = f.drain;
        }
        if (self.receiverFor(handle)) |r| {
            // Only this receiver grants credit. A sender's Flow may reconcile
            // its view and reduce what remains, but can never manufacture a
            // larger local authorization.
            var reconciled = @min(
                r.credit,
                remainingToDeliveryLimit(r.delivery_limit, r.delivery_count),
            );
            if (f.link_credit) |peer_credit| {
                const peer_count = f.delivery_count orelse r.delivery_count;
                const peer_limit = peer_count +% peer_credit;
                reconciled = @min(
                    reconciled,
                    remainingToDeliveryLimit(peer_limit, r.delivery_count),
                );
            }
            if (f.drain) {
                // A drain response advances the sender's count over whatever
                // credit went unused, so its count is authoritative. When
                // link-credit is omitted, the locally emitted delivery limit
                // still determines what remains.
                if (f.delivery_count) |their_count| {
                    reconciled = @min(
                        reconciled,
                        remainingToDeliveryLimit(r.delivery_limit, their_count),
                    );
                    r.delivery_count = their_count;
                }
            }
            r.credit = reconciled;
        }
        if (f.echo) try self.sendFlow(null);
    }

    /// The peer's remaining capacity per §2.5.6:
    ///
    ///     next-incoming-id(flow) + incoming-window(flow) - next-outgoing-id
    ///
    /// which is `incoming-window` less the frames sent since the id the peer
    /// named. The subtraction matters: `incoming-window` states the peer's room
    /// as of that id, so taking it raw re-credits everything sent since and
    /// lets a sender run past the window.
    ///
    /// A flow may omit `next-incoming-id` until the peer has seen a transfer,
    /// in which case the spec substitutes our first transfer id.
    ///
    /// Only the distance we have sent is clamped as a serial number (RFC 1982),
    /// never the window itself. The window is a peer-supplied `uint` spanning
    /// the whole range — this library advertises `maxInt(u32)` — so testing it
    /// against a serial bound would read the most open window possible as a
    /// shut one. The distance is bounded by the frames actually in flight, so
    /// a value in the top half means the peer named an id beyond anything we
    /// sent, which is nonsense; take its window at face value and let credit
    /// bound the sending.
    fn windowFrom(self: *const Session, next_incoming_id: ?u32, incoming_window: u32) u32 {
        const base = next_incoming_id orelse self.initial_outgoing_id;
        const sent_since = self.next_outgoing_id -% base;
        if (sent_since >= 1 << 31) return incoming_window;
        return incoming_window -| sent_since;
    }

    fn applyDisposition(self: *Session, d: perf.Disposition) LinkError!void {
        const last = d.last orelse d.first;
        if (d.role == .receiver) {
            // A disposition from the receiving side settles what we sent.
            try self.acknowledgeReceiverDisposition(d.first, last, d.settled, d.state);
            for (self.senders.items) |s| {
                s.applyDisposition(d.first, last, d.state) catch |err| {
                    // The disposition frame is consumed and cannot be replayed.
                    // Ensure every id in its range has a terminal outcome before
                    // the session is invalidated, including entries on senders we
                    // had not reached yet.
                    for (self.senders.items) |sender| {
                        sender.terminalizeDispositionRange(d.first, last, d.state);
                    }
                    return err;
                };
            }
            return;
        }

        // In receiver-settle-mode second, our first disposition is not
        // terminal. The peer, acting as sender, settles it with a second
        // disposition; only that acknowledgement releases the active ids.
        if (!d.settled) return;
        for (self.receivers.items) |receiver| {
            if (receiver.rcv_settle_mode == .second) {
                try receiver.acknowledgeSettlementRange(d.first, last);
            }
        }
    }

    fn acknowledgeReceiverDisposition(
        self: *Session,
        first: u32,
        last: u32,
        settled: bool,
        state: ?perf.DeliveryState,
    ) LinkError!void {
        if (settled) return;
        const span = last -% first;
        if (span >= 1 << 31) return;

        var cursor: ?u32 = null;
        var run_first: u32 = 0;
        var run_last: u32 = 0;
        var have_run = false;
        while (true) {
            var next_id: ?u32 = null;
            var next_offset: u32 = 0;
            for (self.senders.items) |sender| {
                if (sender.rcv_settle_mode != .second) continue;
                for (0..sender.in_flight_len) |i| {
                    const entry = sender.entryAt(i);
                    if (entry.second_ack_sent) continue;
                    const offset = entry.id -% first;
                    if (offset > span) continue;
                    if (cursor) |after| {
                        if (offset <= after) continue;
                    }
                    if (next_id == null or offset < next_offset) {
                        next_id = entry.id;
                        next_offset = offset;
                    }
                }
            }

            const id = next_id orelse {
                if (have_run) try self.emitSenderSettlementAck(run_first, run_last, state);
                return;
            };
            if (!have_run) {
                run_first = id;
                run_last = id;
                have_run = true;
            } else if (next_offset == cursor.? + 1) {
                run_last = id;
            } else {
                try self.emitSenderSettlementAck(run_first, run_last, state);
                run_first = id;
                run_last = id;
            }
            cursor = next_offset;
        }
    }

    fn emitSenderSettlementAck(
        self: *Session,
        first: u32,
        last: u32,
        state: ?perf.DeliveryState,
    ) LinkError!void {
        try self.driver.sendPerformative(.amqp, self.channel, .{ .disposition = .{
            .role = .sender,
            .first = first,
            .last = last,
            .settled = true,
            .state = state,
        } });
        const span = last -% first;
        for (self.senders.items) |sender| {
            if (sender.rcv_settle_mode != .second) continue;
            for (0..sender.in_flight_len) |i| {
                const entry = sender.entryAt(i);
                if (entry.id -% first <= span) entry.second_ack_sent = true;
            }
        }
    }

    fn applyAttach(self: *Session, a: perf.Attach) LinkError!void {
        // Match by link name: the peer echoes it and picks its own handle.
        for (self.senders.items) |s| {
            if (s.awaiting_attach and
                !s.poisoned and
                a.role == .receiver and
                std.mem.eql(u8, s.name, a.name))
            {
                if (s.attach_refused) return error.MalformedFrame;
                s.remote_handle = a.handle;
                if (a.target == null) {
                    // A receiver answers a locally initiated sender Attach
                    // with a null target when it cannot create the terminus.
                    // The required Detach carries the useful remote error.
                    s.attach_refused = true;
                    return;
                }
                // `openSender` initiated this link, so its Attach declared the
                // actual mode. The receiver's response is advisory even when
                // it expresses the opposite fixed preference.
                s.max_message_size = a.max_message_size;
                s.rcv_settle_mode = a.rcv_settle_mode;
                if (a.initial_delivery_count) |c| s.delivery_count = c;
                s.attached = true;
                s.awaiting_attach = false;
                return;
            }
        }
        for (self.receivers.items) |r| {
            if (r.awaiting_attach and
                !r.poisoned and
                a.role == .sender and
                std.mem.eql(u8, r.name, a.name))
            {
                if (r.attach_refused) return error.MalformedFrame;
                r.remote_handle = a.handle;
                if (a.source == null) {
                    // A sender answers a locally initiated receiver Attach
                    // with a null source when it cannot create the terminus.
                    // Keep pumping until its required Detach supplies detail.
                    r.attach_refused = true;
                    return;
                }
                r.peer_max_message_size = a.max_message_size;
                r.attached = true;
                r.awaiting_attach = false;
                return;
            }
        }
        for (self.senders.items) |s| {
            if (s.awaiting_attach and
                !s.poisoned and
                std.mem.eql(u8, s.name, a.name))
            {
                return error.MalformedFrame;
            }
        }
        for (self.receivers.items) |r| {
            if (r.awaiting_attach and
                !r.poisoned and
                std.mem.eql(u8, r.name, a.name))
            {
                return error.MalformedFrame;
            }
        }
    }

    fn applyDetach(self: *Session, d: perf.Detach) LinkError!void {
        if (self.senderForDetach(d.handle)) |s| {
            const respond = !s.detach_sent;
            s.attached = false;
            s.awaiting_attach = false;
            s.poisoned = true;
            try s.recordDetach(d.err);
            if (respond) {
                try self.driver.sendPerformative(.amqp, self.channel, .{
                    .detach = .{ .handle = s.handle, .closed = true },
                });
                s.detach_sent = true;
            }
            return;
        }
        if (self.receiverForDetach(d.handle)) |r| {
            const respond = !r.detach_sent;
            r.attached = false;
            r.awaiting_attach = false;
            r.poisoned = true;
            // A detached link can still hand already completed deliveries to
            // its caller, but an in-progress one can never finish.
            r.clearPartialAndFree();
            self.releaseReceiverDeliveries(r);
            try r.recordDetach(d.err);
            if (respond) {
                try self.driver.sendPerformative(.amqp, self.channel, .{
                    .detach = .{ .handle = r.handle, .closed = true },
                });
                r.detach_sent = true;
            }
        }
    }

    fn applyTransfer(self: *Session, t: perf.Transfer, payload: []const u8) LinkError!void {
        // `incoming_window` is capacity, not a countdown, so it is not spent
        // here. This endpoint takes every transfer it is sent — the receiver
        // buffers the delivery and link credit is what bounds a peer — so the
        // room it can offer from `next_incoming_id` is the same after each
        // frame as before it. Decrementing without ever replenishing pins the
        // limit a peer computes from this, `next-incoming-id + incoming-window`
        // (§2.5.6), at its opening value, turning a sliding window into a
        // once-per-session budget that stops a conformant peer for good.
        self.next_incoming_id +%= 1;

        const receiver = self.receiverFor(t.handle) orelse {
            // A link detached locally keeps receiving until the peer notices,
            // and `refuseOverrun` detaches without waiting for it precisely
            // because the peer is misbehaving. `pump` is shared with every
            // other link on the session, so failing here would let one bad
            // link take down the CBS and `$management` links beside it. The
            // straggler is dropped; the session window was already advanced
            // above, so accounting stays correct.
            if (self.detachedReceiverFor(t.handle) != null) return;
            return error.UnknownHandle;
        };
        try receiver.acceptTransfer(t, payload);
    }

    /// Emit a session `flow`, optionally carrying link credit.
    fn sendFlow(self: *Session, link: ?*Receiver) LinkError!void {
        return self.sendFlowWithLinkState(
            link,
            if (link) |r| r.credit else null,
            if (link) |r| r.drain else false,
        );
    }

    /// Emit a receiver flow using prospective credit that is not committed to
    /// the receiver until the complete frame has reached the transport.
    fn sendFlowWithCredit(
        self: *Session,
        link: ?*Receiver,
        prospective_credit: ?u32,
    ) LinkError!void {
        return self.sendFlowWithLinkState(
            link,
            prospective_credit,
            if (link) |r| r.drain else false,
        );
    }

    fn sendFlowWithLinkState(
        self: *Session,
        link: ?*Receiver,
        prospective_credit: ?u32,
        prospective_drain: bool,
    ) LinkError!void {
        var f = perf.Flow{
            .next_incoming_id = self.next_incoming_id,
            .incoming_window = self.incoming_window,
            .next_outgoing_id = self.next_outgoing_id,
            .outgoing_window = self.outgoing_window,
        };
        if (link) |r| {
            f.handle = r.handle;
            f.link_credit = prospective_credit orelse r.credit;
            f.delivery_count = r.delivery_count;
            f.drain = prospective_drain;
        }
        try self.driver.sendPerformative(.amqp, self.channel, .{ .flow = f });
    }
};

/// Byte length of the described performative at the head of a frame body.
///
/// A transfer frame carries the message payload immediately after the
/// performative, so the split has to be found by measuring the performative.
///
/// The receive path does not use this: `perf.Decoded.bytes_consumed` reports
/// the same number as a by-product of the decode that `pump` already performs,
/// which is why decoding a second time here would be pure waste. It remains
/// for peers and tests, which hold a frame body without having decoded it.
///
/// Distinguishing `error.OutOfMemory` from `error.MalformedFrame` still matters
/// now that only peers and tests call this, because `checkAllAllocationFailures`
/// injects the former deliberately. Collapsing the two — as returning `?usize`
/// did — makes an injected failure indistinguishable from the peer sending
/// garbage. Until #333 that was a live receive-path bug; what is left is that
/// every caller that consumed the optional unwrapped it with `.?`, so an
/// injected failure aborted the test process on a null unwrap instead of being
/// reported as the allocation failure it was. (`transferPayload` forwarded the
/// null instead, which merely moved the unwrap to its own callers.)
pub fn performativeLength(allocator: Allocator, body: []const u8) connection.ConnectionError!usize {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const result = uamqp.decoder.decode(arena.allocator(), body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedFrame,
    };
    return result.bytes_consumed;
}

// ─────────────────────── Sender ───────────────────────

pub const SenderOptions = struct {
    name: []const u8,
    /// The entity the messages go to, such as `eh` or `eh/Partitions/3`.
    target_address: []const u8,
    source_address: ?[]const u8 = null,
    /// Actual sender settlement mode. For this locally initiated link, the
    /// receiver's Attach carries only an advisory desired preference and
    /// cannot replace this selection.
    snd_settle_mode: perf.SenderSettleMode = .mixed,
    rcv_settle_mode: perf.ReceiverSettleMode = .first,
    desired_capabilities: ?[]const []const u8 = null,
    properties: ?perf.Fields = null,
    /// How many deliveries may be unsettled at once.
    ///
    /// One means every send waits a full round trip for the peer's
    /// disposition before the next transfer goes out, so a link's throughput
    /// is capped at one delivery per round trip however small the messages
    /// are. Raising it lets `sendBytesAsync` keep that many deliveries on the
    /// wire and collect the outcomes afterwards. The default stays at one so
    /// that `send` and `sendBytes` behave exactly as they always have.
    ///
    /// The peer's session `incoming-window` bounds this independently and is
    /// enforced, so a sender waits for the peer to reopen the window rather
    /// than overrunning it.
    max_in_flight: u32 = 1,
};

/// Identifies one delivery that has been written but not yet settled.
pub const DeliveryToken = struct { id: u32 };

/// What the peer decided about a delivery.
///
/// Deliberately payload-free. The peer's own `DeliveryState` carries slices
/// decoded into the frame's arena, which `pump` releases before it returns, so
/// handing that union to a caller would hand out freed memory. The detail that
/// matters — a rejection's condition — is duplicated into `Rejection` instead
/// and reported alongside.
pub const Outcome = enum { accepted, rejected, released, modified };

fn outcomeFromDeliveryState(state: perf.DeliveryState) Outcome {
    return switch (state) {
        .accepted => .accepted,
        .released => .released,
        .modified => .modified,
        .rejected => .rejected,
    };
}

/// The peer's verdict on one delivery, paired with the token it answers.
///
/// A non-accepted outcome is data, not an error: the transfer itself
/// succeeded and only the peer's decision differs, and a pipelining caller
/// needs to know *which* delivery was refused. `sendBytes` keeps mapping the
/// outcome onto an error for callers that send one at a time.
pub const Settlement = struct {
    token: DeliveryToken,
    outcome: Outcome,
    /// Why a rejected delivery was refused, when the peer said. Owned by the
    /// sender and valid until its next `awaitSettlement`, so copy anything
    /// worth keeping past that point.
    rejection: ?Rejection = null,
};

/// A delivery the peer had already decided when its window was abandoned.
///
/// Carries no rejection detail, deliberately. A `Rejection` is heap-owned and
/// the sender holds exactly one slot for it, valid until the next
/// `awaitSettlement`; there is nowhere to put a windowful, and handing them
/// out individually would put a second, different ownership contract on a
/// function whose whole job is to release things. The outcome is what decides
/// whether a message must be sent again, which is what a caller abandoning a
/// window needs. A rejection's condition still reaches the caller through
/// `awaitSettlement` on the path where the peer answers in order.
pub const DecidedDelivery = struct {
    token: DeliveryToken,
    outcome: Outcome,
};

/// Per-delivery options.
pub const SendOptions = struct {
    /// The `message-format` field of the transfer (§2.7.5). Zero is a plain
    /// AMQP message; Event Hubs identifies a batch with `0x80013700`, whose
    /// body is one data section per contained message.
    message_format: u32 = 0,
};

/// One delivery written to the wire and not yet settled by the peer.
const InFlight = struct {
    id: u32,
    outcome: ?Outcome = null,
    rejection: ?Rejection = null,
    second_ack_sent: bool = false,
};

pub const Sender = struct {
    allocator: Allocator,
    session: *Session,
    name: []const u8,
    handle: u32,
    remote_handle: u32 = std.math.maxInt(u32),
    attached: bool = false,
    awaiting_attach: bool = true,
    attach_refused: bool = false,
    poisoned: bool = false,
    detach_sent: bool = false,

    credit: u32 = 0,
    drain: bool = false,
    delivery_count: u32 = 0,
    /// Authoritative sender settlement mode selected locally.
    snd_settle_mode: perf.SenderSettleMode = .mixed,
    /// Receiver settlement mode selected by the remote receiver's Attach.
    rcv_settle_mode: perf.ReceiverSettleMode = .first,
    /// Peer's `max-message-size`; null or 0 means unlimited.
    max_message_size: ?u64 = null,

    /// Deliveries on the wire, oldest first.
    ///
    /// A ring rather than a growable list: entries are pushed in send order
    /// and retired in that same order, so a head cursor keeps both ends O(1)
    /// without the `orderedRemove(0)` quadratic that draining a deep queue
    /// otherwise costs. The capacity is fixed at attach, which is what bounds
    /// how much a silent peer can make a sender hold.
    in_flight: []InFlight = &.{},
    in_flight_head: usize = 0,
    in_flight_len: usize = 0,

    /// The most recent rejection, owned by the sender and replaced each time
    /// a rejected delivery is retired.
    rejection: ?Rejection = null,
    detach_error: ?connection.RemoteError = null,

    /// Scratch for one outgoing frame body, reused for every frame of every
    /// send. Sized to the peer's `max-frame-size`, which `chunkBudget` has
    /// already guaranteed is enough for a transfer performative plus its
    /// chunk. Growing this per frame meant a doubling series of reallocs and
    /// copies, up to the frame size, on every frame of every batch.
    frame_buf: []u8 = &.{},

    pub fn deinit(self: *Sender) void {
        self.allocator.free(self.name);
        if (self.frame_buf.len > 0) self.allocator.free(self.frame_buf);
        for (0..self.in_flight_len) |i| {
            if (self.entryAt(i).rejection) |r| r.deinit(self.allocator);
        }
        if (self.in_flight.len > 0) self.allocator.free(self.in_flight);
        if (self.rejection) |r| r.deinit(self.allocator);
        if (self.detach_error) |e| e.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// The `i`th oldest in-flight delivery.
    fn entryAt(self: *Sender, i: usize) *InFlight {
        return &self.in_flight[(self.in_flight_head + i) % self.in_flight.len];
    }

    /// Give up on every delivery still in flight, emptying the window.
    ///
    /// Their verdicts are lost — including any the peer has already sent but
    /// the caller has not collected, since `awaitSettlement` retires strictly
    /// in send order and a peer may settle out of it. In receiver-settle-mode
    /// second, abandoning an undecided id terminally detaches the link because
    /// a later first-phase disposition could no longer be acknowledged after
    /// the id was discarded. Other modes remain at-least-once: a caller that
    /// abandons a delivery the broker went on to accept and then resends it has
    /// published it twice.
    ///
    /// This is the way out of a pipelined send that failed partway. A sender
    /// still holding unsettled deliveries refuses every later blocking send
    /// with `error.DeliveriesInFlight`, so without it a single timed-out
    /// pipeline would wedge the link for good — the caller cannot wait the
    /// deliveries out, because waiting is what just failed.
    ///
    /// The `Settlement` from the last `awaitSettlement` stays valid: this is
    /// not an `awaitSettlement`, so it does not disturb the rejection the
    /// sender is holding for the caller to read.
    ///
    /// This discards any verdict the peer had already returned for a delivery
    /// behind an undecided one. Use `abandonInFlightInto` to collect those
    /// first; it is the same call otherwise.
    pub fn abandonInFlight(self: *Sender) void {
        _ = self.abandonInFlightInto(&.{});
    }

    /// Abandon the window, reporting the deliveries the peer had already
    /// decided.
    ///
    /// `Session.applyDisposition` records an outcome on whichever entry the
    /// peer names, wherever it sits in the window, but `awaitSettlement`
    /// retires strictly in send order and blocks while the oldest entry is
    /// undecided. A peer that settles out of order therefore leaves decided
    /// entries stranded *behind* an undecided head — and that is exactly the
    /// state a caller is in when it gives up waiting and abandons.
    ///
    /// Plain `abandonInFlight` throws those verdicts away, so a caller
    /// following the at-least-once advice sends again every message in the
    /// window, including ones the peer had already accepted. Collecting them
    /// first is what keeps that duplication down to the deliveries whose fate
    /// is genuinely unknown (#330).
    ///
    /// Writes in send order and returns the number of decided deliveries,
    /// which may exceed `out.len`: the excess is dropped, and a caller
    /// comparing the result against `out.len` can tell that it was. Sizing
    /// `out` to `inFlight()` before the call is always enough.
    pub fn abandonInFlightInto(self: *Sender, out: []DecidedDelivery) usize {
        self.terminalizeAbandonedModeSecond();
        var decided: usize = 0;
        while (self.in_flight_len > 0) {
            const entry = self.entryAt(0);
            if (entry.outcome) |outcome| {
                if (decided < out.len) out[decided] = .{
                    .token = .{ .id = entry.id },
                    .outcome = outcome,
                };
                decided += 1;
            }
            self.discardOldest();
        }
        return decided;
    }

    /// Receiver-settle-mode second requires us to acknowledge a late
    /// unsettled receiver disposition. Once an undecided entry is discarded,
    /// its id is gone and that acknowledgment cannot be produced safely.
    /// Close the link instead of retaining unbounded tombstones or pretending
    /// it remains reusable.
    fn terminalizeAbandonedModeSecond(self: *Sender) void {
        if (self.rcv_settle_mode != .second or self.poisoned) return;
        var has_undecided = false;
        for (0..self.in_flight_len) |i| {
            if (self.entryAt(i).outcome == null) {
                has_undecided = true;
                break;
            }
        }
        if (!has_undecided) return;

        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        self.detach_sent = true;
        self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:link:detach-forced",
                    .description = "mode-second delivery was abandoned before settlement",
                },
            },
        }) catch {
            // Without the Detach the peer would retain an id we are about to
            // forget. Close the whole stream rather than leave an
            // unacknowledgeable mode-second delivery on a reusable session.
            self.session.driver.invalidate();
            self.session.terminate();
        };
    }

    /// How many deliveries are written but not yet settled.
    pub fn inFlight(self: *const Sender) usize {
        return self.in_flight_len;
    }

    /// Detach the link, waiting for the peer's detach.
    ///
    /// A peer that has already gone reads as closed rather than as a failure:
    /// the link is detached either way, and reporting an error would make a
    /// caller tearing down think it had to retry.
    pub fn detach(self: *Sender, deadline_ms: i64) LinkError!void {
        if (self.poisoned or !self.attached or self.detach_sent or self.session.ended)
            return error.LinkDetached;
        self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{ .handle = self.handle, .closed = true },
        }) catch |err| {
            if (self.session.driver.state == .err) {
                self.attached = false;
                self.poisoned = true;
            }
            return err;
        };
        self.detach_sent = true;
        while (self.attached) {
            _ = self.session.pump(deadline_ms) catch |e| switch (e) {
                error.RemoteClosed, error.ConnectionClosed => return,
                else => return e,
            };
        }
    }

    /// The largest message the peer will take, or null when unlimited.
    pub fn maxMessageSize(self: *const Sender) ?u64 {
        return normalizeMaxMessageSize(self.max_message_size);
    }

    fn recordDetach(self: *Sender, err: ?perf.AmqpError) LinkError!void {
        if (self.detach_error) |e| e.deinit(self.allocator);
        self.detach_error = null;
        const e = err orelse return;
        self.detach_error = try connection.RemoteError.dupe(self.allocator, e);
    }

    fn applyDisposition(
        self: *Sender,
        first: u32,
        last: u32,
        state: ?perf.DeliveryState,
    ) LinkError!void {
        // Delivery ids are serial numbers (§2.8.2), so a range that straddles
        // the 2^32 wrap has `last` numerically below `first` and the obvious
        // `id >= first and id <= last` silently matches nothing. Comparing the
        // offsets from `first` keeps the containment test correct on both
        // sides of the wrap; the same reasoning fixed the receiver's settle
        // path.
        const span = last -% first;
        // That offset test alone would read a merely backwards range — a
        // garbled `first = 10, last = 5` — as a span of nearly the whole id
        // space and settle every delivery on the link with whatever state it
        // carried. RFC 1982 leaves a distance of 2^31 or more undefined, and
        // no session can have that many deliveries outstanding, so a span that
        // large is nonsense rather than a wrap. Ignoring it matters because
        // the first outcome to arrive wins: a bogus `accepted` would otherwise
        // pre-empt the real rejection behind it and report a lost message as
        // sent.
        if (span >= 1 << 31) return;

        for (0..self.in_flight_len) |i| {
            const entry = self.entryAt(i);
            if (entry.outcome != null) continue;
            if (entry.id -% first > span) continue;

            const decided = state orelse .accepted;
            // An entry only reaches here while undecided, and an undecided
            // entry has never been given a rejection.
            std.debug.assert(entry.rejection == null);
            if (decided == .rejected) {
                if (decided.rejected) |e| {
                    // Both dupes complete into locals before the field is
                    // written. Assigning the struct literal directly would
                    // use `entry.rejection` as the result location, so the
                    // optional would already read as non-null with `condition`
                    // stored and `description` still undefined if the second
                    // dupe failed — the errdefer would then free `condition`
                    // that `deinit` still believes it owns, and `deinit` would
                    // free a `description` that was never allocated.
                    const condition = try self.allocator.dupe(u8, e.condition);
                    errdefer self.allocator.free(condition);
                    const description = if (e.description) |d|
                        try self.allocator.dupe(u8, d)
                    else
                        null;
                    entry.rejection = .{
                        .condition = condition,
                        .description = description,
                    };
                }
            }
            entry.outcome = outcomeFromDeliveryState(decided);
        }
    }

    fn terminalizeDispositionRange(
        self: *Sender,
        first: u32,
        last: u32,
        state: ?perf.DeliveryState,
    ) void {
        const span = last -% first;
        if (span >= 1 << 31) return;
        const outcome = outcomeFromDeliveryState(state orelse .accepted);
        for (0..self.in_flight_len) |i| {
            const entry = self.entryAt(i);
            if (entry.outcome != null or entry.id -% first > span) continue;
            entry.outcome = outcome;
        }
    }

    /// Send a message and wait for the peer to settle it.
    pub fn send(self: *Sender, msg: message.Message, deadline_ms: i64) LinkError!void {
        return self.sendWithOptions(msg, .{}, deadline_ms);
    }

    /// Send a message under explicit delivery options.
    pub fn sendWithOptions(
        self: *Sender,
        msg: message.Message,
        options: SendOptions,
        deadline_ms: i64,
    ) LinkError!void {
        if (self.poisoned or !self.attached or self.detach_sent or self.session.ended)
            return error.LinkDetached;
        const payload = try message.encodeAlloc(self.allocator, msg);
        defer self.allocator.free(payload);
        try self.sendBytesWithOptions(payload, options, deadline_ms);
    }

    /// Send an already encoded message payload.
    pub fn sendBytes(self: *Sender, payload: []const u8, deadline_ms: i64) LinkError!void {
        return self.sendBytesWithOptions(payload, .{}, deadline_ms);
    }

    /// Send an already encoded message payload under explicit delivery
    /// options.
    pub fn sendBytesWithOptions(
        self: *Sender,
        payload: []const u8,
        options: SendOptions,
        deadline_ms: i64,
    ) LinkError!void {
        if (self.poisoned or !self.attached or self.detach_sent or self.session.ended)
            return error.LinkDetached;
        // This call waits for the oldest delivery, so it is only waiting for
        // its own if nothing else is outstanding. Mixing it with
        // `sendBytesAsync` would either report another delivery's verdict as
        // this one's or discard that delivery's verdict entirely, so refuse
        // rather than guess. A caller that never pipelines never sees this.
        if (self.snd_settle_mode != .settled and self.in_flight_len != 0)
            return error.DeliveriesInFlight;

        const token = try self.sendBytesAsync(payload, options, deadline_ms);
        if (self.snd_settle_mode == .settled) return;
        // A send that never reaches a verdict — a timeout, a detach — used to
        // leave no trace. Keeping the entry would wedge the sender: with the
        // default window of one, every later send would find it full.
        errdefer {
            self.terminalizeAbandonedModeSecond();
            self.discardOldest();
        }

        const settlement = try self.awaitSettlement(deadline_ms);
        std.debug.assert(settlement.token.id == token.id);
        switch (settlement.outcome) {
            .accepted => {},
            .rejected => return error.SendRejected,
            .released, .modified => return error.SendNotAccepted,
        }
    }

    /// Forget the oldest delivery without waiting for a verdict.
    fn discardOldest(self: *Sender) void {
        if (self.in_flight_len == 0) return;
        const entry = self.entryAt(0);
        if (entry.rejection) |r| r.deinit(self.allocator);
        entry.rejection = null;
        self.in_flight_head = (self.in_flight_head + 1) % self.in_flight.len;
        self.in_flight_len -= 1;
    }

    /// Write a delivery to the wire and return without waiting for the peer
    /// to settle it.
    ///
    /// The returned token names the delivery in the `Settlement` that
    /// `awaitSettlement` later produces, so a caller keeping several
    /// deliveries in flight can tell which one the peer refused. Deliveries
    /// settle in the order they were sent. In negotiated sender-settled mode,
    /// the token identifies the emitted delivery but no settlement entry is
    /// retained and `awaitSettlement` has nothing to return.
    ///
    /// Returns `error.InFlightWindowFull` when `max_in_flight` deliveries are
    /// already unsettled. Blocking instead would deadlock: only the caller
    /// can retire a delivery, and it cannot do so from inside this call.
    ///
    /// If emitting any transfer frame fails, or if a continuation cannot be
    /// emitted after the opening frame succeeded, the link is poisoned and
    /// later sends return `error.LinkDetached`; recovery must open a new
    /// connection or sender as appropriate.
    pub fn sendBytesAsync(
        self: *Sender,
        payload: []const u8,
        options: SendOptions,
        deadline_ms: i64,
    ) LinkError!DeliveryToken {
        if (self.poisoned or !self.attached or self.detach_sent or self.session.ended)
            return error.LinkDetached;
        if (self.maxMessageSize()) |limit| {
            if (payload.len > limit) return error.MessageTooLarge;
        }
        const sender_settled = self.snd_settle_mode == .settled;
        if (!sender_settled and self.in_flight_len == self.in_flight.len)
            return error.InFlightWindowFull;
        try self.awaitCredit(deadline_ms);

        const delivery_id = self.session.next_outgoing_id;
        var tag: [4]u8 = undefined;
        std.mem.writeInt(u32, &tag, delivery_id, .big);

        var offset: usize = 0;
        var first = true;
        // At most two budgets exist for a delivery: the opening frame carries
        // the delivery id, tag and message format, and every continuation
        // carries none of them. Measuring per chunk re-encoded the same
        // performative once per frame to learn the same two numbers.
        const first_budget = try self.chunkBudget(
            delivery_id,
            &tag,
            true,
            options.message_format,
            sender_settled,
        );
        const cont_budget: usize = if (payload.len > first_budget)
            try self.chunkBudget(
                delivery_id,
                &tag,
                false,
                options.message_format,
                sender_settled,
            )
        else
            first_budget;
        var begun = false;
        var complete = false;
        errdefer if ((begun or self.session.driver.state == .err) and !complete)
            self.poisonPartialDelivery();

        while (first or offset < payload.len) {
            const budget = if (first) first_budget else cont_budget;
            const take = @min(budget, payload.len - offset);
            const more = offset + take < payload.len;

            // §2.5.6 forbids sending while the peer's window is closed, and a
            // multi-frame delivery can exhaust it partway through. The peer
            // reopens it with a flow, so unlike the in-flight ring this is
            // something waiting can actually resolve.
            try self.awaitSessionWindow(deadline_ms);

            const xfer = perf.Transfer{
                .handle = self.handle,
                .delivery_id = if (first) delivery_id else null,
                .delivery_tag = if (first) &tag else null,
                .message_format = if (first) options.message_format else null,
                .settled = sender_settled,
                .more = more,
            };
            // The frame is the performative plus the chunk, and `chunkBudget`
            // measured that performative as `maxOutgoingBody() - budget`.
            const frame_cap = self.session.driver.maxOutgoingBody() - budget + take;
            try self.sendTransfer(xfer, payload[offset..][0..take], frame_cap);

            if (first) {
                // Link credit and delivery-count are consumed when a delivery
                // begins, not when its final continuation is written. Keeping
                // them until the end made a failed multi-frame delivery look
                // as though it had never existed even though the peer had
                // already accepted its opening transfer.
                self.delivery_count +%= 1;
                self.credit -|= 1;
                begun = true;
            }

            // Session ids count transfer *frames*, not deliveries (§2.5.6):
            // every frame of a multi-frame delivery consumes one, even though
            // only the first carries the delivery id. Advancing once per
            // delivery instead would leave the next delivery's id short of
            // what the peer expects, so its dispositions would name ids we
            // never issued.
            self.session.next_outgoing_id +%= 1;
            self.session.remote_incoming_window -|= 1;

            offset += take;
            first = false;
        }

        complete = true;

        if (sender_settled) return .{ .id = delivery_id };

        // Pushed only once every frame is away. A failure after the opening
        // frame poisons the link instead: the peer is holding an unterminated
        // delivery, so reusing the link would make the next transfer a
        // continuation of bytes the caller believed had failed.
        self.in_flight[(self.in_flight_head + self.in_flight_len) % self.in_flight.len] = .{
            .id = delivery_id,
        };
        self.in_flight_len += 1;
        return .{ .id = delivery_id };
    }

    /// Make a link with an unterminated outbound delivery unusable.
    ///
    /// A detach is best effort. A session-window timeout leaves the transport
    /// usable and the peer benefits from being told; a socket failure may make
    /// this write fail too. Local poisoning is unconditional either way, so a
    /// caller can only recover by opening a new link.
    fn poisonPartialDelivery(self: *Sender) void {
        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        if (self.detach_sent or self.session.ended) return;
        self.detach_sent = true;
        self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:link:detach-forced",
                    .description = "outbound delivery did not reach its final transfer",
                },
            },
        }) catch {
            self.session.driver.invalidate();
            self.session.terminate();
        };
    }

    /// Wait for the oldest delivery still in flight to settle and retire it.
    ///
    /// A refused delivery is reported through `Settlement.outcome` rather
    /// than as an error, and its rejection detail lands in `rejection`.
    /// Errors are reserved for the link itself failing.
    pub fn awaitSettlement(self: *Sender, deadline_ms: i64) LinkError!Settlement {
        if (self.in_flight_len == 0) return error.NoDeliveryInFlight;

        while (self.entryAt(0).outcome == null) {
            if (!self.attached) return error.LinkDetached;
            _ = try self.session.pump(deadline_ms);
        }

        const entry = self.entryAt(0);
        self.in_flight_head = (self.in_flight_head + 1) % self.in_flight.len;
        self.in_flight_len -= 1;

        const outcome = entry.outcome.?;
        // Replace the recorded rejection for every refusal, not only for one
        // that named a condition. A `rejected` with no error field is legal,
        // and leaving the previous delivery's condition in place would pair
        // this refusal with an explanation belonging to an older message.
        if (outcome == .rejected) {
            if (self.rejection) |old| old.deinit(self.allocator);
            self.rejection = entry.rejection;
            entry.rejection = null;
        }
        std.debug.assert(entry.rejection == null);
        return .{
            .token = .{ .id = entry.id },
            .outcome = outcome,
            .rejection = if (outcome == .rejected) self.rejection else null,
        };
    }

    /// How many payload bytes fit alongside the transfer performative.
    fn chunkBudget(
        self: *Sender,
        delivery_id: u32,
        tag: *const [4]u8,
        first: bool,
        message_format: u32,
        settled: bool,
    ) LinkError!usize {
        var buf = uamqp.encoder.Buffer.initDynamic(self.allocator);
        defer buf.deinit();
        // Encode with `more` set so the measurement is never an underestimate:
        // a true boolean is written where a defaulted false would be elided.
        // The real message format has to be measured too, since a zero uint
        // encodes as one byte and a batch format as five.
        try perf.encodeTransfer(self.allocator, .{
            .handle = self.handle,
            .delivery_id = if (first) delivery_id else null,
            .delivery_tag = if (first) tag else null,
            .message_format = if (first) message_format else null,
            .settled = settled,
            .more = true,
        }, &buf);

        const available = self.session.driver.maxOutgoingBody();
        if (available <= buf.written().len) return error.FrameTooLarge;
        return available - buf.written().len;
    }

    fn sendTransfer(
        self: *Sender,
        xfer: perf.Transfer,
        chunk: []const u8,
        frame_cap: usize,
    ) LinkError!void {
        var buf = uamqp.encoder.Buffer.initFixed(try self.frameBuffer(frame_cap));
        try perf.encodeTransfer(self.allocator, xfer, &buf);
        // A fixed buffer never allocates, so the only way `writeAll` fails is
        // running out of room — which `chunkBudget` is supposed to have made
        // impossible. Report that as the frame problem it is rather than as a
        // memory problem it is not.
        buf.writeAll(chunk) catch return error.FrameTooLarge;
        try self.session.driver.sendFrame(.amqp, self.session.channel, buf.written());
    }

    /// The reusable frame scratch, grown to `need` if it is not already there.
    ///
    /// `need` is the size of the frame actually being written, not the peer's
    /// advertised `max-frame-size`. That value is unbounded on the wire — AMQP
    /// §2.7.1 makes an absent `max-frame-size` mean `2^32-1`, which this
    /// codec implements — so sizing to it would let a peer dictate a 4 GiB
    /// allocation for a five-byte message. Sizing to the frame instead means
    /// a sender holds only as much as its largest real frame, and every
    /// later frame of the same size reuses it.
    fn frameBuffer(self: *Sender, need: usize) LinkError![]u8 {
        if (self.frame_buf.len >= need) return self.frame_buf;
        self.frame_buf = if (self.frame_buf.len == 0)
            try self.allocator.alloc(u8, need)
        else
            try self.allocator.realloc(self.frame_buf, need);
        return self.frame_buf;
    }

    fn awaitCredit(self: *Sender, deadline_ms: i64) LinkError!void {
        while (self.credit == 0) {
            if (!self.attached) return error.LinkDetached;
            _ = try self.session.pump(deadline_ms);
        }
    }

    /// Wait until the peer can absorb another transfer frame.
    fn awaitSessionWindow(self: *Sender, deadline_ms: i64) LinkError!void {
        while (self.session.remote_incoming_window == 0) {
            if (!self.attached) return error.LinkDetached;
            _ = try self.session.pump(deadline_ms);
        }
    }
};

/// Attach a sender and wait for the peer's attach.
pub fn openSender(
    session: *Session,
    options: SenderOptions,
    deadline_ms: i64,
) LinkError!*Sender {
    session.clearFailedLinkOpen();
    var opening_resolved = false;

    for (session.senders.items) |sender| {
        if (std.mem.eql(u8, sender.name, options.name)) return error.LinkNameInUse;
    }

    const sender = try session.allocator.create(Sender);
    errdefer session.allocator.destroy(sender);

    const name = try session.allocator.dupe(u8, options.name);
    errdefer session.allocator.free(name);

    // At least one slot, so a caller that asks for zero gets the blocking
    // send rather than a link that can never send anything.
    const window = @max(options.max_in_flight, 1);
    const in_flight = try session.allocator.alloc(InFlight, window);
    errdefer session.allocator.free(in_flight);

    sender.* = .{
        .allocator = session.allocator,
        .session = session,
        .name = name,
        .handle = session.allocateHandle(),
        .in_flight = in_flight,
        .snd_settle_mode = options.snd_settle_mode,
        .rcv_settle_mode = options.rcv_settle_mode,
    };

    try session.senders.append(session.allocator, sender);
    errdefer _ = session.senders.pop();
    errdefer session.preserveFailedLinkOpen(&sender.detach_error);

    try session.driver.sendPerformative(.amqp, session.channel, .{ .attach = .{
        .name = name,
        .handle = sender.handle,
        .role = .sender,
        .snd_settle_mode = options.snd_settle_mode,
        .rcv_settle_mode = options.rcv_settle_mode,
        .source = .{ .address = options.source_address },
        .target = .{ .address = options.target_address },
        .initial_delivery_count = 0,
        .desired_capabilities = options.desired_capabilities,
        .properties = options.properties,
    } });
    errdefer {
        if (!opening_resolved) {
            session.driver.invalidate();
            session.terminate();
        }
    }

    while (sender.awaiting_attach) {
        _ = try session.pump(deadline_ms);
    }
    if (!sender.attached) {
        opening_resolved = true;
        session.preserveFailedLinkOpen(&sender.detach_error);
        return error.LinkDetached;
    }
    opening_resolved = true;
    session.clearFailedLinkOpen();
    return sender;
}

// ─────────────────────── Receiver ───────────────────────

pub const ReceiverOptions = struct {
    name: []const u8,
    /// The entity to read from, such as
    /// `eh/ConsumerGroups/$default/Partitions/0`.
    source_address: []const u8,
    target_address: ?[]const u8 = null,
    rcv_settle_mode: perf.ReceiverSettleMode = .first,
    /// Source filters; Event Hubs carries the starting position in a selector.
    filters: ?[]const perf.Filter = null,
    desired_capabilities: ?[]const []const u8 = null,
    properties: ?perf.Fields = null,
    /// Credit issued on attach and topped back up as deliveries arrive. Zero
    /// disables prefetch, leaving credit to `issueCredit`.
    prefetch: u32 = 300,
    /// How far past its granted credit a peer may run before the link is
    /// detached with `amqp:link:transfer-limit-exceeded`.
    ///
    /// A peer can legitimately have transfers in flight when its credit runs
    /// out, so an overrun is absorbed rather than refused — but something
    /// has to bound it, because this endpoint advertises a constant
    /// `incoming-window` and so relies on link credit alone for backpressure
    /// (#326). Null derives a bound from `prefetch`; zero disables only the
    /// detach, not the charging, so an overrunning peer is still granted less
    /// but is never torn down.
    max_overrun: ?u32 = null,
    /// The largest message this receiver will accept, declared in our `attach`
    /// and enforced during reassembly.
    ///
    /// Both halves are needed. Declaring it makes a conformant sender fail the
    /// message on its own side, which is the outcome everyone wants; enforcing
    /// it locally is what makes it a *bound*, because §2.7.3 makes respecting
    /// the field the sender's obligation and a peer under no obligation to be
    /// honest is exactly the one this defends against.
    ///
    /// Null or zero means unlimited only when `max_buffered_bytes` is also
    /// null. With a finite aggregate budget, that budget becomes the effective
    /// per-message limit and is what the receiver advertises.
    ///
    /// The peer's own declaration is not consulted;
    /// `Receiver.maxMessageSize` says why.
    max_message_size: ?u64 = default_max_message_size,
    /// Aggregate payload bytes retained in completed deliveries and the
    /// delivery currently being reassembled.
    ///
    /// When finite, credit is capped so a conforming peer cannot fill more
    /// than this even when every delivery reaches `max_message_size`.
    /// The delivery already handed to the caller is outside this budget; it is
    /// bounded separately by `max_message_size` and remains valid until the
    /// next successful `receive`.
    ///
    /// Null explicitly disables the aggregate bound. The default is finite;
    /// callers choosing null also choose responsibility for bounding total
    /// retention above this layer.
    /// A zero-byte finite budget is invalid.
    max_buffered_bytes: ?u64 = default_max_buffered_bytes,
    /// Maximum unsettled delivery ids retained while the application decides
    /// an outcome or mode second waits for the sender's acknowledgment.
    ///
    /// This is independent of payload bytes: handing a delivery to the caller
    /// releases its aggregate-byte reservation, but its id remains live until
    /// settlement. Credit never authorizes more unsettled deliveries than the
    /// remaining slots.
    max_unsettled_deliveries: u32 = default_max_unsettled_deliveries,
};

/// The floor for a derived `max_overrun`, so a receiver driving credit by
/// hand rather than by prefetch still has a bound.
const min_overrun_allowance: u32 = 64;

/// Default ceiling on a single received message, in bytes.
///
/// Sized to clear the largest message Azure will hand us with room to spare:
/// Event Hubs allows 1 MB, or up to 20 MB on Dedicated clusters, and Service
/// Bus 256 KB standard / 100 MB premium. 100 MiB would equal that last figure
/// to the byte, leaving none for the annotations a broker adds on delivery
/// (`x-opt-sequence-number`, `x-opt-enqueued-time`, and friends), and going
/// over detaches the link rather than returning something retryable.
///
pub const default_max_message_size: u64 = 128 * 1024 * 1024;

/// Default aggregate ceiling for payload bytes retained by one receiver.
///
/// With the default 128 MiB per-message limit this authorizes two deliveries
/// at a time. Services with smaller known message limits can safely retain a
/// deeper delivery window by setting both receiver limits explicitly.
pub const default_max_buffered_bytes: u64 = 256 * 1024 * 1024;

/// Default bound on unsettled delivery-id bookkeeping per receiver.
pub const default_max_unsettled_deliveries: u32 = 1024;

/// §2.7.3: an absent *or zero* `max-message-size` means no limit.
fn normalizeMaxMessageSize(size: ?u64) ?u64 {
    const n = size orelse return null;
    return if (n == 0) null else n;
}

/// A finite aggregate budget is also the largest message that can be accepted
/// without violating it, so advertise that effective limit to a conforming
/// peer rather than granting credit for a message we would later detach.
fn effectiveMaxMessageSize(message_size: ?u64, buffered_bytes: ?u64) LinkError!?u64 {
    const budget = buffered_bytes orelse return message_size;
    if (budget == 0) return error.InvalidReceiverOptions;
    return @min(normalizeMaxMessageSize(message_size) orelse budget, budget);
}

/// One received message, valid until the next `receive`.
pub const Delivery = struct {
    id: u32,
    tag: []const u8,
    payload: []const u8,
    settled: bool,
};

const IncomingUnsettled = struct {
    id: u32,
    settle_mode: perf.ReceiverSettleMode,
    disposition_sent: bool = false,
};

pub const Receiver = struct {
    allocator: Allocator,
    session: *Session,
    name: []const u8,
    handle: u32,
    remote_handle: u32 = std.math.maxInt(u32),
    attached: bool = false,
    awaiting_attach: bool = true,
    attach_refused: bool = false,
    poisoned: bool = false,
    detach_sent: bool = false,

    credit: u32 = 0,
    prefetch: u32 = 0,
    /// Deliveries accepted beyond the credit granted, not yet charged against
    /// a later grant. Debt, not a counter: it is what the peer owes, and it is
    /// paid off by reducing the next grant rather than by consuming messages.
    overrun: u32 = 0,
    max_overrun: u32 = 0,
    /// Manual credit requested through `issueCredit` but not yet safe to put
    /// on the wire under the aggregate byte budget.
    deferred_credit: u32 = 0,
    drain: bool = false,
    delivery_count: u32 = 0,
    /// Exclusive delivery id limit established only by a successfully emitted
    /// local Flow. Remote Flow state may reduce credit but never advances it.
    delivery_limit: u32 = 0,
    /// The limit declared in our `attach`; see `maxMessageSize` for the rule
    /// actually enforced, and `ReceiverOptions.max_message_size` for what null
    /// means.
    max_message_size: ?u64 = null,
    /// Receiver settlement mode selected by this local receiver's Attach.
    rcv_settle_mode: perf.ReceiverSettleMode = .first,
    /// What the peer declared in its own `attach`, recorded but not enforced;
    /// `maxMessageSize` says why. It is the largest message the *peer*
    /// supports, which is a bound on a sender rather than on us.
    peer_max_message_size: ?u64 = null,
    /// Payload bytes in `partial` and the live portion of `ready`. The
    /// delivery handed to the caller is no longer buffered and is not counted.
    buffered_bytes: u64 = 0,
    max_buffered_bytes: ?u64 = null,
    detach_error: ?connection.RemoteError = null,

    /// Bytes of the delivery currently being assembled.
    partial: std.ArrayList(u8) = .empty,
    partial_id: ?u32 = null,
    partial_tag: std.ArrayList(u8) = .empty,
    partial_settled: bool = false,
    partial_rcv_settle_mode: perf.ReceiverSettleMode = .first,
    /// This in-progress delivery consumed one application delivery requested
    /// through manual credit. An abort restores exactly this one request.
    partial_manual_demand: bool = false,
    /// Unsettled ids owned by this link, mirrored in the session-wide map so
    /// reuse is rejected across every receiver on the channel.
    unsettled_ids: std.ArrayList(IncomingUnsettled) = .empty,
    /// Maximum unsettled ids retained independently of payload bytes.
    max_unsettled_deliveries: u32 = default_max_unsettled_deliveries,
    /// Completed deliveries not yet handed to the caller.
    ///
    /// Drained with a head cursor rather than by removing the front element:
    /// a prefetching receiver holds hundreds of deliveries, and shifting them
    /// all down on every `receive` makes draining the queue quadratic.
    ready: std.ArrayList(Delivery) = .empty,
    ready_head: usize = 0,
    /// The delivery most recently returned. Owned here, not copied: `receive`
    /// takes the buffers straight out of `ready` and frees them when the next
    /// `receive` ends their "valid until" window.
    current: ?[]const u8 = null,
    current_tag: ?[]const u8 = null,

    pub fn deinit(self: *Receiver) void {
        self.session.releaseReceiverDeliveries(self);
        self.allocator.free(self.name);
        if (self.detach_error) |e| e.deinit(self.allocator);
        self.releaseBuffered(self.partial.items.len);
        self.partial.deinit(self.allocator);
        self.partial_tag.deinit(self.allocator);
        self.unsettled_ids.deinit(self.allocator);
        // Everything before `ready_head` was already handed out, so its
        // buffers belong to `current` and are freed by `releaseCurrent`.
        for (self.ready.items[self.ready_head..]) |d| {
            self.releaseBuffered(d.payload.len);
            self.allocator.free(d.payload);
            self.allocator.free(d.tag);
        }
        self.ready.deinit(self.allocator);
        self.releaseCurrent();
        std.debug.assert(self.buffered_bytes == 0);
        self.allocator.destroy(self);
    }

    fn retainBuffered(self: *Receiver, bytes: usize) void {
        self.buffered_bytes +|= @intCast(bytes);
    }

    fn releaseBuffered(self: *Receiver, bytes: usize) void {
        self.buffered_bytes -|= @intCast(bytes);
    }

    fn acknowledgeSettlementRange(self: *Receiver, first: u32, last: u32) LinkError!void {
        const span = last -% first;
        if (span >= 1 << 31) return;
        const before = self.unsettled_ids.items.len;
        var i = self.unsettled_ids.items.len;
        while (i > 0) {
            i -= 1;
            const active = self.unsettled_ids.items[i];
            if (!active.disposition_sent or active.settle_mode != .second) continue;
            if (active.id -% first > span) continue;
            self.session.releaseIncomingDelivery(self, active.id);
        }
        if (self.unsettled_ids.items.len != before) try self.replenish();
    }

    fn bufferWouldOverflow(self: *const Receiver, bytes: usize) bool {
        const limit = self.max_buffered_bytes orelse return false;
        const add = std.math.cast(u64, bytes) orelse return true;
        return self.buffered_bytes > limit or add > limit - self.buffered_bytes;
    }

    fn clearPartialRetainingCapacity(self: *Receiver) void {
        if (self.partial_id) |id| {
            if (!self.partial_settled) self.session.releaseIncomingDelivery(self, id);
        }
        self.releaseBuffered(self.partial.items.len);
        self.partial.clearRetainingCapacity();
        self.partial_tag.clearRetainingCapacity();
        self.partial_id = null;
        self.partial_settled = false;
        self.partial_rcv_settle_mode = self.rcv_settle_mode;
        self.partial_manual_demand = false;
    }

    fn clearPartialAndFree(self: *Receiver) void {
        if (self.partial_id) |id| {
            if (!self.partial_settled) self.session.releaseIncomingDelivery(self, id);
        }
        self.releaseBuffered(self.partial.items.len);
        self.partial.clearAndFree(self.allocator);
        self.partial_tag.clearAndFree(self.allocator);
        self.partial_id = null;
        self.partial_settled = false;
        self.partial_rcv_settle_mode = self.rcv_settle_mode;
        self.partial_manual_demand = false;
    }

    /// A consumed transfer cannot be replayed. Any failure incorporating it
    /// makes the receiver terminal, otherwise a later continuation could be
    /// appended to an older prefix and surfaced as a truncated delivery.
    fn poisonAfterConsumedTransfer(self: *Receiver) void {
        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        self.clearPartialAndFree();
        self.session.releaseReceiverDeliveries(self);
        self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:link:detach-forced",
                    .description = "receiver could not incorporate a consumed transfer",
                },
            },
        }) catch {};
    }

    fn chargeDeliveryStart(self: *Receiver) bool {
        self.delivery_count +%= 1;
        if (self.credit == 0) {
            self.overrun +|= 1;
            return false;
        }
        self.credit -= 1;
        return self.prefetch == 0 and !self.drain;
    }

    fn restoreAbortedManualDemand(self: *Receiver, consumed: bool) void {
        if (consumed and !self.drain) self.deferred_credit +|= 1;
    }

    fn ensurePartialCapacity(self: *Receiver, needed: usize) Allocator.Error!void {
        if (self.partial.capacity >= needed) return;

        var ceiling: usize = std.math.maxInt(usize);
        if (self.maxMessageSize()) |limit| {
            ceiling = @min(ceiling, std.math.cast(usize, limit) orelse ceiling);
        }
        if (self.max_buffered_bytes) |limit| {
            const other = self.buffered_bytes -| @as(u64, @intCast(self.partial.items.len));
            const available = limit -| other;
            ceiling = @min(ceiling, std.math.cast(usize, available) orelse ceiling);
        }

        // Grow geometrically, but never reserve bytes beyond either ceiling.
        // Exact growth on every continuation would make a long delivery
        // quadratic; unconstrained ArrayList growth could retain more than the
        // aggregate budget even when the logical payload remained within it.
        const geometric = self.partial.capacity +|
            (self.partial.capacity / 2) +| 8;
        const target = @min(@max(needed, geometric), ceiling);
        try self.partial.ensureTotalCapacityPrecise(self.allocator, target);
    }

    fn recordDetach(self: *Receiver, err: ?perf.AmqpError) LinkError!void {
        if (self.detach_error) |e| e.deinit(self.allocator);
        self.detach_error = null;
        const e = err orelse return;
        self.detach_error = try connection.RemoteError.dupe(self.allocator, e);
    }

    /// Queue a completed delivery. The buffers stay the caller's until this
    /// succeeds, so a failed append does not free them twice.
    fn enqueue(self: *Receiver, id: u32, tag: []u8, payload: []u8, settled: bool) LinkError!void {
        self.ready.append(self.allocator, .{
            .id = id,
            .tag = tag,
            .payload = payload,
            .settled = settled,
        }) catch |err| {
            self.poisonAfterConsumedTransfer();
            return err;
        };
    }

    /// Drop the entries the cursor has already passed.
    ///
    /// The cursor alone would let `ready` grow without bound: it only shrinks
    /// when the caller happens to consume the exact last queued delivery, and
    /// a receiver that stays even one delivery behind — an app pumping the
    /// session itself, or two links on one session consumed in turn — never
    /// hits that. Compacting once the consumed run reaches half the array
    /// bounds it by the live backlog while still moving each entry at most
    /// once per two `receive` calls, so draining stays amortised O(1).
    fn compactReady(self: *Receiver) void {
        if (self.ready_head == self.ready.items.len) {
            self.ready.clearRetainingCapacity();
            self.ready_head = 0;
            return;
        }
        if (self.ready_head * 2 < self.ready.items.len) return;

        const live = self.ready.items.len - self.ready_head;
        std.mem.copyForwards(
            Delivery,
            self.ready.items[0..live],
            self.ready.items[self.ready_head..],
        );
        self.ready.shrinkRetainingCapacity(live);
        self.ready_head = 0;
    }

    /// Free the delivery handed out by the previous `receive`, whose "valid
    /// until the next `receive`" window has just closed.
    fn releaseCurrent(self: *Receiver) void {
        if (self.current) |payload| self.allocator.free(payload);
        if (self.current_tag) |tag| self.allocator.free(tag);
        self.current = null;
        self.current_tag = null;
    }

    fn acceptTransfer(self: *Receiver, t: perf.Transfer, chunk: []const u8) LinkError!void {
        if (self.partial_id) |partial_id| {
            // §2.7.5 permits continuations to omit delivery-id or repeat the
            // original value. Only a different id attempts to interleave a
            // new delivery and is terminal.
            if (t.delivery_id) |id| {
                if (id != partial_id) {
                    self.poisonAfterConsumedTransfer();
                    return error.MalformedFrame;
                }
            }
            // Settlement may be asserted on any transfer in the delivery.
            // Once true it is terminal and remains true when later frames
            // omit the field. Receiver-settle-mode is ignored for a
            // sender-settled delivery, including the frame that first makes
            // the cumulative settlement true.
            const settled = self.partial_settled or (t.settled orelse false);
            if (!settled) {
                if (t.rcv_settle_mode) |mode| {
                    if (mode != self.partial_rcv_settle_mode) {
                        self.poisonAfterConsumedTransfer();
                        return error.MalformedFrame;
                    }
                }
            }
            if (settled) {
                if (!self.partial_settled) {
                    self.partial_settled = true;
                    self.session.releaseIncomingDelivery(self, partial_id);
                }
            }
            if (t.aborted) {
                const restore_demand = self.partial_manual_demand;
                self.clearPartialAndFree();
                self.restoreAbortedManualDemand(restore_demand);
                return;
            }
        } else {
            if (t.delivery_id == null) {
                self.poisonAfterConsumedTransfer();
                return error.MalformedFrame;
            }
            try self.refuseOverrun();
            // Link credit and delivery-count are consumed by the initial
            // transfer, whether the delivery later completes or is aborted.
            const manual_demand = self.chargeDeliveryStart();

            const id = t.delivery_id.?;
            if (self.session.incoming_deliveries.contains(id)) {
                self.refuseDuplicateDelivery();
                return error.DuplicateDeliveryId;
            }
            const settled = t.settled orelse false;
            const settle_mode = if (settled)
                self.rcv_settle_mode
            else
                self.effectiveReceiverSettleMode(t.rcv_settle_mode) catch |err| {
                    self.poisonAfterConsumedTransfer();
                    return err;
                };
            if (t.aborted) {
                self.restoreAbortedManualDemand(manual_demand);
                return;
            }
            if (!settled) {
                if (self.unsettled_ids.items.len >= self.max_unsettled_deliveries) {
                    try self.refuseSettlementLimit();
                }
                self.session.reserveIncomingDelivery(self, id, settle_mode) catch |err| {
                    if (err == error.DuplicateDeliveryId) {
                        self.refuseDuplicateDelivery();
                    }
                    return err;
                };
            }

            // A delivery that arrives whole in a single transfer — nearly all
            // Azure messages — bypasses the reassembly buffer.
            if (!t.more) {
                if (self.maxMessageSize()) |limit| {
                    if (chunk.len > limit) try self.refuseOversize();
                }
                if (self.bufferWouldOverflow(chunk.len)) try self.refuseBufferLimit();
                const payload = self.allocator.dupe(u8, chunk) catch |err| {
                    self.poisonAfterConsumedTransfer();
                    return err;
                };
                self.retainBuffered(payload.len);
                errdefer {
                    self.releaseBuffered(payload.len);
                    self.allocator.free(payload);
                }
                const tag = self.allocator.dupe(u8, t.delivery_tag orelse "") catch |err| {
                    self.poisonAfterConsumedTransfer();
                    return err;
                };
                errdefer self.allocator.free(tag);
                return self.enqueue(id, tag, payload, settled);
            }

            self.partial_id = t.delivery_id.?;
            self.partial_settled = settled;
            self.partial_rcv_settle_mode = settle_mode;
            self.partial_manual_demand = manual_demand;
            if (!self.partialReservationFits()) try self.refuseBufferLimit();
            if (t.delivery_tag) |tag| {
                self.partial_tag.appendSlice(self.allocator, tag) catch |err| {
                    self.poisonAfterConsumedTransfer();
                    return err;
                };
            }
        }

        const new_len = std.math.add(usize, self.partial.items.len, chunk.len) catch {
            try self.refuseOversize();
            unreachable;
        };
        if (self.maxMessageSize()) |limit| {
            if (new_len > limit) try self.refuseOversize();
        }
        if (self.bufferWouldOverflow(chunk.len)) try self.refuseBufferLimit();
        self.ensurePartialCapacity(new_len) catch |err| {
            self.poisonAfterConsumedTransfer();
            return err;
        };
        self.partial.appendSliceAssumeCapacity(chunk);
        self.retainBuffered(chunk.len);

        if (t.more) return;

        // The delivery is complete.
        const payload = self.partial.toOwnedSlice(self.allocator) catch |err| {
            self.poisonAfterConsumedTransfer();
            return err;
        };
        errdefer {
            self.releaseBuffered(payload.len);
            self.allocator.free(payload);
        }
        const tag = self.partial_tag.toOwnedSlice(self.allocator) catch |err| {
            self.poisonAfterConsumedTransfer();
            return err;
        };
        errdefer self.allocator.free(tag);

        const id = self.partial_id.?;
        const settled = self.partial_settled;
        self.partial_id = null;
        self.partial_manual_demand = false;

        try self.enqueue(id, tag, payload, settled);
    }

    /// The largest message this receiver will accept, or null when unlimited.
    ///
    /// Our own declared limit only. The peer's declaration is recorded in
    /// `peer_max_message_size` and deliberately not enforced: it would be a
    /// threshold the peer picks, with no headroom for the annotations a broker
    /// adds on delivery, and exceeding it here tears the link down — the same
    /// trade rejected when sizing `default_max_message_size`.
    ///
    /// It would buy a tighter ceiling, not a qualitatively different one:
    /// against a peer declaring 1 MB it would cap a message at 1 MB rather
    /// than 128 MiB. But unbounded growth is already closed by the limit
    /// above, and that marginal tightening does not pay for detaching on a
    /// threshold the peer chose.
    ///
    /// §2.7.3 would permit it: a sender that declares 1 MB and delivers 2 MB
    /// is violating its own declaration. Permitted is not obliged, and what we
    /// are obliged to defend is the limit we ourselves declared.
    pub fn maxMessageSize(self: *const Receiver) ?u64 {
        return normalizeMaxMessageSize(self.max_message_size);
    }

    fn effectiveReceiverSettleMode(
        self: *const Receiver,
        transfer_mode: ?perf.ReceiverSettleMode,
    ) LinkError!perf.ReceiverSettleMode {
        const mode = transfer_mode orelse self.rcv_settle_mode;
        // A sender may ask a mode-second receiver to settle a particular
        // delivery on first disposition. It cannot make a mode-first receiver
        // retain state for a second phase the receiver never negotiated.
        if (self.rcv_settle_mode == .first and mode == .second) {
            return error.MalformedFrame;
        }
        return mode;
    }

    /// Aggregate payload bytes currently waiting in this receiver.
    pub fn bufferedBytes(self: *const Receiver) u64 {
        return self.buffered_bytes;
    }

    fn pendingSettlementCount(self: *const Receiver) usize {
        var count: usize = 0;
        for (self.unsettled_ids.items) |active| {
            if (active.disposition_sent) count += 1;
        }
        return count;
    }

    /// Maximum credit that can be outstanding without letting a conforming
    /// sender exceed the aggregate payload budget.
    fn byteCreditCapacity(self: *const Receiver) u32 {
        // Delivery limits are serial numbers; a grant spanning the undefined
        // half-range cannot later be reconciled safely across wrap.
        const slots = @min(
            self.max_unsettled_deliveries -|
                @as(u32, @intCast(self.unsettled_ids.items.len)),
            @as(u32, std.math.maxInt(i32)),
        );
        const limit = self.max_buffered_bytes orelse return slots;
        // With no per-message bound, one delivery may consume the whole
        // aggregate budget. If the configured message limit is larger than
        // the aggregate budget, the aggregate limit remains authoritative.
        const reservation = @min(self.maxMessageSize() orelse limit, limit);
        if (reservation == 0) return 0;
        const reserved = self.reservedBufferedBytes(reservation);
        if (reserved >= limit) return 0;
        const free = limit - reserved;
        const bytes: u32 = @intCast(@min(free / reservation, std.math.maxInt(u32)));
        return @min(bytes, slots);
    }

    /// Ready deliveries consume their actual size. An in-progress delivery
    /// reserves its full legal size: its current prefix plus the maximum
    /// remaining continuation bytes. Consuming one credit and creating this
    /// reservation are therefore a lossless exchange for a conforming peer.
    fn reservedBufferedBytes(self: *const Receiver, message_size: u64) u64 {
        const partial_bytes: u64 = @intCast(self.partial.items.len);
        const ready_bytes = self.buffered_bytes -| partial_bytes;
        return ready_bytes +| if (self.partial_id != null) message_size else 0;
    }

    fn partialReservationFits(self: *const Receiver) bool {
        const limit = self.max_buffered_bytes orelse return true;
        const message_size = self.maxMessageSize() orelse limit;
        return self.reservedBufferedBytes(message_size) <= limit;
    }

    /// Request `count` additional application deliveries from the peer.
    ///
    /// In manual mode (`prefetch = 0`), an authorized transfer that is later
    /// aborted does not satisfy that request: `receive` reissues its one slot
    /// from inside the pump. Completed deliveries do satisfy it. In prefetch
    /// mode the automatic window, rather than manual demand replacement, owns
    /// replenishment. Aggregate bytes, unsettled slots, and overrun debt may
    /// defer or reduce what can be authorized on the wire at once.
    pub fn issueCredit(self: *Receiver, count: u32) LinkError!void {
        if (self.poisoned or !self.attached or self.detach_sent or self.session.ended)
            return error.LinkDetached;
        try self.reserveIncomingCapacity(count);
        var prospective = self.creditState();
        prospective.deferred_credit +|= count;
        self.grantDeferredCredit(&prospective);
        try self.session.sendFlowWithCredit(self, prospective.credit);
        self.commitEmittedCreditState(prospective);
    }

    fn reserveIncomingCapacity(self: *Receiver, count: u32) Allocator.Error!void {
        const remaining = self.max_unsettled_deliveries -|
            @as(u32, @intCast(self.unsettled_ids.items.len));
        const reserve_count = @min(count, remaining);
        const total = self.unsettled_ids.items.len + @as(usize, reserve_count);
        try self.unsettled_ids.ensureTotalCapacityPrecise(self.allocator, total);
        try self.session.incoming_deliveries.ensureUnusedCapacity(self.allocator, reserve_count);
    }

    const CreditState = struct {
        credit: u32,
        deferred_credit: u32,
        overrun: u32,
    };

    fn creditState(self: *const Receiver) CreditState {
        return .{
            .credit = self.credit,
            .deferred_credit = self.deferred_credit,
            .overrun = self.overrun,
        };
    }

    fn commitCreditState(self: *Receiver, state: CreditState) void {
        self.credit = state.credit;
        self.deferred_credit = state.deferred_credit;
        self.overrun = state.overrun;
    }

    fn commitEmittedCreditState(self: *Receiver, state: CreditState) void {
        self.commitCreditState(state);
        self.delivery_limit = self.delivery_count +% state.credit;
    }

    fn grantDeferredCredit(self: *const Receiver, state: *CreditState) void {
        const capacity = self.byteCreditCapacity();
        if (state.credit >= capacity or state.deferred_credit == 0) return;
        const issued = @min(state.deferred_credit, capacity - state.credit);
        state.deferred_credit -= issued;
        self.grantCreditState(state, state.credit + issued);
    }

    /// Set prospective locally authorized credit, charging overrun debt.
    fn grantCreditState(self: *const Receiver, state: *CreditState, amount: u32) void {
        const bounded = @min(amount, self.byteCreditCapacity());
        const charged = @min(state.overrun, bounded);
        state.overrun -= charged;
        state.credit = bounded - charged;
    }

    /// Top prefetch credit back up once half of it has been consumed, so a
    /// prefetching receiver never stalls waiting for the caller.
    fn replenish(self: *Receiver) LinkError!void {
        var prospective = self.creditState();
        if (prospective.deferred_credit != 0) {
            const before = prospective.credit;
            self.grantDeferredCredit(&prospective);
            if (prospective.credit != before) {
                try self.session.sendFlowWithCredit(self, prospective.credit);
                self.commitEmittedCreditState(prospective);
                return;
            }
        }
        if (self.prefetch == 0) {
            self.commitCreditState(prospective);
            return;
        }
        const target = @min(self.prefetch, self.byteCreditCapacity());
        if (target == 0) {
            self.commitCreditState(prospective);
            return;
        }
        // A one- or two-delivery byte window has no useful half-window: using
        // its last credit avoids a flow write before every second delivery.
        if (prospective.credit > 0 and
            (target <= 2 or prospective.credit > target / 2))
        {
            self.commitCreditState(prospective);
            return;
        }
        // A peer that ran past its last grant is granted that much less now,
        // so it is slowed rather than handed the same window again. Run far
        // enough past and the charge cancels the window entirely, which is
        // what "stop granting credit" means here; keep going and
        // `refuseOverrun` ends the link.
        const before = prospective.credit;
        self.grantCreditState(&prospective, self.prefetch);
        // No flow when the charge cancelled the whole window. A peer only gets
        // here by ignoring credit already, so announcing zero to it buys
        // nothing and would put a frame on the wire per `receive` for as long
        // as it misbehaves. A peer merely racing a flow is usually charged
        // less than a window and is still told its reduced credit below.
        if (prospective.credit == 0 or prospective.credit == before) {
            self.commitCreditState(prospective);
            return;
        }
        try self.session.sendFlowWithCredit(self, prospective.credit);
        self.commitEmittedCreditState(prospective);
    }

    /// Charge overrun debt as buffered deliveries are released, but defer a
    /// positive top-up while a ready backlog already exists. This preserves
    /// the running credit accounting without making `receive` fail while
    /// handing back events that arrived before a connection failure.
    fn chargeOverrunAfterRelease(self: *Receiver, bytes: usize) void {
        if (self.prefetch == 0 or self.overrun == 0) return;
        self.releaseBuffered(bytes);
        defer self.retainBuffered(bytes);
        const allowance = @min(self.prefetch, self.byteCreditCapacity());
        self.overrun -= @min(self.overrun, allowance);
    }

    /// Detach because the peer sent a message past our declared limit.
    ///
    /// A link error rather than a returned error the peer never hears about:
    /// §2.7.3 makes exceeding a declared `max-message-size` a
    /// `message-size-exceeded` link error, and a peer told nothing is free to
    /// repeat it on the very next frame. The reassembly buffer is released
    /// rather than merely cleared, since the whole point is to stop holding
    /// the bytes.
    fn refuseOversize(self: *Receiver) LinkError!void {
        // Detached locally before the frame goes out, for the same reason as
        // `refuseOverrun`: a send failure must not leave the link looking
        // attached and retrying this on every subsequent transfer.
        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        self.clearPartialAndFree();
        self.session.releaseReceiverDeliveries(self);
        try self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:link:message-size-exceeded",
                    .description = "message exceeds the declared max-message-size",
                },
            },
        });
        return error.MessageTooLarge;
    }

    /// Detach before retaining payload bytes past the configured aggregate
    /// receiver budget.
    fn refuseBufferLimit(self: *Receiver) LinkError!void {
        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        self.clearPartialAndFree();
        self.session.releaseReceiverDeliveries(self);
        try self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:resource-limit-exceeded",
                    .description = "receiver buffered payload budget exhausted",
                },
            },
        });
        return error.BufferLimitExceeded;
    }

    fn refuseSettlementLimit(self: *Receiver) LinkError!void {
        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        self.clearPartialAndFree();
        self.session.releaseReceiverDeliveries(self);
        try self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:resource-limit-exceeded",
                    .description = "receiver unsettled delivery limit exhausted",
                },
            },
        });
        return error.SettlementLimitExceeded;
    }

    fn refuseDuplicateDelivery(self: *Receiver) void {
        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        self.clearPartialAndFree();
        self.session.releaseReceiverDeliveries(self);
        self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:link:transfer-limit-exceeded",
                    .description = "unsettled delivery-id was reused",
                },
            },
        }) catch {};
    }

    /// Tear the link down once a peer has run too far past its credit.
    ///
    /// `LinkError.CreditExceeded` was declared from the start and never raised
    /// (#327), which read as enforcement that did not exist. This is the only
    /// thing that raises it.
    fn refuseOverrun(self: *Receiver) LinkError!void {
        if (self.max_overrun == 0) return;
        if (self.overrun < self.max_overrun) return;
        // Every local path that establishes credit charges the debt first, and
        // incoming sender Flow can only reduce credit, so this should be
        // unreachable — and it survives mutation for that reason.
        // It stays a guard rather than an assert because `credit` is computed
        // from values the peer supplies in a flow, and an assert on an
        // invariant a remote peer participates in is a way to be aborted
        // remotely rather than a way to be correct.
        if (self.credit > 0) return;

        // Detached locally before the frame goes out, so that a send failure
        // does not leave the link looking attached and retrying this on every
        // subsequent transfer. The caller then sees the send error rather than
        // `CreditExceeded`, which is the more urgent of the two.
        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        self.clearPartialAndFree();
        self.session.releaseReceiverDeliveries(self);
        try self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:link:transfer-limit-exceeded",
                    .description = "peer sent more transfers than the credit granted",
                },
            },
        });
        return error.CreditExceeded;
    }

    /// Wait for the next complete delivery.
    ///
    /// The returned slices stay valid until the next `receive`.
    pub fn receive(self: *Receiver, deadline_ms: i64) LinkError!Delivery {
        if (self.session.ended or self.detach_sent) return error.LinkDetached;
        while (self.ready.items.len == self.ready_head) {
            if (!self.attached) return error.LinkDetached;
            try self.replenish();
            _ = try self.session.pump(deadline_ms);
        }

        const delivery = self.ready.items[self.ready_head];
        self.chargeOverrunAfterRelease(delivery.payload.len);
        self.ready_head += 1;
        self.compactReady();
        self.releaseBuffered(delivery.payload.len);

        // Only now that a replacement is in hand, so a `receive` that fails or
        // times out leaves the previously returned delivery readable, as it
        // was when this held a reused scratch buffer.
        self.releaseCurrent();

        // The delivery already owns correctly sized buffers, so hand those to
        // the caller instead of copying them into scratch storage.
        self.current = delivery.payload;
        self.current_tag = delivery.tag;

        return delivery;
    }

    /// Settle a delivery with a terminal state.
    pub fn settle(
        self: *Receiver,
        delivery: Delivery,
        state: perf.DeliveryState,
    ) LinkError!void {
        return self.settleRange(delivery.id, delivery.id, state);
    }

    /// Settle a contiguous run of deliveries with one disposition.
    ///
    /// A disposition names a `first`..`last` range (Â§2.7.6), so a consumer
    /// working through a prefetch window does not need a frame per message.
    /// At the default 300-deep prefetch that is the difference between 300
    /// frames of bookkeeping and one.
    ///
    /// The range must be contiguous and must not span a delivery the caller
    /// does not mean to settle: `SettleBatch` builds runs safely from ids that
    /// may have gaps, which they do whenever another link on the same session
    /// took a delivery id in between.
    pub fn settleRange(
        self: *Receiver,
        first: u32,
        last: u32,
        state: perf.DeliveryState,
    ) LinkError!void {
        if (self.session.ended or self.poisoned or !self.attached or self.detach_sent)
            return error.LinkDetached;

        const span = last -% first;
        if (span >= 1 << 31) return error.InvalidState;
        var has_active = false;
        for (self.unsettled_ids.items) |active| {
            if (active.id -% first <= span) {
                has_active = true;
                break;
            }
        }

        var emitted = false;
        var cursor: ?u32 = null;
        var run_first: u32 = 0;
        var run_last: u32 = 0;
        var run_mode: perf.ReceiverSettleMode = .first;
        var have_run = false;

        while (true) {
            var next: ?IncomingUnsettled = null;
            var next_offset: u32 = 0;
            for (self.unsettled_ids.items) |active| {
                const offset = active.id -% first;
                if (offset > span) continue;
                if (active.settle_mode == .second and active.disposition_sent) continue;
                if (cursor) |after| {
                    if (offset <= after) continue;
                }
                if (next == null or offset < next_offset) {
                    next = active;
                    next_offset = offset;
                }
            }

            const active = next orelse {
                if (have_run) {
                    try self.emitSettlementRun(
                        run_first,
                        run_last,
                        run_mode,
                        state,
                        emitted,
                    );
                } else if (!has_active) {
                    // Preserve the API's historical ability to disposition an
                    // explicit range even when those ids were pre-settled or
                    // are no longer retained locally.
                    try self.emitSettlementRun(
                        first,
                        last,
                        self.rcv_settle_mode,
                        state,
                        false,
                    );
                }
                return;
            };

            if (!have_run) {
                run_first = active.id;
                run_last = active.id;
                run_mode = active.settle_mode;
                have_run = true;
            } else if (next_offset == cursor.? + 1 and active.settle_mode == run_mode) {
                run_last = active.id;
            } else {
                try self.emitSettlementRun(
                    run_first,
                    run_last,
                    run_mode,
                    state,
                    emitted,
                );
                emitted = true;
                run_first = active.id;
                run_last = active.id;
                run_mode = active.settle_mode;
            }
            cursor = next_offset;
        }
    }

    fn emitSettlementRun(
        self: *Receiver,
        first: u32,
        last: u32,
        mode: perf.ReceiverSettleMode,
        state: perf.DeliveryState,
        emitted_before: bool,
    ) LinkError!void {
        if (mode == .second) self.setDispositionSent(first, last, true);
        self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .disposition = .{
                .role = .receiver,
                .first = first,
                .last = last,
                .settled = mode == .first,
                .state = state,
            },
        }) catch |err| {
            if (mode == .second and !emitted_before and self.session.driver.state != .err) {
                self.setDispositionSent(first, last, false);
            }
            if (emitted_before or self.session.driver.state == .err) {
                if (self.session.driver.state != .err) self.session.driver.invalidate();
                self.session.terminate();
            }
            return err;
        };

        if (mode == .first) {
            self.session.releaseIncomingRange(self, first, last);
            self.replenish() catch |err| {
                self.session.driver.invalidate();
                self.session.terminate();
                return err;
            };
        }
    }

    fn setDispositionSent(self: *Receiver, first: u32, last: u32, sent: bool) void {
        const span = last -% first;
        for (self.unsettled_ids.items) |*active| {
            if (active.settle_mode != .second or active.id -% first > span) continue;
            active.disposition_sent = sent;
        }
    }

    pub fn accept(self: *Receiver, delivery: Delivery) LinkError!void {
        try self.settle(delivery, .accepted);
    }

    pub fn release(self: *Receiver, delivery: Delivery) LinkError!void {
        try self.settle(delivery, .released);
    }

    /// A drain Flow is visible to the peer once emitted, so an ambiguous wait
    /// failure cannot return this link to normal traffic. Close only this link
    /// when the stream is still clean; a dirty/terminal driver already closes
    /// the wider scope.
    fn failPendingDrain(self: *Receiver, err: LinkError) LinkError {
        const can_emit_detach = self.attached and
            !self.poisoned and
            !self.detach_sent and
            !self.session.ended and
            self.session.driver.state != .err;
        self.drain = false;
        self.credit = 0;
        self.deferred_credit = 0;
        self.delivery_limit = self.delivery_count;
        self.attached = false;
        self.awaiting_attach = false;
        self.poisoned = true;
        self.clearPartialAndFree();
        self.session.releaseReceiverDeliveries(self);

        if (!can_emit_detach) return err;
        self.detach_sent = true;
        self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{
                .handle = self.handle,
                .closed = true,
                .err = .{
                    .condition = "amqp:link:detach-forced",
                    .description = "drain acknowledgement did not complete",
                },
            },
        }) catch {
            self.session.driver.invalidate();
            self.session.terminate();
        };
        return err;
    }

    /// Drain outstanding credit so the peer reports what it has left.
    ///
    /// Once the drain Flow is emitted, a timeout or other ambiguous wait
    /// failure terminally detaches this link. Clearing `drain` and reusing it
    /// would race a peer that may still process the old request, and would
    /// suppress manual abort-demand replacement on later Transfers.
    pub fn drainCredit(self: *Receiver, deadline_ms: i64) LinkError!void {
        if (self.session.ended or self.poisoned or !self.attached or self.detach_sent)
            return error.LinkDetached;
        try self.session.sendFlowWithLinkState(self, self.credit, true);
        self.drain = true;
        // The sender answers a drain by advancing its delivery count over the
        // outstanding credit (§2.6.7), so wait until that lands rather than
        // leaving the link in a half-drained state.
        while (self.credit > 0 and self.attached) {
            _ = self.session.pump(deadline_ms) catch |e| switch (e) {
                error.RemoteClosed, error.ConnectionClosed => break,
                else => return self.failPendingDrain(e),
            };
        }
        self.drain = false;
    }

    /// Detach the link, waiting for the peer's detach.
    pub fn detach(self: *Receiver, deadline_ms: i64) LinkError!void {
        if (self.session.ended or self.poisoned or !self.attached or self.detach_sent)
            return error.LinkDetached;
        self.session.driver.sendPerformative(.amqp, self.session.channel, .{
            .detach = .{ .handle = self.handle, .closed = true },
        }) catch |err| {
            if (self.session.driver.state == .err) {
                self.attached = false;
                self.poisoned = true;
            }
            return err;
        };
        self.detach_sent = true;
        while (self.attached) {
            _ = self.session.pump(deadline_ms) catch |e| switch (e) {
                error.RemoteClosed, error.ConnectionClosed => return,
                else => return e,
            };
        }
    }
};

/// Coalesces deliveries into as few dispositions as their ids allow.
///
/// Delivery ids are allocated by the session, not by the link, so a receiver
/// sharing a session with anything else — a CBS link, `$management`, a second
/// partition — sees gaps in the ids it is handed. Settling a range that spans
/// a gap would settle a delivery belonging to another link, so a run is
/// closed and emitted whenever the next id is not the one after it.
///
/// Nothing is on the wire until `flush`, so a caller that abandons a batch
/// must either flush it or accept that the deliveries stay unsettled — which
/// is the safe direction, since the peer redelivers them.
pub const SettleBatch = struct {
    receiver: *Receiver,
    state: perf.DeliveryState = .accepted,
    first: ?u32 = null,
    last: u32 = 0,

    pub fn init(receiver: *Receiver, state: perf.DeliveryState) SettleBatch {
        return .{ .receiver = receiver, .state = state };
    }

    /// Extend the open run, or close it and start a new one.
    pub fn add(self: *SettleBatch, delivery: Delivery) LinkError!void {
        return self.addId(delivery.id);
    }

    pub fn addId(self: *SettleBatch, id: u32) LinkError!void {
        if (self.first) |_| {
            // A delivery id is a serial number (Â§2.8.3), so 0 really does
            // follow 0xffffffff — but a range written that way reads as
            // `first > last` to anything comparing the two numerically, which
            // includes this library's own `Sender.applyDisposition`. Rather
            // than emit a form only a strict serial-number implementation can
            // read, close the run at the wrap and start a new one.
            if (self.last != std.math.maxInt(u32) and id == self.last + 1) {
                self.last = id;
                return;
            }
            try self.flush();
        }
        self.first = id;
        self.last = id;
    }

    /// Put the open run on the wire, if there is one.
    pub fn flush(self: *SettleBatch) LinkError!void {
        const first = self.first orelse return;
        self.first = null;
        try self.receiver.settleRange(first, self.last, self.state);
    }

    /// Whether anything is waiting to be settled.
    pub fn pending(self: SettleBatch) bool {
        return self.first != null;
    }
};

/// Attach a receiver and wait for the peer's attach.
pub fn openReceiver(
    session: *Session,
    options: ReceiverOptions,
    deadline_ms: i64,
) LinkError!*Receiver {
    session.clearFailedLinkOpen();
    var opening_resolved = false;

    for (session.receivers.items) |receiver| {
        if (std.mem.eql(u8, receiver.name, options.name)) return error.LinkNameInUse;
    }
    const max_message_size = try effectiveMaxMessageSize(
        options.max_message_size,
        options.max_buffered_bytes,
    );
    if (options.max_unsettled_deliveries == 0) return error.InvalidReceiverOptions;

    const receiver = try session.allocator.create(Receiver);
    errdefer session.allocator.destroy(receiver);

    const name = try session.allocator.dupe(u8, options.name);
    errdefer session.allocator.free(name);

    receiver.* = .{
        .allocator = session.allocator,
        .session = session,
        .name = name,
        .handle = session.allocateHandle(),
        .prefetch = options.prefetch,
        .max_overrun = options.max_overrun orelse
            @max(options.prefetch, min_overrun_allowance),
        .max_message_size = max_message_size,
        .max_buffered_bytes = options.max_buffered_bytes,
        .rcv_settle_mode = options.rcv_settle_mode,
        .max_unsettled_deliveries = options.max_unsettled_deliveries,
    };
    errdefer receiver.unsettled_ids.deinit(session.allocator);

    try session.receivers.append(session.allocator, receiver);
    errdefer _ = session.receivers.pop();
    errdefer session.preserveFailedLinkOpen(&receiver.detach_error);

    try session.driver.sendPerformative(.amqp, session.channel, .{ .attach = .{
        .name = name,
        .handle = receiver.handle,
        .role = .receiver,
        .rcv_settle_mode = options.rcv_settle_mode,
        .source = .{
            .address = options.source_address,
            .filters = options.filters,
        },
        .target = .{ .address = options.target_address },
        .initial_delivery_count = 0,
        .max_message_size = max_message_size,
        .desired_capabilities = options.desired_capabilities,
        .properties = options.properties,
    } });
    errdefer {
        if (!opening_resolved) {
            session.driver.invalidate();
            session.terminate();
        }
    }

    while (receiver.awaiting_attach) {
        _ = try session.pump(deadline_ms);
    }
    if (!receiver.attached) {
        opening_resolved = true;
        session.preserveFailedLinkOpen(&receiver.detach_error);
        return error.LinkDetached;
    }

    if (options.prefetch > 0) try receiver.issueCredit(options.prefetch);
    opening_resolved = true;
    session.clearFailedLinkOpen();
    return receiver;
}

// ─────────────────────── Tests ───────────────────────

const testing = std.testing;
const maxInt = std.math.maxInt;
const MemoryTransport = @import("transport.zig").MemoryTransport;
const harness = @import("test_peer.zig");
const Peer = harness.Peer;
const EmittedFrames = harness.EmittedFrames;
const test_options = harness.driver_options;
const Fixture = harness.Fixture;

fn testSession(allocator: Allocator) Session {
    return .{
        .allocator = allocator,
        .driver = undefined,
        .channel = 0,
        .remote_channel = 0,
        .incoming_window = 0,
        .outgoing_window = 0,
    };
}

fn failedLinkOpenUnderAllocator(allocator: Allocator) !void {
    var session = testSession(allocator);
    defer session.deinit();

    const sender_info = [_]uamqp.MapEntry{.{
        .key = .{ .symbol = "link-name" },
        .value = .{ .string = "sender-a" },
    }};
    var sender = Sender{
        .allocator = allocator,
        .session = &session,
        .name = "sender-a",
        .handle = 0,
    };
    sender.detach_error = try connection.RemoteError.dupe(allocator, .{
        .condition = "amqp:unauthorized-access",
        .description = "sender rejected",
        .info = &sender_info,
    });
    session.preserveFailedLinkOpen(&sender.detach_error);
    try testing.expect(sender.detach_error == null);
    // The open path also has an errdefer safety net; its second move is a
    // no-op rather than clearing the diagnostic already retained above.
    session.preserveFailedLinkOpen(&sender.detach_error);

    const sender_diagnostic = session.failedLinkOpen().?;
    try testing.expectEqualStrings("amqp:unauthorized-access", sender_diagnostic.condition());
    try testing.expectEqualStrings("sender rejected", sender_diagnostic.description().?);
    try testing.expectEqualStrings(
        "sender-a",
        sender_diagnostic.info().?[0].value.string,
    );

    const receiver_info = [_]uamqp.MapEntry{.{
        .key = .{ .symbol = "link-name" },
        .value = .{ .string = "receiver-b" },
    }};
    // A new open attempt clears the previous failure before doing anything
    // that can allocate, so an OOM below cannot expose sender-a as its result.
    session.clearFailedLinkOpen();
    var receiver = Receiver{
        .allocator = allocator,
        .session = &session,
        .name = "receiver-b",
        .handle = 1,
    };
    receiver.detach_error = try connection.RemoteError.dupe(allocator, .{
        .condition = "amqp:not-found",
        .description = "receiver rejected",
        .info = &receiver_info,
    });
    session.preserveFailedLinkOpen(&receiver.detach_error);
    try testing.expect(receiver.detach_error == null);

    const receiver_diagnostic = session.failedLinkOpen().?;
    try testing.expectEqualStrings("amqp:not-found", receiver_diagnostic.condition());
    try testing.expectEqualStrings("receiver rejected", receiver_diagnostic.description().?);
    try testing.expectEqualStrings(
        "receiver-b",
        receiver_diagnostic.info().?[0].value.string,
    );

    var taken = session.takeFailedLinkOpen().?;
    defer taken.deinit();
    try testing.expect(session.failedLinkOpen() == null);
    try testing.expectEqualStrings("amqp:not-found", taken.condition());

    session.clearFailedLinkOpen();
    try testing.expect(session.failedLinkOpen() == null);
}

test "failed sender and receiver opens preserve owned remote diagnostics" {
    try failedLinkOpenUnderAllocator(testing.allocator);
}

test "failed link open diagnostics survive every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        failedLinkOpenUnderAllocator,
        .{},
    );
}

test "starting or completing a link open clears stale diagnostics" {
    var session = testSession(testing.allocator);
    defer session.deinit();

    var remote: ?connection.RemoteError = try connection.RemoteError.dupe(
        testing.allocator,
        .{ .condition = "amqp:link:stolen" },
    );
    session.preserveFailedLinkOpen(&remote);
    try testing.expect(session.failedLinkOpen() != null);

    try testing.expectError(error.InvalidReceiverOptions, openReceiver(&session, .{
        .name = "receiver",
        .source_address = "source",
        .max_unsettled_deliveries = 0,
    }, 10_000));
    try testing.expect(session.failedLinkOpen() == null);
    session.clearFailedLinkOpen();
    try testing.expect(session.failedLinkOpen() == null);
}

test "link open allocation failure cannot expose stale diagnostics" {
    // RemoteError with only a condition performs two backing allocations.
    // Fail the first allocation in the following receiver-open attempt.
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 2,
    });
    const allocator = failing.allocator();
    var session = testSession(allocator);
    defer session.deinit();

    var remote: ?connection.RemoteError = try connection.RemoteError.dupe(
        allocator,
        .{ .condition = "amqp:old-error" },
    );
    session.preserveFailedLinkOpen(&remote);
    try testing.expect(session.failedLinkOpen() != null);

    try testing.expectError(error.OutOfMemory, openReceiver(&session, .{
        .name = "receiver",
        .source_address = "source",
    }, 10_000));
    try testing.expect(session.failedLinkOpen() == null);
}

const RefusedLinkKind = enum { sender, receiver };

fn pushRefusedAttach(
    peer: Peer,
    kind: RefusedLinkKind,
    name: []const u8,
    handle: u32,
) !void {
    try peer.pushExact(0, .{ .attach = .{
        .name = name,
        .handle = handle,
        .role = if (kind == .sender) .receiver else .sender,
        .source = if (kind == .sender) .{} else null,
        .target = if (kind == .receiver) .{} else null,
        .initial_delivery_count = if (kind == .receiver) 0 else null,
    } });
}

fn pushDiagnosticRefusal(
    peer: Peer,
    kind: RefusedLinkKind,
    name: []const u8,
    err: perf.AmqpError,
) !void {
    try pushRefusedAttach(peer, kind, name, 40);
    try peer.push(0, .{ .detach = .{
        .handle = 40,
        .closed = true,
        .err = err,
    } });
}

fn openDiagnosticTestLink(session: *Session, kind: RefusedLinkKind, name: []const u8) LinkError!void {
    switch (kind) {
        .sender => _ = try openSender(session, .{
            .name = name,
            .target_address = "entity",
        }, 10_000),
        .receiver => _ = try openReceiver(session, .{
            .name = name,
            .source_address = "entity",
            .prefetch = 0,
        }, 10_000),
    }
}

fn expectDiagnosticRefusal(session: *Session, kind: RefusedLinkKind, name: []const u8) !void {
    openDiagnosticTestLink(session, kind, name) catch |err| {
        if (err == error.LinkDetached) return;
        return err;
    };
    return error.TestUnexpectedResult;
}

test "caller serialized opens keep independent session diagnostics isolated" {
    const allocator = testing.allocator;
    var first_mem = MemoryTransport.init(allocator);
    defer first_mem.deinit();
    var second_mem = MemoryTransport.init(allocator);
    defer second_mem.deinit();
    var first_clock: connection.ManualClock = .{};
    var second_clock: connection.ManualClock = .{};
    const first_peer = Peer{ .allocator = allocator, .mem = &first_mem };
    const second_peer = Peer{ .allocator = allocator, .mem = &second_mem };
    try scriptHandshake(first_peer, 65536);
    try scriptHandshake(second_peer, 65536);

    var first_driver = try Driver.init(allocator, first_mem.transport(), first_clock.clock(), test_options);
    defer first_driver.deinit();
    var second_driver = try Driver.init(allocator, second_mem.transport(), second_clock.clock(), test_options);
    defer second_driver.deinit();
    var first = try Fixture.init(allocator, &first_mem, &first_clock, &first_driver);
    defer first.deinit();
    var second = try Fixture.init(allocator, &second_mem, &second_clock, &second_driver);
    defer second.deinit();

    // Reuse both the link name and remote handle on independent connections.
    try pushDiagnosticRefusal(first_peer, .sender, "link", .{ .condition = "amqp:unauthorized-access" });
    try expectDiagnosticRefusal(&first.session, .sender, "link");
    const first_borrowed = first.session.failedLinkOpen().?;
    try testing.expect(second.session.failedLinkOpen() == null);

    try pushDiagnosticRefusal(second_peer, .receiver, "link", .{ .condition = "amqp:not-found" });
    try expectDiagnosticRefusal(&second.session, .receiver, "link");
    const second_borrowed = second.session.failedLinkOpen().?;
    try testing.expectEqualStrings("amqp:unauthorized-access", first_borrowed.condition());
    try testing.expectEqualStrings("amqp:not-found", second_borrowed.condition());

    var taken = first.session.takeFailedLinkOpen().?;
    defer taken.deinit();
    try testing.expect(first.session.takeFailedLinkOpen() == null);
    try testing.expectEqualStrings("amqp:not-found", second_borrowed.condition());

    try pushDiagnosticRefusal(first_peer, .receiver, "link", .{ .condition = "amqp:resource-limit-exceeded" });
    try expectDiagnosticRefusal(&first.session, .receiver, "link");
    try testing.expectEqualStrings("amqp:resource-limit-exceeded", first.session.failedLinkOpen().?.condition());
    try testing.expectEqualStrings("amqp:not-found", second_borrowed.condition());

    try second_peer.push(0, .{ .attach = .{
        .name = "link",
        .handle = 41,
        .role = .receiver,
    } });
    try openDiagnosticTestLink(&second.session, .sender, "link");
    try testing.expect(second.session.failedLinkOpen() == null);
    try testing.expectEqualStrings("amqp:resource-limit-exceeded", first.session.failedLinkOpen().?.condition());

    try first_peer.push(0, .{ .attach = .{
        .name = "link",
        .handle = 41,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try openDiagnosticTestLink(&first.session, .receiver, "link");
    try testing.expect(first.session.failedLinkOpen() == null);
    try testing.expectEqualStrings("amqp:unauthorized-access", taken.condition());
    try testing.expect(!first.session.ended and !second.session.ended);
}

const diagnostic_test_payload = "nested diagnostic payload" ** 64;
const diagnostic_test_map = [_]uamqp.MapEntry{
    .{ .key = .{ .symbol = "payload" }, .value = .{ .binary = diagnostic_test_payload } },
    .{ .key = .{ .string = "reason" }, .value = .{ .symbol = "unavailable" } },
};
const diagnostic_test_list = [_]uamqp.AmqpValue{
    .{ .string = "context" },
    .{ .map = @constCast(&diagnostic_test_map) },
};
const diagnostic_test_info = [_]uamqp.MapEntry{.{
    .key = .{ .symbol = "details" },
    .value = .{ .list = @constCast(&diagnostic_test_list) },
}};
const diagnostic_test_error = perf.AmqpError{
    .condition = "amqp:not-found",
    .description = "current refusal",
    .info = &diagnostic_test_info,
};

fn expectNestedDiagnostic(diagnostic: FailedLinkOpen) !void {
    try testing.expectEqualStrings(diagnostic_test_error.condition, diagnostic.condition());
    try testing.expectEqualStrings(diagnostic_test_error.description.?, diagnostic.description().?);
    const info = diagnostic.info().?;
    try testing.expectEqual(@as(usize, 1), info.len);
    try testing.expectEqualStrings("details", info[0].key.symbol);
    const list = info[0].value.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("context", list[0].string);
    const map = list[1].map;
    try testing.expectEqual(@as(usize, 2), map.len);
    try testing.expectEqualStrings("payload", map[0].key.symbol);
    try testing.expectEqualStrings(diagnostic_test_payload, map[0].value.binary);
    try testing.expectEqualStrings("reason", map[1].key.string);
    try testing.expectEqualStrings("unavailable", map[1].value.symbol);
}

fn refusedOpenUnderAllocator(allocator: Allocator, kind: RefusedLinkKind) !void {
    var taken: ?FailedLinkOpen = null;
    defer if (taken) |*diagnostic| diagnostic.deinit();
    {
        // Peer scripting is not part of the client's allocation-failure sweep.
        var mem = MemoryTransport.init(testing.allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = testing.allocator, .mem = &mem };
        try scriptHandshake(peer, 65536);
        var options = test_options;
        options.max_frame_size = 65536;
        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        try pushDiagnosticRefusal(peer, kind, "old", .{ .condition = "amqp:old-error" });
        try expectDiagnosticRefusal(&fixture.session, kind, "old");
        try testing.expect(fixture.session.failedLinkOpen() != null);

        try pushDiagnosticRefusal(peer, kind, "refused", diagnostic_test_error);
        mem.clearWritten();
        const result = if (openDiagnosticTestLink(&fixture.session, kind, "refused"))
            return error.TestUnexpectedResult
        else |err|
            err;
        try testing.expectEqual(@as(usize, 0), fixture.session.senders.items.len);
        try testing.expectEqual(@as(usize, 0), fixture.session.receivers.items.len);
        try testing.expectEqual(@as(u32, 0), fixture.session.incoming_deliveries.count());
        if (fixture.session.failedLinkOpen()) |diagnostic| {
            try expectNestedDiagnostic(diagnostic.*);
        } else {
            try testing.expectEqual(error.OutOfMemory, result);
        }
        if (result == error.OutOfMemory) {
            if (mem.written().len != 0) {
                try testing.expect(fixture.session.ended);
                try testing.expectEqual(connection.State.err, driver.state);
                try testing.expect(mem.closed);
                try testing.expectError(error.LinkDetached, fixture.session.pump(10_000));
            } else {
                try testing.expect(!fixture.session.ended);
                try testing.expectEqual(connection.State.opened, driver.state);
            }
            return error.OutOfMemory;
        }
        try testing.expectEqual(error.LinkDetached, result);
        try testing.expect(!fixture.session.ended);
        try testing.expectEqual(connection.State.opened, driver.state);
        taken = fixture.session.takeFailedLinkOpen().?;
        try testing.expect(fixture.session.failedLinkOpen() == null);

        try peer.push(0, .{ .attach = .{
            .name = "retry",
            .handle = 41,
            .role = if (kind == .sender) .receiver else .sender,
            .initial_delivery_count = if (kind == .receiver) 0 else null,
        } });
        openDiagnosticTestLink(&fixture.session, kind, "retry") catch |err| {
            try testing.expect(fixture.session.failedLinkOpen() == null);
            return err;
        };
        try testing.expect(fixture.session.failedLinkOpen() == null);
        try expectNestedDiagnostic(taken.?);
    }
    // The taken arena outlives the frame buffers, session, and driver.
    try expectNestedDiagnostic(taken.?);
}

test "failed open nested diagnostics survive frame reuse and session destruction" {
    inline for (std.meta.tags(RefusedLinkKind)) |kind| {
        try refusedOpenUnderAllocator(testing.allocator, kind);
    }
}

test "refused Attach Detach and cleanup survive every allocation failure" {
    inline for (std.meta.tags(RefusedLinkKind)) |kind| {
        var counting = testing.FailingAllocator.init(testing.allocator, .{});
        try refusedOpenUnderAllocator(counting.allocator(), kind);
        try testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
        for (0..counting.alloc_index) |fail_index| {
            var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
            // Arena reset can fail an optional retention allocation and still
            // decode. Success must satisfy all the same protocol and lifetime
            // assertions; every injected failure must still free its bytes.
            refusedOpenUnderAllocator(failing.allocator(), kind) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
            };
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

fn failDiagnosticDetachFlush(ptr: *anyopaque) @import("transport.zig").TransportError!void {
    const mem: *MemoryTransport = @ptrCast(@alignCast(ptr));
    if (mem.pending.items.len > frame.frame_header_size and
        perf.peekDescriptor(mem.pending.items[frame.frame_header_size..]) == perf.descriptor.detach)
        return error.WriteFailed;
    return mem.transport().flush();
}

test "refused Attach response emission failures preserve diagnostics but forbid reuse" {
    const Failure = enum { header, body, flush };
    inline for (std.meta.tags(RefusedLinkKind)) |kind| {
        inline for (std.meta.tags(Failure)) |failure| {
            const allocator = testing.allocator;
            var mem = MemoryTransport.init(allocator);
            defer mem.deinit();
            var clock: connection.ManualClock = .{};
            const peer = Peer{ .allocator = allocator, .mem = &mem };
            try scriptHandshake(peer, 65536);
            var options = test_options;
            options.max_frame_size = 65536;
            var driver = try Driver.init(allocator, mem.transport(), clock.clock(), options);
            defer driver.deinit();
            var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
            defer fixture.deinit();

            try pushDiagnosticRefusal(peer, kind, "old", .{ .condition = "amqp:old-error" });
            try expectDiagnosticRefusal(&fixture.session, kind, "old");
            try pushDiagnosticRefusal(peer, kind, "refused", diagnostic_test_error);
            mem.clearWritten();
            var vtable = mem.transport().vtable.*;
            switch (failure) {
                .header => mem.fail_write_after = mem.write_count + 2,
                .body => mem.fail_write_after = mem.write_count + 3,
                .flush => {
                    vtable.flush = failDiagnosticDetachFlush;
                    driver.transport = .{ .ptr = &mem, .vtable = &vtable };
                },
            }

            try testing.expectError(error.WriteFailed, openDiagnosticTestLink(&fixture.session, kind, "refused"));
            try testing.expect(fixture.session.ended);
            try testing.expectEqual(connection.State.err, driver.state);
            try testing.expect(mem.closed);
            try testing.expectEqual(@as(usize, 0), fixture.session.senders.items.len);
            try testing.expectEqual(@as(usize, 0), fixture.session.receivers.items.len);
            try testing.expectEqual(@as(usize, 0), mem.pending.items.len);
            try expectNestedDiagnostic(fixture.session.failedLinkOpen().?.*);

            var frames = try EmittedFrames.parse(allocator, mem.written());
            defer frames.deinit();
            try testing.expectEqual(@as(usize, 1), frames.bodies.items.len);
            try testing.expectEqual(perf.descriptor.attach, perf.peekDescriptor(frames.bodies.items[0]).?);
            var taken = fixture.session.takeFailedLinkOpen().?;
            defer taken.deinit();
            const written = mem.written().len;
            mem.fail_write_after = null;
            driver.transport = mem.transport();
            try testing.expectError(error.ConnectionClosed, openDiagnosticTestLink(&fixture.session, kind, "retry"));
            try testing.expect(fixture.session.failedLinkOpen() == null);
            try testing.expectEqual(written, mem.written().len);
            try expectNestedDiagnostic(taken);
        }
    }
}

test "sender and receiver refused Attach wait for Detach and preserve diagnostics" {
    inline for (std.meta.tags(RefusedLinkKind)) |kind| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        try pushRefusedAttach(peer, kind, "refused", 40);
        // Refusal is not complete at the Attach. Keep pumping even when an
        // unrelated session frame separates it from the required Detach.
        try peer.push(0, .{ .flow = .{
            .next_incoming_id = 0,
            .incoming_window = 1000,
            .next_outgoing_id = 1,
            .outgoing_window = 1000,
        } });
        const info = [_]uamqp.MapEntry{.{
            .key = .{ .symbol = "tracking-id" },
            .value = .{ .string = if (kind == .sender) "sender-id" else "receiver-id" },
        }};
        try peer.push(0, .{ .detach = .{
            .handle = 40,
            .closed = true,
            .err = .{
                .condition = if (kind == .sender)
                    "amqp:unauthorized-access"
                else
                    "com.microsoft:georeplication:invalid-offset",
                .description = if (kind == .sender)
                    "sender refused"
                else
                    "receiver refused",
                .info = &info,
            },
        } });

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        switch (kind) {
            .sender => try testing.expectError(error.LinkDetached, openSender(&fixture.session, .{
                .name = "refused",
                .target_address = "entity",
            }, 10_000)),
            .receiver => try testing.expectError(error.LinkDetached, openReceiver(&fixture.session, .{
                .name = "refused",
                .source_address = "entity",
            }, 10_000)),
        }

        try testing.expect(!fixture.session.ended);
        try testing.expectEqual(connection.State.opened, driver.state);
        try testing.expectEqual(@as(usize, 0), fixture.session.senders.items.len);
        try testing.expectEqual(@as(usize, 0), fixture.session.receivers.items.len);

        var diagnostic = fixture.session.takeFailedLinkOpen().?;
        defer diagnostic.deinit();
        try testing.expectEqualStrings(
            if (kind == .sender)
                "amqp:unauthorized-access"
            else
                "com.microsoft:georeplication:invalid-offset",
            diagnostic.condition(),
        );
        try testing.expectEqualStrings(
            if (kind == .sender) "sender refused" else "receiver refused",
            diagnostic.description().?,
        );
        try testing.expectEqualStrings(
            if (kind == .sender) "sender-id" else "receiver-id",
            diagnostic.info().?[0].value.string,
        );

        // The completed refusal is link-scoped. A replacement can open on the
        // same live session, while the taken diagnostics remain independently
        // owned across the next performative decode.
        try peer.push(0, .{ .attach = .{
            .name = "replacement",
            .handle = 41,
            .role = if (kind == .sender) .receiver else .sender,
            .initial_delivery_count = if (kind == .receiver) 1 else null,
        } });
        switch (kind) {
            .sender => _ = try openSender(&fixture.session, .{
                .name = "replacement",
                .target_address = "entity",
            }, 10_000),
            .receiver => _ = try openReceiver(&fixture.session, .{
                .name = "replacement",
                .source_address = "entity",
            }, 10_000),
        }
        try testing.expectEqualStrings(
            if (kind == .sender) "sender refused" else "receiver refused",
            diagnostic.description().?,
        );
    }
}

test "refused Attach without Detach times out and terminalizes opening" {
    inline for (std.meta.tags(RefusedLinkKind)) |kind| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{ .auto_advance_ms = 1 };
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        try pushRefusedAttach(peer, kind, "refused", 40);
        mem.starve = true;

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        const deadline = clock.millis + 10;
        switch (kind) {
            .sender => try testing.expectError(error.Timeout, openSender(&fixture.session, .{
                .name = "refused",
                .target_address = "entity",
            }, deadline)),
            .receiver => try testing.expectError(error.Timeout, openReceiver(&fixture.session, .{
                .name = "refused",
                .source_address = "entity",
            }, deadline)),
        }
        try testing.expect(fixture.session.ended);
        try testing.expectEqual(connection.State.err, driver.state);
        try testing.expect(mem.closed);
        try testing.expect(fixture.session.failedLinkOpen() == null);
        const written = mem.written().len;
        switch (kind) {
            .sender => try testing.expectError(error.ConnectionClosed, openSender(&fixture.session, .{
                .name = "retry",
                .target_address = "entity",
            }, deadline + 10)),
            .receiver => try testing.expectError(error.ConnectionClosed, openReceiver(&fixture.session, .{
                .name = "retry",
                .source_address = "entity",
            }, deadline + 10)),
        }
        try testing.expectEqual(written, mem.written().len);
    }
}

test "malformed Detach after refused Attach terminalizes opening" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try pushRefusedAttach(peer, .receiver, "refused", 40);
    // Detach descriptor with a string where its uint handle must be.
    try peer.pushRaw(0, &.{ 0x00, 0x53, 0x16, 0xc0, 0x04, 0x01, 0xa1, 0x01, 'x' });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    try testing.expectError(error.MalformedFrame, openReceiver(&fixture.session, .{
        .name = "refused",
        .source_address = "entity",
    }, 10_000));
    try testing.expect(fixture.session.ended);
    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    try testing.expect(fixture.session.failedLinkOpen() == null);
    const written = mem.written().len;
    try testing.expectError(error.ConnectionClosed, openReceiver(&fixture.session, .{
        .name = "retry",
        .source_address = "entity",
    }, 10_000));
    try testing.expectEqual(written, mem.written().len);
}

test "Attach response role is validated before accepting a link" {
    inline for (std.meta.tags(RefusedLinkKind)) |kind| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        try peer.pushExact(0, .{ .attach = .{
            .name = "link",
            .handle = 40,
            .role = if (kind == .sender) .sender else .receiver,
            .source = .{},
            .target = .{},
            .initial_delivery_count = 0,
        } });

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        switch (kind) {
            .sender => try testing.expectError(error.MalformedFrame, openSender(&fixture.session, .{
                .name = "link",
                .target_address = "entity",
            }, 10_000)),
            .receiver => try testing.expectError(error.MalformedFrame, openReceiver(&fixture.session, .{
                .name = "link",
                .source_address = "entity",
            }, 10_000)),
        }
        try testing.expect(fixture.session.ended);
        try testing.expectEqual(connection.State.err, driver.state);
    }
}

test "only the peer role's authoritative terminus decides Attach refusal" {
    const Kind = enum { sender_with_null_source, receiver_with_null_target };
    inline for (std.meta.tags(Kind)) |kind| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        try peer.pushExact(0, .{ .attach = .{
            .name = "link",
            .handle = 40,
            .role = if (kind == .sender_with_null_source) .receiver else .sender,
            .source = if (kind == .sender_with_null_source) null else .{},
            .target = if (kind == .receiver_with_null_target) null else .{},
            .initial_delivery_count = if (kind == .receiver_with_null_target) 0 else null,
        } });

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        switch (kind) {
            .sender_with_null_source => {
                const sender = try openSender(&fixture.session, .{
                    .name = "link",
                    .target_address = "entity",
                }, 10_000);
                try testing.expect(sender.attached);
            },
            .receiver_with_null_target => {
                const receiver = try openReceiver(&fixture.session, .{
                    .name = "link",
                    .source_address = "entity",
                }, 10_000);
                try testing.expect(receiver.attached);
            },
        }
    }
}

const scriptHandshake = harness.scriptHandshake;

fn expectReceiverAccounting(receiver: *const Receiver) !void {
    var expected: u64 = @intCast(receiver.partial.items.len);
    for (receiver.ready.items[receiver.ready_head..]) |delivery| {
        expected += @intCast(delivery.payload.len);
    }
    try testing.expectEqual(expected, receiver.bufferedBytes());
    if (receiver.partial_id == null) {
        try testing.expectEqual(@as(usize, 0), receiver.partial.items.len);
    }
    if (receiver.max_buffered_bytes) |budget| {
        const message_size = receiver.maxMessageSize().?;
        const partial_reservation: u128 =
            if (receiver.partial_id != null) message_size else 0;
        const ready_bytes = receiver.bufferedBytes() -|
            @as(u64, @intCast(receiver.partial.items.len));
        const authorised: u128 = @as(u128, ready_bytes) +
            partial_reservation +
            @as(u128, receiver.credit) * @as(u128, message_size);
        try testing.expect(authorised <= budget);
    }
    try testing.expect(
        receiver.unsettled_ids.items.len + @as(usize, receiver.credit) <=
            receiver.max_unsettled_deliveries,
    );
    try testing.expect(
        receiver.credit <=
            remainingToDeliveryLimit(receiver.delivery_limit, receiver.delivery_count),
    );
    try testing.expect(receiver.unsettled_ids.capacity <= receiver.max_unsettled_deliveries);
}

test "a sender attaches and reports the peer's max-message-size" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .max_message_size = 1048576,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .desired_capabilities = &.{connection.georeplication_capability},
    }, 10_000);

    try testing.expect(sender.attached);
    try testing.expectEqual(@as(u64, 1048576), sender.maxMessageSize().?);

    // The attach carried the target address and the geo-replication capability.
    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const attaches = try frames.of(allocator, perf.descriptor.attach);
    defer allocator.free(attaches);
    try testing.expectEqual(@as(usize, 1), attaches.len);

    var decoded = try perf.decode(allocator, attaches[0]);
    defer decoded.deinit();
    const a = decoded.performative.attach;
    try testing.expectEqualStrings("producer", a.name);
    try testing.expectEqual(perf.Role.sender, a.role);
    try testing.expectEqualStrings("eh", a.target.?.address.?);
    try testing.expectEqual(perf.SenderSettleMode.mixed, a.snd_settle_mode);
    try testing.expectEqual(perf.ReceiverSettleMode.first, a.rcv_settle_mode);
    try testing.expectEqualStrings(
        connection.georeplication_capability,
        a.desired_capabilities.?[0],
    );
}

test "a successful link open leaves no prior failed-open diagnostics" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    var remote: ?connection.RemoteError = try connection.RemoteError.dupe(
        allocator,
        .{ .condition = "amqp:link:stolen" },
    );
    fixture.session.preserveFailedLinkOpen(&remote);
    try testing.expect(fixture.session.failedLinkOpen() != null);

    _ = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);
    try testing.expect(fixture.session.failedLinkOpen() == null);
}

test "a message past max-frame-size is split and reassembles to the original" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    // 512 is the spec minimum, so the payload must span several frames.
    try scriptHandshake(peer, 512);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    const big = try allocator.alloc(u8, 1500);
    defer allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);

    mem.clearWritten();
    try sender.sendBytes(big, 10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();

    // Reassemble exactly as a peer would: concatenate the payload that follows
    // each transfer performative, stopping at the frame without `more`.
    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(allocator);

    var count: usize = 0;
    var saw_final = false;
    var first_delivery_id: ?u32 = null;
    var first_tag: ?[]const u8 = null;

    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) != perf.descriptor.transfer) continue;
        count += 1;
        var decoded = try perf.decode(allocator, body);
        defer decoded.deinit();
        const t = decoded.performative.transfer;

        if (count == 1) {
            first_delivery_id = t.delivery_id;
            first_tag = t.delivery_tag;
            try testing.expectEqual(@as(u32, 0), t.message_format.?);
        } else {
            // Continuation frames must not repeat the delivery id or tag.
            try testing.expectEqual(@as(?u32, null), t.delivery_id);
            try testing.expectEqual(@as(?[]const u8, null), t.delivery_tag);
        }

        const consumed = try performativeLength(allocator, body);
        try reassembled.appendSlice(allocator, body[consumed..]);
        if (!t.more) saw_final = true;
    }

    try testing.expect(count > 1);
    try testing.expect(saw_final);
    try testing.expectEqualSlices(u8, big, reassembled.items);
    try testing.expectEqual(@as(u32, 0), first_delivery_id.?);
    // The tag is the delivery id in network order.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, first_tag.?);

    // Every frame stayed inside the peer's advertised limit.
    for (frames.bodies.items) |body| {
        try testing.expect(body.len + frame.frame_header_size <= 512);
    }
}

test "a session-window timeout after the first frame poisons the sender" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try peer.pushHeader(&frame.amqp_header);
    try peer.push(0, .{ .open = .{
        .container_id = "service-bus",
        .max_frame_size = 512,
        .channel_max = 255,
    } });
    // Exactly one transfer frame fits. The continuation has to wait for a
    // flow that this peer deliberately never sends.
    try peer.push(0, .{ .begin = .{
        .remote_channel = 0,
        .next_outgoing_id = 1,
        .incoming_window = 1,
        .outgoing_window = 1000,
    } });
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 5,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    const big = try allocator.alloc(u8, 1500);
    defer allocator.free(big);
    @memset(big, 'x');

    mem.clearWritten();
    mem.starve = true;
    try testing.expectError(error.Timeout, sender.sendBytesAsync(big, .{}, 0));

    try testing.expect(!sender.attached);
    try testing.expectEqual(@as(u32, 1), sender.delivery_count);
    try testing.expectEqual(@as(u32, 4), sender.credit);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const transfers = try frames.of(allocator, perf.descriptor.transfer);
    defer allocator.free(transfers);
    try testing.expectEqual(@as(usize, 1), transfers.len);
    var decoded = try perf.decode(allocator, transfers[0]);
    defer decoded.deinit();
    try testing.expect(decoded.performative.transfer.more);
    const detaches = try frames.of(allocator, perf.descriptor.detach);
    defer allocator.free(detaches);
    try testing.expectEqual(@as(usize, 1), detaches.len);

    // A crossing disposition for the incomplete id has no phantom ring entry
    // to retire or settle twice.
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());

    const before = mem.written().len;
    try testing.expectError(error.LinkDetached, sender.sendBytesAsync("new", .{}, 10_000));
    try testing.expectEqual(before, mem.written().len);
}

test "partial send does not duplicate terminal Detach or emit after End" {
    const Terminal = enum { detach, end };
    inline for (std.meta.tags(Terminal)) |terminal| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try peer.pushHeader(&frame.amqp_header);
        try peer.push(0, .{ .open = .{
            .container_id = "service-bus",
            .max_frame_size = 512,
            .channel_max = 255,
        } });
        try peer.push(0, .{ .begin = .{
            .remote_channel = 0,
            .next_outgoing_id = 1,
            .incoming_window = 1,
            .outgoing_window = 1000,
        } });
        try peer.push(0, .{ .attach = .{
            .name = "producer",
            .handle = 0,
            .role = .receiver,
            .initial_delivery_count = 0,
        } });
        try peer.push(0, .{ .flow = .{
            .next_incoming_id = 0,
            .incoming_window = 1,
            .next_outgoing_id = 1,
            .outgoing_window = 1000,
            .handle = 0,
            .delivery_count = 0,
            .link_credit = 5,
        } });
        switch (terminal) {
            .detach => try peer.push(0, .{ .detach = .{
                .handle = 0,
                .closed = true,
            } }),
            .end => try peer.push(0, .{ .end = .{} }),
        }

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();
        const sender = try openSender(&fixture.session, .{
            .name = "producer",
            .target_address = "eh",
        }, 10_000);

        const big = try allocator.alloc(u8, 1500);
        defer allocator.free(big);
        @memset(big, 'x');

        mem.clearWritten();
        const result = sender.sendBytesAsync(big, .{}, 10_000);
        switch (terminal) {
            .detach => try testing.expectError(error.LinkDetached, result),
            .end => try testing.expectError(error.RemoteClosed, result),
        }
        try testing.expect(sender.poisoned);
        try testing.expectEqual(@as(usize, 0), sender.inFlight());
        switch (terminal) {
            .detach => {
                try testing.expect(sender.detach_sent);
                try testing.expect(!fixture.session.ended);
            },
            .end => try testing.expect(fixture.session.ended),
        }

        var frames = try EmittedFrames.parse(allocator, mem.written());
        defer frames.deinit();
        try testing.expectEqual(@as(usize, 2), frames.bodies.items.len);
        try testing.expectEqual(
            perf.descriptor.transfer,
            perf.peekDescriptor(frames.bodies.items[0]).?,
        );
        var transfer = try perf.decode(allocator, frames.bodies.items[0]);
        defer transfer.deinit();
        try testing.expect(transfer.performative.transfer.more);
        try testing.expectEqual(
            if (terminal == .detach) perf.descriptor.detach else perf.descriptor.end,
            perf.peekDescriptor(frames.bodies.items[1]).?,
        );
        const detaches = try frames.of(allocator, perf.descriptor.detach);
        defer allocator.free(detaches);
        const ends = try frames.of(allocator, perf.descriptor.end);
        defer allocator.free(ends);
        try testing.expectEqual(
            @as(usize, if (terminal == .detach) 1 else 0),
            detaches.len,
        );
        try testing.expectEqual(
            @as(usize, if (terminal == .end) 1 else 0),
            ends.len,
        );

        const written = mem.written().len;
        try testing.expectError(error.LinkDetached, sender.sendBytesAsync("reuse", .{}, 10_000));
        try testing.expectEqual(written, mem.written().len);
    }
}

test "a socket failure after the first frame poisons the sender" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 5);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    const big = try allocator.alloc(u8, 150_000);
    defer allocator.free(big);
    @memset(big, 'x');

    mem.clearWritten();
    // A frame is two writes, header then body. Fail the continuation's header.
    mem.fail_write_after = mem.write_count + 2;
    try testing.expectError(error.WriteFailed, sender.sendBytesAsync(big, .{}, 10_000));

    try testing.expect(!sender.attached);
    try testing.expectEqual(@as(u32, 1), sender.delivery_count);
    try testing.expectEqual(@as(u32, 4), sender.credit);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const transfers = try frames.of(allocator, perf.descriptor.transfer);
    defer allocator.free(transfers);
    try testing.expectEqual(@as(usize, 1), transfers.len);

    mem.fail_write_after = null;
    const before = mem.written().len;
    try testing.expectError(error.LinkDetached, sender.sendBytesAsync("new", .{}, 10_000));
    try testing.expectEqual(before, mem.written().len);
}

test "an opening frame emission failure closes the transport and poisons the sender" {
    const Failure = enum { header, body, flush };
    inline for (std.meta.tags(Failure)) |failure| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptSenderAttach(peer, 5);

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        const sender = try openSender(&fixture.session, .{
            .name = "producer",
            .target_address = "eh",
        }, 10_000);

        mem.clearWritten();
        switch (failure) {
            .header => mem.fail_write_after = mem.write_count,
            .body => mem.fail_write_after = mem.write_count + 1,
            .flush => mem.fail_flush = true,
        }
        try testing.expectError(
            error.WriteFailed,
            sender.sendBytesAsync("opening frame", .{}, 10_000),
        );

        try testing.expectEqual(connection.State.err, driver.state);
        try testing.expect(mem.closed);
        try testing.expectEqual(@as(usize, 0), mem.pending.items.len);
        try testing.expectEqual(@as(usize, 0), mem.written().len);
        try testing.expect(sender.poisoned);
        try testing.expect(!sender.attached);
        try testing.expectEqual(@as(u32, 0), sender.delivery_count);
        try testing.expectEqual(@as(u32, 5), sender.credit);
        try testing.expectEqual(@as(usize, 0), sender.inFlight());

        mem.fail_write_after = null;
        mem.fail_flush = false;
        try testing.expectError(
            error.LinkDetached,
            sender.sendBytesAsync("must not be reused", .{}, 10_000),
        );
        try testing.expectEqual(@as(usize, 0), mem.pending.items.len);
        try testing.expectEqual(@as(usize, 0), mem.written().len);
    }
}

test "a poisoned sender ignores late attach and must be removed before replacement" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 5);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const old = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);
    _ = try fixture.session.pump(10_000);
    old.poisonPartialDelivery();
    try testing.expect(old.poisoned);

    // A late response cannot turn the terminal object back into a live link.
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 7,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 7,
        .delivery_count = 0,
        .link_credit = 99,
    } });
    _ = try fixture.session.pump(10_000);
    _ = try fixture.session.pump(10_000);
    try testing.expect(!old.attached);
    try testing.expect(old.poisoned);
    try testing.expectEqual(@as(u32, 0), old.remote_handle);
    try testing.expectEqual(@as(u32, 5), old.credit);
    try testing.expectError(error.LinkDetached, old.sendBytes("blocked", 10_000));
    try testing.expectError(error.LinkDetached, old.sendBytesAsync("blocked", .{}, 10_000));

    try testing.expectError(error.LinkNameInUse, openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000));

    fixture.session.closeSender(old, 0);

    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 8,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 8,
        .delivery_count = 0,
        .link_credit = 3,
    } });
    const replacement = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);
    _ = try fixture.session.pump(10_000);
    try testing.expect(replacement.attached);
    try testing.expect(!replacement.poisoned);
    try testing.expectEqual(@as(u32, 8), replacement.remote_handle);
    try testing.expectEqual(@as(u32, 3), replacement.credit);
}

test "remote End and Close terminalize the session before returning" {
    const Case = enum { end, close };
    inline for (std.meta.tags(Case)) |case| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        try peer.push(0, .{ .attach = .{
            .name = "producer",
            .handle = 0,
            .role = .receiver,
            .initial_delivery_count = 0,
        } });
        try peer.push(0, .{ .flow = .{
            .next_incoming_id = 0,
            .incoming_window = 1000,
            .next_outgoing_id = 1,
            .outgoing_window = 1000,
            .handle = 0,
            .delivery_count = 0,
            .link_credit = 1,
        } });
        try peer.push(0, .{ .attach = .{
            .name = "consumer",
            .handle = 1,
            .role = .sender,
            .initial_delivery_count = 0,
        } });
        switch (case) {
            .end => try peer.push(0, .{ .end = .{} }),
            .close => try peer.push(7, .{ .close = .{} }),
        }

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        const sender = try openSender(&fixture.session, .{
            .name = "producer",
            .target_address = "eh",
        }, 10_000);
        const receiver = try openReceiver(&fixture.session, .{
            .name = "consumer",
            .source_address = "partition/0",
            .prefetch = 0,
        }, 10_000);

        mem.clearWritten();
        try testing.expectError(error.RemoteClosed, fixture.session.pump(10_000));
        try testing.expect(fixture.session.ended);
        try testing.expect(sender.poisoned);
        try testing.expect(receiver.poisoned);
        if (case == .close) {
            try testing.expectEqual(connection.State.closed, driver.state);
            try testing.expect(mem.closed);
        } else {
            try testing.expectEqual(connection.State.opened, driver.state);
            try testing.expect(!mem.closed);
        }

        var frames = try EmittedFrames.parse(allocator, mem.written());
        defer frames.deinit();
        const descriptor = if (case == .end) perf.descriptor.end else perf.descriptor.close;
        const responses = try frames.of(allocator, descriptor);
        defer allocator.free(responses);
        try testing.expectEqual(@as(usize, 1), responses.len);

        const written = mem.written().len;
        try testing.expectError(error.LinkDetached, sender.sendBytes("blocked", 10_000));
        try testing.expectError(error.LinkDetached, receiver.receive(10_000));
        try testing.expectError(error.LinkDetached, receiver.issueCredit(1));
        try testing.expectError(
            error.LinkDetached,
            receiver.settleRange(0, 0, .accepted),
        );
        try testing.expectEqual(written, mem.written().len);
    }
}

test "a malformed consumed End response terminalizes the local session" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 1);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);
    _ = try fixture.session.pump(10_000); // sender flow
    try peer.pushRaw(0, &.{ 0x00, 0x53, 0x17 });

    try testing.expectError(error.MalformedFrame, fixture.session.end(10_000));
    try testing.expect(fixture.session.ended);
    try testing.expect(sender.poisoned);
    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    const writes = mem.write_count;
    try testing.expectError(error.LinkDetached, sender.sendBytes("blocked", 10_000));
    try testing.expectEqual(writes, mem.write_count);
}

test "End acknowledgement timeout leaves the session terminal without duplicate output" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 1);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);
    _ = try fixture.session.pump(10_000); // sender flow

    mem.clearWritten();
    mem.starve = true;
    try testing.expectError(error.Timeout, fixture.session.end(0));
    try testing.expect(fixture.session.ended);
    try testing.expect(sender.poisoned);
    const written = mem.written().len;
    try testing.expect(written > 0);

    try testing.expectError(error.LinkDetached, fixture.session.end(10_000));
    try testing.expectError(error.LinkDetached, sender.sendBytes("blocked", 10_000));
    try testing.expectEqual(written, mem.written().len);
}

test "Detach acknowledgement timeout blocks transfer flow disposition and retry output" {
    const Case = enum { sender, receiver };
    inline for (std.meta.tags(Case)) |case| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        switch (case) {
            .sender => {
                try peer.push(0, .{ .attach = .{
                    .name = "link",
                    .handle = 0,
                    .role = .receiver,
                    .initial_delivery_count = 0,
                } });
                try peer.push(0, .{ .flow = .{
                    .next_incoming_id = 0,
                    .incoming_window = 1000,
                    .next_outgoing_id = 1,
                    .outgoing_window = 1000,
                    .handle = 0,
                    .delivery_count = 0,
                    .link_credit = 1,
                } });
            },
            .receiver => try peer.push(0, .{ .attach = .{
                .name = "link",
                .handle = 0,
                .role = .sender,
                .initial_delivery_count = 0,
            } }),
        }

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        mem.clearWritten();
        mem.starve = true;
        switch (case) {
            .sender => {
                const sender = try openSender(&fixture.session, .{
                    .name = "link",
                    .target_address = "entity",
                }, 10_000);
                _ = try fixture.session.pump(10_000); // sender flow
                mem.clearWritten();
                try testing.expectError(error.Timeout, sender.detach(0));
                try testing.expect(sender.detach_sent);
                const written = mem.written().len;
                try testing.expect(written > 0);
                try testing.expectError(error.LinkDetached, sender.detach(10_000));
                try testing.expectError(error.LinkDetached, sender.sendBytes("blocked", 10_000));
                try testing.expectEqual(written, mem.written().len);
            },
            .receiver => {
                const receiver = try openReceiver(&fixture.session, .{
                    .name = "link",
                    .source_address = "entity",
                    .prefetch = 0,
                }, 10_000);
                mem.clearWritten();
                try testing.expectError(error.Timeout, receiver.detach(0));
                try testing.expect(receiver.detach_sent);
                const written = mem.written().len;
                try testing.expect(written > 0);
                try testing.expectError(error.LinkDetached, receiver.detach(10_000));
                try testing.expectError(error.LinkDetached, receiver.issueCredit(1));
                try testing.expectError(
                    error.LinkDetached,
                    receiver.settleRange(0, 0, .accepted),
                );
                try testing.expectEqual(written, mem.written().len);
            },
        }
    }
}

test "Attach timeout terminalizes the session before a stale response can bind a replacement" {
    const Kind = enum { sender, receiver };
    inline for (std.meta.tags(Kind)) |kind| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{ .auto_advance_ms = 1 };
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        mem.starve = true;

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        mem.clearWritten();
        const deadline = clock.millis + 10;
        switch (kind) {
            .sender => try testing.expectError(error.Timeout, openSender(&fixture.session, .{
                .name = "link",
                .target_address = "entity",
            }, deadline)),
            .receiver => try testing.expectError(error.Timeout, openReceiver(&fixture.session, .{
                .name = "link",
                .source_address = "entity",
            }, deadline)),
        }
        try testing.expect(fixture.session.ended);
        try testing.expectEqual(connection.State.err, driver.state);
        try testing.expect(mem.closed);
        const written = mem.written().len;
        try testing.expect(written > 0);

        // Even if the old response arrives later, the closed stream cannot
        // route it by name into a replacement object.
        try peer.push(0, .{ .attach = .{
            .name = "link",
            .handle = 77,
            .role = if (kind == .sender) .receiver else .sender,
            .initial_delivery_count = 0,
        } });
        try testing.expectError(error.LinkDetached, fixture.session.pump(deadline + 10));
        switch (kind) {
            .sender => try testing.expectError(
                error.ConnectionClosed,
                openSender(&fixture.session, .{
                    .name = "link",
                    .target_address = "entity",
                }, deadline + 10),
            ),
            .receiver => try testing.expectError(
                error.ConnectionClosed,
                openReceiver(&fixture.session, .{
                    .name = "link",
                    .source_address = "entity",
                }, deadline + 10),
            ),
        }
        try testing.expectEqual(written, mem.written().len);
    }
}

test "a delivery carries the requested message format" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 5,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    mem.clearWritten();
    // The Event Hubs batch format, which is what motivates the option.
    try sender.sendBytesWithOptions("payload", .{ .message_format = 0x80013700 }, 10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const transfers = try frames.of(allocator, perf.descriptor.transfer);
    defer allocator.free(transfers);
    try testing.expectEqual(@as(usize, 1), transfers.len);

    var decoded = try perf.decode(allocator, transfers[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 0x80013700), decoded.performative.transfer.message_format.?);

    const consumed = try performativeLength(allocator, transfers[0]);
    try testing.expectEqualStrings("payload", transfers[0][consumed..]);
}

test "a formatted delivery split across frames keeps every frame within the limit" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    // 512 is the spec minimum, so a five-byte format field is a meaningful
    // share of the budget and an unmeasured one would overflow the frame.
    try scriptHandshake(peer, 512);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    const big = try allocator.alloc(u8, 1500);
    defer allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);

    mem.clearWritten();
    try sender.sendBytesWithOptions(big, .{ .message_format = 0x80013700 }, 10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();

    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(allocator);

    var count: usize = 0;
    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) != perf.descriptor.transfer) continue;
        count += 1;
        var decoded = try perf.decode(allocator, body);
        defer decoded.deinit();

        // Only the first frame names the format; the rest continue it.
        if (count == 1) {
            try testing.expectEqual(@as(u32, 0x80013700), decoded.performative.transfer.message_format.?);
        } else {
            try testing.expectEqual(@as(?u32, null), decoded.performative.transfer.message_format);
        }

        const consumed = try performativeLength(allocator, body);
        try reassembled.appendSlice(allocator, body[consumed..]);
        try testing.expect(body.len + frame.frame_header_size <= 512);
    }

    try testing.expect(count > 1);
    try testing.expectEqualSlices(u8, big, reassembled.items);
}

test "a multi-frame send does not allocate per frame" {
    // The transport and the scripted peer stay on the plain test allocator so
    // that the count reflects the link layer only, not the growth of the
    // in-memory wire.
    var counting = CountingAllocator{ .child = testing.allocator };
    const allocator = counting.allocator();

    var mem = MemoryTransport.init(testing.allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = testing.allocator, .mem = &mem };

    try scriptHandshake(peer, 512);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });
    // The second delivery's id is the first delivery's frame count, since
    // session ids count frames. This test is about allocations, so it settles
    // a range rather than restating that arithmetic.
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 1,
        .last = 1000,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    // Twenty-odd frames at the spec-minimum frame size, so a per-frame cost
    // is impossible to miss.
    const big = try testing.allocator.alloc(u8, 8000);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    // The first send pays for the frame scratch once.
    try sender.sendBytes(big, 10_000);
    try testing.expect(sender.frame_buf.len > 0);

    const before = counting.allocs;
    try sender.sendBytes(big, 10_000);
    const spent = counting.allocs - before;

    var frames = try EmittedFrames.parse(testing.allocator, mem.written());
    defer frames.deinit();
    var transfers: usize = 0;
    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) == perf.descriptor.transfer) transfers += 1;
    }
    // Both sends, so the second one alone sent half of these.
    const per_send = transfers / 2;
    try testing.expect(per_send > 15);

    // One allocation per frame is left: the temporary `encodeDescribedList`
    // builds for the performative's list body. The constant covers the two
    // budget measurements and decoding the peer's disposition.
    //
    // Before the frame scratch and the hoisted budget this same send cost 88
    // allocations rather than 24 — and at the spec-minimum 512-byte frame the
    // old buffer only doubled three times. A real 64 KiB frame doubled ten.
    try testing.expect(spent <= per_send + 8);
}

test "the frame scratch is sized by the message, not by the peer's frame size" {
    var counting = CountingAllocator{ .child = testing.allocator };
    const allocator = counting.allocator();

    var mem = MemoryTransport.init(testing.allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = testing.allocator, .mem = &mem };

    // AMQP §2.7.1: an absent `max-frame-size` means 2^32-1, and this codec
    // decodes it that way. A peer is entitled to say so, and plenty do rather
    // than nominate a number.
    try scriptHandshake(peer, std.math.maxInt(u32));
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    try testing.expectEqual(
        @as(usize, std.math.maxInt(u32) - frame.frame_header_size),
        driver.maxOutgoingBody(),
    );

    try sender.sendBytes("five!", 10_000);

    // Reserving what the peer advertised would have asked for four gibibytes
    // to put five bytes on the wire — either an outright `OutOfMemory` for a
    // well-formed small message, or four gibibytes of address space held for
    // the life of every link.
    try testing.expect(sender.frame_buf.len < 256);
}

test "a rejected disposition surfaces the AMQP condition" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 5,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:link:message-size-exceeded",
            .description = "The received message is larger than the maximum allowed size.",
        } },
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    try testing.expectError(error.SendRejected, sender.sendBytes("payload", 10_000));
    try testing.expectEqualStrings(
        "amqp:link:message-size-exceeded",
        sender.rejection.?.condition,
    );
    try testing.expectEqualStrings(
        "The received message is larger than the maximum allowed size.",
        sender.rejection.?.description.?,
    );
}

/// Script the peer half of a sender attach, granting `credit` deliveries.
fn scriptSenderAttach(peer: Peer, credit: u32) !void {
    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = credit,
    } });
}

fn scriptSettledSenderAttach(peer: Peer, credit: u32) !void {
    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .snd_settle_mode = .settled,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = credit,
    } });
}

fn scriptModeSecondSenderAttach(peer: Peer, credit: u32) !void {
    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .rcv_settle_mode = .second,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = credit,
    } });
}

test "negotiated settled sender completes sync and async sends on emission" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSettledSenderAttach(peer, 3);
    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
        .snd_settle_mode = .settled,
        .max_in_flight = 1,
    }, 10_000);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(perf.SenderSettleMode.settled, sender.snd_settle_mode);

    mem.clearWritten();
    try sender.sendBytes("sync", 10_000);
    const token = try sender.sendBytesAsync("async", .{}, 10_000);
    try testing.expectEqual(@as(u32, 1), token.id);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
    try testing.expectError(error.NoDeliveryInFlight, sender.awaitSettlement(10_000));

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const transfers = try frames.of(allocator, perf.descriptor.transfer);
    defer allocator.free(transfers);
    try testing.expectEqual(@as(usize, 2), transfers.len);
    for (transfers, 0..) |body, id| {
        var decoded = try perf.decode(allocator, body);
        defer decoded.deinit();
        const transfer = decoded.performative.transfer;
        try testing.expect(transfer.settled orelse false);
        try testing.expectEqual(@as(?u32, @intCast(id)), transfer.delivery_id);
    }
}

test "an omitted receiver preference preserves local settled mode" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    // The receiver omits its preference, which decodes as mixed. That accepts
    // rather than overwrites the sender's authoritative settled mode.
    try scriptSenderAttach(peer, 1);
    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
        .snd_settle_mode = .settled,
    }, 10_000);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(perf.SenderSettleMode.settled, sender.snd_settle_mode);

    mem.clearWritten();
    const token = try sender.sendBytesAsync("mixed", .{}, 10_000);
    try testing.expectEqual(@as(u32, 0), token.id);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const transfers = try frames.of(allocator, perf.descriptor.transfer);
    defer allocator.free(transfers);
    try testing.expectEqual(@as(usize, 1), transfers.len);
    var decoded = try perf.decode(allocator, transfers[0]);
    defer decoded.deinit();
    try testing.expect(decoded.performative.transfer.settled orelse false);
    try testing.expectError(error.NoDeliveryInFlight, sender.awaitSettlement(10_000));
}

test "an omitted receiver preference does not pre-settle an unsettled sender" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 1,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
        .snd_settle_mode = .unsettled,
    }, 10_000);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(perf.SenderSettleMode.unsettled, sender.snd_settle_mode);

    mem.clearWritten();
    _ = try sender.sendBytesAsync("unsettled", .{}, 10_000);
    try testing.expectEqual(@as(usize, 1), sender.inFlight());

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const transfers = try frames.of(allocator, perf.descriptor.transfer);
    defer allocator.free(transfers);
    try testing.expectEqual(@as(usize, 1), transfers.len);
    var decoded = try perf.decode(allocator, transfers[0]);
    defer decoded.deinit();
    try testing.expect(!(decoded.performative.transfer.settled orelse false));
}

test "a conflicting receiver preference preserves actual mode and other links" {
    const Case = struct {
        local: perf.SenderSettleMode,
        remote: perf.SenderSettleMode,
    };
    const cases = [_]Case{
        .{ .local = .settled, .remote = .unsettled },
        .{ .local = .unsettled, .remote = .settled },
    };
    for (cases) |case| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        try peer.push(0, .{ .attach = .{
            .name = "survivor",
            .handle = 10,
            .role = .receiver,
            .initial_delivery_count = 0,
        } });
        try peer.push(0, .{ .flow = .{
            .next_incoming_id = 0,
            .incoming_window = 1000,
            .next_outgoing_id = 1,
            .outgoing_window = 1000,
            .handle = 10,
            .delivery_count = 0,
            .link_credit = 1,
        } });
        try peer.push(0, .{ .attach = .{
            .name = "producer",
            .handle = 11,
            .role = .receiver,
            .snd_settle_mode = case.remote,
            .initial_delivery_count = 0,
        } });
        try peer.push(0, .{ .flow = .{
            .next_incoming_id = 0,
            .incoming_window = 1000,
            .next_outgoing_id = 1,
            .outgoing_window = 1000,
            .handle = 11,
            .delivery_count = 0,
            .link_credit = 1,
        } });

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        const survivor = try openSender(&fixture.session, .{
            .name = "survivor",
            .target_address = "other",
            .snd_settle_mode = .settled,
        }, 10_000);
        const sender = try openSender(&fixture.session, .{
            .name = "producer",
            .target_address = "entity",
            .snd_settle_mode = case.local,
        }, 10_000);
        _ = try fixture.session.pump(10_000);

        try testing.expectEqual(connection.State.opened, driver.state);
        try testing.expect(!fixture.session.ended);
        try testing.expect(survivor.attached);
        try testing.expect(sender.attached);
        try testing.expectEqual(case.local, sender.snd_settle_mode);

        mem.clearWritten();
        _ = try survivor.sendBytesAsync("other", .{}, 10_000);
        _ = try sender.sendBytesAsync("actual", .{}, 10_000);
        var frames = try EmittedFrames.parse(allocator, mem.written());
        defer frames.deinit();
        const transfers = try frames.of(allocator, perf.descriptor.transfer);
        defer allocator.free(transfers);
        try testing.expectEqual(@as(usize, 2), transfers.len);

        var survivor_transfer = try perf.decode(allocator, transfers[0]);
        defer survivor_transfer.deinit();
        try testing.expect(survivor_transfer.performative.transfer.settled orelse false);

        var actual_transfer = try perf.decode(allocator, transfers[1]);
        defer actual_transfer.deinit();
        try testing.expectEqual(
            case.local == .settled,
            actual_transfer.performative.transfer.settled orelse false,
        );
        try testing.expectEqual(
            @as(usize, if (case.local == .settled) 0 else 1),
            sender.inFlight(),
        );
    }
}

test "settled sender emission failure poisons without retaining in-flight state" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSettledSenderAttach(peer, 1);
    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
        .snd_settle_mode = .settled,
    }, 10_000);
    _ = try fixture.session.pump(10_000);

    mem.clearWritten();
    mem.fail_write_after = mem.write_count + 1;
    try testing.expectError(
        error.WriteFailed,
        sender.sendBytesAsync("settled", .{}, 10_000),
    );
    mem.fail_write_after = null;

    try testing.expect(sender.poisoned);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expectError(error.LinkDetached, sender.sendBytes("no reuse", 10_000));
}

test "mode-second settlement timeout closes the link before forgetting its id" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{ .auto_advance_ms = 1 };
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptModeSecondSenderAttach(peer, 1);
    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
        .rcv_settle_mode = .second,
    }, 10_000);
    _ = try fixture.session.pump(10_000);

    mem.clearWritten();
    mem.starve = true;
    try testing.expectError(
        error.Timeout,
        sender.sendBytes("payload", clock.millis + 10),
    );
    try testing.expect(sender.poisoned);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const transfers = try frames.of(allocator, perf.descriptor.transfer);
    defer allocator.free(transfers);
    const detaches = try frames.of(allocator, perf.descriptor.detach);
    defer allocator.free(detaches);
    try testing.expectEqual(@as(usize, 1), transfers.len);
    try testing.expectEqual(@as(usize, 1), detaches.len);
    var decoded = try perf.decode(allocator, detaches[0]);
    defer decoded.deinit();
    try testing.expect(decoded.performative.detach.closed);

    // A late first-phase disposition needs no acknowledgment: the peer was
    // already told this link is terminal before the id was discarded.
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .settled = false,
        .state = .accepted,
    } });
    mem.clearWritten();
    _ = try fixture.session.pump(clock.millis + 10_000);
    try testing.expectEqual(@as(usize, 0), mem.written().len);
    try testing.expectError(
        error.LinkDetached,
        sender.sendBytes("no reuse", clock.millis + 10_000),
    );
}

test "abandoning undecided mode-second deliveries closes the bounded link state" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptModeSecondSenderAttach(peer, 2);
    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
        .rcv_settle_mode = .second,
        .max_in_flight = 2,
    }, 10_000);
    _ = try fixture.session.pump(10_000);
    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);

    mem.clearWritten();
    sender.abandonInFlight();
    sender.abandonInFlight();
    try testing.expect(sender.poisoned);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const detaches = try frames.of(allocator, perf.descriptor.detach);
    defer allocator.free(detaches);
    try testing.expectEqual(@as(usize, 1), detaches.len);

    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 1,
        .settled = false,
        .state = .accepted,
    } });
    mem.clearWritten();
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(usize, 0), mem.written().len);
    try testing.expectError(error.LinkDetached, sender.sendBytes("no reuse", 10_000));
}

test "session ids count transfer frames, so a delivery id follows the frames before it" {
    // A multi-frame delivery consumes one session id per frame even though
    // only its first frame carries the delivery id. Advancing once per
    // delivery leaves every later id short of the peer's count, and the peer
    // then settles ids this sender never issued.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    // 512 is the spec minimum, so the first message must span frames.
    try scriptHandshake(peer, 512);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    const big = try allocator.alloc(u8, 1500);
    defer allocator.free(big);
    @memset(big, 'x');

    mem.clearWritten();
    _ = try sender.sendBytesAsync(big, .{}, 10_000);
    _ = try sender.sendBytesAsync("second", .{}, 10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();

    var transfer_frames: u32 = 0;
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(allocator);
    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) != perf.descriptor.transfer) continue;
        transfer_frames += 1;
        var decoded = try perf.decode(allocator, body);
        defer decoded.deinit();
        if (decoded.performative.transfer.delivery_id) |id| try ids.append(allocator, id);
    }

    // The big message spans frames and the small one does not, so the two
    // deliveries are one frame apart plus however many the first added.
    try testing.expect(transfer_frames > 2);
    try testing.expectEqual(@as(usize, 2), ids.items.len);
    try testing.expectEqual(@as(u32, 0), ids.items[0]);
    try testing.expectEqual(transfer_frames - 1, ids.items[1]);
    try testing.expectEqual(transfer_frames, fixture.session.next_outgoing_id);
}

test "a peer settling by the ids it counted reaches the right delivery" {
    // The end-to-end consequence of the id accounting: a spec-conformant peer
    // numbers transfers by frame, so its disposition for the second delivery
    // names an id a per-delivery counter never issues. The sender would then
    // pump for a disposition that can never match and fail on the deadline.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 512);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    const big = try allocator.alloc(u8, 1500);
    defer allocator.free(big);
    @memset(big, 'x');

    // Count the frames the peer would have seen, exactly as it would.
    mem.clearWritten();
    const token = try sender.sendBytesAsync(big, .{}, 10_000);
    try testing.expectEqual(@as(u32, 0), token.id);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    var counted: u32 = 0;
    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) == perf.descriptor.transfer) counted += 1;
    }
    try testing.expect(counted > 1);

    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });
    const first = try sender.awaitSettlement(10_000);
    try testing.expectEqual(Outcome.accepted, first.outcome);

    // The peer's next id is the frame count, not one.
    const next = try sender.sendBytesAsync("second", .{}, 10_000);
    try testing.expectEqual(counted, next.id);

    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = counted,
        .last = counted,
        .settled = true,
        .state = .accepted,
    } });
    const second = try sender.awaitSettlement(10_000);
    try testing.expectEqual(Outcome.accepted, second.outcome);
    try testing.expectEqual(counted, second.token.id);
}

test "the peer's begin seeds the session window" {
    // Discarding the peer's begin left the window at zero, which is why it
    // could not be enforced without deadlocking every send.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try peer.pushHeader(&frame.amqp_header);
    try peer.push(0, .{ .open = .{
        .container_id = "service-bus",
        .max_frame_size = 65536,
        .channel_max = 255,
    } });
    try peer.push(0, .{ .begin = .{
        .remote_channel = 0,
        .next_outgoing_id = 42,
        .incoming_window = 17,
        .outgoing_window = 1000,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    try driver.open(10_000);
    var session = try Session.begin(allocator, &driver, 0, .{}, 10_000);
    defer session.deinit();

    try testing.expectEqual(@as(u32, 17), session.remote_incoming_window);
    try testing.expectEqual(@as(u32, 42), session.next_incoming_id);
}

test "a flow's window is rebased onto the frames already sent" {
    // `incoming-window` describes the peer's capacity as of the id it names,
    // so taking it raw re-credits everything sent since and lets a sender run
    // past the window.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 8,
    }, 10_000);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);
    _ = try sender.sendBytesAsync("c", .{}, 10_000);
    try testing.expectEqual(@as(u32, 3), fixture.session.next_outgoing_id);

    // The peer has processed nothing yet: it can still take 10 from id 0, so
    // only 7 of them are left to us.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 10,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
    } });
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 7), fixture.session.remote_incoming_window);

    // Once it has taken all three, the full window is ours again.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 3,
        .incoming_window = 10,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
    } });
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 10), fixture.session.remote_incoming_window);
}

test "the fallback for a missing next-incoming-id is the session's first id, not zero" {
    // Sessions currently open at id zero, which makes the fallback and the
    // literal indistinguishable on the wire. Drive the arithmetic directly so
    // a session that ever starts elsewhere is still held to the spec.
    var session: Session = undefined;
    session.initial_outgoing_id = 100;
    session.next_outgoing_id = 104;

    // 100 + 10 - 104.
    try testing.expectEqual(@as(u32, 6), session.windowFrom(null, 10));
    // A supplied id wins over the fallback: 102 + 10 - 104.
    try testing.expectEqual(@as(u32, 8), session.windowFrom(102, 10));
    // And the peer is entitled to shrink below what is already in flight.
    try testing.expectEqual(@as(u32, 0), session.windowFrom(null, 2));
}

test "a window is a count, not a serial number, so the widest one stays open" {
    // The clamp applies to how far we have sent past the id the peer named,
    // which the frames in flight bound. The window itself is a peer-supplied
    // uint spanning the whole range, and this library advertises the very
    // largest of them, so clamping that would read the most open window
    // possible as a shut one and stall every send.
    var session: Session = undefined;
    session.initial_outgoing_id = 0;
    session.next_outgoing_id = 0;

    try testing.expectEqual(@as(u32, 0x7FFF_FFFF), session.windowFrom(0, 0x7FFF_FFFF));
    try testing.expectEqual(@as(u32, 0x8000_0000), session.windowFrom(0, 0x8000_0000));
    try testing.expectEqual(maxInt(u32), session.windowFrom(0, maxInt(u32)));
    try testing.expectEqual(maxInt(u32), session.windowFrom(null, maxInt(u32)));

    // Frames sent still come off the widest window.
    session.next_outgoing_id = 3;
    try testing.expectEqual(maxInt(u32) - 3, session.windowFrom(0, maxInt(u32)));

    // A peer naming an id past anything we sent is nonsense rather than a
    // window we have overrun, so its window stands.
    session.next_outgoing_id = 3;
    try testing.expectEqual(@as(u32, 10), session.windowFrom(9, 10));

    // A genuine wrap is a short distance, not a huge one.
    session.next_outgoing_id = 5;
    try testing.expectEqual(@as(u32, 90), session.windowFrom(0xFFFF_FFFB, 100));
}

test "a peer advertising the widest window is sent to, not waited on" {
    // The end-to-end shape of the same thing: this library's own sessions
    // advertise maxInt(u32), so a pair of them would deadlock on the first
    // flow if the widest window read as closed.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try peer.pushHeader(&frame.amqp_header);
    try peer.push(0, .{ .open = .{
        .container_id = "service-bus",
        .max_frame_size = 65536,
        .channel_max = 255,
    } });
    try peer.push(0, .{ .begin = .{
        .remote_channel = 0,
        .next_outgoing_id = 1,
        .incoming_window = maxInt(u32),
        .outgoing_window = maxInt(u32),
    } });
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = maxInt(u32),
        .next_outgoing_id = 1,
        .outgoing_window = maxInt(u32),
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    try testing.expectEqual(maxInt(u32), fixture.session.remote_incoming_window);

    // The flow arrives while sending and must not shut the window.
    mem.clearWritten();
    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    var transfers: usize = 0;
    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) == perf.descriptor.transfer) transfers += 1;
    }
    try testing.expectEqual(@as(usize, 2), transfers);
    try testing.expectEqual(maxInt(u32) - 2, fixture.session.remote_incoming_window);
}

test "a flow without next-incoming-id falls back to the first transfer id" {
    // A peer may omit `next-incoming-id` until it has seen a transfer, and
    // §2.5.6 substitutes our initial outgoing id rather than treating it as
    // zero credit.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 8,
    }, 10_000);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);

    try peer.push(0, .{ .flow = .{
        .incoming_window = 6,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
    } });
    _ = try fixture.session.pump(10_000);

    // initial_outgoing_id (0) + 6 - next_outgoing_id (2).
    try testing.expectEqual(@as(u32, 4), fixture.session.remote_incoming_window);
}

test "a window the sender has run past reads as closed, not as nearly four billion" {
    // The rebase is serial arithmetic, so a peer that shrinks its window below
    // what is already in flight yields a span in the top half rather than a
    // negative. Read raw that is a wide-open window.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 8,
    }, 10_000);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);
    _ = try sender.sendBytesAsync("c", .{}, 10_000);

    // Room for one from id 0, while three are already gone.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
    } });
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), fixture.session.remote_incoming_window);
}

test "a sender waits for the peer to reopen the window instead of sending past it" {
    // §2.5.6 forbids transferring into a closed window. Unlike the in-flight
    // ring, the peer alone reopens this, so waiting is what resolves it.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try peer.pushHeader(&frame.amqp_header);
    try peer.push(0, .{ .open = .{
        .container_id = "service-bus",
        .max_frame_size = 65536,
        .channel_max = 255,
    } });
    // Room for exactly two transfer frames.
    try peer.push(0, .{ .begin = .{
        .remote_channel = 0,
        .next_outgoing_id = 1,
        .incoming_window = 2,
        .outgoing_window = 1000,
    } });
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 2,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 8,
    }, 10_000);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);
    try testing.expectEqual(@as(u32, 0), fixture.session.remote_incoming_window);

    // Nothing more may go out until the peer says so, and this is the only
    // frame left for the sender to find.
    mem.clearWritten();
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 2,
        .incoming_window = 4,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
    } });
    _ = try sender.sendBytesAsync("c", .{}, 10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    var transfers: usize = 0;
    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) == perf.descriptor.transfer) transfers += 1;
    }
    try testing.expectEqual(@as(usize, 1), transfers);
    try testing.expectEqual(@as(u32, 3), fixture.session.remote_incoming_window);
}

test "abandoning the window frees a rejection and lets blocking sends resume" {
    // Waiting is what fails when a pipeline fails, so a caller cannot wait the
    // deliveries out. Without a way to drop them the sender refuses every
    // later blocking send and the link is finished.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    // One verdict covering all three, so the two the caller never collects are
    // each left holding an allocated rejection for the abandon to release.
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 2,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:resource-limit-exceeded",
            .description = "slow down",
        } },
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 3,
        .last = 3,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);
    _ = try sender.sendBytesAsync("c", .{}, 10_000);
    try testing.expectEqual(@as(usize, 3), sender.inFlight());

    // The first comes back refused, which parks an allocated rejection on its
    // entry; the other two are never answered.
    const first = try sender.awaitSettlement(10_000);
    try testing.expectEqual(Outcome.rejected, first.outcome);
    try testing.expectEqual(@as(usize, 2), sender.inFlight());

    // A blocking send is refused while they are outstanding.
    try testing.expectError(error.DeliveriesInFlight, sender.sendBytes("d", 10_000));

    sender.abandonInFlight();
    try testing.expectEqual(@as(usize, 0), sender.inFlight());

    // Abandoning is not a settlement, so the verdict already handed out is
    // still readable — its contract says it lives until the next
    // `awaitSettlement`, and this was not one.
    try testing.expectEqualStrings("slow down", first.rejection.?.description.?);

    // And now it goes through, with the peer settling id 3 as it would.
    try sender.sendBytes("d", 10_000);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
}

test "abandoning an unanswered window leaks nothing" {
    // The entries hold duplicated rejection text, so dropping them has to
    // release it rather than just moving the cursors.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 1,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:internal-error",
            .description = "a description long enough to be worth freeing",
        } },
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);

    // Pump the refusal onto both entries without retiring either.
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(usize, 2), sender.inFlight());

    // testing.allocator reports anything left behind.
    sender.abandonInFlight();
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
}

test "one disposition settles every delivery a pipelining sender put on the wire" {
    // The peer answers four deliveries with a single `0..3` disposition,
    // which it can only do if all four were unsettled at the same moment.
    // A sender that waits for each disposition before writing the next
    // transfer consumes this one frame during its first send and then has
    // nothing left to read, so this cannot pass without pipelining.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 3,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    var tokens: [4]DeliveryToken = undefined;
    for (&tokens) |*token| token.* = try sender.sendBytesAsync("payload", .{}, 10_000);
    try testing.expectEqual(@as(usize, 4), sender.inFlight());

    for (tokens) |token| {
        const settlement = try sender.awaitSettlement(10_000);
        try testing.expectEqual(token.id, settlement.token.id);
        try testing.expect(settlement.outcome == .accepted);
    }
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
}

test "sender acknowledges mode-second receiver dispositions exactly once" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .rcv_settle_mode = .second,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 2,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
        .max_in_flight = 2,
    }, 10_000);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(perf.ReceiverSettleMode.second, sender.rcv_settle_mode);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 1,
        .settled = false,
        .state = .accepted,
    } });

    mem.clearWritten();
    _ = try fixture.session.pump(10_000);
    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const dispositions = try frames.of(allocator, perf.descriptor.disposition);
    defer allocator.free(dispositions);
    try testing.expectEqual(@as(usize, 1), dispositions.len);
    var decoded = try perf.decode(allocator, dispositions[0]);
    defer decoded.deinit();
    const ack = decoded.performative.disposition;
    try testing.expectEqual(perf.Role.sender, ack.role);
    try testing.expectEqual(@as(u32, 0), ack.first);
    try testing.expectEqual(@as(?u32, 1), ack.last);
    try testing.expect(ack.settled);

    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 1,
        .settled = false,
        .state = .accepted,
    } });
    mem.clearWritten();
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(usize, 0), mem.written().len);

    _ = try sender.awaitSettlement(10_000);
    _ = try sender.awaitSettlement(10_000);

    // A mode-second receiver may also settle its disposition itself; that
    // terminal form needs no sender-side second phase.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 2,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 2,
        .link_credit = 1,
    } });
    _ = try fixture.session.pump(10_000);
    _ = try sender.sendBytesAsync("c", .{}, 10_000);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 2,
        .settled = true,
        .state = .accepted,
    } });
    mem.clearWritten();
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(usize, 0), mem.written().len);
    _ = try sender.awaitSettlement(10_000);
}

test "failed sender second-phase acknowledgment terminalizes the session" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .rcv_settle_mode = .second,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 1,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
    }, 10_000);
    _ = try fixture.session.pump(10_000);
    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .settled = false,
        .state = .accepted,
    } });

    mem.fail_write = true;
    try testing.expectError(error.WriteFailed, fixture.session.pump(10_000));
    try testing.expect(fixture.session.ended);
    try testing.expect(sender.poisoned);
    try testing.expectEqual(connection.State.err, driver.state);
}

test "a pipelining sender attributes a rejection to the delivery it names" {
    // The middle delivery is refused and the two around it are accepted. A
    // sender holding one outcome for the whole link cannot say which of the
    // three the broker turned down.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 1,
        .last = 1,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:resource-limit-exceeded",
            .description = "quota",
        } },
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 2,
        .last = 2,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 3,
    }, 10_000);

    var tokens: [3]DeliveryToken = undefined;
    for (&tokens) |*token| token.* = try sender.sendBytesAsync("payload", .{}, 10_000);

    const first = try sender.awaitSettlement(10_000);
    try testing.expectEqual(tokens[0].id, first.token.id);
    try testing.expect(first.outcome == .accepted);

    const refused = try sender.awaitSettlement(10_000);
    try testing.expectEqual(tokens[1].id, refused.token.id);
    try testing.expect(refused.outcome == .rejected);
    try testing.expectEqualStrings(
        "amqp:resource-limit-exceeded",
        sender.rejection.?.condition,
    );

    const last = try sender.awaitSettlement(10_000);
    try testing.expectEqual(tokens[2].id, last.token.id);
    try testing.expect(last.outcome == .accepted);
}

test "a disposition range that wraps past the delivery id ceiling still settles" {
    // Delivery ids are serial numbers, so the run 0xFFFFFFFE, 0xFFFFFFFF, 0
    // is contiguous and the peer may answer it with one range whose `last`
    // is numerically below its `first`.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0xFFFF_FFFE,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 3,
    }, 10_000);
    fixture.session.next_outgoing_id = 0xFFFF_FFFE;

    var tokens: [3]DeliveryToken = undefined;
    for (&tokens) |*token| token.* = try sender.sendBytesAsync("payload", .{}, 10_000);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFE), tokens[0].id);
    try testing.expectEqual(@as(u32, 0), tokens[2].id);

    for (tokens) |token| {
        const settlement = try sender.awaitSettlement(10_000);
        try testing.expectEqual(token.id, settlement.token.id);
        try testing.expect(settlement.outcome == .accepted);
    }
}

test "a sender refuses to exceed its in-flight window" {
    // Leaves two deliveries unsettled at teardown, so this also covers
    // discarding a sender with deliveries still on the wire.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 2,
    }, 10_000);

    _ = try sender.sendBytesAsync("one", .{}, 10_000);
    _ = try sender.sendBytesAsync("two", .{}, 10_000);
    try testing.expectError(
        error.InFlightWindowFull,
        sender.sendBytesAsync("three", .{}, 10_000),
    );
    try testing.expectEqual(@as(usize, 2), sender.inFlight());
}

test "a sender keeps one delivery in flight unless asked for more" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    try testing.expectError(error.NoDeliveryInFlight, sender.awaitSettlement(10_000));
    _ = try sender.sendBytesAsync("one", .{}, 10_000);
    try testing.expectError(
        error.InFlightWindowFull,
        sender.sendBytesAsync("two", .{}, 10_000),
    );
}

test "a zero-byte settlement timeout leaves the sender usable" {
    // A timed-out send used to leave nothing behind. Keeping its ring entry
    // would wedge a default sender: every later send would find the window
    // full and fail with an error no existing caller handles.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{ .auto_advance_ms = 1 };
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    // Nothing is scripted to answer the first send, but zero-byte timeout is
    // intentionally retryable and abandons only this in-flight entry.
    mem.starve = true;
    try testing.expectError(error.Timeout, sender.sendBytes("one", clock.millis + 10));
    try testing.expectEqual(@as(usize, 0), sender.inFlight());

    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 1,
        .last = 1,
        .settled = true,
        .state = .accepted,
    } });
    try sender.sendBytes("two", clock.millis + 10_000);
}

test "a blocking send refuses to run alongside pipelined deliveries" {
    // `sendBytes` waits for the oldest delivery, which is only its own when
    // nothing else is outstanding. Guessing would either report another
    // delivery's verdict as this one's or swallow that delivery's verdict.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    _ = try sender.sendBytesAsync("one", .{}, 10_000);
    try testing.expectError(error.DeliveriesInFlight, sender.sendBytes("two", 10_000));
}

test "a backwards disposition range settles nothing" {
    // A garbled `first = 10, last = 5` is a span of nearly the whole id space
    // under serial arithmetic. Acting on it would settle every delivery on
    // the link, and because the first outcome wins it would pre-empt the real
    // rejection behind it and report a lost message as sent.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 10,
        .last = 5,
        .settled = true,
        .state = .accepted,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .{ .rejected = .{ .condition = "amqp:not-allowed", .description = null } },
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    try testing.expectError(error.SendRejected, sender.sendBytes("payload", 10_000));
    try testing.expectEqualStrings("amqp:not-allowed", sender.rejection.?.condition);
}

test "a rejection with no condition does not inherit the previous one" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:resource-limit-exceeded",
            .description = null,
        } },
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 1,
        .last = 1,
        .settled = true,
        .state = .{ .rejected = null },
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    try testing.expectError(error.SendRejected, sender.sendBytes("one", 10_000));
    try testing.expectEqualStrings(
        "amqp:resource-limit-exceeded",
        sender.rejection.?.condition,
    );

    try testing.expectError(error.SendRejected, sender.sendBytes("two", 10_000));
    try testing.expect(sender.rejection == null);
}

test "a sender discarded with a rejected delivery still in flight frees it" {
    // The rejection condition is heap allocated by the disposition that
    // carried it, so a sender torn down before the delivery is retired has to
    // release it. The leak checker in the test allocator is the assertion.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 1,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:resource-limit-exceeded",
            .description = "quota",
        } },
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 2,
    }, 10_000);

    _ = try sender.sendBytesAsync("one", .{}, 10_000);
    _ = try sender.sendBytesAsync("two", .{}, 10_000);

    // Retire only the first, leaving the second holding a rejection that the
    // session teardown has to free.
    const settlement = try sender.awaitSettlement(10_000);
    try testing.expect(settlement.outcome == .rejected);
    try testing.expectEqual(@as(usize, 1), sender.inFlight());
}

/// Drive a rejected send end to end, so every allocation on the path — the
/// rejection's condition and description among them — is exercised.
fn rejectedSendUnderAllocator(allocator: Allocator) !void {
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:resource-limit-exceeded",
            .description = "the request was terminated by the broker",
        } },
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    sender.sendBytes("payload", 10_000) catch |err| switch (err) {
        error.SendRejected => {},
        else => return err,
    };
}

fn multiFrameReceiveUnderAllocator(allocator: Allocator) !void {
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "\x00\x00\x00\x04",
        .message_format = 0,
        .settled = false,
        .more = true,
    }, "part-one|");
    try peer.pushTransfer(0, .{ .handle = 0, .more = true }, "part-two|");
    try peer.pushTransfer(0, .{ .handle = 0, .more = false }, "part-three");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
    }, 10_000);

    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("part-one|part-two|part-three", delivery.payload);
    try receiver.accept(delivery);
}

fn bufferedReceiveUnderAllocator(allocator: Allocator) !void {
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "t",
        .settled = true,
    }, "event");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 8,
        .max_buffered_bytes = 8,
    }, 10_000);
    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("event", delivery.payload);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
}

test "reassembling a delivery leaks nothing however the allocator fails" {
    // A multi-frame delivery is the receive path's allocating shape: the
    // payload buffer grows per frame, and on completion the payload and the
    // delivery tag are each duped out of their own reassembly buffer. Every
    // one of those is a place a failure could leave a half-built delivery
    // behind.
    //
    // Until #333 this could not have passed: `applyTransfer` measured the
    // performative through `performativeLength` and turned the injected
    // failure into `error.MalformedFrame`. So this is regression cover for
    // #333, not for the signature change this commit makes — it passes
    // either way, and fails if the pre-#333 measurement is reinstated.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        multiFrameReceiveUnderAllocator,
        .{},
    );
}

test "aggregate receive accounting survives every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        bufferedReceiveUnderAllocator,
        .{},
    );
}

fn inspectWrittenPayloadUnderAllocator(allocator: Allocator) !void {
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    mem.clearWritten();
    _ = try sender.sendBytesAsync("payload", .{}, 10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    // Through `of` rather than indexing `bodies`, because `of` is how a test
    // that selects frames by descriptor reaches a body, and `of` leaked its
    // list when an append failed. That is a different defect from the sentinel
    // — `of` reported the failure faithfully and merely stranded memory on
    // the way out — but for those tests it was an independent blocker, so
    // fixing `transferPayload` alone would have left the road closed one step
    // earlier. Tests that walk `bodies` directly, which most here do, met only
    // the sentinel.
    const transfers = try frames.of(allocator, perf.descriptor.transfer);
    defer allocator.free(transfers);
    const payload = try harness.transferPayload(allocator, transfers[0]);
    try testing.expectEqualStrings("payload", payload);
}

test "inspecting what was written survives a failing allocator" {
    // Regression cover for both of the things that stopped
    // `checkAllAllocationFailures` being pointed at a test that inspects
    // written bytes: `performativeLength` answering `?usize`, and
    // `EmittedFrames.of` stranding its list. Note that this is a different
    // set of tests from "the receive path" the issue named — #333 had
    // already cleared that, as the test above shows.
    //
    // Splitting a transfer's payload from its performative means decoding the
    // performative again, which allocates, so an injected failure lands here.
    // While that answered `?usize` the failure was indistinguishable from a
    // malformed frame, and since every caller that consumed it unwrapped it,
    // the injection aborted the test process on a null unwrap.
    //
    // Revert the signature and this does not fail — it panics. Drop the
    // `errdefer` in `of` and it fails with a leak instead.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        inspectWrittenPayloadUnderAllocator,
        .{},
    );
}

test "a rejected send leaks nothing however the allocator fails" {
    // Recording a rejection allocates twice, and the second dupe failing is
    // the only way to observe a half-built `Rejection`. Assigning the struct
    // literal straight into `entry.rejection` would use the field as the
    // result location, publishing a non-null optional holding a live
    // `condition` and an undefined `description` before the failure — a
    // double free of the one and a wild free of the other. No mutation of
    // working code reaches this; only a failing allocator does.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        rejectedSendUnderAllocator,
        .{},
    );
}

test "a message past the peer's max-message-size is refused before sending" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .max_message_size = 16,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    mem.clearWritten();
    try testing.expectError(
        error.MessageTooLarge,
        sender.sendBytes("this payload is well past sixteen bytes", 10_000),
    );
    // Nothing went on the wire.
    try testing.expectEqual(@as(usize, 0), mem.written().len);
}

test "a receiver applies the epoch and receiver-name link properties" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const props = [_]uamqp.MapEntry{
        .{ .key = .{ .symbol = receiver_name_property }, .value = .{ .string = "instance-7" } },
        .{ .key = .{ .symbol = epoch_property }, .value = .{ .long = 5 } },
    };
    const filters = [_]perf.Filter{
        perf.Filter.selector("amqp.annotation.x-opt-offset > '100'"),
    };

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .target_address = "instance-7",
        .filters = &filters,
        .properties = &props,
        .desired_capabilities = &.{connection.georeplication_capability},
        .prefetch = 0,
    }, 10_000);
    try testing.expect(receiver.attached);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const attaches = try frames.of(allocator, perf.descriptor.attach);
    defer allocator.free(attaches);
    try testing.expectEqual(@as(usize, 1), attaches.len);

    var decoded = try perf.decode(allocator, attaches[0]);
    defer decoded.deinit();
    const a = decoded.performative.attach;
    try testing.expectEqual(perf.Role.receiver, a.role);
    try testing.expectEqualStrings(
        "eh/ConsumerGroups/$default/Partitions/0",
        a.source.?.address.?,
    );
    try testing.expectEqualStrings("instance-7", a.target.?.address.?);

    try testing.expectEqualStrings(receiver_name_property, a.properties.?[0].key.symbol);
    try testing.expectEqualStrings("instance-7", a.properties.?[0].value.string);
    try testing.expectEqualStrings(epoch_property, a.properties.?[1].key.symbol);
    try testing.expectEqual(@as(i64, 5), a.properties.?[1].value.long);

    const f = a.source.?.filters.?[0];
    try testing.expectEqualStrings(perf.selector_filter_name, f.name);
    try testing.expectEqual(perf.selector_filter_code, f.code.?);
    try testing.expectEqualStrings("amqp.annotation.x-opt-offset > '100'", f.value.string);
}

test "a receiver reassembles a multi-frame delivery" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "\x00\x00\x00\x04",
        .message_format = 0,
        .settled = false,
        .more = true,
    }, "part-one|");
    try peer.pushTransfer(0, .{ .handle = 0, .more = true }, "part-two|");
    try peer.pushTransfer(0, .{ .handle = 0, .more = false }, "part-three");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
    }, 10_000);

    const delivery = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 4), delivery.id);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x04", delivery.tag);
    try testing.expectEqualStrings("part-one|part-two|part-three", delivery.payload);

    mem.clearWritten();
    try receiver.accept(delivery);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    try testing.expectEqual(@as(usize, 1), frames.bodies.items.len);
    var decoded = try perf.decode(allocator, frames.bodies.items[0]);
    defer decoded.deinit();
    const d = decoded.performative.disposition;
    try testing.expectEqual(perf.Role.receiver, d.role);
    try testing.expectEqual(@as(u32, 4), d.first);
    try testing.expect(d.settled);
    try testing.expectEqual(perf.DeliveryState.accepted, d.state.?);
}

/// Counts allocations so a test can assert that a code path performs none.
/// Deliberately local to the tests: `azure_sdk_amqp` depends on nothing but
/// `uamqp`, and a benchmark harness is not worth changing that.
const CountingAllocator = struct {
    child: Allocator,
    allocs: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, a, ra);
        if (result != null) self.allocs += 1;
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, a, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(buf, a, new_len, ra);
        // Only a move is a new allocation; growing in place is not.
        if (result) |p| {
            if (p != buf.ptr) self.allocs += 1;
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
    }
};

/// Fails every allocation operation while switched on, then resumes normally.
/// This lets a test fail one consumed transfer and continue pumping the same
/// connection to prove the receiver cannot reuse a stale prefix.
const SwitchAllocator = struct {
    child: Allocator,
    failing: bool = false,
    allocations_before_failure: ?usize = null,

    fn allocator(self: *SwitchAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *SwitchAllocator = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return null;
        return self.child.rawAlloc(len, a, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *SwitchAllocator = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return false;
        return self.child.rawResize(buf, a, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *SwitchAllocator = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return null;
        return self.child.rawRemap(buf, a, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *SwitchAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
    }

    fn shouldFail(self: *SwitchAllocator) bool {
        if (self.failing) return true;
        if (self.allocations_before_failure) |remaining| {
            if (remaining == 0) return true;
            self.allocations_before_failure = remaining - 1;
        }
        return false;
    }
};

test "body-buffer OOM after a frame header invalidates the session and sender" {
    var switching = SwitchAllocator{ .child = testing.allocator };
    const allocator = switching.allocator();
    var mem = MemoryTransport.init(testing.allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = testing.allocator, .mem = &mem };

    try scriptSenderAttach(peer, 1);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);
    _ = try fixture.session.pump(10_000); // sender flow

    // Larger than every handshake body, so receiveFrame consumes this frame's
    // header and then has to grow body_buf before it can read the body.
    try peer.pushRaw(0, "x" ** 400);
    switching.failing = true;
    try testing.expectError(error.OutOfMemory, fixture.session.pump(10_000));
    switching.failing = false;

    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    try testing.expect(fixture.session.ended);
    try testing.expect(sender.poisoned);
    try testing.expect(!sender.attached);
    try testing.expectError(error.LinkDetached, sender.sendBytes("no reuse", 10_000));
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
}

const TerminalReadFailure = enum { eof, read_failed };

fn terminalReadFailureInvalidatesSession(failure: TerminalReadFailure) !void {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 1,
    } });
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 1,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "entity",
    }, 10_000);
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .prefetch = 0,
    }, 10_000);

    // A zero-byte deadline remains retryable.
    mem.starve = true;
    try testing.expectError(error.Timeout, fixture.session.pump(0));
    try testing.expectEqual(connection.State.opened, driver.state);
    try testing.expect(!fixture.session.ended);
    try testing.expect(sender.attached);
    try testing.expect(receiver.attached);

    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 2,
    } });
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 2), sender.credit);

    mem.starve = false;
    mem.fail_read = failure == .read_failed;
    mem.clearWritten();
    const result = fixture.session.pump(10_000);
    mem.fail_read = false;
    switch (failure) {
        .eof => try testing.expectError(error.ConnectionClosed, result),
        .read_failed => try testing.expectError(error.ReadFailed, result),
    }

    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    try testing.expect(fixture.session.ended);
    try testing.expect(sender.poisoned);
    try testing.expect(!sender.attached);
    try testing.expect(receiver.poisoned);
    try testing.expect(!receiver.attached);

    const writes = mem.write_count;
    try testing.expectError(error.LinkDetached, sender.sendBytes("blocked", 10_000));
    try testing.expectError(error.LinkDetached, receiver.issueCredit(1));
    try testing.expectEqual(writes, mem.write_count);
    try testing.expectEqual(@as(usize, 0), mem.written().len);
}

test "zero-byte EOF terminalizes every link in the session" {
    try terminalReadFailureInvalidatesSession(.eof);
}

test "zero-byte read failure terminalizes every link in the session" {
    try terminalReadFailureInvalidatesSession(.read_failed);
}

test "remote Close error-copy OOM invalidates the consumed control frame" {
    var switching = SwitchAllocator{ .child = testing.allocator };
    const allocator = switching.allocator();
    var mem = MemoryTransport.init(testing.allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = testing.allocator, .mem = &mem };

    try scriptSenderAttach(peer, 1);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);
    _ = try fixture.session.pump(10_000); // flow also warms the decode arena
    try peer.push(0, .{ .close = .{ .err = .{
        .condition = "amqp:connection:forced",
        .description = "closing",
    } } });

    switching.failing = true;
    try testing.expectError(error.OutOfMemory, fixture.session.pump(10_000));
    switching.failing = false;

    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    try testing.expect(fixture.session.ended);
    try testing.expect(sender.poisoned);
    const writes = mem.write_count;
    try testing.expectError(error.LinkDetached, sender.sendBytes("blocked", 10_000));
    try testing.expectEqual(writes, mem.write_count);
}

test "disposition range OOM terminalizes every matching in-flight delivery" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 3);

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 3,
    }, 10_000);
    _ = try fixture.session.pump(10_000); // sender flow
    for (0..3) |_| _ = try sender.sendBytesAsync("payload", .{}, 10_000);

    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 2,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:resource-limit-exceeded",
            .description = "rejected range",
        } },
    } });

    // Two allocations complete the first rejection. Fail the condition copy
    // for the second entry, after the range has already begun mutating.
    var switching = SwitchAllocator{ .child = allocator, .allocations_before_failure = 2 };
    sender.allocator = switching.allocator();
    const result = fixture.session.pump(10_000);
    sender.allocator = allocator;
    switching.allocations_before_failure = null;
    try testing.expectError(error.OutOfMemory, result);

    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    try testing.expect(sender.poisoned);
    try testing.expectEqual(@as(usize, 3), sender.inFlight());
    for (0..3) |i| {
        try testing.expectEqual(Outcome.rejected, sender.entryAt(i).outcome.?);
    }

    // All three terminal outcomes remain drainable even though only the first
    // rejection detail could be represented before the allocator failed.
    for (0..3) |i| {
        const settlement = try sender.awaitSettlement(10_000);
        try testing.expectEqual(@as(u32, @intCast(i)), settlement.token.id);
        try testing.expectEqual(Outcome.rejected, settlement.outcome);
        if (i == 0) {
            try testing.expectEqualStrings(
                "amqp:resource-limit-exceeded",
                settlement.rejection.?.condition,
            );
        } else {
            try testing.expectEqual(@as(?Rejection, null), settlement.rejection);
        }
    }
    try testing.expectError(error.LinkDetached, sender.sendBytes("no reuse", 10_000));
}

test "the window this endpoint advertises slides forward with what it receives" {
    // A peer computes its own capacity from `next-incoming-id +
    // incoming-window` (§2.5.6). Spending the window per frame while the id
    // rises pins that sum for the life of the session, so the peer's capacity
    // runs down to nothing and it stops sending — a once-per-session budget
    // wearing the shape of a window. Now that senders honour the number, a
    // pair of these endpoints would stall on it.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    const deliveries = 20;
    var i: u32 = 0;
    while (i < deliveries) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 64,
    }, 10_000);

    const capacity = fixture.session.incoming_window;
    const limit_before = fixture.session.next_incoming_id +% capacity;

    i = 0;
    while (i < deliveries) : (i += 1) {
        const delivery = try receiver.receive(10_000);
        try testing.expectEqualStrings("event", delivery.payload);
    }

    // The room on offer is undiminished, and the limit the peer derives from
    // it has moved forward by exactly what arrived.
    try testing.expectEqual(capacity, fixture.session.incoming_window);
    const limit_after = fixture.session.next_incoming_id +% fixture.session.incoming_window;
    try testing.expectEqual(limit_before +% deliveries, limit_after);
}

test "a single-frame delivery bypasses the reassembly buffer" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 16,
    }, 10_000);

    i = 0;
    while (i < 5) : (i += 1) {
        const delivery = try receiver.receive(10_000);
        try testing.expectEqualStrings("event", delivery.payload);
    }

    // Staging a whole-in-one-frame delivery in `partial` would copy the body
    // in and straight back out. Never having allocated the buffer is the
    // observable proof that neither copy happened.
    try testing.expectEqual(@as(usize, 0), receiver.partial.capacity);
    try testing.expectEqual(@as(usize, 0), receiver.partial_tag.capacity);
}

test "receive hands out the queued buffer rather than copying it" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 16,
    }, 10_000);

    // Queue every delivery before taking any, which is the state a
    // prefetching receiver is normally in.
    while (receiver.ready.items.len < 3) _ = try fixture.session.pump(10_000);

    const first = try receiver.receive(10_000);

    // Draining advances a cursor instead of shifting the queue down — which
    // is what made draining a 300-deep prefetch quadratic.
    try testing.expectEqual(@as(usize, 3), receiver.ready.items.len);
    try testing.expectEqual(@as(usize, 1), receiver.ready_head);

    // Same allocation, not a copy of it.
    try testing.expectEqual(receiver.ready.items[0].payload.ptr, first.payload.ptr);
    try testing.expectEqual(receiver.ready.items[0].tag.ptr, first.tag.ptr);

    // The second receive puts the consumed run at half the array, so the live
    // tail is shifted down and the cursor resets.
    _ = try receiver.receive(10_000);
    try testing.expectEqual(@as(usize, 0), receiver.ready_head);
    try testing.expectEqual(@as(usize, 1), receiver.ready.items.len);

    const last = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 2), last.id);
    // Fully drained, so the queue resets rather than growing without bound.
    try testing.expectEqual(@as(usize, 0), receiver.ready.items.len);
    try testing.expectEqual(@as(usize, 0), receiver.ready_head);
}

test "a partially drained queue stays bounded by the backlog" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    const count = 400;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 512,
    }, 10_000);

    while (receiver.ready.items.len < count) _ = try fixture.session.pump(10_000);

    // Consume all but one. A cursor that only reset on an exactly empty queue
    // would still be holding all 400 entries, 399 of them dead, and would go
    // on accruing them for the life of the link.
    i = 0;
    while (i < count - 1) : (i += 1) {
        const delivery = try receiver.receive(10_000);
        try testing.expectEqual(i, delivery.id);
    }

    const backlog = receiver.ready.items.len - receiver.ready_head;
    try testing.expectEqual(@as(usize, 1), backlog);
    try testing.expect(receiver.ready.items.len <= 2 * backlog);

    const last = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, count - 1), last.id);
}

test "draining an already queued backlog allocates nothing" {
    var counting = CountingAllocator{ .child = testing.allocator };
    const allocator = counting.allocator();

    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    // Bodies grow, so a receiver that copied each delivery into one reused
    // scratch buffer would have to keep reallocating it.
    const count = 64;
    var body: [8 + count * 4]u8 = undefined;
    @memset(&body, 'x');

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, body[0 .. 8 + i * 4]);
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 128,
        .max_buffered_bytes = null,
    }, 10_000);

    // Queue the whole backlog first, so the receives below are pure drain.
    while (receiver.ready.items.len < count) _ = try fixture.session.pump(10_000);

    const first = try receiver.receive(10_000);
    try testing.expectEqual(@as(usize, 8), first.payload.len);

    counting.allocs = 0;
    i = 1;
    while (i < count) : (i += 1) {
        const delivery = try receiver.receive(10_000);
        try testing.expectEqual(i, delivery.id);
        try testing.expectEqual(@as(usize, 8 + i * 4), delivery.payload.len);
    }
    try testing.expectEqual(@as(usize, 0), counting.allocs);
}

/// Every disposition on the wire, as `first..last` pairs.
fn settledRanges(allocator: Allocator, written: []const u8) ![]const [2]u32 {
    var frames = try EmittedFrames.parse(allocator, written);
    defer frames.deinit();

    var ranges: std.ArrayList([2]u32) = .empty;
    errdefer ranges.deinit(allocator);
    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) != perf.descriptor.disposition) continue;
        var decoded = try perf.decode(allocator, body);
        defer decoded.deinit();
        const d = decoded.performative.disposition;
        try testing.expectEqual(perf.Role.receiver, d.role);
        try testing.expect(d.settled);
        try testing.expectEqual(perf.DeliveryState.accepted, d.state.?);
        try ranges.append(allocator, .{ d.first, d.last orelse d.first });
    }
    return ranges.toOwnedSlice(allocator);
}

/// Attach a receiver and feed it `ids` as settled single-frame deliveries.
fn scriptedReceiver(
    allocator: Allocator,
    mem: *MemoryTransport,
    clock: *connection.ManualClock,
    driver: *Driver,
    fixture: *Fixture,
    ids: []const u32,
) !*Receiver {
    const peer = Peer{ .allocator = allocator, .mem = mem };
    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    for (ids) |id| {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = id,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = false,
            .more = false,
        }, "event");
    }

    driver.* = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    fixture.* = try Fixture.init(allocator, mem, clock, driver);
    return openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 32,
    }, 10_000);
}

test "a batch settles a contiguous run in one disposition" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};

    const ids = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var driver: Driver = undefined;
    var fixture: Fixture = undefined;
    const receiver = try scriptedReceiver(allocator, &mem, &clock, &driver, &fixture, &ids);
    defer driver.deinit();
    defer fixture.deinit();

    mem.clearWritten();
    var batch = SettleBatch.init(receiver, .accepted);
    for (ids) |_| try batch.add(try receiver.receive(10_000));
    try testing.expect(batch.pending());
    try batch.flush();
    try testing.expect(!batch.pending());

    const ranges = try settledRanges(allocator, mem.written());
    defer allocator.free(ranges);

    // Settling one at a time put eight frames on the wire to say the same
    // thing. At the default 300-deep prefetch that is 300.
    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual([2]u32{ 0, 7 }, ranges[0]);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
}

test "receiver settle mode second retains ids through timeout until sender acknowledgment" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{ .auto_advance_ms = 1 };
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{
        .attach = .{
            .name = "consumer",
            .handle = 0,
            .role = .sender,
            // The remote sender's preference does not override the mode selected
            // by the local receiver in its Attach.
            .rcv_settle_mode = .first,
            .initial_delivery_count = 0,
        },
    });
    for (10..12) |id| {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = @intCast(id),
            .delivery_tag = "t",
        }, "event");
    }
    mem.starve = true;

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .second,
        .prefetch = 2,
        .max_message_size = 1024,
        .max_buffered_bytes = 2048,
    }, 10_000);
    try testing.expectEqual(perf.ReceiverSettleMode.second, receiver.rcv_settle_mode);

    for (0..2) |_| _ = try fixture.session.pump(10_000);
    _ = try receiver.receive(10_000);
    _ = try receiver.receive(10_000);
    try testing.expect(fixture.session.incoming_deliveries.contains(10));
    try testing.expect(fixture.session.incoming_deliveries.contains(11));

    // A sender-role disposition is not our second-phase acknowledgment until
    // this receiver has actually emitted its first disposition.
    try peer.push(0, .{ .disposition = .{
        .role = .sender,
        .first = 10,
        .last = 11,
        .settled = true,
        .state = .accepted,
    } });
    _ = try fixture.session.pump(clock.millis + 10);
    try testing.expect(fixture.session.incoming_deliveries.contains(10));
    try testing.expect(fixture.session.incoming_deliveries.contains(11));

    mem.clearWritten();
    try receiver.settleRange(10, 11, .accepted);
    try testing.expect(fixture.session.incoming_deliveries.contains(10));
    try testing.expect(fixture.session.incoming_deliveries.contains(11));
    try testing.expectEqual(@as(usize, 2), receiver.pendingSettlementCount());

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const dispositions = try frames.of(allocator, perf.descriptor.disposition);
    defer allocator.free(dispositions);
    try testing.expectEqual(@as(usize, 1), dispositions.len);
    var decoded = try perf.decode(allocator, dispositions[0]);
    defer decoded.deinit();
    try testing.expectEqual(perf.Role.receiver, decoded.performative.disposition.role);
    try testing.expect(!decoded.performative.disposition.settled);

    try testing.expectError(error.Timeout, fixture.session.pump(clock.millis + 5));
    try testing.expect(fixture.session.incoming_deliveries.contains(10));
    try testing.expect(fixture.session.incoming_deliveries.contains(11));

    try peer.push(0, .{ .disposition = .{
        .role = .sender,
        .first = 10,
        .last = 11,
        .settled = false,
        .state = .accepted,
    } });
    _ = try fixture.session.pump(clock.millis + 10);
    try testing.expect(fixture.session.incoming_deliveries.contains(10));
    try testing.expect(fixture.session.incoming_deliveries.contains(11));
    try testing.expectEqual(@as(usize, 2), receiver.pendingSettlementCount());

    try peer.push(0, .{ .disposition = .{
        .role = .sender,
        .first = 10,
        .last = 11,
        .settled = true,
        .state = .accepted,
    } });
    _ = try fixture.session.pump(clock.millis + 10);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
    try testing.expectEqual(@as(usize, 0), receiver.pendingSettlementCount());
}

test "mixed per-transfer receiver settlement modes split disposition ranges" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .rcv_settle_mode = .first,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 40,
        .delivery_tag = "a",
    }, "a");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 41,
        .delivery_tag = "b",
        .rcv_settle_mode = .first,
    }, "b");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 42,
        .delivery_tag = "c",
    }, "c");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .second,
        .prefetch = 3,
        .max_message_size = 8,
        .max_buffered_bytes = 24,
    }, 10_000);

    for (0..3) |_| _ = try receiver.receive(10_000);
    mem.clearWritten();
    try receiver.settleRange(40, 42, .accepted);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const dispositions = try frames.of(allocator, perf.descriptor.disposition);
    defer allocator.free(dispositions);
    try testing.expectEqual(@as(usize, 3), dispositions.len);
    for (dispositions, 0..) |body, i| {
        var decoded = try perf.decode(allocator, body);
        defer decoded.deinit();
        const d = decoded.performative.disposition;
        try testing.expectEqual(@as(u32, 40 + @as(u32, @intCast(i))), d.first);
        try testing.expectEqual(d.first, d.last.?);
        try testing.expectEqual(i == 1, d.settled);
    }
    try testing.expect(fixture.session.incoming_deliveries.contains(40));
    try testing.expect(!fixture.session.incoming_deliveries.contains(41));
    try testing.expect(fixture.session.incoming_deliveries.contains(42));
    try testing.expectEqual(@as(usize, 2), receiver.pendingSettlementCount());

    try peer.push(0, .{ .disposition = .{
        .role = .sender,
        .first = 40,
        .last = 42,
        .settled = true,
        .state = .accepted,
    } });
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
}

test "an initially sender-settled delivery ignores mode on its continuations" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 50,
        .delivery_tag = "t",
        .settled = true,
        .rcv_settle_mode = .second,
        .more = true,
    }, "ev");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 50,
        .rcv_settle_mode = .second,
    }, "ent");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .first,
        .prefetch = 1,
        .max_message_size = 8,
        .max_buffered_bytes = 8,
    }, 10_000);

    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("event", delivery.payload);
    try testing.expect(delivery.settled);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
}

test "a sender-settled final continuation ignores receiver settle mode" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 51,
        .delivery_tag = "t",
        .more = true,
        .rcv_settle_mode = .first,
    }, "ev");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 51,
        .settled = true,
        .rcv_settle_mode = .second,
    }, "ent");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .first,
        .prefetch = 1,
        .max_message_size = 8,
        .max_buffered_bytes = 8,
    }, 10_000);

    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("event", delivery.payload);
    try testing.expect(delivery.settled);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
}

test "an unsettled initial transfer cannot upgrade a mode-first receiver" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 50,
        .delivery_tag = "t",
        .rcv_settle_mode = .second,
    }, "event");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .first,
        .prefetch = 1,
        .max_message_size = 8,
        .max_buffered_bytes = 8,
    }, 10_000);

    try testing.expectError(error.MalformedFrame, fixture.session.pump(10_000));
    try testing.expect(receiver.poisoned);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
}

test "an unsettled continuation cannot upgrade a mode-first receiver" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 52,
        .delivery_tag = "t",
        .more = true,
        .rcv_settle_mode = .first,
    }, "ev");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 52,
        .rcv_settle_mode = .second,
    }, "ent");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .first,
        .prefetch = 1,
        .max_message_size = 8,
        .max_buffered_bytes = 8,
    }, 10_000);

    try testing.expectError(error.MalformedFrame, receiver.receive(10_000));
    try testing.expect(receiver.poisoned);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
}

test "failed second-mode disposition terminalizes and releases active ids" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .rcv_settle_mode = .second,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 20,
        .delivery_tag = "t",
    }, "event");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .second,
        .prefetch = 1,
        .max_message_size = 1024,
        .max_buffered_bytes = 1024,
    }, 10_000);

    _ = try receiver.receive(10_000);
    try testing.expect(fixture.session.incoming_deliveries.contains(20));
    mem.fail_write = true;
    try testing.expectError(error.WriteFailed, receiver.settleRange(20, 20, .accepted));
    try testing.expect(fixture.session.ended);
    try testing.expect(receiver.poisoned);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
    try testing.expectEqual(@as(usize, 0), receiver.pendingSettlementCount());
}

test "deinit releases ids awaiting second-mode settlement acknowledgment" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{ .auto_advance_ms = 1 };
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .rcv_settle_mode = .second,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 30,
        .delivery_tag = "t",
    }, "event");
    mem.starve = true;

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .second,
        .prefetch = 1,
        .max_message_size = 1024,
        .max_buffered_bytes = 1024,
    }, 10_000);

    const delivery = try receiver.receive(10_000);
    try receiver.accept(delivery);
    try testing.expect(fixture.session.incoming_deliveries.contains(30));
    fixture.session.closeReceiver(receiver, clock.millis + 5);
    try testing.expectEqual(@as(usize, 0), fixture.session.receivers.items.len);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
}

test "settlement slots bound withheld mode-second acknowledgments and replenish on release" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    for (0..4) |id| {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = @intCast(id),
            .delivery_tag = "t",
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .rcv_settle_mode = .second,
        .prefetch = 0,
        .max_message_size = 8,
        .max_buffered_bytes = 32,
        .max_unsettled_deliveries = 4,
    }, 10_000);
    try receiver.issueCredit(100);
    try testing.expectEqual(@as(u32, 4), receiver.credit);

    for (0..4) |_| {
        const delivery = try receiver.receive(10_000);
        try receiver.accept(delivery);
    }
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
    try testing.expectEqual(@as(usize, 4), receiver.unsettled_ids.items.len);
    try testing.expectEqual(@as(usize, 4), receiver.pendingSettlementCount());

    for (0..20) |cycle| {
        const released: u32 = @intCast(cycle * 2);
        try peer.push(0, .{ .disposition = .{
            .role = .sender,
            .first = released,
            .last = released + 1,
            .settled = true,
            .state = .accepted,
        } });
        _ = try fixture.session.pump(10_000);
        try testing.expectEqual(@as(u32, 2), receiver.credit);
        try testing.expectEqual(@as(usize, 2), receiver.unsettled_ids.items.len);

        const next: u32 = @intCast(4 + cycle * 2);
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = next,
            .delivery_tag = "t",
        }, "event");
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = next + 1,
            .delivery_tag = "t",
        }, "event");
        for (0..2) |_| {
            const delivery = try receiver.receive(10_000);
            try receiver.accept(delivery);
        }
        try testing.expectEqual(@as(u32, 0), receiver.credit);
        try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
        try testing.expectEqual(@as(usize, 4), receiver.unsettled_ids.items.len);
        try testing.expectEqual(@as(usize, 4), receiver.pendingSettlementCount());
        try testing.expect(receiver.unsettled_ids.capacity <= 4);
    }

    // A peer that ignores the withheld credit cannot grow the bounded id set.
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 44,
        .delivery_tag = "t",
    }, "event");
    try testing.expectError(error.SettlementLimitExceeded, fixture.session.pump(10_000));
    try testing.expect(receiver.poisoned);
    try testing.expectEqual(@as(usize, 0), receiver.unsettled_ids.items.len);
    try testing.expectEqual(@as(usize, 0), fixture.session.incoming_deliveries.count());
}

test "a batch does not settle across a gap in delivery ids" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};

    // Delivery ids are the session's, not the link's, so anything else on the
    // session — a CBS link, `$management`, another partition — takes ids out
    // of this receiver's run. Settling 3..9 as one range would settle two
    // deliveries this receiver was never handed.
    const ids = [_]u32{ 3, 4, 5, 8, 9, 11 };
    var driver: Driver = undefined;
    var fixture: Fixture = undefined;
    const receiver = try scriptedReceiver(allocator, &mem, &clock, &driver, &fixture, &ids);
    defer driver.deinit();
    defer fixture.deinit();

    mem.clearWritten();
    var batch = SettleBatch.init(receiver, .accepted);
    for (ids) |_| try batch.add(try receiver.receive(10_000));
    try batch.flush();

    const ranges = try settledRanges(allocator, mem.written());
    defer allocator.free(ranges);

    try testing.expectEqual(@as(usize, 3), ranges.len);
    try testing.expectEqual([2]u32{ 3, 5 }, ranges[0]);
    try testing.expectEqual([2]u32{ 8, 9 }, ranges[1]);
    try testing.expectEqual([2]u32{ 11, 11 }, ranges[2]);
}

test "a batch does not settle across the delivery id wrap" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};

    const max = std.math.maxInt(u32);
    const ids = [_]u32{ max - 2, max - 1, max, 0, 1 };
    var driver: Driver = undefined;
    var fixture: Fixture = undefined;
    const receiver = try scriptedReceiver(allocator, &mem, &clock, &driver, &fixture, &ids);
    defer driver.deinit();
    defer fixture.deinit();

    mem.clearWritten();
    var batch = SettleBatch.init(receiver, .accepted);
    for (ids) |_| try batch.add(try receiver.receive(10_000));
    try batch.flush();

    const ranges = try settledRanges(allocator, mem.written());
    defer allocator.free(ranges);

    // Treating these five as one run would put `first = 0xfffffffd,
    // last = 1` on the wire: legal under serial-number arithmetic, and
    // unreadable to every peer that just compares the two.
    try testing.expectEqual(@as(usize, 2), ranges.len);
    try testing.expectEqual([2]u32{ max - 2, max }, ranges[0]);
    try testing.expectEqual([2]u32{ 0, 1 }, ranges[1]);
    for (ranges) |r| try testing.expect(r[0] <= r[1]);
}

test "flushing an empty batch says nothing" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};

    var driver: Driver = undefined;
    var fixture: Fixture = undefined;
    const receiver = try scriptedReceiver(allocator, &mem, &clock, &driver, &fixture, &.{});
    defer driver.deinit();
    defer fixture.deinit();

    mem.clearWritten();
    var batch = SettleBatch.init(receiver, .accepted);
    try testing.expect(!batch.pending());
    try batch.flush();
    try batch.flush();

    const ranges = try settledRanges(allocator, mem.written());
    defer allocator.free(ranges);
    try testing.expectEqual(@as(usize, 0), ranges.len);
}

test "a prefetching receiver replenishes credit rather than stalling" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    const prefetch: u32 = 4;
    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    // More deliveries than the prefetch window, so credit must be topped up.
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = prefetch,
        .max_buffered_bytes = null,
    }, 10_000);

    mem.clearWritten();
    i = 0;
    while (i < 12) : (i += 1) {
        const delivery = try receiver.receive(10_000);
        try testing.expectEqualStrings("event", delivery.payload);
        try testing.expectEqual(i, delivery.id);
    }

    // Credit was re-issued as flows; without them the peer would have stalled.
    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expect(flows.len > 1);

    for (flows) |body| {
        var decoded = try perf.decode(allocator, body);
        defer decoded.deinit();
        const f = decoded.performative.flow;
        try testing.expectEqual(receiver.handle, f.handle.?);
        try testing.expectEqual(prefetch, f.link_credit.?);
    }
    try testing.expect(receiver.credit > 0);
}

test "the attach flow issues the requested prefetch credit" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh",
        .prefetch = 250,
        .max_buffered_bytes = null,
    }, 10_000);
    try testing.expectEqual(@as(u32, 250), receiver.credit);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);

    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 250), decoded.performative.flow.link_credit.?);
}

const CreditFlowPath = enum {
    issue,
    deferred_replenish,
    prefetch_replenish,
};

const CreditFlowFailure = enum {
    encode_oom,
    pre_write,
    partial_write,
    flush,
};

fn invokeCreditFlow(receiver: *Receiver, path: CreditFlowPath) LinkError!void {
    switch (path) {
        .issue => try receiver.issueCredit(4),
        .deferred_replenish, .prefetch_replenish => try receiver.replenish(),
    }
}

fn creditFlowFailureIsTransactional(path: CreditFlowPath, failure: CreditFlowFailure) !void {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh",
        .prefetch = 0,
        .max_buffered_bytes = null,
    }, 10_000);

    switch (path) {
        .issue => {},
        .deferred_replenish => receiver.deferred_credit = 4,
        .prefetch_replenish => receiver.prefetch = 4,
    }
    // Exercise debt as part of the transaction, and prove the Flow advertises
    // the unchanged delivery-count paired with the newly committed credit.
    receiver.overrun = 1;
    receiver.delivery_count = 7;
    const before = receiver.creditState();
    const before_limit = receiver.delivery_limit;
    mem.clearWritten();

    var switching = SwitchAllocator{ .child = allocator };
    const writes_before = mem.write_count;
    switch (failure) {
        .encode_oom => {
            driver.allocator = switching.allocator();
            switching.failing = true;
        },
        .pre_write => mem.fail_write = true,
        .partial_write => mem.fail_write_after = writes_before + 1,
        .flush => mem.fail_flush = true,
    }

    const result = invokeCreditFlow(receiver, path);
    switching.failing = false;
    driver.allocator = allocator;
    mem.fail_write = false;
    mem.fail_write_after = null;
    mem.fail_flush = false;

    switch (failure) {
        .encode_oom => try testing.expectError(error.OutOfMemory, result),
        .pre_write, .partial_write, .flush => try testing.expectError(error.WriteFailed, result),
    }

    try testing.expectEqual(before.credit, receiver.credit);
    try testing.expectEqual(before.deferred_credit, receiver.deferred_credit);
    try testing.expectEqual(before.overrun, receiver.overrun);
    try testing.expectEqual(before_limit, receiver.delivery_limit);
    try testing.expectEqual(@as(usize, 0), mem.written().len);
    try testing.expectEqual(@as(usize, 0), mem.pending.items.len);

    if (failure == .encode_oom) {
        try testing.expectEqual(connection.State.opened, driver.state);
        try testing.expect(!mem.closed);
        try invokeCreditFlow(receiver, path);

        try testing.expectEqual(@as(u32, 3), receiver.credit);
        try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
        try testing.expectEqual(@as(u32, 0), receiver.overrun);
        try testing.expectEqual(@as(u32, 10), receiver.delivery_limit);

        var frames = try EmittedFrames.parse(allocator, mem.written());
        defer frames.deinit();
        const flows = try frames.of(allocator, perf.descriptor.flow);
        defer allocator.free(flows);
        try testing.expectEqual(@as(usize, 1), flows.len);
        var decoded = try perf.decode(allocator, flows[0]);
        defer decoded.deinit();
        const flow = decoded.performative.flow;
        try testing.expectEqual(receiver.handle, flow.handle.?);
        try testing.expectEqual(receiver.credit, flow.link_credit.?);
        try testing.expectEqual(receiver.delivery_count, flow.delivery_count.?);
        return;
    }

    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    const successful_writes: usize = switch (failure) {
        .pre_write => 0,
        .partial_write => 1,
        .flush => 2,
        .encode_oom => unreachable,
    };
    try testing.expectEqual(
        writes_before + successful_writes,
        mem.write_count,
    );
    try testing.expectError(error.ConnectionClosed, invokeCreditFlow(receiver, path));
    try testing.expectEqual(before.credit, receiver.credit);
    try testing.expectEqual(before.deferred_credit, receiver.deferred_credit);
    try testing.expectEqual(before.overrun, receiver.overrun);
    try testing.expectEqual(before_limit, receiver.delivery_limit);
    try testing.expectEqual(@as(usize, 0), mem.written().len);
}

test "issueCredit commits only a completely emitted Flow" {
    inline for (std.meta.tags(CreditFlowFailure)) |failure| {
        try creditFlowFailureIsTransactional(.issue, failure);
    }
}

test "deferred replenishment commits only a completely emitted Flow" {
    inline for (std.meta.tags(CreditFlowFailure)) |failure| {
        try creditFlowFailureIsTransactional(.deferred_replenish, failure);
    }
}

test "prefetch replenishment commits only a completely emitted Flow" {
    inline for (std.meta.tags(CreditFlowFailure)) |failure| {
        try creditFlowFailureIsTransactional(.prefetch_replenish, failure);
    }
}

fn abortedReplacementFlowFailureIsTransactional(failure: CreditFlowFailure) !void {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = std.math.maxInt(u32),
        .aborted = true,
    }, "");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    receiver.delivery_count = std.math.maxInt(u32);
    receiver.delivery_limit = receiver.delivery_count;
    try receiver.issueCredit(1);
    try testing.expectEqual(@as(u32, 0), receiver.delivery_limit);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 1), receiver.deferred_credit);
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "replacement",
        .settled = true,
    }, "event");

    const before = receiver.creditState();
    const before_limit = receiver.delivery_limit;
    mem.clearWritten();
    const writes_before = mem.write_count;
    var switching = SwitchAllocator{ .child = allocator };
    switch (failure) {
        .encode_oom => {
            driver.allocator = switching.allocator();
            switching.failing = true;
        },
        .pre_write => mem.fail_write = true,
        .partial_write => mem.fail_write_after = writes_before + 1,
        .flush => mem.fail_flush = true,
    }

    const result = receiver.receive(10_000);
    switching.failing = false;
    driver.allocator = allocator;
    mem.fail_write = false;
    mem.fail_write_after = null;
    mem.fail_flush = false;

    switch (failure) {
        .encode_oom => try testing.expectError(error.OutOfMemory, result),
        .pre_write, .partial_write, .flush => try testing.expectError(error.WriteFailed, result),
    }
    try testing.expectEqual(before.credit, receiver.credit);
    try testing.expectEqual(before.deferred_credit, receiver.deferred_credit);
    try testing.expectEqual(before.overrun, receiver.overrun);
    try testing.expectEqual(before_limit, receiver.delivery_limit);
    try testing.expectEqual(@as(usize, 0), mem.written().len);
    try testing.expectEqual(@as(usize, 0), mem.pending.items.len);

    if (failure == .encode_oom) {
        try testing.expectEqual(connection.State.opened, driver.state);
        const delivery = try receiver.receive(10_000);
        try testing.expectEqualStrings("event", delivery.payload);
        try testing.expectEqual(@as(u32, 0), receiver.credit);
        try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
        try testing.expectEqual(@as(u32, 1), receiver.delivery_limit);
        try testing.expectEqual(@as(u32, 1), receiver.delivery_count);

        var frames = try EmittedFrames.parse(allocator, mem.written());
        defer frames.deinit();
        const flows = try frames.of(allocator, perf.descriptor.flow);
        defer allocator.free(flows);
        try testing.expectEqual(@as(usize, 1), flows.len);
        var decoded = try perf.decode(allocator, flows[0]);
        defer decoded.deinit();
        try testing.expectEqual(@as(u32, 0), decoded.performative.flow.delivery_count.?);
        try testing.expectEqual(@as(u32, 1), decoded.performative.flow.link_credit.?);
        return;
    }

    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    try testing.expectError(error.ConnectionClosed, receiver.receive(10_000));
    try testing.expectEqual(before.credit, receiver.credit);
    try testing.expectEqual(before.deferred_credit, receiver.deferred_credit);
    try testing.expectEqual(before_limit, receiver.delivery_limit);
}

test "aborted replacement Flow is transactional across failure and wrap" {
    inline for (std.meta.tags(CreditFlowFailure)) |failure| {
        try abortedReplacementFlowFailureIsTransactional(failure);
    }
}

test "drain state commits only after its Flow is emitted" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh",
        .prefetch = 0,
        .max_buffered_bytes = null,
    }, 10_000);
    receiver.credit = 4;
    receiver.delivery_count = 7;
    receiver.delivery_limit = 11;
    mem.clearWritten();

    var switching = SwitchAllocator{ .child = allocator, .failing = true };
    driver.allocator = switching.allocator();
    try testing.expectError(error.OutOfMemory, receiver.drainCredit(10_000));
    switching.failing = false;
    driver.allocator = allocator;

    try testing.expect(!receiver.drain);
    try testing.expectEqual(@as(u32, 4), receiver.credit);
    try testing.expectEqual(@as(u32, 7), receiver.delivery_count);
    try testing.expectEqual(connection.State.opened, driver.state);
    try testing.expectEqual(@as(usize, 0), mem.written().len);

    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 11,
        .link_credit = 0,
        .drain = true,
    } });
    try receiver.drainCredit(10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    const flow = decoded.performative.flow;
    try testing.expectEqual(@as(?u32, 4), flow.link_credit);
    try testing.expectEqual(@as(?u32, 7), flow.delivery_count);
    try testing.expect(flow.drain);
    try testing.expect(!receiver.drain);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 11), receiver.delivery_count);
}

test "a detach surfaces the condition that stole the link" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .detach = .{
        .handle = 0,
        .closed = true,
        .err = .{
            .condition = "amqp:link:stolen",
            .description = "New receiver with higher epoch of '1' is created.",
        },
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh",
        .prefetch = 0,
    }, 10_000);

    try testing.expectError(error.LinkDetached, receiver.receive(10_000));
    try testing.expect(!receiver.attached);
    try testing.expectEqualStrings("amqp:link:stolen", receiver.detach_error.?.condition);
}

test "credit from the peer is rebased onto our delivery count" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "producer",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    // The peer grants 10 from a delivery count of 0. By the time we apply it we
    // have already sent 3, so only 7 remain usable.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 10,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    sender.delivery_count = 3;
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 7), sender.credit);
}

test "a message round-trips from the sender's encoding to the receiver's payload" {
    const allocator = testing.allocator;
    const app_props = [_]uamqp.MapEntry{
        .{ .key = .{ .string = "operation" }, .value = .{ .string = "put-token" } },
    };
    const msg = message.Message{
        .properties = .{ .to = "$cbs", .message_id = .{ .string = "req-1" } },
        .application_properties = &app_props,
        .body = .{ .value = .{ .string = "token" } },
    };

    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "cbs-sender",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 1,
    } });
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "cbs-sender",
        .target_address = "$cbs",
    }, 10_000);

    mem.clearWritten();
    try sender.send(msg, 10_000);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    try testing.expectEqual(@as(usize, 1), frames.bodies.items.len);

    const body = frames.bodies.items[0];
    const consumed = try performativeLength(allocator, body);
    var decoded = try message.decode(allocator, body[consumed..]);
    defer decoded.deinit();

    try testing.expectEqualStrings("$cbs", decoded.message.properties.to.?);
    try testing.expectEqualStrings("req-1", decoded.message.properties.message_id.?.string);
    try testing.expectEqualStrings("put-token", decoded.message.application_properties.?[0].value.string);
    try testing.expectEqualStrings("token", decoded.message.body.value.string);
}

test "a session routes transfers by the peer's handle, not our own" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    // Two receivers on one session, as a client holding both a CBS link and an
    // events link has. The peer numbers its handles independently of ours, so
    // here they cross over: our handle 0 is the peer's 7, and our 1 is its 0.
    try peer.push(0, .{ .attach = .{
        .name = "cbs-receiver",
        .handle = 7,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .attach = .{
        .name = "events-receiver",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    // Addressed to the peer's handle 0, which is the events link. A lookup that
    // also matched our own handles would hand this to the CBS receiver, whose
    // local handle happens to be 0.
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "e",
        .message_format = 0,
        .settled = true,
        .more = false,
    }, "event-body");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const cbs = try openReceiver(&fixture.session, .{
        .name = "cbs-receiver",
        .source_address = "$cbs",
        .prefetch = 0,
    }, 10_000);
    const events = try openReceiver(&fixture.session, .{
        .name = "events-receiver",
        .source_address = "partition/0",
        .prefetch = 0,
    }, 10_000);

    try testing.expectEqual(@as(u32, 0), cbs.handle);
    try testing.expectEqual(@as(u32, 7), cbs.remote_handle);
    try testing.expectEqual(@as(u32, 1), events.handle);
    try testing.expectEqual(@as(u32, 0), events.remote_handle);

    const delivery = try events.receive(10_000);
    try testing.expectEqualStrings("event-body", delivery.payload);
    try testing.expectEqual(@as(usize, 0), cbs.ready.items.len);
    try testing.expectEqual(@as(usize, 0), cbs.partial.items.len);
}

test "draining a receiver waits for the sender to consume the outstanding credit" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "drainable",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    // One message, then a drain response advancing the delivery count over the
    // four credits left unused.
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "d",
        .message_format = 0,
        .settled = true,
        .more = false,
    }, "last");
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 5,
        .drain = true,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "drainable",
        .source_address = "partition/0",
        .prefetch = 5,
        .max_buffered_bytes = null,
    }, 10_000);
    try testing.expectEqual(@as(u32, 5), receiver.credit);

    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("last", delivery.payload);

    try receiver.drainCredit(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expect(!receiver.drain);

    mem.clearWritten();
    try receiver.issueCredit(1);
    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expect(!decoded.performative.flow.drain);
}

test "drain acknowledgement timeout terminally detaches manual receiver" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "drainable",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "drainable",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);
    try receiver.issueCredit(1);

    mem.clearWritten();
    mem.starve = true;
    clock.auto_advance_ms = 1;
    try testing.expectError(error.Timeout, receiver.drainCredit(clock.millis));
    try testing.expect(!receiver.drain);
    try testing.expect(receiver.poisoned);
    try testing.expect(!receiver.attached);
    try testing.expect(receiver.detach_sent);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
    try testing.expectEqual(connection.State.opened, driver.state);
    try testing.expect(!fixture.session.ended);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    try testing.expectEqual(@as(usize, 2), frames.bodies.items.len);
    try testing.expectEqual(
        perf.descriptor.flow,
        perf.peekDescriptor(frames.bodies.items[0]).?,
    );
    try testing.expectEqual(
        perf.descriptor.detach,
        perf.peekDescriptor(frames.bodies.items[1]).?,
    );
    var flow = try perf.decode(allocator, frames.bodies.items[0]);
    defer flow.deinit();
    try testing.expect(flow.performative.flow.drain);

    const written = mem.written().len;
    try testing.expectError(error.LinkDetached, receiver.issueCredit(1));
    try testing.expectEqual(written, mem.written().len);

    // A late aborted Transfer from a peer that processed the old drain is
    // ignored as a detached-link straggler and cannot recreate demand.
    mem.starve = false;
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .aborted = true,
    }, "");
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
    try testing.expectEqual(written, mem.written().len);
}

test "omitted drain credit derives remaining across delivery-count wrap" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "drainable",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "drainable",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_buffered_bytes = null,
    }, 10_000);
    receiver.delivery_count = std.math.maxInt(u32) - 1;
    receiver.credit = 4;
    receiver.delivery_limit = 2;
    receiver.drain = true;

    // The previous delivery limit wraps to 2. Advancing to 0 consumes two
    // credits and leaves two, even though link-credit is omitted.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .drain = true,
    } });
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 2), receiver.credit);

    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 2,
        .drain = true,
    } });
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 2), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
}

test "closing a sender detaches it and drops it from the session" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock = connection.ManualClock{};
    var conn = try Driver.init(allocator, mem.transport(), clock.clock(), harness.driver_options);
    defer conn.deinit();

    const peer = harness.Peer{ .allocator = allocator, .mem = &mem };
    try harness.scriptHandshake(peer, 512);
    try peer.push(0, .{ .attach = .{
        .name = "s",
        .handle = 0,
        .role = .receiver,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .detach = .{ .handle = 0, .closed = true } });

    var fixture = try harness.Fixture.init(allocator, &mem, &clock, &conn);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "s",
        .target_address = "hub",
    }, 10_000);
    try testing.expectEqual(@as(usize, 1), fixture.session.senders.items.len);

    mem.clearWritten();
    fixture.session.closeSender(sender, 10_000);

    // Left in the list, the session would keep pumping frames at a link
    // nobody can reach and `deinit` would free it a second time.
    try testing.expectEqual(@as(usize, 0), fixture.session.senders.items.len);

    var frames = try harness.EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    var detaches: usize = 0;
    for (frames.bodies.items) |body| {
        if (perf.peekDescriptor(body) == perf.descriptor.detach) detaches += 1;
    }
    try testing.expectEqual(@as(usize, 1), detaches);
}

test "closing a receiver the peer already detached sends no detach" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock = connection.ManualClock{};
    var conn = try Driver.init(allocator, mem.transport(), clock.clock(), harness.driver_options);
    defer conn.deinit();

    const peer = harness.Peer{ .allocator = allocator, .mem = &mem };
    try harness.scriptHandshake(peer, 512);
    try peer.push(0, .{ .attach = .{
        .name = "r",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.push(0, .{ .detach = .{
        .handle = 0,
        .closed = true,
        .err = .{ .condition = "amqp:link:stolen", .description = "taken" },
    } });

    var fixture = try harness.Fixture.init(allocator, &mem, &clock, &conn);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "r",
        .source_address = "hub/ConsumerGroups/$default/Partitions/0",
    }, 10_000);

    // Drain the peer's detach so the link knows it is gone.
    try testing.expectError(error.LinkDetached, receiver.receive(10_000));
    try testing.expectEqualStrings("amqp:link:stolen", receiver.detach_error.?.condition);

    mem.clearWritten();
    fixture.session.closeReceiver(receiver, 10_000);
    try testing.expectEqual(@as(usize, 0), fixture.session.receivers.items.len);

    var frames = try harness.EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    for (frames.bodies.items) |body| {
        try testing.expect(perf.peekDescriptor(body) != perf.descriptor.detach);
    }
}

test "a pumped transfer allocates only what it hands the caller" {
    var counting = CountingAllocator{ .child = testing.allocator };
    const allocator = counting.allocator();

    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    const count = 32;
    const body = "0123456789" ** 20;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "tag!",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, body);
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        // Comfortably more than `count`, so no `flow` is emitted to top credit
        // back up inside the window measured below.
        .prefetch = 256,
    }, 10_000);

    // Pump one transfer to size the frame buffer and the queue, so the window
    // below measures the steady state rather than one-off growth.
    _ = try fixture.session.pump(10_000);
    try receiver.ready.ensureTotalCapacity(allocator, count);

    counting.allocs = 0;
    var pumped: usize = 1;
    while (pumped < count) : (pumped += 1) _ = try fixture.session.pump(10_000);
    const spent = counting.allocs;

    // Two per transfer, and both are what the caller is handed: the payload
    // and the delivery tag. Nothing is allocated to decode the frame.
    //
    // It was six. The frame body was allocated and freed per frame rather than
    // read into a buffer the driver keeps; the transfer performative was
    // decoded a second time — into a throwaway arena, discarding everything
    // but the length — purely to find where the payload started, which the
    // first decode already reported as `bytes_consumed`; and the performative
    // arena was built per frame rather than reset.
    try testing.expectEqual(@as(usize, 2 * (count - 1)), spent);
}

test "what a session keeps from a performative outlives the frames after it" {
    // The receive path decodes every frame into one arena it resets, so a
    // performative's slices are gone the moment the next frame arrives. That
    // is only sound because everything the session retains is duped out first.
    // A field that borrowed instead would read as intact here and as garbage
    // in production, so drive real frames over it rather than trusting review.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    const condition = "amqp:link:message-size-exceeded";
    const description = "The received message is larger than the maximum allowed size.";

    try scriptSenderAttach(peer, 5);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 0,
        .last = 0,
        .settled = true,
        .state = .{ .rejected = .{ .condition = condition, .description = description } },
    } });

    // Frames behind the rejection, each decoding far more than the rejection
    // did, so the arena is not merely reset but written clean past wherever
    // the condition sat. Padding it lightly is not enough: an arena reset
    // bumps from the start of a retained page, so a later frame that decodes
    // to less than the earlier one leaves the tail of the earlier one intact
    // and a borrowed slice reads as correct by luck. Each entry is sized to
    // fill the harness's 512-byte frame, and the frame is repeated.
    var pad: [4]uamqp.MapEntry = undefined;
    for (&pad) |*entry| entry.* = .{
        .key = .{ .symbol = "com.microsoft:padding" },
        .value = .{ .string = "y" ** 64 },
    };

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try peer.push(0, .{ .flow = .{
            .next_incoming_id = 0,
            .incoming_window = 1000 + i,
            .next_outgoing_id = 1,
            .outgoing_window = 1000,
            .handle = 0,
            .delivery_count = 0,
            .link_credit = 5,
            .properties = &pad,
        } });
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
    }, 10_000);

    try testing.expectError(error.SendRejected, sender.sendBytes("payload", 10_000));
    // Pump a fixed count. `mem.inbound_pos` is where the *transport* has been
    // read to, and the driver slurps up to 16 KiB into `in_buf` ahead of
    // parsing, so draining on it would exit before parsing a single one of
    // these frames and the test would pass without testing anything.
    var pumped: usize = 0;
    while (pumped < 16) : (pumped += 1) _ = try fixture.session.pump(10_000);

    try testing.expectEqualStrings(condition, sender.rejection.?.condition);
    try testing.expectEqualStrings(description, sender.rejection.?.description.?);
}

test "a queued single-frame delivery outlives the frames after it" {
    // Companion to the test above, for the other thing the receive path keeps
    // out of a performative: `acceptTransfer` dupes the tag off the transfer
    // and the payload out of the frame body, then queues both. The multi-frame
    // path is covered incidentally elsewhere, because reassembly pumps more
    // frames before the delivery is read; the single-frame fast path is not,
    // so a borrow there would survive every other test in this file.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    const tag = "\x00\x00\x00\x07";
    const payload = "the body of a delivery nobody reads until later";

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 7,
        .delivery_tag = tag,
        .message_format = 0,
        .settled = false,
        .more = false,
    }, payload);

    // As in the test above: each entry fills the harness's 512-byte frame, and
    // the frame is repeated, so the arena is written clean past wherever the
    // transfer's tag landed rather than merely reset over it.
    var pad: [4]uamqp.MapEntry = undefined;
    for (&pad) |*entry| entry.* = .{
        .key = .{ .symbol = "com.microsoft:padding" },
        .value = .{ .string = "y" ** 64 },
    };
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try peer.push(0, .{ .flow = .{
            .next_incoming_id = 0,
            .incoming_window = 1000 + i,
            .next_outgoing_id = 1,
            .outgoing_window = 1000,
            .handle = 0,
            .delivery_count = 0,
            .link_credit = 5,
            .properties = &pad,
        } });
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
    }, 10_000);

    // Queue the delivery, then bury it. `receive` would stop at the first one
    // ready, so pump past it explicitly. A fixed count, not a drain on
    // `mem.inbound_pos` — see the note in the test above.
    while (receiver.ready.items.len == receiver.ready_head) _ = try fixture.session.pump(10_000);
    var pumped: usize = 0;
    while (pumped < 16) : (pumped += 1) _ = try fixture.session.pump(10_000);

    const delivery = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 7), delivery.id);
    try testing.expectEqualSlices(u8, tag, delivery.tag);
    try testing.expectEqualStrings(payload, delivery.payload);
}

test "one hostile frame does not pin an oversized decode arena" {
    // The receive arena is reused, so whatever it grows to it keeps. A frame
    // is bounded by `max_frame_size`, but the *decode* is not bounded by the
    // frame: a map header costs two bytes and buys 48 of arena per entry, so
    // a legal frame decodes to many times its own size. Retaining outright
    // would pin that peak for the life of the connection.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    const frame_size = 65536;
    try scriptHandshake(peer, frame_size);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    // ~5 encoded bytes each, 48 of `MapEntry` each once decoded.
    const bloat = 3000;
    const entries = try allocator.alloc(uamqp.MapEntry, bloat);
    defer allocator.free(entries);
    for (entries) |*entry| entry.* = .{
        .key = .{ .symbol = "p" },
        .value = .{ .null = {} },
    };

    var opts = test_options;
    opts.max_frame_size = frame_size;

    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 5,
        .properties = entries,
    } });
    // One ordinary frame behind it, which is what releases the outlier.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1001,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 5,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), opts);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    _ = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    const peak = driver.perf_arena.?.queryCapacity();
    _ = try fixture.session.pump(10_000);
    const retained = driver.perf_arena.?.queryCapacity();

    // Assert the size, not a symptom: the peak really did exceed the cap, and
    // the next frame really did give it back.
    try testing.expect(peak > Driver.perf_arena_limit);
    try testing.expect(retained <= Driver.perf_arena_limit);
}

test "a peer that overruns its credit is absorbed and charged for it" {
    // #327: the receive path enqueued unconditionally and decremented credit
    // with a saturating `-|= 1`, so a peer past its grant was buffered and the
    // overrun left no trace -- credit simply sat at zero.
    //
    // A peer can legitimately have transfers in flight when credit runs out,
    // so those are still accepted. What changes is that they are remembered
    // and charged against the next grant, rather than forgiven.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    // Two more than the two credits that will be granted.
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    // Prefetch off, so credit moves only when this test moves it and nothing
    // is topped up behind the assertions.
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_buffered_bytes = null,
    }, 10_000);
    try receiver.issueCredit(2);

    i = 0;
    while (i < 4) : (i += 1) {
        const delivery = try receiver.receive(10_000);
        try testing.expectEqualStrings("event", delivery.payload);
    }

    // All four accepted, and the two beyond the grant are recorded as debt
    // rather than lost to saturation.
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 2), receiver.overrun);

    mem.clearWritten();
    try receiver.issueCredit(3);

    // Three asked for, two owed, so one is actually granted -- and the peer is
    // told one, not three.
    try testing.expectEqual(@as(u32, 1), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.overrun);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 1), decoded.performative.flow.link_credit.?);
}

test "a peer that keeps overrunning is detached with transfer-limit-exceeded" {
    // The backstop. Charging the overrun slows a peer that is listening; a
    // peer that ignores credit outright is not slowed by anything, and #327
    // was filed because nothing bounded what it could make this endpoint
    // allocate. `LinkError.CreditExceeded` was declared for this and had never
    // been raised anywhere in the package.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    // Far past the one credit granted and the overrun allowance of four.
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_overrun = 4,
    }, 10_000);
    try receiver.issueCredit(1);

    mem.clearWritten();
    // One within credit, then four absorbed as overrun. The sixth is the one
    // that would take the peer past the allowance, and it is refused before
    // anything is duped for it.
    i = 0;
    while (i < 5) : (i += 1) {
        _ = try receiver.receive(10_000);
    }
    try testing.expectEqual(@as(u32, 4), receiver.overrun);
    try testing.expectError(error.CreditExceeded, receiver.receive(10_000));
    try testing.expect(!receiver.attached);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const detaches = try frames.of(allocator, perf.descriptor.detach);
    defer allocator.free(detaches);
    try testing.expectEqual(@as(usize, 1), detaches.len);
    var decoded = try perf.decode(allocator, detaches[0]);
    defer decoded.deinit();
    const d = decoded.performative.detach;
    try testing.expect(d.closed);
    try testing.expectEqualStrings("amqp:link:transfer-limit-exceeded", d.err.?.condition);
}

test "a prefetching receiver charges an overrun against its next top-up" {
    // The default receiver replenishes rather than being credited by hand, so
    // this is where "stop granting further credit" actually has to happen.
    //
    // The overrun is built by pumping the session directly instead of calling
    // `receive`, which is not contrived: it is what an app pumping the session
    // itself does, and what happens whenever two links share one session and
    // are consumed in turn. `replenish` only runs inside `receive`, so credit
    // is not topped up between arrivals.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    const prefetch: u32 = 2;
    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 7) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = prefetch,
        .max_buffered_bytes = null,
    }, 10_000);

    while (receiver.ready.items.len < 6) _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 4), receiver.overrun);

    // Two top-ups' worth of debt, so two `receive` calls put nothing on the
    // wire: the charge cancels the whole window each time.
    mem.clearWritten();
    _ = try receiver.receive(10_000);
    _ = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.overrun);

    var silent = try EmittedFrames.parse(allocator, mem.written());
    defer silent.deinit();
    const none = try silent.of(allocator, perf.descriptor.flow);
    defer allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // Positive credit is deferred while a ready backlog exists: there is no
    // reason to risk a flow write hiding events already in hand. Drain the
    // other four, then the next receive replenishes before pumping delivery 6.
    i = 0;
    while (i < 4) : (i += 1) _ = try receiver.receive(10_000);
    const next = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 6), next.id);
    try testing.expectEqual(@as(u32, 1), receiver.credit);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expectEqual(prefetch, decoded.performative.flow.link_credit.?);
}

test "the overrun bound is on by default, not only when asked for" {
    // The bound above is set explicitly by its test, so it would pass just as
    // well if `openReceiver` derived nothing and left every real receiver
    // unbounded -- which is the case #327 is actually about, since no caller
    // in this repo or its dependents passes `max_overrun`.
    //
    // With prefetch off and no credit ever issued, every delivery is an
    // overrun: the peer ignoring credit outright, which is the case charging
    // cannot slow because there is no next grant to charge against.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < min_overrun_allowance + 8) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_buffered_bytes = null,
    }, 10_000);
    try testing.expectEqual(min_overrun_allowance, receiver.max_overrun);

    var received: u32 = 0;
    while (receiver.receive(10_000)) |_| {
        received += 1;
    } else |e| {
        try testing.expectEqual(error.CreditExceeded, e);
    }
    // Bounded at the allowance rather than buffering all seventy-two.
    try testing.expectEqual(min_overrun_allowance, received);
    try testing.expect(!receiver.attached);
}

test "a prefetching receiver derives its overrun bound from the window" {
    // A 300-deep prefetch legitimately has far more in flight than a 4-deep
    // one, so a fixed allowance would either throttle the large window or fail
    // to bound the small one. The floor only applies below it.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    for ([_][]const u8{ "wide", "narrow", "loose" }, 0..) |name, h| {
        try peer.push(0, .{ .attach = .{
            .name = name,
            .handle = @intCast(h),
            .role = .sender,
            .initial_delivery_count = 0,
        } });
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const wide = try openReceiver(&fixture.session, .{
        .name = "wide",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 1024,
    }, 10_000);
    try testing.expectEqual(@as(u32, 1024), wide.max_overrun);

    const narrow = try openReceiver(&fixture.session, .{
        .name = "narrow",
        .source_address = "eh/ConsumerGroups/$default/Partitions/1",
        .prefetch = 4,
    }, 10_000);
    try testing.expectEqual(min_overrun_allowance, narrow.max_overrun);

    // Zero is the documented escape hatch back to advisory credit.
    const loose = try openReceiver(&fixture.session, .{
        .name = "loose",
        .source_address = "eh/ConsumerGroups/$default/Partitions/2",
        .prefetch = 4,
        .max_overrun = 0,
    }, 10_000);
    try testing.expectEqual(@as(u32, 0), loose.max_overrun);
}

test "a peer cannot clear the debt it ran up by sending a flow" {
    // Regression test for a bug this change introduced and review caught.
    //
    // `Session.applyFlow` is a third writer of `Receiver.credit`, alongside
    // `replenish` and `issueCredit`. The first version of this change taught
    // only the latter two to charge the overrun, and then asserted that credit
    // and debt were never both outstanding -- an invariant the peer could
    // break from the wire. Worse than unenforced: in a ReleaseSafe build the
    // assert aborted the process, so a credit-ignoring peer went from causing
    // unbounded buffering to being able to kill the endpoint remotely.
    //
    // The flow scripted below is an ordinary one, not a malformed frame: its
    // `delivery-count` simply lags the transfers already on the wire, which is
    // what a flow crossing transfers in flight looks like. Read as `u32` the
    // remainder wrapped to about four billion credits, which would also have
    // made the overrun bound unreachable.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }
    // Lags the four transfers already sent.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 100,
        .next_outgoing_id = 4,
        .outgoing_window = 100,
        .handle = 0,
        .delivery_count = 2,
        .link_credit = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "t",
        .message_format = 0,
        .settled = true,
        .more = false,
    }, "event");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_overrun = 4,
    }, 10_000);

    i = 0;
    while (i < 4) : (i += 1) _ = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 4), receiver.overrun);

    // The lagging flow grants nothing rather than wrapping, and leaves the
    // debt standing, so the bound still fires on the next delivery.
    try testing.expectError(error.CreditExceeded, receiver.receive(10_000));
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expect(!receiver.attached);
}

test "a peer flow cannot grant receiver credit or clear overrun debt" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 100,
        .next_outgoing_id = 3,
        .outgoing_window = 100,
        .handle = 0,
        .link_credit = 10,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_buffered_bytes = null,
    }, 10_000);

    i = 0;
    while (i < 3) : (i += 1) _ = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 3), receiver.overrun);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 3), receiver.overrun);

    // Only the local receiver can authorize more deliveries. Its ten-credit
    // request pays the three-delivery debt and emits the remaining seven.
    try receiver.issueCredit(10);
    try testing.expectEqual(@as(u32, 7), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.overrun);
}

test "a link torn down for overrunning does not take its session's other links with it" {
    // `refuseOverrun` detaches locally without waiting for the peer, because
    // the peer is by definition not cooperating. It therefore keeps sending
    // for a handle this endpoint no longer considers attached, and `pump` is
    // shared: CBS and `$management` sit on the same session as a consumer in
    // both dependent packages. Erroring on the straggler would let one bad
    // link take those down with it.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    for ([_][]const u8{ "hostile", "healthy" }, 0..) |name, h| {
        try peer.push(0, .{ .attach = .{
            .name = name,
            .handle = @intCast(h),
            .role = .sender,
            .initial_delivery_count = 0,
        } });
    }
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "hostile");
    }
    // Arrives after this endpoint has already given up on handle 0.
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 3,
        .delivery_tag = "t",
        .message_format = 0,
        .settled = true,
        .more = false,
    }, "straggler");
    try peer.pushTransfer(0, .{
        .handle = 1,
        .delivery_id = 4,
        .delivery_tag = "t",
        .message_format = 0,
        .settled = true,
        .more = false,
    }, "good");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const hostile = try openReceiver(&fixture.session, .{
        .name = "hostile",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_overrun = 2,
    }, 10_000);
    const healthy = try openReceiver(&fixture.session, .{
        .name = "healthy",
        .source_address = "eh/ConsumerGroups/$default/Partitions/1",
        .prefetch = 0,
    }, 10_000);
    try healthy.issueCredit(4);

    _ = try hostile.receive(10_000);
    _ = try hostile.receive(10_000);
    try testing.expectError(error.CreditExceeded, hostile.receive(10_000));
    try testing.expect(!hostile.attached);

    // The straggler for the dead handle is dropped rather than failing the
    // shared pump, so this still arrives.
    const delivery = try healthy.receive(10_000);
    try testing.expectEqualStrings("good", delivery.payload);
    try testing.expect(healthy.attached);
}

test "an overrun bound of zero disables the detach but not the charging" {
    // `max_overrun = 0` is documented as an escape hatch. The test above only
    // asserted that the field round-trips, which would have passed just as
    // well if the zero check had been deleted and every such receiver detached
    // on its first delivery.
    //
    // It disables the detach only. Charging is the policy, not the backstop,
    // so an overrunning peer is still granted less -- which is why calling
    // this "advisory credit" or "the old behaviour" would be wrong.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < min_overrun_allowance + 8) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_overrun = 0,
        .max_buffered_bytes = null,
    }, 10_000);

    // Far past what the derived bound would have been, with no detach.
    i = 0;
    while (i < min_overrun_allowance + 8) : (i += 1) _ = try receiver.receive(10_000);
    try testing.expect(receiver.attached);
    try testing.expectEqual(min_overrun_allowance + 8, receiver.overrun);

    // Still charged, so this is not the pre-#327 behaviour.
    try receiver.issueCredit(4);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(min_overrun_allowance + 4, receiver.overrun);
}

test "disabled overrun detachment saturates debt instead of overflowing" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .settled = true,
        }, "x");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_overrun = 0,
        .max_message_size = 8,
        .max_buffered_bytes = null,
    }, 10_000);
    receiver.overrun = std.math.maxInt(u32) - 1;

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(std.math.maxInt(u32), receiver.overrun);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(std.math.maxInt(u32), receiver.overrun);
    try testing.expect(receiver.attached);
    try testing.expectEqual(@as(u32, 2), receiver.delivery_count);
}

test "a peer flow with delivery count cannot grant receiver credit" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .message_format = 0,
            .settled = true,
            .more = false,
        }, "event");
    }
    // Even an internally consistent peer delivery-count and link-credit pair
    // cannot create authorization that this receiver never emitted.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 100,
        .next_outgoing_id = 3,
        .outgoing_window = 100,
        .handle = 0,
        .delivery_count = 3,
        .link_credit = 10,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_buffered_bytes = null,
    }, 10_000);

    i = 0;
    while (i < 3) : (i += 1) _ = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 3), receiver.overrun);
    try testing.expectEqual(@as(u32, 3), receiver.delivery_count);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 3), receiver.overrun);

    try receiver.issueCredit(10);
    try testing.expectEqual(@as(u32, 7), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.overrun);
}

test "hostile receiver flows cannot mint credit across delivery-count wrap" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "entity",
        .prefetch = 0,
        .max_overrun = 1,
        .max_buffered_bytes = null,
    }, 10_000);

    // A local one-credit grant wraps its exclusive delivery limit to zero.
    receiver.delivery_count = std.math.maxInt(u32);
    try receiver.issueCredit(1);
    try testing.expectEqual(@as(u32, 0), receiver.delivery_limit);
    mem.clearWritten();

    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "a",
        .settled = true,
    }, "");
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);

    // One raced transfer consumes the configured overrun allowance. Its
    // preceding Flow claims fresh credit, but cannot enlarge local authority.
    try peer.push(0, .{ .flow = .{
        .next_incoming_id = 0,
        .incoming_window = 1000,
        .next_outgoing_id = 1,
        .outgoing_window = 1000,
        .handle = 0,
        .delivery_count = 0,
        .link_credit = 1,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 1,
        .delivery_tag = "b",
        .settled = true,
    }, "");
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 1), receiver.overrun);

    const ready_len = receiver.ready.items.len;
    const ready_capacity = receiver.ready.capacity;
    for (2..6) |id| {
        try peer.push(0, .{ .flow = .{
            .next_incoming_id = 0,
            .incoming_window = 1000,
            .next_outgoing_id = @intCast(id),
            .outgoing_window = 1000,
            .handle = 0,
            .delivery_count = @intCast(id - 1),
            .link_credit = 1,
        } });
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = @intCast(id),
            .delivery_tag = "hostile",
            .settled = true,
        }, "");
    }

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectError(error.CreditExceeded, fixture.session.pump(10_000));
    for (0..6) |_| _ = try fixture.session.pump(10_000);

    try testing.expect(receiver.poisoned);
    try testing.expectEqual(ready_len, receiver.ready.items.len);
    try testing.expectEqual(ready_capacity, receiver.ready.capacity);
    try testing.expectEqual(@as(u32, 1), receiver.overrun);
}

test "abandoning collects a verdict stranded behind an undecided delivery" {
    // The case #330 is about. `applyDisposition` records on whichever entry
    // the peer names, but `awaitSettlement` retires in send order and blocks
    // on the head, so a verdict for a later delivery is held and unreachable.
    // A caller that gives up on the head and abandons used to throw it away
    // and then re-send a message the peer had said it accepted.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    // Answers the last delivery only. The head is never settled, which is
    // what makes the verdict unreachable through `awaitSettlement`.
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 2,
        .last = 2,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);
    _ = try sender.sendBytesAsync("c", .{}, 10_000);
    _ = try fixture.session.pump(10_000);

    // Held by the sender and not reachable through `awaitSettlement`, which
    // would pump for the head rather than return this.
    try testing.expect(sender.entryAt(0).outcome == null);
    try testing.expectEqual(Outcome.accepted, sender.entryAt(2).outcome.?);

    var decided: [4]DecidedDelivery = undefined;
    try testing.expectEqual(@as(usize, 1), sender.abandonInFlightInto(&decided));
    try testing.expectEqual(@as(u32, 2), decided[0].token.id);
    try testing.expectEqual(Outcome.accepted, decided[0].outcome);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
}

test "collecting reports in send order and says how many verdicts did not fit" {
    // A short buffer must not read as "that was all of them", or a caller
    // sizing it wrong silently re-sends accepted messages again — the very
    // thing collecting exists to stop. The count is of verdicts held, not of
    // entries written, so the two disagree exactly when it matters.
    //
    // The dropped verdicts are rejections, so this also pins that an entry
    // whose verdict does not fit still has its rejection released:
    // `testing.allocator` fails the test otherwise.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 1,
        .last = 3,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:resource-limit-exceeded",
            .description = "slow down",
        } },
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    for ([_][]const u8{ "a", "b", "c", "d" }) |body| {
        _ = try sender.sendBytesAsync(body, .{}, 10_000);
    }
    _ = try fixture.session.pump(10_000);

    var decided: [2]DecidedDelivery = undefined;
    try testing.expectEqual(@as(usize, 3), sender.abandonInFlightInto(&decided));
    // Send order, so the caller can line the verdicts up against the tokens
    // it holds without sorting them.
    try testing.expectEqual(@as(u32, 1), decided[0].token.id);
    try testing.expectEqual(@as(u32, 2), decided[1].token.id);
    try testing.expectEqual(Outcome.rejected, decided[0].outcome);
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
}

test "abandoning with no room for verdicts still empties the window" {
    // `abandonInFlight` is this call with an empty buffer, so the discarding
    // form has to keep working for callers that genuinely do not care --
    // tearing a link down, say. Pins the delegation rather than trusting it.
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptSenderAttach(peer, 10);
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 1,
        .last = 1,
        .settled = true,
        .state = .{ .rejected = .{
            .condition = "amqp:resource-limit-exceeded",
            .description = "slow down",
        } },
    } });
    // For the blocking send below, which takes the next id after the two
    // abandoned ones.
    try peer.push(0, .{ .disposition = .{
        .role = .receiver,
        .first = 2,
        .last = 2,
        .settled = true,
        .state = .accepted,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const sender = try openSender(&fixture.session, .{
        .name = "producer",
        .target_address = "eh",
        .max_in_flight = 4,
    }, 10_000);

    _ = try sender.sendBytesAsync("a", .{}, 10_000);
    _ = try sender.sendBytesAsync("b", .{}, 10_000);
    _ = try fixture.session.pump(10_000);

    sender.abandonInFlight();
    try testing.expectEqual(@as(usize, 0), sender.inFlight());
    // And the blocking send that the outstanding deliveries were refusing now
    // completes. Swallowing the error instead would assert nothing: the only
    // error it could have discriminated is `DeliveriesInFlight`, which the
    // line above already rules out.
    try sender.sendBytes("c", 10_000);
}

test "an endless multi-frame delivery is bounded and detaches the link" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    // The peer declares no max-message-size, which before #347 meant the
    // reassembly buffer had no limit at all.
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "\x00\x00\x00\x04",
        .more = true,
    }, "0123456789");
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try peer.pushTransfer(0, .{ .handle = 0, .more = true }, "0123456789");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_message_size = 32,
    }, 10_000);
    try receiver.issueCredit(1);

    mem.clearWritten();
    try testing.expectError(error.MessageTooLarge, receiver.receive(10_000));
    try testing.expect(!receiver.attached);
    // The bytes are released, not merely cleared: holding them is the problem.
    try testing.expectEqual(@as(usize, 0), receiver.partial.capacity);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const detaches = try frames.of(allocator, perf.descriptor.detach);
    defer allocator.free(detaches);
    try testing.expectEqual(@as(usize, 1), detaches.len);
    var decoded = try perf.decode(allocator, detaches[0]);
    defer decoded.deinit();
    const d = decoded.performative.detach;
    try testing.expect(d.closed);
    try testing.expectEqualStrings("amqp:link:message-size-exceeded", d.err.?.condition);
}

test "a single oversize transfer is refused without reassembly" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    // Whole in one frame, so it takes the fast path that skips `partial`
    // entirely: a separate check from the reassembly one.
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "\x00\x00\x00\x04",
        .more = false,
    }, "this payload is comfortably past sixteen bytes");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_message_size = 16,
    }, 10_000);
    try receiver.issueCredit(1);

    try testing.expectError(error.MessageTooLarge, receiver.receive(10_000));
    try testing.expect(!receiver.attached);
}

test "the peer's declaration is recorded but does not bound us" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    // The peer declares 8 and then delivers 28. That is the peer violating its
    // own declaration, and §2.7.3 would let us call it a link error — but
    // tearing the link down on a threshold the peer chose, with no room for
    // the annotations a broker adds on delivery, is the trade this change
    // exists to avoid making.
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .max_message_size = 8,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "\x00\x00\x00\x04",
        .more = false,
    }, "twenty-eight bytes of body..");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_message_size = 1024,
    }, 10_000);
    try receiver.issueCredit(1);

    // Kept apart: recording the peer's number must not overwrite ours, which
    // is the confusion that left reassembly unbounded.
    try testing.expectEqual(@as(u64, 8), receiver.peer_max_message_size.?);
    try testing.expectEqual(@as(u64, 1024), receiver.max_message_size.?);
    try testing.expectEqual(@as(u64, 1024), receiver.maxMessageSize().?);

    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("twenty-eight bytes of body..", delivery.payload);
    try testing.expect(receiver.attached);
}

test "our limit applies when the peer declares a looser one" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    // Far looser than ours, so ours is the one that has to bind. A separate
    // case because the failure mode is ours being ignored in favour of the
    // peer's, which is #347 exactly.
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .max_message_size = 1 << 40,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "\x00\x00\x00\x04",
        .more = false,
    }, "twenty-eight bytes of body..");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_message_size = 16,
    }, 10_000);
    try receiver.issueCredit(1);

    try testing.expectEqual(@as(u64, 16), receiver.maxMessageSize().?);
    try testing.expectError(error.MessageTooLarge, receiver.receive(10_000));
    try testing.expect(!receiver.attached);
}

test "a receiver declares its own max-message-size in its attach" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    mem.clearWritten();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_message_size = 4096,
    }, 10_000);
    try testing.expect(receiver.attached);

    // Declaring it is what lets a conformant sender fail the message on its
    // own side instead of putting it on the wire for us to refuse.
    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const attaches = try frames.of(allocator, perf.descriptor.attach);
    defer allocator.free(attaches);
    try testing.expectEqual(@as(usize, 1), attaches.len);
    var decoded = try perf.decode(allocator, attaches[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u64, 4096), decoded.performative.attach.max_message_size.?);
}

test "a null max-message-size declares and enforces no limit" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
        .max_message_size = 8,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "\x00\x00\x00\x04",
        .more = false,
    }, "twenty-eight bytes of body..");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    mem.clearWritten();
    // Null is an explicit opt-out, not "fall back to the default".
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_message_size = null,
        .max_buffered_bytes = null,
    }, 10_000);
    try testing.expectEqual(@as(?u64, null), receiver.maxMessageSize());

    // Enforcement too, not just declaration. The peer declared 8 and sends 28:
    // opting out has to mean no limit, not "fall back to whatever the peer
    // said", which is the reading that left reassembly unbounded.
    try receiver.issueCredit(1);
    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("twenty-eight bytes of body..", delivery.payload);
    try testing.expect(receiver.attached);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const attaches = try frames.of(allocator, perf.descriptor.attach);
    defer allocator.free(attaches);
    var decoded = try perf.decode(allocator, attaches[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(?u64, null), decoded.performative.attach.max_message_size);
}

test "the default receiver derives granted credit from its finite byte budget" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    for (0..2) |i| {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = @intCast(i),
            .delivery_tag = "t",
            .settled = true,
        }, "legal");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    mem.clearWritten();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
    }, 10_000);
    try testing.expectEqual(default_max_message_size, receiver.maxMessageSize().?);
    try testing.expectEqual(
        @as(?u64, default_max_buffered_bytes),
        receiver.max_buffered_bytes,
    );
    try testing.expectEqual(@as(u32, 2), receiver.credit);
    try testing.expectEqual(@as(u32, 298), receiver.deferred_credit);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const attaches = try frames.of(allocator, perf.descriptor.attach);
    defer allocator.free(attaches);
    var decoded = try perf.decode(allocator, attaches[0]);
    defer decoded.deinit();
    try testing.expectEqual(default_max_message_size, decoded.performative.attach.max_message_size.?);

    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var flow = try perf.decode(allocator, flows[0]);
    defer flow.deinit();
    try testing.expectEqual(@as(u32, 2), flow.performative.flow.link_credit.?);

    for (0..2) |_| _ = try fixture.session.pump(10_000);
    try testing.expect(receiver.attached);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u64, 10), receiver.bufferedBytes());
    try testing.expectEqual(@as(usize, 2), receiver.ready.items.len);
    try expectReceiverAccounting(receiver);
}

test "a finite aggregate budget is also the advertised per-message ceiling" {
    try testing.expectEqual(
        @as(?u64, 16),
        try effectiveMaxMessageSize(64, 16),
    );
    try testing.expectEqual(
        @as(?u64, 16),
        try effectiveMaxMessageSize(null, 16),
    );
    try testing.expectEqual(
        @as(?u64, 16),
        try effectiveMaxMessageSize(0, 16),
    );
    try testing.expectError(
        error.InvalidReceiverOptions,
        effectiveMaxMessageSize(0, 0),
    );

    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "t",
        .settled = true,
    }, "1234567890abcdef");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    try testing.expectError(error.InvalidReceiverOptions, openReceiver(&fixture.session, .{
        .name = "invalid",
        .source_address = "partition/0",
        .max_unsettled_deliveries = 0,
    }, 10_000));

    mem.clearWritten();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 64,
        .max_buffered_bytes = 16,
    }, 10_000);
    try testing.expectEqual(@as(u64, 16), receiver.maxMessageSize().?);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const attaches = try frames.of(allocator, perf.descriptor.attach);
    defer allocator.free(attaches);
    var decoded = try perf.decode(allocator, attaches[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u64, 16), decoded.performative.attach.max_message_size.?);

    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("1234567890abcdef", delivery.payload);
    try testing.expect(receiver.attached);
}

test "aggregate budget caps credit and replenishes as deliveries leave the queue" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .settled = true,
            .more = false,
        }, "12345678");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 10,
        .max_message_size = 8,
        .max_buffered_bytes = 24,
    }, 10_000);
    try testing.expectEqual(@as(u32, 3), receiver.credit);

    while (receiver.ready.items.len < 3) _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u64, 24), receiver.bufferedBytes());
    try testing.expectEqual(@as(u32, 0), receiver.credit);

    mem.clearWritten();
    const first = try receiver.receive(10_000);
    try testing.expectEqualStrings("12345678", first.payload);
    try testing.expectEqual(@as(u64, 16), receiver.bufferedBytes());
    try testing.expectEqual(@as(u32, 0), receiver.credit);

    _ = try receiver.receive(10_000);
    _ = try receiver.receive(10_000);
    // The fourth receive finds the ready queue empty, advertises the byte
    // budget released by the first three, and then accepts the next delivery.
    const fourth = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 3), fourth.id);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 3), decoded.performative.flow.link_credit.?);
}

test "an in-progress delivery reserves its remaining maximum before credit top-up" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "t",
        .more = true,
    }, "1");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .settled = true,
    }, "234567890");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 2,
        .max_message_size = 10,
        .max_buffered_bytes = 16,
    }, 10_000);
    // Only one maximum-sized delivery initially fits.
    try testing.expectEqual(@as(u32, 1), receiver.credit);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u64, 1), receiver.bufferedBytes());
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try expectReceiverAccounting(receiver);

    // The one-byte prefix still reserves all ten bytes that this delivery may
    // legally reach, leaving only six bytes: not enough for another credit.
    mem.clearWritten();
    try receiver.issueCredit(1);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try expectReceiverAccounting(receiver);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 0), decoded.performative.flow.link_credit.?);

    // Continuations consume no additional link credit, so the conforming peer
    // can complete the already authorised delivery.
    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("1234567890", delivery.payload);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());

    // Once the completed delivery leaves the queue, its reservation is
    // released and a new maximum-sized delivery can be authorised.
    try receiver.issueCredit(1);
    try testing.expectEqual(@as(u32, 1), receiver.credit);
    try expectReceiverAccounting(receiver);
}

test "one bounded manual credit request is issued repeatedly until satisfied" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    for (0..5) |i| {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = @intCast(i),
            .delivery_tag = "t",
            .settled = true,
        }, "1234567890");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 10,
        .max_buffered_bytes = 20,
    }, 10_000);

    // Event Hubs and Service Bus request a whole receive count once. Only two
    // maximum-sized deliveries may be outstanding, but the remaining request
    // is remembered and reissued as bounded queue space becomes available.
    try receiver.issueCredit(300);
    try testing.expectEqual(@as(u32, 2), receiver.credit);
    try testing.expectEqual(@as(u32, 298), receiver.deferred_credit);

    for (0..5) |i| {
        const delivery = try receiver.receive(10_000);
        try testing.expectEqual(@as(u32, @intCast(i)), delivery.id);
        try testing.expectEqualStrings("1234567890", delivery.payload);
        try expectReceiverAccounting(receiver);
    }
    try testing.expect(receiver.attached);
    try testing.expect(receiver.deferred_credit < 298);
}

test "manual batch larger than its live window survives aborted deliveries" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var delivery_id: u32 = 0;
    for (0..12) |i| {
        if (i % 4 == 0) {
            try peer.pushTransfer(0, .{
                .handle = 0,
                .delivery_id = delivery_id,
                .aborted = true,
            }, "");
            delivery_id += 1;
        }
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = delivery_id,
            .delivery_tag = "t",
            .settled = true,
        }, "x");
        delivery_id += 1;
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 1,
        .max_buffered_bytes = 8,
    }, 10_000);

    try receiver.issueCredit(12);
    try testing.expectEqual(@as(u32, 8), receiver.credit);
    try testing.expectEqual(@as(u32, 4), receiver.deferred_credit);
    for (0..12) |_| {
        const delivery = try receiver.receive(10_000);
        try testing.expectEqualStrings("x", delivery.payload);
        try expectReceiverAccounting(receiver);
    }

    try testing.expectEqual(@as(u32, 15), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
    try testing.expectEqual(@as(u32, 0), receiver.overrun);
    try testing.expectEqual(@as(usize, 0), receiver.ready.items.len);
    try testing.expectEqual(@as(usize, 0), receiver.unsettled_ids.items.len);
    try testing.expect(receiver.attached);
}

test "repeated manual aborts keep live plus deferred demand bounded" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    for (0..64) |i| {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = @intCast(i),
            .aborted = true,
        }, "");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    try receiver.issueCredit(1);
    const partial_capacity = receiver.partial.capacity;
    const ready_capacity = receiver.ready.capacity;
    const unsettled_capacity = receiver.unsettled_ids.capacity;
    mem.clearWritten();
    for (0..64) |_| {
        _ = try fixture.session.pump(10_000);
        try testing.expectEqual(@as(u32, 0), receiver.credit);
        try testing.expectEqual(@as(u32, 1), receiver.deferred_credit);
        try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
        try testing.expectEqual(@as(?u32, null), receiver.partial_id);
        try testing.expectEqual(@as(usize, 0), receiver.ready.items.len);
        try testing.expectEqual(@as(usize, 0), receiver.unsettled_ids.items.len);
        try testing.expectEqual(partial_capacity, receiver.partial.capacity);
        try testing.expectEqual(ready_capacity, receiver.ready.capacity);
        try testing.expectEqual(unsettled_capacity, receiver.unsettled_ids.capacity);
        try testing.expectEqual(
            @as(u32, 1),
            receiver.credit + receiver.deferred_credit +
                @intFromBool(receiver.partial_manual_demand),
        );

        try receiver.replenish();
        try testing.expectEqual(@as(u32, 1), receiver.credit);
        try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
        try testing.expectEqual(
            @as(u32, 1),
            receiver.credit + receiver.deferred_credit +
                @intFromBool(receiver.partial_manual_demand),
        );
    }

    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 64,
        .delivery_tag = "valid",
        .settled = true,
    }, "event");
    _ = try fixture.session.pump(10_000);
    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("event", delivery.payload);
    try testing.expectEqual(@as(u32, 65), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 64), flows.len);
}

test "an unauthorized aborted overrun cannot mint replacement demand" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    for (0..2) |i| {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = @intCast(i),
            .aborted = true,
        }, "");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    try receiver.issueCredit(1);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 1), receiver.deferred_credit);
    try testing.expectEqual(@as(u32, 0), receiver.overrun);

    // The second abort was never authorized. It is protocol debt and cannot
    // create a second unit of application demand.
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 1), receiver.deferred_credit);
    try testing.expectEqual(@as(u32, 1), receiver.overrun);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 2), receiver.delivery_count);
}

test "draining an aborted manual slot does not recreate application demand" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .aborted = true,
    }, "");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    try receiver.issueCredit(1);
    mem.clearWritten();
    try receiver.drainCredit(10_000);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
    try testing.expect(!receiver.drain);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expect(decoded.performative.flow.drain);
    try testing.expectEqual(@as(u32, 1), decoded.performative.flow.link_credit.?);
}

test "prefetch abort replenishment does not also create manual demand" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .aborted = true,
    }, "");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 1,
        .delivery_tag = "valid",
        .settled = true,
    }, "event");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    mem.clearWritten();
    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("event", delivery.payload);
    try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
    try testing.expectEqual(@as(u32, 0), receiver.credit);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 1), decoded.performative.flow.link_credit.?);
}

test "aborted manual demand remains bounded by byte and settlement slots" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 10,
        .aborted = true,
    }, "");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 11,
        .delivery_tag = "valid",
    }, "1234567890");
    try peer.push(0, .{ .disposition = .{
        .role = .sender,
        .first = 11,
        .settled = true,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 10,
        .max_buffered_bytes = 10,
        .rcv_settle_mode = .second,
        .max_unsettled_deliveries = 1,
    }, 10_000);

    try receiver.issueCredit(3);
    try testing.expectEqual(@as(u32, 1), receiver.credit);
    try testing.expectEqual(@as(u32, 2), receiver.deferred_credit);
    mem.clearWritten();

    const delivery = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 11), delivery.id);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 2), receiver.deferred_credit);
    try testing.expectEqual(@as(usize, 1), receiver.unsettled_ids.items.len);
    try receiver.accept(delivery);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 2), receiver.deferred_credit);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(usize, 0), receiver.unsettled_ids.items.len);
    try testing.expectEqual(@as(u32, 1), receiver.credit);
    try testing.expectEqual(@as(u32, 1), receiver.deferred_credit);
    try expectReceiverAccounting(receiver);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 2), flows.len);
    for (flows) |body| {
        var decoded = try perf.decode(allocator, body);
        defer decoded.deinit();
        try testing.expectEqual(@as(u32, 1), decoded.performative.flow.link_credit.?);
    }
}

test "a credit-ignoring sender cannot cross the aggregate buffered budget" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = i,
            .delivery_tag = "t",
            .settled = true,
            .more = false,
        }, "twelve-bytes");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_overrun = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    mem.clearWritten();
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u64, 12), receiver.bufferedBytes());
    try testing.expectError(error.BufferLimitExceeded, fixture.session.pump(10_000));
    try testing.expectEqual(@as(u64, 12), receiver.bufferedBytes());
    try testing.expectEqual(@as(usize, 1), receiver.ready.items.len);
    try testing.expect(!receiver.attached);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const detaches = try frames.of(allocator, perf.descriptor.detach);
    defer allocator.free(detaches);
    try testing.expectEqual(@as(usize, 1), detaches.len);
    var decoded = try perf.decode(allocator, detaches[0]);
    defer decoded.deinit();
    try testing.expectEqualStrings(
        "amqp:resource-limit-exceeded",
        decoded.performative.detach.err.?.condition,
    );
}

test "aggregate budget rejects an unreserved in-progress delivery before retaining it" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "t",
        .more = false,
    }, "12345678");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 1,
        .delivery_tag = "t",
        .more = true,
    }, "12345");
    try peer.pushTransfer(0, .{ .handle = 0, .more = true }, "67890");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 64,
        .max_buffered_bytes = 16,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expectError(error.BufferLimitExceeded, fixture.session.pump(10_000));
    try testing.expectEqual(@as(u64, 8), receiver.bufferedBytes());
    try testing.expectEqual(@as(usize, 1), receiver.ready.items.len);
    try testing.expectEqual(@as(usize, 0), receiver.partial.capacity);
    try testing.expectEqual(@as(u32, 2), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 1), receiver.overrun);
    try expectReceiverAccounting(receiver);
    try testing.expect(!receiver.attached);

    // The continuation for the rejected delivery is discarded as a straggler
    // and cannot change the retained accounting.
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u64, 8), receiver.bufferedBytes());
    try expectReceiverAccounting(receiver);
}

test "an aborted multi-frame delivery consumes credit once and is not queued" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "a",
        .more = true,
    }, "prefix");
    try peer.pushTransfer(0, .{ .handle = 0, .aborted = true }, "ignored");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 1,
        .delivery_tag = "b",
        .settled = true,
    }, "good");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 2,
        .max_message_size = 16,
        .max_buffered_bytes = 32,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 1), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 1), receiver.credit);
    try testing.expectEqual(@as(u64, 6), receiver.bufferedBytes());
    try expectReceiverAccounting(receiver);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 1), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 1), receiver.credit);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
    try testing.expectEqual(@as(usize, 0), receiver.ready.items.len);
    try expectReceiverAccounting(receiver);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 2), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(usize, 1), receiver.ready.items.len);
    try expectReceiverAccounting(receiver);
    const delivery = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 1), delivery.id);
    try testing.expectEqualStrings("good", delivery.payload);
}

test "manual one-credit receive replaces an initial aborted transfer in-pump" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "aborted",
        .aborted = true,
    }, "");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 1,
        .delivery_tag = "valid",
        .settled = true,
    }, "event");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    try receiver.issueCredit(1);
    mem.clearWritten();
    const delivery = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 1), delivery.id);
    try testing.expectEqualStrings("event", delivery.payload);
    try testing.expectEqual(@as(u32, 2), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
    try testing.expectEqual(@as(usize, 0), mem.reads_with_pending_writes);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 1), decoded.performative.flow.delivery_count.?);
    try testing.expectEqual(@as(u32, 1), decoded.performative.flow.link_credit.?);
}

test "manual one-credit receive replaces an aborted continuation in-pump" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 7,
        .delivery_tag = "aborted",
        .more = true,
    }, "prefix");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 7,
        .aborted = true,
    }, "");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 8,
        .delivery_tag = "valid",
        .settled = true,
    }, "replacement");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    try receiver.issueCredit(1);
    mem.clearWritten();
    const delivery = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 8), delivery.id);
    try testing.expectEqualStrings("replacement", delivery.payload);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
    try testing.expectEqual(@as(u32, 2), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u32, 0), receiver.deferred_credit);
    try testing.expectEqual(@as(?u32, null), receiver.partial_id);
    try testing.expectEqual(@as(usize, 0), mem.reads_with_pending_writes);

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const flows = try frames.of(allocator, perf.descriptor.flow);
    defer allocator.free(flows);
    try testing.expectEqual(@as(usize, 1), flows.len);
    var decoded = try perf.decode(allocator, flows[0]);
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 1), decoded.performative.flow.delivery_count.?);
    try testing.expectEqual(@as(u32, 1), decoded.performative.flow.link_credit.?);
}

test "continuations may repeat the original delivery id without consuming credit" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 7,
        .delivery_tag = "tag",
        .more = true,
    }, "first-");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 7,
        .more = true,
    }, "second-");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 7,
        .settled = true,
    }, "third");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 32,
        .max_buffered_bytes = 32,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    _ = try fixture.session.pump(10_000);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 1), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try expectReceiverAccounting(receiver);
    try testing.expect(!fixture.session.incoming_deliveries.contains(7));

    const delivery = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 7), delivery.id);
    try testing.expectEqualStrings("first-second-third", delivery.payload);
    try testing.expectEqualStrings("tag", delivery.tag);
    try testing.expect(delivery.settled);
}

test "continuation settlement accumulates true and omission preserves state" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 20,
        .delivery_tag = "a",
        .more = true,
    }, "a");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .settled = true,
        .more = true,
    }, "b");
    try peer.pushTransfer(0, .{ .handle = 0 }, "c");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 21,
        .delivery_tag = "b",
        .more = true,
    }, "x");
    try peer.pushTransfer(0, .{ .handle = 0 }, "y");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 2,
        .max_message_size = 16,
        .max_buffered_bytes = 32,
    }, 10_000);

    for (0..5) |_| _ = try fixture.session.pump(10_000);
    try testing.expect(!fixture.session.incoming_deliveries.contains(20));
    try testing.expect(fixture.session.incoming_deliveries.contains(21));

    const settled = try receiver.receive(10_000);
    try testing.expectEqualStrings("abc", settled.payload);
    try testing.expect(settled.settled);
    const unsettled = try receiver.receive(10_000);
    try testing.expectEqualStrings("xy", unsettled.payload);
    try testing.expect(!unsettled.settled);
}

test "an aborted continuation may repeat the original delivery id" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 3,
        .delivery_tag = "a",
        .more = true,
    }, "prefix");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 3,
        .aborted = true,
    }, "ignored");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 1), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
    try testing.expectEqual(@as(?u32, null), receiver.partial_id);
    try testing.expect(receiver.attached);
    try testing.expect(!fixture.session.incoming_deliveries.contains(3));
    try expectReceiverAccounting(receiver);
}

test "a completed unsettled delivery id cannot be reused on the same link" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    for (0..2) |_| {
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = 7,
            .delivery_tag = "t",
        }, "payload");
    }

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 2,
        .max_message_size = 16,
        .max_buffered_bytes = 32,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expect(fixture.session.incoming_deliveries.contains(7));
    try testing.expectError(error.DuplicateDeliveryId, fixture.session.pump(10_000));
    try testing.expect(receiver.poisoned);
    try testing.expect(!receiver.attached);
    try testing.expect(!fixture.session.incoming_deliveries.contains(7));
}

test "an unsettled delivery id cannot be reused across receiver links" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    inline for (.{ "first", "second" }, 0..) |name, handle| {
        try peer.push(0, .{ .attach = .{
            .name = name,
            .handle = handle,
            .role = .sender,
            .initial_delivery_count = 0,
        } });
    }
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 9,
        .delivery_tag = "a",
    }, "first");
    try peer.pushTransfer(0, .{
        .handle = 1,
        .delivery_id = 9,
        .delivery_tag = "b",
    }, "duplicate");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const first = try openReceiver(&fixture.session, .{
        .name = "first",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);
    const second = try openReceiver(&fixture.session, .{
        .name = "second",
        .source_address = "partition/1",
        .prefetch = 1,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(first, fixture.session.incoming_deliveries.get(9).?);
    try testing.expectError(error.DuplicateDeliveryId, fixture.session.pump(10_000));
    try testing.expect(first.attached);
    try testing.expect(second.poisoned);
    try testing.expectEqual(first, fixture.session.incoming_deliveries.get(9).?);
}

test "settled and aborted initial transfers still check cross-link id collisions" {
    const Case = enum { settled, aborted };
    inline for (std.meta.tags(Case)) |case| {
        const allocator = testing.allocator;
        var mem = MemoryTransport.init(allocator);
        defer mem.deinit();
        var clock: connection.ManualClock = .{};
        const peer = Peer{ .allocator = allocator, .mem = &mem };

        try scriptHandshake(peer, 65536);
        inline for (.{ "first", "second" }, 0..) |name, handle| {
            try peer.push(0, .{ .attach = .{
                .name = name,
                .handle = handle,
                .role = .sender,
                .initial_delivery_count = 0,
            } });
        }
        try peer.pushTransfer(0, .{
            .handle = 0,
            .delivery_id = 11,
            .delivery_tag = "a",
        }, "active");
        try peer.pushTransfer(0, .{
            .handle = 1,
            .delivery_id = 11,
            .delivery_tag = "b",
            .settled = if (case == .settled) true else null,
            .aborted = case == .aborted,
        }, if (case == .aborted) "discarded" else "settled");

        var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
        defer driver.deinit();
        var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
        defer fixture.deinit();

        const first = try openReceiver(&fixture.session, .{
            .name = "first",
            .source_address = "partition/0",
            .prefetch = 1,
        }, 10_000);
        const second = try openReceiver(&fixture.session, .{
            .name = "second",
            .source_address = "partition/1",
            .prefetch = 1,
        }, 10_000);

        _ = try fixture.session.pump(10_000);
        try testing.expectEqual(first, fixture.session.incoming_deliveries.get(11).?);
        try testing.expectError(error.DuplicateDeliveryId, fixture.session.pump(10_000));
        try testing.expect(first.attached);
        try testing.expect(second.poisoned);
        try testing.expectEqual(first, fixture.session.incoming_deliveries.get(11).?);
    }
}

test "a delivery id may be reused after terminal settlement" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 5,
        .delivery_tag = "a",
    }, "first");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 2,
        .max_message_size = 16,
        .max_buffered_bytes = 32,
    }, 10_000);

    const first = try receiver.receive(10_000);
    try testing.expect(fixture.session.incoming_deliveries.contains(5));
    try receiver.accept(first);
    try testing.expect(!fixture.session.incoming_deliveries.contains(5));

    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 5,
        .delivery_tag = "b",
    }, "second");
    const second = try receiver.receive(10_000);
    try testing.expectEqual(@as(u32, 5), second.id);
    try testing.expectEqualStrings("second", second.payload);
    try testing.expect(fixture.session.incoming_deliveries.contains(5));
}

test "a new delivery id cannot replace an unfinished delivery or bypass credit" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "a",
        .more = true,
    }, "first");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 1,
        .delivery_tag = "b",
        .more = true,
    }, "replacement");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_overrun = 0,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u32, 1), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.credit);
    try testing.expectError(error.MalformedFrame, fixture.session.pump(10_000));
    try testing.expectEqual(@as(u32, 1), receiver.delivery_count);
    try testing.expectEqual(@as(u32, 0), receiver.overrun);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
    try testing.expectEqual(@as(usize, 0), receiver.ready.items.len);
    try testing.expect(receiver.poisoned);
    try testing.expect(!receiver.attached);
    try expectReceiverAccounting(receiver);
}

test "allocation failure after a consumed continuation poisons the receiver" {
    var switching = SwitchAllocator{ .child = testing.allocator };
    const allocator = switching.allocator();

    var mem = MemoryTransport.init(testing.allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = testing.allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "t",
        .more = true,
    }, "prefix");
    var large: [400]u8 = undefined;
    @memset(&large, 'x');
    try peer.pushTransfer(0, .{ .handle = 0, .more = true }, &large);
    try peer.pushTransfer(0, .{ .handle = 0, .more = false }, "tail");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 512,
        .max_buffered_bytes = 512,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u64, 6), receiver.bufferedBytes());
    // Keep the frame reader and performative arena out of the injection: the
    // failure belongs to incorporating the already decoded payload into the
    // receiver's partial buffer.
    driver.body_buf = try allocator.realloc(driver.body_buf, 512);

    switching.failing = true;
    try testing.expectError(error.OutOfMemory, fixture.session.pump(10_000));
    switching.failing = false;

    try testing.expect(receiver.poisoned);
    try testing.expect(!receiver.attached);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
    try testing.expectEqual(@as(usize, 0), receiver.partial.capacity);
    try expectReceiverAccounting(receiver);

    // The consumed frame cannot be replayed, so the whole connection is
    // terminal and the unread continuation is never parsed as a new frame.
    try testing.expectEqual(connection.State.err, driver.state);
    try testing.expect(mem.closed);
    try testing.expectError(error.LinkDetached, fixture.session.pump(10_000));
    try testing.expectEqual(@as(usize, 0), receiver.ready.items.len);
    try expectReceiverAccounting(receiver);
    try testing.expectError(error.LinkDetached, receiver.receive(10_000));
}

test "a remote detach releases an in-progress delivery's budget" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "t",
        .more = true,
    }, "0123456789");
    try peer.push(0, .{ .detach = .{
        .handle = 0,
        .closed = true,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 64,
        .max_buffered_bytes = 16,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u64, 10), receiver.bufferedBytes());
    try testing.expect(fixture.session.incoming_deliveries.contains(0));
    try expectReceiverAccounting(receiver);
    _ = try fixture.session.pump(10_000);
    try testing.expectEqual(@as(u64, 0), receiver.bufferedBytes());
    try testing.expectEqual(@as(usize, 0), receiver.partial.capacity);
    try testing.expect(!receiver.attached);
    try testing.expect(receiver.poisoned);
    try testing.expect(!fixture.session.incoming_deliveries.contains(0));
    try expectReceiverAccounting(receiver);
    const written = mem.written().len;
    try testing.expectError(error.LinkDetached, receiver.issueCredit(1));
    try testing.expectEqual(written, mem.written().len);
    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const detaches = try frames.of(allocator, perf.descriptor.detach);
    defer allocator.free(detaches);
    try testing.expectEqual(@as(usize, 1), detaches.len);
}

test "a remote non-closing Detach is answered closed and cannot resume the poisoned link" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "t",
        .more = true,
    }, "prefix");
    try peer.push(0, .{ .detach = .{
        .handle = 0,
        .closed = false,
    } });
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 2,
        .role = .sender,
        .initial_delivery_count = 0,
    } });

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_message_size = 16,
        .max_buffered_bytes = 16,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expect(fixture.session.incoming_deliveries.contains(4));
    mem.clearWritten();
    _ = try fixture.session.pump(10_000);
    try testing.expect(receiver.poisoned);
    try testing.expect(!fixture.session.incoming_deliveries.contains(4));

    var frames = try EmittedFrames.parse(allocator, mem.written());
    defer frames.deinit();
    const detaches = try frames.of(allocator, perf.descriptor.detach);
    defer allocator.free(detaches);
    try testing.expectEqual(@as(usize, 1), detaches.len);
    var decoded = try perf.decode(allocator, detaches[0]);
    defer decoded.deinit();
    try testing.expect(decoded.performative.detach.closed);

    _ = try fixture.session.pump(10_000); // late attach is ignored
    try testing.expect(receiver.poisoned);
    try testing.expect(!receiver.attached);
    try testing.expectEqual(@as(u32, 0), receiver.remote_handle);
    const written = mem.written().len;
    try testing.expectError(error.LinkDetached, receiver.issueCredit(1));
    try testing.expectEqual(written, mem.written().len);
}

test "one receiver exhausting its budget does not block another link" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    for ([_][]const u8{ "hostile", "healthy" }, 0..) |name, handle| {
        try peer.push(0, .{ .attach = .{
            .name = name,
            .handle = @intCast(handle),
            .role = .sender,
            .initial_delivery_count = 0,
        } });
    }
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 0,
        .delivery_tag = "t",
        .settled = true,
    }, "123456");
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 1,
        .delivery_tag = "t",
        .settled = true,
    }, "123456");
    try peer.pushTransfer(0, .{
        .handle = 1,
        .delivery_id = 2,
        .delivery_tag = "t",
        .settled = true,
    }, "good");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    const hostile = try openReceiver(&fixture.session, .{
        .name = "hostile",
        .source_address = "partition/0",
        .prefetch = 1,
        .max_overrun = 0,
        .max_message_size = 8,
        .max_buffered_bytes = 8,
    }, 10_000);
    const healthy = try openReceiver(&fixture.session, .{
        .name = "healthy",
        .source_address = "partition/1",
        .prefetch = 1,
        .max_message_size = 8,
        .max_buffered_bytes = 8,
    }, 10_000);

    _ = try fixture.session.pump(10_000);
    try testing.expectError(error.BufferLimitExceeded, fixture.session.pump(10_000));
    try testing.expect(!hostile.attached);

    const delivery = try healthy.receive(10_000);
    try testing.expectEqualStrings("good", delivery.payload);
    try testing.expect(healthy.attached);
}

test "a zero max-message-size means unlimited, not zero" {
    const allocator = testing.allocator;
    var mem = MemoryTransport.init(allocator);
    defer mem.deinit();
    var clock: connection.ManualClock = .{};
    const peer = Peer{ .allocator = allocator, .mem = &mem };

    try scriptHandshake(peer, 65536);
    try peer.push(0, .{ .attach = .{
        .name = "consumer",
        .handle = 0,
        .role = .sender,
        .initial_delivery_count = 0,
    } });
    try peer.pushTransfer(0, .{
        .handle = 0,
        .delivery_id = 4,
        .delivery_tag = "\x00\x00\x00\x04",
        .more = false,
    }, "twenty-eight bytes of body..");

    var driver = try Driver.init(allocator, mem.transport(), clock.clock(), test_options);
    defer driver.deinit();
    var fixture = try Fixture.init(allocator, &mem, &clock, &driver);
    defer fixture.deinit();

    // §2.7.3 makes zero mean "no limit". Taking it literally would refuse every
    // non-empty delivery and detach the link.
    const receiver = try openReceiver(&fixture.session, .{
        .name = "consumer",
        .source_address = "eh/ConsumerGroups/$default/Partitions/0",
        .prefetch = 0,
        .max_message_size = 0,
        .max_buffered_bytes = null,
    }, 10_000);
    try receiver.issueCredit(1);

    try testing.expectEqual(@as(?u64, null), receiver.maxMessageSize());
    const delivery = try receiver.receive(10_000);
    try testing.expectEqualStrings("twenty-eight bytes of body..", delivery.payload);
    try testing.expect(receiver.attached);
}
