//! Azure SDK testing helpers for recording and playback.
//!
//! `PlaybackTransport` and `RecordingTransport` expose copyable Core 0.4
//! transport descriptors whose opaque contexts borrow the transport values.
//! The values and any wrapped backend contexts must outlive every descriptor
//! copy and open operation. Playback is caller-serialized. Recording attempt
//! ordering/finalization and recorder-owned allocation are synchronized;
//! borrowed slices, policy contexts, and lifecycle calls still require caller
//! synchronization.
const std = @import("std");
const core = @import("azure_sdk_core");

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
    redacted: bool = false,
    url_redaction_template: ?[]const u8 = null,
};

/// Stable failure stages represented by a raw transport attempt.
pub const RecordedOutcome = enum {
    response,
    transport_error,
    open_error,
    body_error,
    finish_error,
};

/// Stable, serializable failure categories used instead of backend-specific
/// error identities. Playback maps these to the corresponding
/// `OperationCancelled`, `RecordedTimeout`, `RecordedConnectionFailure`,
/// `RecordedTlsFailure`, `RecordedProtocolFailure`, `RecordedIoFailure`,
/// `RecordedResourceExhausted`, `RecordedUnsupported`, or
/// `RecordedUnknownFailure` error.
pub const RecordedErrorCategory = enum {
    cancelled,
    timeout,
    connection,
    tls,
    protocol,
    io,
    resource_exhausted,
    unsupported,
    unknown,
};

/// A borrowed HTTP exchange used by playback.
///
/// Method, URL, and body are matched exactly, including whether a body is
/// present. Every request header listed here must occur with the same value;
/// additional live headers are allowed. `REDACTED` values produced by
/// `toJson` wildcard only recognized sensitive header values and explicit URL
/// redaction-template positions; literal `REDACTED` values and nonsensitive
/// fields remain exact. Response headers retain wire order and duplicate
/// values. `outcome` replays stable failure categories at transport, open,
/// response-body, or finish stages.
pub const RecordedExchange = struct {
    request_method: core.http.Method,
    request_url: []const u8,
    request_url_redaction_template: ?[]const u8 = null,
    request_headers: []const HeaderPair = &.{},
    request_body: ?[]const u8 = null,
    response_status: u16 = 0,
    response_body: []const u8 = "",
    response_headers: []const HeaderPair = &.{},
    outcome: RecordedOutcome = .response,
    error_category: ?RecordedErrorCategory = null,
};

/// An allocator-owned exchange captured by `RecordingTransport`.
pub const OwnedExchange = struct {
    request_method: core.http.Method,
    request_url: []u8,
    request_url_redaction_template: ?[]u8 = null,
    request_headers: []HeaderPair,
    request_body: ?[]u8,
    response_status: u16,
    response_body: []u8,
    response_body_allocation: ?[]u8 = null,
    response_headers: []HeaderPair,
    outcome: RecordedOutcome = .response,
    error_category: ?RecordedErrorCategory = null,
    resolved: bool = true,

    fn deinit(self: *OwnedExchange, allocator: std.mem.Allocator) void {
        allocator.free(self.request_url);
        if (self.request_url_redaction_template) |template|
            allocator.free(template);
        deinitHeaderPairs(allocator, self.request_headers);
        if (self.request_body) |body| allocator.free(body);
        allocator.free(self.response_body_allocation orelse self.response_body);
        deinitHeaderPairs(allocator, self.response_headers);
        self.* = undefined;
    }
};

/// Allocator-owned recordings parsed from `RecordingTransport.toJson`.
///
/// `asSlice` borrows this value. Keep it alive until playback and all open
/// playback operations are finished.
pub const ParsedRecordings = struct {
    allocator: std.mem.Allocator,
    owned: []OwnedExchange,
    recordings: []RecordedExchange,

    pub fn asSlice(self: *const ParsedRecordings) []const RecordedExchange {
        return self.recordings;
    }

    pub fn deinit(self: *ParsedRecordings) void {
        for (self.owned) |*exchange| exchange.deinit(self.allocator);
        self.allocator.free(self.owned);
        self.allocator.free(self.recordings);
        self.* = undefined;
    }
};

pub const BodyDirection = enum {
    request,
    response,
};

/// Exchange-aware input for an optional recording body policy.
pub const BodySafetyContext = struct {
    direction: BodyDirection,
    method: core.http.Method,
    url: []const u8,
    content_type: ?[]const u8,
    content_encoding: ?[]const u8,
    body: []const u8,
};

/// A caller body policy may add a schema-specific rejection or explicitly
/// request built-in inspection of a supported textual body, or allow an
/// otherwise opaque/unsupported body that the caller knows is safe.
///
/// Every non-empty body requires a configured policy. Built-in recognizable
/// credentials and private-key markers are checked before default rejection;
/// the callback is the explicit trust boundary for persistence.
pub const BodyPolicyDecision = enum {
    inspect,
    reject_sensitive,
    allow_opaque,
};

/// Exchange-aware input for an optional recording header policy.
pub const HeaderSafetyContext = struct {
    direction: BodyDirection,
    method: core.http.Method,
    url: []const u8,
    name: []const u8,
    value: []const u8,
};

/// Header policy decisions are serialized into structured matching metadata.
///
/// `inspect` applies the built-in known-safe header-name allowlist, volatile
/// request-header rules, and value scanning; unknown names and recognizable
/// credentials are redacted.
/// `preserve` is an explicit escape hatch for application headers that the
/// built-in conservative name rules classify as sensitive. The caller is
/// responsible for proving that the value is safe to persist.
pub const HeaderPolicyDecision = enum {
    inspect,
    redact,
    preserve,
};

/// Recording safety policy callbacks and their borrowed contexts.
///
/// Callback contexts must outlive every `toJson` call on the transport.
pub const RecordingOptions = struct {
    body_policy_context: ?*anyopaque = null,
    bodyPolicyFn: ?*const fn (
        context: ?*anyopaque,
        body: BodySafetyContext,
    ) BodyPolicyDecision = null,
    header_policy_context: ?*anyopaque = null,
    headerPolicyFn: ?*const fn (
        context: ?*anyopaque,
        header: HeaderSafetyContext,
    ) HeaderPolicyDecision = null,
};

/// Parse the versioned, lossless JSON format emitted by `toJson`.
///
/// All returned strings and decoded bodies are allocator-owned. Invalid JSON,
/// unsupported versions or encodings, invalid outcomes, and invalid base64
/// are distinct errors. Version 2 successful-response recordings remain
/// readable; new recordings use version 3 failure outcomes.
pub fn parseJson(
    allocator: std.mem.Allocator,
    json: []const u8,
) !ParsedRecordings {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRecordingJson,
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidRecordingJson,
    };
    const version = root.get("version") orelse return error.InvalidRecordingJson;
    if (version != .integer or
        (version.integer != 2 and
            version.integer != recording_format_version))
        return error.UnsupportedRecordingVersion;
    const format_version: u32 = @intCast(version.integer);
    const exchanges_value = root.get("exchanges") orelse
        return error.InvalidRecordingJson;
    const exchange_values = switch (exchanges_value) {
        .array => |value| value.items,
        else => return error.InvalidRecordingJson,
    };

    const owned = try allocator.alloc(OwnedExchange, exchange_values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |*exchange| exchange.deinit(allocator);
        allocator.free(owned);
    }
    for (exchange_values, owned) |value, *exchange| {
        exchange.* = try parseExchange(allocator, value, format_version);
        initialized += 1;
    }

    const recordings = try allocator.alloc(RecordedExchange, owned.len);
    for (owned, recordings) |exchange, *recording| {
        recording.* = .{
            .request_method = exchange.request_method,
            .request_url = exchange.request_url,
            .request_url_redaction_template = exchange.request_url_redaction_template,
            .request_headers = exchange.request_headers,
            .request_body = exchange.request_body,
            .response_status = exchange.response_status,
            .response_body = exchange.response_body,
            .response_headers = exchange.response_headers,
            .outcome = exchange.outcome,
            .error_category = exchange.error_category,
        };
    }
    return .{
        .allocator = allocator,
        .owned = owned,
        .recordings = recordings,
    };
}

/// Construct the canonical Core runtime while selecting transport and crypto
/// independently. Both descriptors are copied and borrow their contexts.
pub fn initHttpRuntime(
    transport: core.http.HttpTransport,
    crypto_provider: core.crypto.CryptoProvider,
) core.http.HttpRuntime {
    return core.http.HttpRuntime.init(transport, crypto_provider);
}

/// Caller-serialized playback transport.
///
/// The returned descriptor borrows this value. Keep it alive until all
/// descriptor copies and open operations are deinitialized. Each recording is
/// one raw transport invocation and is consumed when its recorded pre-response
/// error is returned or its response head has been allocated, including
/// redirect and retry attempts. A cooperative upload cancellation consumes a
/// matching recorded cancelled-open prefix; preflight cancellation and
/// cancellation against a non-cancelled attempt do not advance playback.
pub const PlaybackTransport = struct {
    recordings: []const RecordedExchange,
    index: usize = 0,
    allocator: std.mem.Allocator,
    open_count: usize = 0,
    finish_count: usize = 0,
    abort_count: usize = 0,
    cancel_count: usize = 0,
    deinit_count: usize = 0,

    const vtable: core.http.HttpTransport.VTable = .{
        .send = &sendImpl,
        .open = &openImpl,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        recordings: []const RecordedExchange,
    ) PlaybackTransport {
        return .{ .recordings = recordings, .allocator = allocator };
    }

    pub fn asTransport(self: *PlaybackTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn matchNext(
        self: *PlaybackTransport,
        request: *const core.http.Request,
        body: ?[]const u8,
    ) !RecordedExchange {
        if (self.index >= self.recordings.len) return error.NoMoreRecordings;
        const exchange = self.recordings[self.index];
        if ((exchange.outcome == .response) !=
            (exchange.error_category == null))
        {
            return error.InvalidRecordedOutcome;
        }
        try matchRequest(exchange, request, body);
        return exchange;
    }

    fn sendImpl(
        context: *anyopaque,
        request: *core.http.Request,
    ) !core.http.Response {
        const self: *PlaybackTransport = @ptrCast(@alignCast(context));
        const exchange = try self.matchNext(request, request.body);
        if (exchange.outcome != .response) {
            if (exchange.outcome != .transport_error)
                return error.RecordedOutcomeStageMismatch;
            self.index += 1;
            return replayRecordedError(exchange.error_category);
        }
        const response = try responseFromExchange(
            self.allocator,
            exchange,
        );
        self.index += 1;
        return response;
    }

    fn openImpl(
        context: *anyopaque,
        request: *core.http.Request,
        options: core.http.OpenOptions,
    ) !*core.http.HttpOperation {
        const self: *PlaybackTransport = @ptrCast(@alignCast(context));
        if (options.body != null and request.body != null)
            return error.MultipleRequestBodies;
        try checkCancelled(options.cancellation);
        try validateRequestFraming(request, options);

        var captured: ?[]u8 = null;
        defer if (captured) |body| self.allocator.free(body);
        const expected = if (self.index < self.recordings.len)
            self.recordings[self.index]
        else
            null;
        const body: ?[]const u8 = if (options.body) |streaming| blk: {
            if (expected) |exchange| {
                if (exchange.outcome == .open_error) {
                    const expected_body = exchange.request_body orelse
                        return error.BodyMismatch;
                    captured = try readRequestBodyPrefix(
                        self.allocator,
                        streaming,
                        expected_body.len,
                    );
                    if (isCancelled(options.cancellation)) {
                        if (exchange.error_category == .cancelled) {
                            try matchRequest(
                                exchange,
                                request,
                                captured.?,
                            );
                            self.index += 1;
                        }
                        return error.OperationCancelled;
                    }
                    break :blk captured.?;
                }
            }
            captured = try readRequestBody(
                self.allocator,
                streaming,
                options.cancellation,
            );
            break :blk captured.?;
        } else request.body;

        const exchange = try self.matchNext(request, body);
        if (exchange.outcome == .transport_error or
            exchange.outcome == .open_error)
        {
            if (exchange.outcome != .open_error)
                return error.RecordedOutcomeStageMismatch;
            self.index += 1;
            return replayRecordedError(exchange.error_category);
        }
        const operation = try PlaybackOperation.create(self, exchange);
        self.index += 1;
        self.open_count += 1;
        return operation;
    }
};

const PlaybackOperation = struct {
    operation: core.http.HttpOperation,
    allocator: std.mem.Allocator,
    owner: *PlaybackTransport,
    response_body: []u8,
    reader_impl: PlaybackBodyReader,
    outcome: RecordedOutcome,
    error_category: ?RecordedErrorCategory,

    fn create(
        owner: *PlaybackTransport,
        exchange: RecordedExchange,
    ) !*core.http.HttpOperation {
        const self = try owner.allocator.create(PlaybackOperation);
        errdefer owner.allocator.destroy(self);
        const body = try owner.allocator.dupe(u8, exchange.response_body);
        errdefer owner.allocator.free(body);
        var header_set = try responseHeaderSet(
            owner.allocator,
            exchange.response_headers,
        );
        errdefer header_set.deinit(owner.allocator);

        self.* = .{
            .operation = undefined,
            .allocator = owner.allocator,
            .owner = owner,
            .response_body = body,
            .reader_impl = undefined,
            .outcome = exchange.outcome,
            .error_category = exchange.error_category,
        };
        self.reader_impl.init(
            body,
            exchange.outcome == .body_error,
            exchange.error_category,
        );
        self.operation = .{
            .status_code = exchange.response_status,
            .headers = header_set.map,
            .response_headers = header_set.ordered,
            .body_reader = &self.reader_impl.interface,
            .finishFn = &finishImpl,
            .abortFn = &abortImpl,
            .cancelFn = &cancelImpl,
            .deinitFn = &deinitImpl,
            .bodyErrorFn = &bodyErrorImpl,
        };
        return &self.operation;
    }

    fn finishImpl(operation: *core.http.HttpOperation) !void {
        const self: *PlaybackOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        _ = self.reader_impl.interface.discardRemaining() catch
            return replayRecordedError(self.error_category);
        if (self.outcome == .finish_error)
            return replayRecordedError(self.error_category);
        self.owner.finish_count += 1;
    }

    fn abortImpl(operation: *core.http.HttpOperation) void {
        const self: *PlaybackOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        self.owner.abort_count += 1;
    }

    fn cancelImpl(operation: *core.http.HttpOperation) void {
        const self: *PlaybackOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        self.owner.cancel_count += 1;
    }

    fn bodyErrorImpl(operation: *const core.http.HttpOperation) ?anyerror {
        const self: *const PlaybackOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        if (self.outcome != .body_error) return null;
        return recordedErrorValue(self.error_category);
    }

    fn deinitImpl(operation: *core.http.HttpOperation) void {
        const self: *PlaybackOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        self.owner.deinit_count += 1;
        deinitResponseStorage(
            self.allocator,
            &self.operation.headers,
            &self.operation.response_headers,
        );
        self.allocator.free(self.response_body);
        self.allocator.destroy(self);
    }
};

const PlaybackBodyReader = struct {
    interface: std.Io.Reader,
    bytes: []const u8,
    offset: usize = 0,
    fail_after_body: bool,

    fn init(
        self: *PlaybackBodyReader,
        bytes: []u8,
        fail_after_body: bool,
        _: ?RecordedErrorCategory,
    ) void {
        self.* = .{
            .interface = undefined,
            .bytes = bytes,
            .fail_after_body = fail_after_body,
        };
        self.interface = .{
            .vtable = &.{
                .stream = &stream,
                .readVec = &readVec,
            },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(
        interface: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *PlaybackBodyReader =
            @alignCast(@fieldParentPtr("interface", interface));
        if (self.offset != self.bytes.len) {
            const count = @min(
                limit.minInt(self.bytes.len - self.offset),
                self.bytes.len - self.offset,
            );
            if (count == 0) return 0;
            try writer.writeAll(self.bytes[self.offset..][0..count]);
            self.offset += count;
            return count;
        }
        if (self.fail_after_body) return error.ReadFailed;
        return error.EndOfStream;
    }

    fn readVec(
        interface: *std.Io.Reader,
        data: [][]u8,
    ) std.Io.Reader.Error!usize {
        const self: *PlaybackBodyReader =
            @alignCast(@fieldParentPtr("interface", interface));
        var total: usize = 0;
        for (data) |destination| {
            const count = @min(
                destination.len,
                self.bytes.len - self.offset,
            );
            @memcpy(
                destination[0..count],
                self.bytes[self.offset..][0..count],
            );
            self.offset += count;
            total += count;
            if (self.offset == self.bytes.len) break;
        }
        if (total != 0) return total;
        if (self.fail_after_body) return error.ReadFailed;
        return error.EndOfStream;
    }
};

fn recordedErrorValue(category: ?RecordedErrorCategory) anyerror {
    return switch (category orelse .unknown) {
        .cancelled => error.OperationCancelled,
        .timeout => error.RecordedTimeout,
        .connection => error.RecordedConnectionFailure,
        .tls => error.RecordedTlsFailure,
        .protocol => error.RecordedProtocolFailure,
        .io => error.RecordedIoFailure,
        .resource_exhausted => error.RecordedResourceExhausted,
        .unsupported => error.RecordedUnsupported,
        .unknown => error.RecordedUnknownFailure,
    };
}

fn replayRecordedError(category: ?RecordedErrorCategory) anyerror {
    return recordedErrorValue(category);
}

fn classifyRecordedError(err: anyerror) RecordedErrorCategory {
    const name = @errorName(err);
    if (containsIgnoreCase(name, "cancel")) return .cancelled;
    if (containsIgnoreCase(name, "timeout") or
        containsIgnoreCase(name, "timedout"))
    {
        return .timeout;
    }
    if (std.mem.eql(u8, name, "OutOfMemory") or
        containsIgnoreCase(name, "resourceexhaust"))
    {
        return .resource_exhausted;
    }
    if (containsIgnoreCase(name, "tls") or
        containsIgnoreCase(name, "ssl") or
        containsIgnoreCase(name, "certificate"))
    {
        return .tls;
    }
    if (containsIgnoreCase(name, "connection") or
        containsIgnoreCase(name, "network") or
        containsIgnoreCase(name, "socket") or
        containsIgnoreCase(name, "dns") or
        containsIgnoreCase(name, "hostnotfound") or
        containsIgnoreCase(name, "brokenpipe"))
    {
        return .connection;
    }
    if (containsIgnoreCase(name, "unsupported") or
        containsIgnoreCase(name, "notimplemented"))
    {
        return .unsupported;
    }
    if (containsIgnoreCase(name, "read") or
        containsIgnoreCase(name, "write") or
        containsIgnoreCase(name, "inputoutput") or
        containsIgnoreCase(name, "ioerror"))
    {
        return .io;
    }
    if (containsIgnoreCase(name, "protocol") or
        containsIgnoreCase(name, "http") or
        containsIgnoreCase(name, "invalidresponse") or
        containsIgnoreCase(name, "malformed"))
    {
        return .protocol;
    }
    return .unknown;
}

const RecordingMutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *RecordingMutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *RecordingMutex) void {
        self.state.unlock();
    }
};

/// Recording transport wrapping a full Core descriptor.
///
/// The inner descriptor is copied by value. Its context, this recording
/// transport, and the recording allocator must outlive every open operation.
/// A configured body-policy context is also borrowed and must outlive calls to
/// `toJson`. Each exchange is one completed raw transport attempt, including
/// redirect, retry, and stable staged failure outcomes. Post-dispatch
/// bookkeeping failure poisons serialization rather than omitting an attempt.
/// Attempt ordering, finalization, and all recorder-owned allocator calls are
/// internally synchronized, so the supplied allocator need not be
/// thread-safe. Borrowed slices from `getExchanges`, policy contexts, and
/// lifecycle calls still require caller synchronization. `deinit` does not
/// deinitialize either borrowed context.
pub const RecordingTransport = struct {
    inner: core.http.HttpTransport,
    exchanges: std.ArrayList(OwnedExchange) = .empty,
    allocator: std.mem.Allocator,
    options: RecordingOptions,
    mutex: RecordingMutex = .{},
    allocator_mutex: RecordingMutex = .{},
    poisoned: bool = false,

    const vtable: core.http.HttpTransport.VTable = .{
        .send = &sendImpl,
        .open = &openImpl,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        inner: core.http.HttpTransport,
    ) RecordingTransport {
        return initWithOptions(allocator, inner, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        inner: core.http.HttpTransport,
        options: RecordingOptions,
    ) RecordingTransport {
        return .{
            .inner = inner,
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn asTransport(self: *RecordingTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn deinit(self: *RecordingTransport) void {
        const allocator = self.synchronizedAllocator();
        for (self.exchanges.items) |*exchange| {
            exchange.deinit(allocator);
        }
        self.exchanges.deinit(allocator);
        self.* = undefined;
    }

    /// Borrow all slots in dispatch order. Unresolved active slots have
    /// `resolved == false`; do not retain this slice across concurrent calls.
    pub fn getExchanges(self: *const RecordingTransport) []const OwnedExchange {
        return self.exchanges.items;
    }

    fn synchronizedAllocator(self: *RecordingTransport) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &synchronized_allocator_vtable,
        };
    }

    const synchronized_allocator_vtable: std.mem.Allocator.VTable = .{
        .alloc = &synchronizedAlloc,
        .resize = &synchronizedResize,
        .remap = &synchronizedRemap,
        .free = &synchronizedFree,
    };

    fn synchronizedAlloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.allocator_mutex.lock();
        defer self.allocator_mutex.unlock();
        return self.allocator.vtable.alloc(
            self.allocator.ptr,
            len,
            alignment,
            return_address,
        );
    }

    fn synchronizedResize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.allocator_mutex.lock();
        defer self.allocator_mutex.unlock();
        return self.allocator.vtable.resize(
            self.allocator.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn synchronizedRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.allocator_mutex.lock();
        defer self.allocator_mutex.unlock();
        return self.allocator.vtable.remap(
            self.allocator.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn synchronizedFree(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.allocator_mutex.lock();
        defer self.allocator_mutex.unlock();
        self.allocator.vtable.free(
            self.allocator.ptr,
            memory,
            alignment,
            return_address,
        );
    }

    /// False when post-dispatch bookkeeping failed or an open operation was
    /// deinitialized without a terminal event. `toJson` then returns
    /// `error.IncompleteRecording`.
    pub fn isComplete(self: *const RecordingTransport) bool {
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        return self.isCompleteLocked();
    }

    fn isCompleteLocked(self: *const RecordingTransport) bool {
        if (self.poisoned) return false;
        for (self.exchanges.items) |exchange| {
            if (!exchange.resolved) return false;
        }
        return true;
    }

    fn ensureCanDispatch(self: *RecordingTransport) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.poisoned) return error.IncompleteRecording;
    }

    fn reserveAttempt(
        self: *RecordingTransport,
        pending: *PendingRequest,
    ) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.poisoned) return error.IncompleteRecording;
        try self.exchanges.ensureUnusedCapacity(
            self.synchronizedAllocator(),
            1,
        );
        const ticket = self.exchanges.items.len;
        self.exchanges.appendAssumeCapacity(pending.intoSlot());
        return ticket;
    }

    fn setRequestBody(
        self: *RecordingTransport,
        ticket: usize,
        body: []u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = &self.exchanges.items[ticket];
        std.debug.assert(!slot.resolved);
        std.debug.assert(slot.request_body == null);
        slot.request_body = body;
    }

    fn finalizePreResponse(
        self: *RecordingTransport,
        ticket: usize,
        outcome: RecordedOutcome,
        category: RecordedErrorCategory,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = &self.exchanges.items[ticket];
        std.debug.assert(!slot.resolved);
        slot.outcome = outcome;
        slot.error_category = category;
        slot.resolved = true;
    }

    fn finalizeResponse(
        self: *RecordingTransport,
        ticket: usize,
        response: OwnedResponse,
        outcome: RecordedOutcome,
        category: ?RecordedErrorCategory,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = &self.exchanges.items[ticket];
        std.debug.assert(!slot.resolved);
        const allocator = self.synchronizedAllocator();
        allocator.free(slot.response_body);
        deinitHeaderPairs(allocator, slot.response_headers);
        slot.response_status = response.status;
        slot.response_body = response.body;
        slot.response_body_allocation = response.body_allocation;
        slot.response_headers = response.headers;
        slot.outcome = outcome;
        slot.error_category = category;
        slot.resolved = true;
    }

    fn poisonAttempt(self: *RecordingTransport, ticket: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(ticket < self.exchanges.items.len);
        self.poisoned = true;
    }

    /// Serialize version 3 recordings with lossless base64 bodies and stable
    /// raw-attempt failure outcomes while
    /// redacting sensitive header values and sensitive URL query parameters.
    ///
    /// Every non-empty body requires a configured `bodyPolicyFn`. Returning
    /// `.inspect` explicitly opts supported text into built-in checks;
    /// `.allow_opaque` is the caller's trust boundary for known-safe opaque
    /// content.
    /// Generated URL wildcard locations are serialized as explicit templates;
    /// literal `REDACTED` URL values remain exact-match data.
    /// Non-UTF-8 URL and header bytes use explicit lossless base64 metadata
    /// objects rather than being emitted as invalid JSON strings.
    ///
    /// Structurally recognized credential-bearing JSON, form, connection
    /// string, XML, and private-key bodies cause
    /// `error.SensitiveBodyRequiresSanitization`. Malformed JSON-like bodies
    /// and unapproved opaque encodings cause an explicit error; neither is
    /// silently emitted under a false sanitization guarantee.
    pub fn toJson(
        self: *const RecordingTransport,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const mutable = @constCast(self);
        const output_allocator = if (allocator.ptr == self.allocator.ptr and
            allocator.vtable == self.allocator.vtable)
            mutable.synchronizedAllocator()
        else
            allocator;
        var output: std.Io.Writer.Allocating = .init(output_allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        self.writeJson(writer, output_allocator) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        return output.toOwnedSlice();
    }

    fn writeJson(
        self: *const RecordingTransport,
        writer: *std.Io.Writer,
        allocator: std.mem.Allocator,
    ) !void {
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        if (!self.isCompleteLocked()) return error.IncompleteRecording;
        try writer.print(
            "{{\"version\":{d},\"exchanges\":[",
            .{recording_format_version},
        );
        for (self.exchanges.items, 0..) |exchange, index| {
            try ensureExchangeBodySafe(
                allocator,
                self.options,
                exchange,
                .request,
            );
            const has_response = exchange.outcome == .response or
                exchange.outcome == .body_error or
                exchange.outcome == .finish_error;
            if (has_response) {
                try ensureExchangeBodySafe(
                    allocator,
                    self.options,
                    exchange,
                    .response,
                );
            }
            if ((exchange.outcome == .response) !=
                (exchange.error_category == null))
            {
                return error.InvalidRecordedOutcome;
            }
            if (index != 0) try writer.writeAll(",");
            try writer.writeAll("\n  {\"request_method\":");
            try writeJsonString(writer, methodToString(exchange.request_method));
            try writer.writeAll(",\"request_url\":");
            const sanitized_request_url = try sanitizeUrlAlloc(
                allocator,
                exchange.request_url,
            );
            defer allocator.free(sanitized_request_url);
            try writeMetadataBytes(
                writer,
                allocator,
                sanitized_request_url,
            );
            try writer.writeAll(",\"request_url_redaction_template\":");
            if (!std.mem.eql(
                u8,
                exchange.request_url,
                sanitized_request_url,
            )) {
                const template = try sanitizeUrlAllocWithMarker(
                    allocator,
                    exchange.request_url,
                    "\x00",
                );
                defer allocator.free(template);
                if (std.mem.indexOfScalar(u8, template, 0) != null)
                    try writeMetadataBytes(writer, allocator, template)
                else
                    try writer.writeAll("null");
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"request_headers\":");
            try writeHeaders(
                writer,
                allocator,
                self.options,
                exchange,
                .request,
            );
            try writer.writeAll(",\"request_body\":");
            try writeOptionalBody(writer, allocator, exchange.request_body);
            try writer.writeAll(",\"outcome\":");
            try writeJsonString(writer, @tagName(exchange.outcome));
            if (exchange.error_category) |category| {
                try writer.writeAll(",\"error_category\":");
                try writeJsonString(writer, @tagName(category));
            }
            if (!has_response) {
                try writer.writeAll("}");
                continue;
            }
            try writer.writeAll(",\"response_status\":");
            try writer.print("{d}", .{exchange.response_status});
            try writer.writeAll(",\"response_headers\":");
            try writeHeaders(
                writer,
                allocator,
                self.options,
                exchange,
                .response,
            );
            try writer.writeAll(",\"response_body\":");
            try writeBody(writer, allocator, exchange.response_body);
            try writer.writeAll("}");
        }
        try writer.writeAll("\n]}\n");
    }

    fn sendImpl(
        context: *anyopaque,
        request: *core.http.Request,
    ) !core.http.Response {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        try self.ensureCanDispatch();
        const allocator = self.synchronizedAllocator();
        var pending = try PendingRequest.init(
            allocator,
            request,
            request.body,
        );
        var pending_owned = true;
        defer if (pending_owned) pending.deinit(allocator);
        const ticket = try self.reserveAttempt(&pending);
        pending_owned = false;

        var response = self.inner.vtable.send(
            self.inner.context,
            request,
        ) catch |err| {
            self.finalizePreResponse(
                ticket,
                .transport_error,
                classifyRecordedError(err),
            );
            return err;
        };
        errdefer response.deinit();
        const owned_response = ownedResponseFromResponse(
            allocator,
            &response,
            response.body,
        ) catch |err| {
            self.poisonAttempt(ticket);
            return err;
        };
        self.finalizeResponse(ticket, owned_response, .response, null);
        return response;
    }

    fn openImpl(
        context: *anyopaque,
        request: *core.http.Request,
        options: core.http.OpenOptions,
    ) !*core.http.HttpOperation {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        try self.ensureCanDispatch();
        const allocator = self.synchronizedAllocator();
        if (options.body != null and request.body != null)
            return error.MultipleRequestBodies;
        try checkCancelled(options.cancellation);
        const open_fn = self.inner.vtable.open;
        if (open_fn == null and options.body != null)
            return error.StreamingRequestUnsupported;

        var pending = try PendingRequest.init(
            allocator,
            request,
            request.body,
        );
        var pending_owned = true;
        defer if (pending_owned) pending.deinit(allocator);
        const ticket = try self.reserveAttempt(&pending);
        pending_owned = false;

        var inner_options = options;
        var request_capture: CapturingReader = undefined;
        var has_capture = false;
        if (options.body) |streaming| {
            request_capture.init(
                allocator,
                streaming.reader,
                null,
            );
            has_capture = true;
            inner_options.body.?.reader = &request_capture.interface;
        }
        defer if (has_capture) request_capture.deinit();

        const inner_operation = if (open_fn) |call_open| blk: {
            const operation = call_open(
                self.inner.context,
                request,
                inner_options,
            ) catch |err| {
                if (has_capture) {
                    if (request_capture.bookkeeping_failed) {
                        self.poisonAttempt(ticket);
                        return error.OutOfMemory;
                    }
                    const captured = request_capture.toOwnedSlice() catch |capture_err| {
                        self.poisonAttempt(ticket);
                        return capture_err;
                    };
                    self.setRequestBody(ticket, captured);
                    if (request_capture.failure) |failure| {
                        self.finalizePreResponse(
                            ticket,
                            .open_error,
                            classifyRecordedError(failure),
                        );
                        return failure;
                    }
                }
                self.finalizePreResponse(
                    ticket,
                    .open_error,
                    classifyRecordedError(err),
                );
                return err;
            };
            break :blk operation;
        } else blk: {
            const response = self.inner.vtable.send(
                self.inner.context,
                request,
            ) catch |err| {
                self.finalizePreResponse(
                    ticket,
                    .open_error,
                    classifyRecordedError(err),
                );
                return err;
            };
            const operation = BufferedInnerOperation.create(response) catch |err| {
                self.poisonAttempt(ticket);
                return err;
            };
            break :blk operation;
        };
        errdefer {
            inner_operation.abort();
            inner_operation.deinit();
        }

        if (has_capture) {
            if (request_capture.bookkeeping_failed) {
                self.poisonAttempt(ticket);
                return error.OutOfMemory;
            }
            const captured = request_capture.toOwnedSlice() catch |err| {
                self.poisonAttempt(ticket);
                return err;
            };
            self.setRequestBody(ticket, captured);
            if (request_capture.failure) |failure| {
                self.finalizePreResponse(
                    ticket,
                    .open_error,
                    classifyRecordedError(failure),
                );
                return failure;
            }
        }
        const operation = RecordingOperation.create(
            self,
            inner_operation,
            ticket,
        ) catch |err| {
            self.poisonAttempt(ticket);
            return err;
        };
        return operation;
    }
};

const PendingRequest = struct {
    method: core.http.Method,
    url: []u8,
    headers: []HeaderPair,
    body: ?[]u8,
    empty_response_body: []u8,
    empty_response_headers: []HeaderPair,

    fn init(
        allocator: std.mem.Allocator,
        request: *const core.http.Request,
        body: ?[]const u8,
    ) !PendingRequest {
        const url = try allocator.dupe(u8, request.url);
        errdefer allocator.free(url);
        const headers = try cloneRequestHeaders(allocator, &request.headers);
        errdefer deinitHeaderPairs(allocator, headers);
        const owned_body = if (body) |bytes|
            try allocator.dupe(u8, bytes)
        else
            null;
        errdefer if (owned_body) |bytes| allocator.free(bytes);
        const empty_response_body = try allocator.dupe(u8, "");
        errdefer allocator.free(empty_response_body);
        const empty_response_headers = try allocator.alloc(HeaderPair, 0);
        return .{
            .method = request.method,
            .url = url,
            .headers = headers,
            .body = owned_body,
            .empty_response_body = empty_response_body,
            .empty_response_headers = empty_response_headers,
        };
    }

    fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        deinitHeaderPairs(allocator, self.headers);
        if (self.body) |body| allocator.free(body);
        allocator.free(self.empty_response_body);
        allocator.free(self.empty_response_headers);
        self.* = undefined;
    }

    fn intoSlot(
        self: *PendingRequest,
    ) OwnedExchange {
        const exchange = OwnedExchange{
            .request_method = self.method,
            .request_url = self.url,
            .request_headers = self.headers,
            .request_body = self.body,
            .response_status = 0,
            .response_body = self.empty_response_body,
            .response_headers = self.empty_response_headers,
            .resolved = false,
        };
        self.* = undefined;
        return exchange;
    }
};

const BufferedInnerOperation = struct {
    operation: core.http.HttpOperation,
    response: core.http.Response,
    reader_impl: std.Io.Reader,

    fn create(
        response_value: core.http.Response,
    ) !*core.http.HttpOperation {
        var response = response_value;
        errdefer response.deinit();
        const self = try response.allocator.create(BufferedInnerOperation);
        self.* = .{
            .operation = undefined,
            .response = response,
            .reader_impl = std.Io.Reader.fixed(response.body),
        };
        self.operation = .{
            .status_code = response.status_code,
            .headers = response.headers,
            .response_headers = response.response_headers,
            .body_reader = &self.reader_impl,
            .finishFn = &finishImpl,
            .abortFn = &abortImpl,
            .cancelFn = &abortImpl,
            .deinitFn = &deinitImpl,
        };
        return &self.operation;
    }

    fn finishImpl(operation: *core.http.HttpOperation) !void {
        const self: *BufferedInnerOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        _ = try self.reader_impl.discardRemaining();
    }

    fn abortImpl(_: *core.http.HttpOperation) void {}

    fn deinitImpl(operation: *core.http.HttpOperation) void {
        const self: *BufferedInnerOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        const allocator = self.response.allocator;
        self.response.deinit();
        allocator.destroy(self);
    }
};

const RecordingOperation = struct {
    operation: core.http.HttpOperation,
    allocator: std.mem.Allocator,
    owner: *RecordingTransport,
    inner: *core.http.HttpOperation,
    ticket: ?usize,
    attempt_headers: ?[]HeaderPair,
    response_reader: CapturingReader,

    fn create(
        owner: *RecordingTransport,
        inner: *core.http.HttpOperation,
        ticket: usize,
    ) !*core.http.HttpOperation {
        const allocator = owner.synchronizedAllocator();
        const self = try allocator.create(RecordingOperation);
        errdefer allocator.destroy(self);
        var header_set = try cloneOperationHeaders(allocator, inner);
        errdefer header_set.deinit(allocator);
        const inner_reader = try inner.reader();
        const attempt_headers = try cloneResponseHeaders(
            allocator,
            &inner.headers,
            &inner.response_headers,
        );
        errdefer deinitHeaderPairs(allocator, attempt_headers);

        self.* = .{
            .operation = undefined,
            .allocator = allocator,
            .owner = owner,
            .inner = inner,
            .ticket = ticket,
            .attempt_headers = attempt_headers,
            .response_reader = undefined,
        };
        self.response_reader.init(allocator, inner_reader, inner);
        self.operation = .{
            .status_code = inner.status_code,
            .headers = header_set.map,
            .response_headers = header_set.ordered,
            .body_reader = &self.response_reader.interface,
            .finishFn = &finishImpl,
            .abortFn = &abortImpl,
            .cancelFn = &cancelImpl,
            .deinitFn = &deinitImpl,
            .bodyErrorFn = &bodyErrorImpl,
        };
        return &self.operation;
    }

    fn completeAttempt(
        self: *RecordingOperation,
        outcome: RecordedOutcome,
        category: ?RecordedErrorCategory,
    ) void {
        const ticket = self.ticket orelse return;
        self.ticket = null;
        const response_headers = self.attempt_headers.?;
        self.attempt_headers = null;
        const captured = self.response_reader.captured.toArrayList();
        const allocation = captured.allocatedSlice();
        self.owner.finalizeResponse(
            ticket,
            .{
                .status = self.operation.status_code,
                .body = allocation[0..captured.items.len],
                .body_allocation = if (allocation.len == 0)
                    null
                else
                    allocation,
                .headers = response_headers,
            },
            outcome,
            category,
        );
    }

    fn poisonIncompleteAttempt(self: *RecordingOperation) void {
        if (self.ticket) |ticket| {
            self.ticket = null;
            if (self.attempt_headers) |headers| {
                deinitHeaderPairs(self.allocator, headers);
                self.attempt_headers = null;
            }
            self.owner.poisonAttempt(ticket);
        }
    }

    fn finishImpl(operation: *core.http.HttpOperation) !void {
        const self: *RecordingOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        _ = self.response_reader.interface.discardRemaining() catch |err| {
            if (self.response_reader.bookkeeping_failed) {
                self.poisonIncompleteAttempt();
                return error.OutOfMemory;
            }
            if (self.response_reader.failure) |failure| {
                self.completeAttempt(
                    .body_error,
                    classifyRecordedError(failure),
                );
                return failure;
            }
            if (self.inner.bodyError()) |failure| {
                self.completeAttempt(
                    .body_error,
                    classifyRecordedError(failure),
                );
                return failure;
            }
            self.completeAttempt(
                .body_error,
                classifyRecordedError(err),
            );
            return err;
        };
        self.inner.finish() catch |err| {
            self.completeAttempt(
                .finish_error,
                classifyRecordedError(err),
            );
            return err;
        };
        if (self.response_reader.failure) |failure| {
            self.completeAttempt(
                .body_error,
                classifyRecordedError(failure),
            );
            return failure;
        }
        self.completeAttempt(.response, null);
    }

    fn abortImpl(operation: *core.http.HttpOperation) void {
        const self: *RecordingOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        self.inner.abort();
        if (self.response_reader.bookkeeping_failed) {
            self.poisonIncompleteAttempt();
            return;
        }
        if (self.response_reader.failure) |failure| {
            self.completeAttempt(
                .body_error,
                classifyRecordedError(failure),
            );
        } else if (self.inner.bodyError()) |failure| {
            self.completeAttempt(
                .body_error,
                classifyRecordedError(failure),
            );
        } else {
            self.completeAttempt(.response, null);
        }
    }

    fn cancelImpl(operation: *core.http.HttpOperation) void {
        const self: *RecordingOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        self.inner.cancel();
        if (self.response_reader.bookkeeping_failed) {
            self.poisonIncompleteAttempt();
            return;
        }
        if (self.response_reader.failure) |failure| {
            self.completeAttempt(
                .body_error,
                classifyRecordedError(failure),
            );
        } else if (self.inner.bodyError()) |failure| {
            self.completeAttempt(
                .body_error,
                classifyRecordedError(failure),
            );
        } else {
            self.completeAttempt(.response, null);
        }
    }

    fn bodyErrorImpl(operation: *const core.http.HttpOperation) ?anyerror {
        const self: *const RecordingOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        if (self.response_reader.failure) |failure| return failure;
        return self.inner.bodyError();
    }

    fn deinitImpl(operation: *core.http.HttpOperation) void {
        const self: *RecordingOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        self.inner.deinit();
        if (self.ticket != null) self.poisonIncompleteAttempt();
        if (self.attempt_headers) |headers| {
            deinitHeaderPairs(self.allocator, headers);
        }
        self.response_reader.deinit();
        deinitResponseStorage(
            self.allocator,
            &self.operation.headers,
            &self.operation.response_headers,
        );
        self.allocator.destroy(self);
    }
};

const CapturingReader = struct {
    interface: std.Io.Reader,
    source: *std.Io.Reader,
    captured: std.Io.Writer.Allocating,
    source_operation: ?*core.http.HttpOperation,
    failure: ?anyerror = null,
    bookkeeping_failed: bool = false,
    scratch: [4096]u8 = undefined,

    fn init(
        self: *CapturingReader,
        allocator: std.mem.Allocator,
        source: *std.Io.Reader,
        source_operation: ?*core.http.HttpOperation,
    ) void {
        self.* = .{
            .interface = undefined,
            .source = source,
            .captured = .init(allocator),
            .source_operation = source_operation,
        };
        self.interface = .{
            .vtable = &.{ .stream = &stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(
        interface: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *CapturingReader =
            @alignCast(@fieldParentPtr("interface", interface));
        const length = limit.minInt(self.scratch.len);
        if (length == 0) return 0;
        const count = self.source.readSliceShort(self.scratch[0..length]) catch |err| {
            self.failure = if (self.source_operation) |operation|
                operation.bodyError() orelse err
            else
                err;
            return error.ReadFailed;
        };
        if (count == 0) {
            if (self.source_operation) |operation| {
                if (operation.bodyError()) |failure| {
                    self.failure = failure;
                    return error.ReadFailed;
                }
            }
            return error.EndOfStream;
        }
        self.captured.writer.writeAll(self.scratch[0..count]) catch {
            self.failure = error.OutOfMemory;
            self.bookkeeping_failed = true;
            return error.ReadFailed;
        };
        try writer.writeAll(self.scratch[0..count]);
        return count;
    }

    fn toOwnedSlice(self: *CapturingReader) ![]u8 {
        const result = try self.captured.toOwnedSlice();
        self.captured = .init(self.captured.allocator);
        return result;
    }

    fn deinit(self: *CapturingReader) void {
        self.captured.deinit();
    }
};

const ResponseHeaderSet = struct {
    map: std.StringHashMap([]const u8),
    ordered: core.http.ResponseHeaders,

    fn deinit(self: *ResponseHeaderSet, allocator: std.mem.Allocator) void {
        deinitOwnedHeaderMap(allocator, &self.map);
        self.ordered.deinit();
    }
};

fn responseFromExchange(
    allocator: std.mem.Allocator,
    exchange: RecordedExchange,
) !core.http.Response {
    const body = try allocator.dupe(u8, exchange.response_body);
    errdefer allocator.free(body);
    var header_set = try responseHeaderSet(allocator, exchange.response_headers);
    errdefer header_set.deinit(allocator);
    return .{
        .status_code = exchange.response_status,
        .headers = header_set.map,
        .body = body,
        .allocator = allocator,
        .response_headers = header_set.ordered,
    };
}

fn responseHeaderSet(
    allocator: std.mem.Allocator,
    headers: []const HeaderPair,
) !ResponseHeaderSet {
    var result = ResponseHeaderSet{
        .map = std.StringHashMap([]const u8).init(allocator),
        .ordered = core.http.ResponseHeaders.init(allocator),
    };
    errdefer result.deinit(allocator);
    for (headers) |header| {
        try result.ordered.append(header.name, header.value);
        try putOwnedHeader(allocator, &result.map, header.name, header.value);
    }
    return result;
}

fn cloneOperationHeaders(
    allocator: std.mem.Allocator,
    operation: *const core.http.HttpOperation,
) !ResponseHeaderSet {
    const pairs = try cloneResponseHeaders(
        allocator,
        &operation.headers,
        &operation.response_headers,
    );
    defer deinitHeaderPairs(allocator, pairs);
    return responseHeaderSet(allocator, pairs);
}

fn cloneResponseHeaders(
    allocator: std.mem.Allocator,
    map: *const std.StringHashMap([]const u8),
    ordered: *const core.http.ResponseHeaders,
) ![]HeaderPair {
    if (ordered.entries.items.len != 0) {
        const result = try allocator.alloc(HeaderPair, ordered.entries.items.len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(result);
        }
        for (ordered.entries.items, result) |header, *pair| {
            pair.* = .{
                .name = try allocator.dupe(u8, header.name),
                .value = undefined,
            };
            errdefer allocator.free(pair.name);
            pair.value = try allocator.dupe(u8, header.value);
            initialized += 1;
        }
        return result;
    }

    const result = try allocator.alloc(HeaderPair, map.count());
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(result);
    }
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        result[initialized] = .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .value = undefined,
        };
        errdefer allocator.free(result[initialized].name);
        result[initialized].value = try allocator.dupe(u8, entry.value_ptr.*);
        initialized += 1;
    }
    return result;
}

const OwnedResponse = struct {
    status: u16,
    body: []u8,
    body_allocation: ?[]u8 = null,
    headers: []HeaderPair,
};

fn ownedResponseFromResponse(
    allocator: std.mem.Allocator,
    response: *const core.http.Response,
    response_body: []const u8,
) !OwnedResponse {
    const body = try allocator.dupe(u8, response_body);
    errdefer allocator.free(body);
    const headers = try cloneResponseHeaders(
        allocator,
        &response.headers,
        &response.response_headers,
    );
    return .{
        .status = response.status_code,
        .body = body,
        .headers = headers,
    };
}

fn parseExchange(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    format_version: u32,
) !OwnedExchange {
    const object = switch (value) {
        .object => |result| result,
        else => return error.InvalidRecordingJson,
    };
    const method_value = object.get("request_method") orelse
        return error.InvalidRecordingJson;
    const request_url_value = object.get("request_url") orelse
        return error.InvalidRecordingJson;
    const request_url_redaction_template: ?[]u8 =
        if (format_version == 2 or
        object.get("request_url_redaction_template") == null)
            null
        else
            try parseOptionalMetadataBytes(
                allocator,
                object.get("request_url_redaction_template").?,
            );
    errdefer if (request_url_redaction_template) |template|
        allocator.free(template);
    const request_headers_value = object.get("request_headers") orelse
        return error.InvalidRecordingJson;
    const request_body_value = object.get("request_body") orelse
        return error.InvalidRecordingJson;
    const method = try parseMethod(try jsonString(method_value));
    const request_url = try parseMetadataBytes(allocator, request_url_value);
    errdefer allocator.free(request_url);
    if (request_url_redaction_template) |template|
        try validateUrlRedactionTemplate(request_url, template);
    const request_headers = try parseHeaders(allocator, request_headers_value);
    errdefer deinitHeaderPairs(allocator, request_headers);
    const request_body = try parseOptionalBody(allocator, request_body_value);
    errdefer if (request_body) |body| allocator.free(body);

    const outcome = if (format_version == 2)
        RecordedOutcome.response
    else
        try parseRecordedOutcome(object.get("outcome") orelse
            return error.InvalidRecordingJson);
    const error_category = if (outcome == .response) blk: {
        if (object.get("error_category") != null)
            return error.InvalidRecordingJson;
        break :blk null;
    } else try parseRecordedErrorCategory(
        object.get("error_category") orelse
            return error.InvalidRecordingJson,
    );
    const has_response = outcome == .response or
        outcome == .body_error or
        outcome == .finish_error;
    if (!has_response) {
        const response_body = try allocator.dupe(u8, "");
        errdefer allocator.free(response_body);
        const response_headers = try allocator.alloc(HeaderPair, 0);
        return .{
            .request_method = method,
            .request_url = request_url,
            .request_url_redaction_template = request_url_redaction_template,
            .request_headers = request_headers,
            .request_body = request_body,
            .response_status = 0,
            .response_body = response_body,
            .response_headers = response_headers,
            .outcome = outcome,
            .error_category = error_category,
        };
    }

    const response_status_value = object.get("response_status") orelse
        return error.InvalidRecordingJson;
    const response_headers_value = object.get("response_headers") orelse
        return error.InvalidRecordingJson;
    const response_body_value = object.get("response_body") orelse
        return error.InvalidRecordingJson;
    const response_status_integer = switch (response_status_value) {
        .integer => |result| result,
        else => return error.InvalidRecordingJson,
    };
    if (response_status_integer < 0 or response_status_integer > 65535)
        return error.InvalidRecordingJson;
    const response_headers = try parseHeaders(allocator, response_headers_value);
    errdefer deinitHeaderPairs(allocator, response_headers);
    const response_body = try parseBody(allocator, response_body_value);
    errdefer allocator.free(response_body);

    return .{
        .request_method = method,
        .request_url = request_url,
        .request_url_redaction_template = request_url_redaction_template,
        .request_headers = request_headers,
        .request_body = request_body,
        .response_status = @intCast(response_status_integer),
        .response_body = response_body,
        .response_headers = response_headers,
        .outcome = outcome,
        .error_category = error_category,
    };
}

fn parseRecordedOutcome(value: std.json.Value) !RecordedOutcome {
    const name = try jsonString(value);
    inline for (std.meta.fields(RecordedOutcome)) |field| {
        if (std.mem.eql(u8, name, field.name))
            return @enumFromInt(field.value);
    }
    return error.InvalidRecordingOutcome;
}

fn parseRecordedErrorCategory(
    value: std.json.Value,
) !RecordedErrorCategory {
    const name = try jsonString(value);
    inline for (std.meta.fields(RecordedErrorCategory)) |field| {
        if (std.mem.eql(u8, name, field.name))
            return @enumFromInt(field.value);
    }
    return error.InvalidRecordingErrorCategory;
}

fn parseHeaders(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]HeaderPair {
    const values = switch (value) {
        .array => |result| result.items,
        else => return error.InvalidRecordingJson,
    };
    const headers = try allocator.alloc(HeaderPair, values.len);
    var initialized: usize = 0;
    errdefer {
        for (headers[0..initialized]) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
            if (header.url_redaction_template) |template|
                allocator.free(template);
        }
        allocator.free(headers);
    }
    for (values, headers) |header_value, *header| {
        const object = switch (header_value) {
            .object => |result| result,
            else => return error.InvalidRecordingJson,
        };
        const name_value = object.get("name") orelse
            return error.InvalidRecordingJson;
        const field_value = object.get("value") orelse
            return error.InvalidRecordingJson;
        const redacted_value_json = object.get("redacted");
        const redacted = if (redacted_value_json) |flag| switch (flag) {
            .bool => |result| result,
            else => return error.InvalidRecordingJson,
        } else false;
        const url_redaction_template: ?[]u8 =
            if (object.get("url_redaction_template")) |template_value|
                try parseOptionalMetadataBytes(allocator, template_value)
            else
                null;
        errdefer if (url_redaction_template) |template|
            allocator.free(template);
        header.name = try parseMetadataBytes(allocator, name_value);
        errdefer allocator.free(header.name);
        header.value = try parseMetadataBytes(allocator, field_value);
        errdefer allocator.free(header.value);
        header.redacted = redacted;
        header.url_redaction_template = url_redaction_template;
        if (url_redaction_template) |template|
            try validateUrlRedactionTemplate(header.value, template);
        initialized += 1;
    }
    return headers;
}

fn parseOptionalBody(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !?[]u8 {
    return switch (value) {
        .null => null,
        else => try parseBody(allocator, value),
    };
}

fn parseBody(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    const object = switch (value) {
        .object => |result| result,
        else => return error.InvalidRecordingJson,
    };
    const encoding_value = object.get("encoding") orelse
        return error.InvalidRecordingJson;
    const data_value = object.get("data") orelse
        return error.InvalidRecordingJson;
    if (!std.mem.eql(u8, try jsonString(encoding_value), "base64"))
        return error.UnsupportedBodyEncoding;
    const encoded = try jsonString(data_value);
    const length = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
        return error.InvalidRecordingBody;
    const decoded = try allocator.alloc(u8, length);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch
        return error.InvalidRecordingBody;
    return decoded;
}

fn parseMetadataBytes(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    return switch (value) {
        .string => |bytes| allocator.dupe(u8, bytes),
        .object => parseBody(allocator, value),
        else => error.InvalidRecordingJson,
    };
}

fn parseOptionalMetadataBytes(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !?[]u8 {
    return switch (value) {
        .null => null,
        else => try parseMetadataBytes(allocator, value),
    };
}

fn jsonString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |result| result,
        else => error.InvalidRecordingJson,
    };
}

fn validateUrlRedactionTemplate(
    visible: []const u8,
    template: []const u8,
) !void {
    var template_offset: usize = 0;
    var visible_offset: usize = 0;
    var found_marker = false;
    while (std.mem.indexOfScalarPos(
        u8,
        template,
        template_offset,
        0,
    )) |marker_offset| {
        found_marker = true;
        const literal = template[template_offset..marker_offset];
        if (!std.mem.startsWith(u8, visible[visible_offset..], literal))
            return error.InvalidRecordingJson;
        visible_offset += literal.len;
        if (!std.mem.startsWith(
            u8,
            visible[visible_offset..],
            redacted_value,
        ))
            return error.InvalidRecordingJson;
        visible_offset += redacted_value.len;
        template_offset = marker_offset + 1;
    }
    if (!found_marker or
        !std.mem.eql(
            u8,
            visible[visible_offset..],
            template[template_offset..],
        ))
    {
        return error.InvalidRecordingJson;
    }
}

fn parseMethod(value: []const u8) !core.http.Method {
    inline for (std.meta.fields(core.http.Method)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidRecordingMethod;
}

fn matchRequest(
    exchange: RecordedExchange,
    request: *const core.http.Request,
    body: ?[]const u8,
) !void {
    if (exchange.request_method != request.method) return error.MethodMismatch;
    if (!try urlMatches(
        request.allocator,
        exchange.request_url,
        request.url,
        exchange.request_url_redaction_template,
    ))
        return error.UrlMismatch;
    if ((exchange.request_body == null) != (body == null))
        return error.BodyMismatch;
    if (exchange.request_body) |expected| {
        if (!std.mem.eql(u8, expected, body.?)) return error.BodyMismatch;
    }
    for (exchange.request_headers) |expected| {
        const actual = request.getHeader(expected.name) orelse
            return error.HeaderMismatch;
        if (!try headerValueMatches(
            request.allocator,
            expected,
            actual,
        ))
            return error.HeaderMismatch;
    }
}

fn headerValueMatches(
    allocator: std.mem.Allocator,
    expected: HeaderPair,
    actual: []const u8,
) !bool {
    if (expected.redacted) return true;
    if (isSanitizedUrlHeader(expected.name)) {
        const template = expected.url_redaction_template orelse
            return std.mem.eql(u8, expected.value, actual);
        const sanitized = try sanitizeLocationUrlAllocWithMarker(
            allocator,
            actual,
            "\x00",
        );
        defer allocator.free(sanitized);
        return std.mem.eql(u8, template, sanitized);
    }
    return std.mem.eql(u8, expected.value, actual);
}

fn urlMatches(
    allocator: std.mem.Allocator,
    expected: []const u8,
    actual: []const u8,
    redaction_template: ?[]const u8,
) !bool {
    const template = redaction_template orelse
        return std.mem.eql(u8, expected, actual);
    const sanitized = try sanitizeUrlAllocWithMarker(
        allocator,
        actual,
        "\x00",
    );
    defer allocator.free(sanitized);
    return std.mem.eql(u8, template, sanitized);
}

fn validateRequestFraming(
    request: *const core.http.Request,
    options: core.http.OpenOptions,
) !void {
    const content_length = request.getHeader("Content-Length");
    const transfer_encoding = request.getHeader("Transfer-Encoding");
    const framing: union(enum) {
        none,
        content_length: u64,
        chunked,
    } = if (options.body) |body|
        if (body.content_length) |length|
            .{ .content_length = length }
        else
            .chunked
    else if (request.body) |body|
        .{ .content_length = body.len }
    else if (request.method.toStd().requestHasBody())
        .{ .content_length = 0 }
    else
        .none;

    switch (framing) {
        .content_length => |length| {
            if (transfer_encoding != null) return error.ConflictingRequestFraming;
            if (content_length) |value| {
                const parsed = std.fmt.parseInt(u64, std.mem.trim(u8, value, " \t"), 10) catch
                    return error.ConflictingRequestFraming;
                if (parsed != length) return error.ConflictingRequestFraming;
            }
        },
        .chunked => {
            if (content_length != null) return error.ConflictingRequestFraming;
            if (transfer_encoding) |value| {
                if (!std.ascii.eqlIgnoreCase(
                    std.mem.trim(u8, value, " \t"),
                    "chunked",
                )) return error.ConflictingRequestFraming;
            }
        },
        .none => if (content_length != null or transfer_encoding != null)
            return error.ConflictingRequestFraming,
    }
}

fn readRequestBody(
    allocator: std.mem.Allocator,
    body: core.http.StreamingRequestBody,
    cancellation: ?*const core.http.CancellationToken,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var buffer: [4096]u8 = undefined;
    if (body.content_length) |length| {
        var remaining = length;
        while (remaining != 0) {
            try checkCancelled(cancellation);
            const read_length: usize = @intCast(@min(remaining, buffer.len));
            const count = try body.reader.readSliceShort(buffer[0..read_length]);
            try checkCancelled(cancellation);
            if (count == 0) return error.RequestBodyTooShort;
            try output.writer.writeAll(buffer[0..count]);
            remaining -= count;
        }
        var extra: [1]u8 = undefined;
        if (try body.reader.readSliceShort(&extra) != 0)
            return error.RequestBodyTooLong;
    } else {
        while (true) {
            try checkCancelled(cancellation);
            const count = try body.reader.readSliceShort(&buffer);
            try checkCancelled(cancellation);
            if (count == 0) break;
            try output.writer.writeAll(buffer[0..count]);
        }
    }
    return output.toOwnedSlice();
}

fn readRequestBodyPrefix(
    allocator: std.mem.Allocator,
    body: core.http.StreamingRequestBody,
    length: usize,
) ![]u8 {
    const result = try allocator.alloc(u8, length);
    errdefer allocator.free(result);
    body.reader.readSliceAll(result) catch |err| switch (err) {
        error.EndOfStream => return error.RequestBodyTooShort,
        else => return err,
    };
    return result;
}

fn isCancelled(token: ?*const core.http.CancellationToken) bool {
    return if (token) |value| value.isCancelled() else false;
}

fn checkCancelled(token: ?*const core.http.CancellationToken) !void {
    if (isCancelled(token)) return error.OperationCancelled;
}

fn cloneRequestHeaders(
    allocator: std.mem.Allocator,
    headers: *const core.http.RequestHeaders,
) ![]HeaderPair {
    const result = try allocator.alloc(HeaderPair, headers.count());
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(result);
    }
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        result[initialized] = .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .value = undefined,
        };
        errdefer allocator.free(result[initialized].name);
        result[initialized].value = try allocator.dupe(u8, entry.value_ptr.*);
        initialized += 1;
    }
    return result;
}

fn requestHeaderSnapshotFixture(allocator: std.mem.Allocator) !void {
    const expected = [_]HeaderPair{
        .{ .name = "X-Snapshot", .value = "ordinary" },
        .{ .name = "TraceParent", .value = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01" },
        .{ .name = "TrAcEsTaTe", .value = "vendor=opaque" },
    };
    var pending = blk: {
        const source_allocator = std.testing.allocator;
        const url = try source_allocator.dupe(u8, "https://example.test/snapshot");
        defer source_allocator.free(url);
        var request = core.http.Request.init(source_allocator, .POST, url);
        defer request.deinit();
        for (expected) |header| try request.setHeader(header.name, header.value);
        try std.testing.expectEqual(@as(usize, 3), request.headers.count());
        var iterator = request.headers.iterator();
        var count: usize = 0;
        while (iterator.next() != null) count += 1;
        try std.testing.expectEqual(@as(usize, 3), count);
        var body = "payload".*;
        const snapshot = try PendingRequest.init(allocator, &request, &body);
        @memset(&body, 'x');
        request.headers.clearAndFree();
        break :blk snapshot;
    };
    defer pending.deinit(allocator);
    try std.testing.expectEqualStrings("https://example.test/snapshot", pending.url);
    try std.testing.expectEqualStrings("payload", pending.body.?);
    try std.testing.expectEqual(expected.len, pending.headers.len);
    for (expected) |wanted| {
        var found = false;
        for (pending.headers) |header| {
            if (!std.mem.eql(u8, header.name, wanted.name)) continue;
            try std.testing.expectEqualStrings(wanted.value, header.value);
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
}

test "Core 0.4 request snapshots own ordinary and trace headers after source teardown" {
    try requestHeaderSnapshotFixture(std.testing.allocator);
}

test "Core 0.4 request snapshot allocation failures release independently owned headers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, requestHeaderSnapshotFixture, .{});
}

test "Core 0.4 request matching and framing remain case insensitive with trace slots" {
    var request = core.http.Request.init(std.testing.allocator, .POST, "https://example.test/headers");
    defer request.deinit();
    try request.setHeader("tRaCePaReNt", "parent");
    try request.setHeader("TrAcEsTaTe", "vendor=state");
    try request.setHeader("cOnTeNt-LeNgTh", "4");
    request.body = "body";
    const exchange = RecordedExchange{
        .request_method = .POST,
        .request_url = request.url,
        .request_body = "body",
        .request_headers = &.{
            .{ .name = "TRACEPARENT", .value = "parent" },
            .{ .name = "tracestate", .value = "vendor=state" },
            .{ .name = "Content-Length", .value = "4" },
        },
    };
    try matchRequest(exchange, &request, request.body);
    try validateRequestFraming(&request, .{});
    try request.setHeader("TRACEPARENT", "changed");
    try std.testing.expectEqual(@as(usize, 3), request.headers.count());
    try std.testing.expectError(error.HeaderMismatch, matchRequest(exchange, &request, request.body));
    try request.setHeader("CoNtEnT-LeNgTh", "5");
    try std.testing.expectError(error.ConflictingRequestFraming, validateRequestFraming(&request, .{}));
    _ = request.removeHeader("CONTENT-LENGTH");
    request.body = null;
    var reader = std.Io.Reader.fixed("body");
    try request.setHeader("tRaNsFeR-EnCoDiNg", "ChUnKeD");
    const options = core.http.OpenOptions{ .body = core.http.StreamingRequestBody.chunked(&reader) };
    try validateRequestFraming(&request, options);
    try request.setHeader("content-length", "4");
    try std.testing.expectError(error.ConflictingRequestFraming, validateRequestFraming(&request, options));
}

fn deinitHeaderPairs(
    allocator: std.mem.Allocator,
    headers: []const HeaderPair,
) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
        if (header.url_redaction_template) |template|
            allocator.free(template);
    }
    allocator.free(headers);
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
            allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = owned_value;
            return;
        }
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try headers.put(owned_name, owned_value);
}

fn deinitOwnedHeaderMap(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn deinitResponseStorage(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    ordered: *core.http.ResponseHeaders,
) void {
    ordered.deinit();
    deinitOwnedHeaderMap(allocator, headers);
}

pub const redacted_value = "REDACTED";
const recording_format_version = 3;

const explicitly_sensitive_headers = [_][]const u8{
    "authorization",
    "proxy-authorization",
    "x-ms-authorization-auxiliary",
    "x-ms-copy-source-authorization",
    "x-ms-source-authorization",
    "x-ms-file-rename-source-authorization",
    "cookie",
    "set-cookie",
    "x-ms-client-secret",
    "x-ms-client-principal",
    "x-ms-encryption-key",
    "x-ms-encryption-key-sha256",
    "x-ms-sas-token",
    "aeg-sas-key",
    "aeg-sas-token",
    "aad-token",
    "identity-token",
    "lock-token",
    "x-auth-token",
    "ocp-apim-subscription-key",
    "api-key",
    "x-api-key",
    "x-functions-key",
    "subscription-key",
    "x-subscription-key",
};

const fully_redacted_url_headers = [_][]const u8{
    "x-ms-copy-source",
    "x-ms-copy-source-url",
    "x-ms-rename-source",
    "x-ms-file-rename-source",
};

const sanitized_url_headers = [_][]const u8{
    "location",
    "content-location",
    "operation-location",
    "azure-asyncoperation",
};

const sensitive_body_fields = [_][]const u8{
    "accesstoken",
    "refreshtoken",
    "clientsecret",
    "clientassertion",
    "password",
    "pwd",
    "secret",
    "credential",
    "credentials",
    "applicationsecret",
    "apikey",
    "connectionstring",
    "aliassecondaryconnectionstring",
    "primaryconnectionstring",
    "secondaryconnectionstring",
    "primarykey",
    "secondarykey",
    "primarymasterkey",
    "secondarymasterkey",
    "primaryreadonlymasterkey",
    "secondaryreadonlymasterkey",
    "accountkey",
    "sharedaccesskey",
    "sharedaccesssignature",
    "sshpassword",
    "adminpassword",
    "administratorloginpassword",
    "runaspassword",
    "accesssas",
    "websiteauthencryptionkey",
    "decryptionkey",
    "privatekey",
    "certificatepassword",
    "sasuri",
    "containerurl",
    "containeruri",
    "inputdatauri",
    "outputdatauri",
    "urlsource",
    "token",
    "aadtoken",
    "identitytoken",
    "oidctoken",
    "assertiontoken",
    "sastoken",
    "aegsaskey",
    "aegsastoken",
    "authorization",
};

const sensitive_body_containers = [_][]const u8{
    "keys",
    "listkeys",
    "accesskeys",
    "secrets",
    "connectionstrings",
};

const sensitive_query_fields = [_][]const u8{
    "sig",
    "signature",
    "access_token",
    "refresh_token",
    "id_token",
    "identity_token",
    "sas_token",
    "client_secret",
    "client_assertion",
    "password",
    "api_key",
    "api-key",
    "subscription-key",
    "aeg-sas-key",
    "aeg-sas-token",
    "account-key",
    "shared-access-key",
    "code",
};

const known_safe_headers = [_][]const u8{
    "accept",
    "accept-charset",
    "accept-encoding",
    "accept-language",
    "cache-control",
    "connection",
    "content-encoding",
    "content-language",
    "content-length",
    "content-range",
    "content-type",
    "date",
    "etag",
    "expires",
    "host",
    "if-match",
    "if-modified-since",
    "if-none-match",
    "if-unmodified-since",
    "last-modified",
    "location",
    "content-location",
    "operation-location",
    "azure-asyncoperation",
    "pragma",
    "range",
    "retry-after",
    "server",
    "traceparent",
    "tracestate",
    "transfer-encoding",
    "user-agent",
    "vary",
    "x-ms-client-request-id",
    "x-ms-continuation-token",
    "x-ms-date",
    "x-ms-error-code",
    "x-ms-request-id",
    "x-ms-return-client-request-id",
    "x-ms-version",
};

const volatile_request_headers = [_][]const u8{
    "date",
    "x-ms-date",
    "x-ms-client-request-id",
    "client-request-id",
    "request-id",
    "x-request-id",
    "x-ms-request-id",
    "correlation-id",
    "x-correlation-id",
    "x-ms-correlation-request-id",
    "x-ms-routing-request-id",
    "traceparent",
    "tracestate",
};

pub fn isSensitiveHeader(name: []const u8) bool {
    for (explicitly_sensitive_headers) |sensitive| {
        if (std.ascii.eqlIgnoreCase(name, sensitive)) return true;
    }
    if (containsIgnoreCase(name, "authorization") or
        containsIgnoreCase(name, "authentication") or
        containsIgnoreCase(name, "credential") or
        containsIgnoreCase(name, "secret") or
        containsIgnoreCase(name, "signature") or
        containsIgnoreCase(name, "auth-token") or
        containsIgnoreCase(name, "access-token") or
        containsIgnoreCase(name, "refresh-token") or
        containsIgnoreCase(name, "sas-token") or
        containsIgnoreCase(name, "encryption-key") or
        containsIgnoreCase(name, "api-key") or
        containsIgnoreCase(name, "apikey") or
        containsIgnoreCase(name, "subscription-key") or
        containsIgnoreCase(name, "functions-key") or
        containsIgnoreCase(name, "account-key") or
        containsIgnoreCase(name, "access-key") or
        containsIgnoreCase(name, "secret-key") or
        containsIgnoreCase(name, "shared-key") or
        normalizedFieldEndsWith(name, "password") or
        normalizedFieldEndsWith(name, "pwd") or
        normalizedFieldEndsWith(name, "privatekey") or
        normalizedFieldEndsWith(name, "connectionstring"))
    {
        return true;
    }
    return isFullyRedactedUrlHeader(name);
}

fn isKnownSafeHeader(name: []const u8) bool {
    for (known_safe_headers) |safe| {
        if (std.ascii.eqlIgnoreCase(name, safe)) return true;
    }
    return false;
}

fn isVolatileRequestHeader(name: []const u8) bool {
    for (volatile_request_headers) |header_name| {
        if (std.ascii.eqlIgnoreCase(name, header_name)) return true;
    }
    return false;
}

fn shouldRedactHeader(
    allocator: std.mem.Allocator,
    direction: BodyDirection,
    name: []const u8,
    value: []const u8,
) !bool {
    return (direction == .request and isVolatileRequestHeader(name)) or
        isSensitiveHeader(name) or
        try containsSensitiveScalar(allocator, value) or
        !isKnownSafeHeader(name);
}

fn ensureExchangeBodySafe(
    allocator: std.mem.Allocator,
    options: RecordingOptions,
    exchange: OwnedExchange,
    direction: BodyDirection,
) !void {
    const body = switch (direction) {
        .request => exchange.request_body,
        .response => exchange.response_body,
    };
    const bytes = body orelse return;
    if (bytes.len == 0) return;
    const headers = switch (direction) {
        .request => exchange.request_headers,
        .response => exchange.response_headers,
    };
    const context = BodySafetyContext{
        .direction = direction,
        .method = exchange.request_method,
        .url = exchange.request_url,
        .content_type = getHeaderPair(headers, "Content-Type"),
        .content_encoding = getHeaderPair(headers, "Content-Encoding"),
        .body = bytes,
    };
    const policy = options.bodyPolicyFn orelse {
        try ensureBodySafe(allocator, context, false);
        return error.BodyPolicyRequired;
    };
    const decision = policy(options.body_policy_context, context);
    if (decision == .reject_sensitive)
        return error.SensitiveBodyRequiresSanitization;
    return ensureBodySafe(
        allocator,
        context,
        decision == .allow_opaque,
    );
}

fn ensureBodySafe(
    allocator: std.mem.Allocator,
    context: BodySafetyContext,
    allow_opaque: bool,
) !void {
    const bytes = context.body;
    if (containsPrivateKeyMarker(bytes))
        return error.SensitiveBodyRequiresSanitization;
    if (try containsSensitiveScalar(allocator, bytes))
        return error.SensitiveBodyRequiresSanitization;

    const content_type = context.content_type orelse "";
    const content_encoding = context.content_encoding orelse "";
    const multipart = containsIgnoreCase(content_type, "multipart/") or
        (containsIgnoreCase(bytes, "content-disposition:") and
            containsIgnoreCase(bytes, "form-data"));
    if (multipart) {
        if (try containsSensitiveMultipartContent(
            allocator,
            content_type,
            bytes,
            0,
        ))
            return error.SensitiveBodyRequiresSanitization;
        if (!allow_opaque) return error.UnsupportedBodySanitization;
        return;
    }

    const valid_text = !hasUnicodeBom(bytes) and
        std.mem.indexOfScalar(u8, bytes, 0) == null and
        std.unicode.utf8ValidateSlice(bytes);
    const identity_encoding = content_encoding.len == 0 or
        std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, content_encoding, " \t"),
            "identity",
        );
    const json = valid_text and identity_encoding and
        (isJsonContentType(content_type) or looksLikeStructuredJson(bytes));
    if (json) {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            bytes,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.UnsupportedBodySanitization,
        };
        defer parsed.deinit();
        if (try jsonContainsSensitiveField(allocator, parsed.value) or
            try jsonContainsExchangeSensitiveSchema(
                allocator,
                parsed.value,
                context,
            ))
        {
            return error.SensitiveBodyRequiresSanitization;
        }
    }

    const xml = valid_text and identity_encoding and
        (containsIgnoreCase(content_type, "xml") or looksLikeXml(bytes));
    if (xml) {
        if (try inspectXmlDocument(allocator, bytes) or
            try containsSensitiveAssignment(allocator, bytes) or
            (try isStorageUserDelegationKeyExchange(allocator, context) and
                containsIgnoreCase(bytes, "<UserDelegationKey") and
                containsIgnoreCase(bytes, "<Value")))
        {
            return error.SensitiveBodyRequiresSanitization;
        }
    }

    if (!valid_text or
        std.mem.indexOfScalar(u8, bytes, 0) != null or
        declaresWideCharset(content_type) or
        !isSupportedTextContentType(content_type) or
        !identity_encoding)
    {
        if (!allow_opaque) return error.OpaqueBodyNotAllowed;
        return;
    }

    if (xml or json) return;
    if (try containsSensitiveAssignment(allocator, bytes) or
        try containsSensitiveXml(allocator, bytes))
    {
        return error.SensitiveBodyRequiresSanitization;
    }
}

fn getHeaderPair(headers: []const HeaderPair, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn containsPrivateKeyMarker(body: []const u8) bool {
    return containsIgnoreCase(body, "-----BEGIN PRIVATE KEY-----") or
        containsIgnoreCase(body, "-----BEGIN RSA PRIVATE KEY-----") or
        containsIgnoreCase(body, "-----BEGIN EC PRIVATE KEY-----") or
        containsIgnoreCase(body, "-----BEGIN ENCRYPTED PRIVATE KEY-----") or
        containsIgnoreCase(body, "-----BEGIN OPENSSH PRIVATE KEY-----") or
        (containsIgnoreCase(body, "-----BEGIN ") and
            containsIgnoreCase(body, "PRIVATE KEY-----"));
}

fn containsSensitiveMultipartField(body: []const u8) bool {
    var search_start: usize = 0;
    while (indexOfIgnoreCasePos(body, search_start, "content-disposition:")) |start| {
        const line_end = std.mem.indexOfAnyPos(
            u8,
            body,
            start,
            "\r\n",
        ) orelse body.len;
        var parameters = std.mem.splitScalar(u8, body[start..line_end], ';');
        _ = parameters.next();
        while (parameters.next()) |parameter| {
            const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse
                continue;
            const name = std.mem.trim(u8, parameter[0..equals], " \t");
            if (!std.ascii.eqlIgnoreCase(name, "name")) continue;
            const value = std.mem.trim(
                u8,
                parameter[equals + 1 ..],
                " \t\"'",
            );
            if (isSensitiveBodyField(value)) return true;
        }
        search_start = line_end;
    }
    return false;
}

fn containsSensitiveMultipartContent(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    body: []const u8,
    depth: usize,
) anyerror!bool {
    if (depth >= 8) return error.UnsupportedBodySanitization;
    if (containsSensitiveMultipartField(body)) return true;
    if (try containsSensitiveHttpHeaderLine(allocator, body)) return true;

    const boundary = try multipartBoundary(content_type);
    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);
    const first = try findMultipartBoundaryLine(body, delimiter, 0) orelse
        return error.UnsupportedBodySanitization;
    if (first.closing) return error.UnsupportedBodySanitization;
    if (try containsSensitiveLoosePayload(
        allocator,
        body[0..first.start],
    )) return true;

    var part_start = first.after;
    var saw_part = false;
    while (true) {
        const next = try findMultipartBoundaryLine(
            body,
            delimiter,
            part_start,
        ) orelse return error.UnsupportedBodySanitization;
        const part = std.mem.trim(
            u8,
            body[part_start..next.start],
            " \t\r\n",
        );
        if (part.len == 0) return error.UnsupportedBodySanitization;
        saw_part = true;
        if (try containsSensitiveMultipartPart(
            allocator,
            part,
            depth,
        )) return true;
        if (next.closing) {
            const epilogue = body[next.after..];
            if (try findMultipartBoundaryLine(
                epilogue,
                delimiter,
                0,
            ) != null) return error.UnsupportedBodySanitization;
            if (try containsSensitiveLoosePayload(
                allocator,
                epilogue,
            )) return true;
            break;
        }
        part_start = next.after;
    }
    if (!saw_part) return error.UnsupportedBodySanitization;
    return false;
}

fn containsSensitiveMultipartPart(
    allocator: std.mem.Allocator,
    part: []const u8,
    depth: usize,
) anyerror!bool {
    const outer_separator = findHeaderSeparator(part) orelse
        return error.UnsupportedBodySanitization;
    const outer_headers = part[0..outer_separator.start];
    var payload = part[outer_separator.end..];
    var payload_content_type = try headerValueFromBlockWithStartLine(
        outer_headers,
        "Content-Type",
        false,
    );
    if (looksLikeHttpMessage(payload)) {
        const inner_separator = findHeaderSeparator(payload) orelse
            return error.UnsupportedBodySanitization;
        const inner_headers = payload[0..inner_separator.start];
        payload_content_type = try headerValueFromBlockWithStartLine(
            inner_headers,
            "Content-Type",
            true,
        );
        payload = payload[inner_separator.end..];
    }
    payload = std.mem.trim(u8, payload, " \t\r\n");
    if (payload.len == 0) return false;
    if (payload_content_type) |part_type| {
        if (containsIgnoreCase(part_type, "multipart/")) {
            return containsSensitiveMultipartContent(
                allocator,
                part_type,
                payload,
                depth + 1,
            );
        }
    }
    return containsSensitiveLoosePayload(allocator, payload);
}

fn containsSensitiveLoosePayload(
    allocator: std.mem.Allocator,
    raw_payload: []const u8,
) !bool {
    const payload = std.mem.trim(u8, raw_payload, " \t\r\n");
    if (payload.len == 0) return false;
    if (try containsSensitiveScalar(allocator, payload)) return true;
    if (try containsSensitiveAssignment(allocator, payload)) return true;
    if (looksLikeStructuredJson(payload)) {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            payload,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.UnsupportedBodySanitization,
        };
        defer parsed.deinit();
        if (try jsonContainsSensitiveField(allocator, parsed.value))
            return true;
        return false;
    }
    if (looksLikeXml(payload))
        return inspectXmlDocument(allocator, payload);
    if (try containsSensitiveXml(allocator, payload)) return true;
    if (std.mem.indexOfAny(u8, payload, "{}[]<>") != null)
        return error.UnsupportedBodySanitization;
    return false;
}

const MultipartBoundaryLine = struct {
    start: usize,
    after: usize,
    closing: bool,
};

fn findMultipartBoundaryLine(
    body: []const u8,
    delimiter: []const u8,
    start: usize,
) !?MultipartBoundaryLine {
    var search_start = start;
    while (std.mem.indexOfPos(u8, body, search_start, delimiter)) |index| {
        if (index != 0 and body[index - 1] != '\n') {
            search_start = index + delimiter.len;
            continue;
        }
        var suffix = index + delimiter.len;
        var closing = false;
        if (std.mem.startsWith(u8, body[suffix..], "--")) {
            closing = true;
            suffix += 2;
        }
        const after = if (suffix == body.len)
            suffix
        else if (std.mem.startsWith(u8, body[suffix..], "\r\n"))
            suffix + 2
        else if (body[suffix] == '\n')
            suffix + 1
        else
            return error.UnsupportedBodySanitization;
        return .{ .start = index, .after = after, .closing = closing };
    }
    return null;
}

fn multipartBoundary(content_type: []const u8) ![]const u8 {
    var parameters = std.mem.splitScalar(u8, content_type, ';');
    const media_type = std.mem.trim(u8, parameters.next() orelse "", " \t");
    if (!std.ascii.startsWithIgnoreCase(media_type, "multipart/"))
        return error.UnsupportedBodySanitization;
    while (parameters.next()) |raw_parameter| {
        const parameter = std.mem.trim(u8, raw_parameter, " \t");
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse
            continue;
        const name = std.mem.trim(u8, parameter[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "boundary")) continue;
        const raw_value = std.mem.trim(
            u8,
            parameter[equals + 1 ..],
            " \t",
        );
        var boundary = raw_value;
        if (raw_value.len != 0 and
            (raw_value[0] == '"' or raw_value[0] == '\''))
        {
            if (raw_value.len < 2 or
                raw_value[raw_value.len - 1] != raw_value[0])
            {
                return error.UnsupportedBodySanitization;
            }
            boundary = raw_value[1 .. raw_value.len - 1];
        } else if (std.mem.indexOfAny(u8, raw_value, "\"'") != null) {
            return error.UnsupportedBodySanitization;
        }
        if (boundary.len == 0 or boundary.len > 70)
            return error.UnsupportedBodySanitization;
        for (boundary) |byte| {
            if (byte <= 0x20 or byte >= 0x7f)
                return error.UnsupportedBodySanitization;
        }
        return boundary;
    }
    return error.UnsupportedBodySanitization;
}

fn headerValueFromBlockWithStartLine(
    headers: []const u8,
    expected_name: []const u8,
    allow_http_start_line: bool,
) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    var line_index: usize = 0;
    var result: ?[]const u8 = null;
    while (lines.next()) |raw_line| {
        if (raw_line.len != 0 and
            (raw_line[0] == ' ' or raw_line[0] == '\t'))
        {
            return error.UnsupportedBodySanitization;
        }
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.indexOfScalar(u8, line, '\r') != null)
            return error.UnsupportedBodySanitization;
        if (line.len == 0) return error.UnsupportedBodySanitization;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            if (allow_http_start_line and line_index == 0 and
                looksLikeHttpMessage(line))
            {
                line_index += 1;
                continue;
            }
            return error.UnsupportedBodySanitization;
        };
        const name = line[0..colon];
        if (name.len == 0) return error.UnsupportedBodySanitization;
        for (name) |byte| {
            if (byte <= 0x20 or byte >= 0x7f or
                std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={}", byte) != null)
            {
                return error.UnsupportedBodySanitization;
            }
        }
        if (std.ascii.eqlIgnoreCase(name, expected_name))
            result = std.mem.trim(u8, line[colon + 1 ..], " \t");
        line_index += 1;
    }
    return result;
}

fn containsSensitiveHttpHeaderLine(
    allocator: std.mem.Allocator,
    body: []const u8,
) !bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, ' ') != null)
            continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (isSensitiveHeader(name) or
            try containsSensitiveScalar(allocator, value))
        {
            return true;
        }
    }
    return false;
}

const HeaderSeparator = struct {
    start: usize,
    end: usize,
};

fn findHeaderSeparator(bytes: []const u8) ?HeaderSeparator {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |index|
        return .{ .start = index, .end = index + 4 };
    if (std.mem.indexOf(u8, bytes, "\n\n")) |index|
        return .{ .start = index, .end = index + 2 };
    return null;
}

fn looksLikeHttpMessage(bytes: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, bytes, " \t\r\n");
    const line_end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse
        trimmed.len;
    const first_line = trimmed[0..line_end];
    return std.ascii.startsWithIgnoreCase(first_line, "HTTP/") or
        std.mem.indexOf(u8, first_line, " HTTP/") != null;
}

fn looksLikeXml(body: []const u8) bool {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return trimmed.len != 0 and trimmed[0] == '<';
}

fn jsonContainsExchangeSensitiveSchema(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    context: BodySafetyContext,
) !bool {
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const target = try parseUrlTarget(
        context.url,
        &host_buffer,
    ) orelse return false;
    if (isKeyVaultHost(target.host)) {
        if ((try pathHasResource(allocator, target.path, "secrets") or
            try pathHasResource(allocator, target.path, "certificates")) and
            jsonRootHasField(value, "value"))
        {
            return true;
        }
        if (try pathHasResource(allocator, target.path, "keys") and
            (jsonRootHasField(value, "value") or
                jsonContainsJwkPrivateField(value)))
        {
            return true;
        }
    }
    if (isKustoHost(target.host) and
        jsonContainsField(value, "sourceuri"))
    {
        return true;
    }
    if (isAzureManagementHost(target.host) and
        try isAzureKeyManagementPath(allocator, target.path) and
        (jsonRootHasField(value, "key1") or
            jsonRootHasField(value, "key2")))
    {
        return true;
    }
    if (isAzureManagementHost(target.host) and
        try pathHasResource(allocator, target.path, "Microsoft.DocumentDB") and
        (try pathHasResource(allocator, target.path, "listKeys") or
            try pathHasResource(
                allocator,
                target.path,
                "listReadOnlyKeys",
            )) and
        (jsonContainsField(value, "primarymasterkey") or
            jsonContainsField(value, "secondarymasterkey") or
            jsonContainsField(value, "primaryreadonlymasterkey") or
            jsonContainsField(value, "secondaryreadonlymasterkey")))
    {
        return true;
    }
    if (isAzureManagementHost(target.host) and
        try pathHasResource(
            allocator,
            target.path,
            "Microsoft.ContainerRegistry",
        ) and
        try pathHasResource(allocator, target.path, "listCredentials") and
        jsonContainsField(value, "passwords"))
    {
        return true;
    }
    if (isAzureManagementHost(target.host) and
        try pathHasResource(allocator, target.path, "Microsoft.Batch") and
        try pathHasResource(allocator, target.path, "listKeys") and
        (jsonRootHasField(value, "primary") or
            jsonRootHasField(value, "secondary")))
    {
        return true;
    }
    if (isAzureManagementHost(target.host) and
        try pathHasResource(allocator, target.path, "Microsoft.Search") and
        try pathHasResource(allocator, target.path, "listQueryKeys") and
        jsonContainsField(value, "key"))
    {
        return true;
    }
    return false;
}

fn jsonRootHasField(value: std.json.Value, field: []const u8) bool {
    const object = switch (value) {
        .object => |result| result,
        else => return false,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (normalizedFieldEquals(entry.key_ptr.*, field)) return true;
    }
    return false;
}

fn jsonContainsField(value: std.json.Value, field: []const u8) bool {
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (normalizedFieldEquals(entry.key_ptr.*, field) or
                    jsonContainsField(entry.value_ptr.*, field))
                {
                    return true;
                }
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (jsonContainsField(item, field)) return true;
            }
        },
        else => {},
    }
    return false;
}

fn jsonContainsJwkPrivateField(value: std.json.Value) bool {
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const name = entry.key_ptr.*;
                if (normalizedFieldEquals(name, "d") or
                    normalizedFieldEquals(name, "p") or
                    normalizedFieldEquals(name, "q") or
                    normalizedFieldEquals(name, "dp") or
                    normalizedFieldEquals(name, "dq") or
                    normalizedFieldEquals(name, "qi") or
                    jsonContainsJwkPrivateField(entry.value_ptr.*))
                {
                    return true;
                }
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (jsonContainsJwkPrivateField(item)) return true;
            }
        },
        else => {},
    }
    return false;
}

const UrlTarget = struct {
    host: []const u8,
    path: []const u8,
};

fn parseUrlTarget(
    url: []const u8,
    host_buffer: *[std.Io.net.HostName.max_len]u8,
) !?UrlTarget {
    const uri = std.Uri.parse(url) catch
        return error.SensitiveBodyRequiresSanitization;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return null;
    if (uri.user != null or uri.password != null)
        return error.SensitiveBodyRequiresSanitization;
    const host_name = uri.getHost(host_buffer) catch
        return error.SensitiveBodyRequiresSanitization;
    var host = host_name.bytes;
    if (host.len != 0 and host[host.len - 1] == '.')
        host = host[0 .. host.len - 1];
    if (!isCanonicalDnsHost(host))
        return error.SensitiveBodyRequiresSanitization;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    return .{
        .host = host,
        .path = path,
    };
}

fn isCanonicalDnsHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or
            label[0] == '-' or label[label.len - 1] == '-')
        {
            return false;
        }
        for (label) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-')
                return false;
        }
    }
    return true;
}

fn hostMatches(host: []const u8, suffix: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, suffix)) return true;
    if (host.len <= suffix.len or host[host.len - suffix.len - 1] != '.')
        return false;
    return std.ascii.eqlIgnoreCase(
        host[host.len - suffix.len ..],
        suffix,
    );
}

fn isKeyVaultHost(host: []const u8) bool {
    return hostMatches(host, "vault.azure.net") or
        hostMatches(host, "vault.azure.cn") or
        hostMatches(host, "vault.usgovcloudapi.net") or
        hostMatches(host, "vault.microsoftazure.de") or
        hostMatches(host, "vaultcore.azure.net") or
        hostMatches(host, "managedhsm.azure.net") or
        hostMatches(host, "managedhsm.azure.cn") or
        hostMatches(host, "managedhsm.usgovcloudapi.net") or
        hostMatches(host, "managedhsm.microsoftazure.de");
}

fn isKustoHost(host: []const u8) bool {
    return hostMatches(host, "kusto.windows.net") or
        hostMatches(host, "kusto.chinacloudapi.cn") or
        hostMatches(host, "kusto.usgovcloudapi.net") or
        hostMatches(host, "kusto.cloudapi.de") or
        hostMatches(host, "kusto.fabric.microsoft.com");
}

fn isAzureManagementHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "management.azure.com") or
        std.ascii.eqlIgnoreCase(host, "management.usgovcloudapi.net") or
        std.ascii.eqlIgnoreCase(host, "management.chinacloudapi.cn") or
        std.ascii.eqlIgnoreCase(host, "management.microsoftazure.de");
}

fn isStorageBlobHost(host: []const u8) bool {
    return hostMatches(host, "blob.core.windows.net") or
        hostMatches(host, "blob.core.usgovcloudapi.net") or
        hostMatches(host, "blob.core.chinacloudapi.cn") or
        hostMatches(host, "blob.core.cloudapi.de");
}

fn isStorageUserDelegationKeyExchange(
    allocator: std.mem.Allocator,
    context: BodySafetyContext,
) !bool {
    if (context.direction != .response) return false;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const target = try parseUrlTarget(
        context.url,
        &host_buffer,
    ) orelse return false;
    if (!isStorageBlobHost(target.host)) return false;
    const query_start = std.mem.indexOfScalar(u8, context.url, '?') orelse
        return false;
    const fragment_start = std.mem.indexOfPos(
        u8,
        context.url,
        query_start,
        "#",
    ) orelse context.url.len;
    var fields = std.mem.splitScalar(
        u8,
        context.url[query_start + 1 .. fragment_start],
        '&',
    );
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const name = try canonicalUrlComponentAlloc(
            allocator,
            field[0..equals],
            true,
        );
        defer allocator.free(name);
        const value = try canonicalUrlComponentAlloc(
            allocator,
            field[equals + 1 ..],
            true,
        );
        defer allocator.free(value);
        if (std.ascii.eqlIgnoreCase(name, "comp") and
            std.ascii.eqlIgnoreCase(value, "userdelegationkey"))
        {
            return true;
        }
    }
    return false;
}

fn isAzureKeyManagementPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) !bool {
    const recognized_provider =
        try pathHasResource(allocator, path, "Microsoft.EventGrid") or
        try pathHasResource(allocator, path, "Microsoft.CognitiveServices");
    const recognized_action =
        try pathHasResource(allocator, path, "listKeys") or
        try pathHasResource(allocator, path, "regenerateKey") or
        try pathHasResource(allocator, path, "regenerateKeys");
    return recognized_provider and recognized_action;
}

fn pathHasResource(
    allocator: std.mem.Allocator,
    path: []const u8,
    resource: []const u8,
) !bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |encoded_segment| {
        const segment = try canonicalUrlComponentAlloc(
            allocator,
            encoded_segment,
            false,
        );
        defer allocator.free(segment);
        var decoded_segments = std.mem.splitScalar(u8, segment, '/');
        while (decoded_segments.next()) |decoded| {
            if (std.ascii.eqlIgnoreCase(decoded, resource)) return true;
        }
    }
    return false;
}

fn looksLikeStructuredJson(body: []const u8) bool {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return trimmed.len != 0 and (trimmed[0] == '{' or trimmed[0] == '[');
}

fn hasUnicodeBom(body: []const u8) bool {
    return std.mem.startsWith(u8, body, "\xef\xbb\xbf") or
        std.mem.startsWith(u8, body, "\xff\xfe") or
        std.mem.startsWith(u8, body, "\xfe\xff") or
        std.mem.startsWith(u8, body, "\xff\xfe\x00\x00") or
        std.mem.startsWith(u8, body, "\x00\x00\xfe\xff");
}

fn declaresWideCharset(content_type: []const u8) bool {
    return containsIgnoreCase(content_type, "charset=utf-16") or
        containsIgnoreCase(content_type, "charset=\"utf-16") or
        containsIgnoreCase(content_type, "charset=utf-32") or
        containsIgnoreCase(content_type, "charset=\"utf-32");
}

fn isJsonContentType(content_type: []const u8) bool {
    return containsIgnoreCase(content_type, "/json") or
        containsIgnoreCase(content_type, "+json");
}

fn isSupportedTextContentType(content_type: []const u8) bool {
    const trimmed = std.mem.trim(u8, content_type, " \t");
    if (trimmed.len == 0) return true;
    return std.ascii.startsWithIgnoreCase(trimmed, "text/") or
        isJsonContentType(trimmed) or
        containsIgnoreCase(trimmed, "/xml") or
        containsIgnoreCase(trimmed, "+xml") or
        std.ascii.startsWithIgnoreCase(
            trimmed,
            "application/x-www-form-urlencoded",
        ) or
        std.ascii.startsWithIgnoreCase(trimmed, "application/javascript") or
        std.ascii.startsWithIgnoreCase(trimmed, "application/ecmascript") or
        std.ascii.startsWithIgnoreCase(trimmed, "application/graphql");
}

fn jsonContainsSensitiveField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !bool {
    return jsonContainsSensitiveFieldInContext(allocator, value, false);
}

fn jsonContainsSensitiveFieldInContext(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    sensitive_container: bool,
) !bool {
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (isSensitiveBodyField(entry.key_ptr.*) or
                    (sensitive_container and
                        normalizedFieldEquals(entry.key_ptr.*, "value")) or
                    try jsonContainsSensitiveFieldInContext(
                        allocator,
                        entry.value_ptr.*,
                        sensitive_container or
                            isSensitiveBodyContainer(entry.key_ptr.*),
                    ))
                {
                    return true;
                }
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (try jsonContainsSensitiveFieldInContext(
                    allocator,
                    item,
                    sensitive_container,
                )) return true;
            }
        },
        .string => |string| return containsSensitiveScalar(allocator, string),
        else => {},
    }
    return false;
}

fn containsSensitiveScalar(
    allocator: std.mem.Allocator,
    value: []const u8,
) !bool {
    if (try containsDirectSensitiveScalar(allocator, value)) return true;
    var current = try allocator.dupe(u8, value);
    defer allocator.free(current);
    var decode_count: usize = 0;
    while (decode_count < max_url_decode_depth) : (decode_count += 1) {
        if (!containsPercentEscape(current)) return false;
        const decoded = try percentDecodeLooseAlloc(allocator, current);
        const changed = !std.mem.eql(u8, current, decoded);
        allocator.free(current);
        current = decoded;
        if (try containsDirectSensitiveScalar(allocator, current)) return true;
        if (!changed) return false;
    }
    return containsPercentEscape(current);
}

fn percentDecodeLooseAlloc(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) ![]u8 {
    const decoded = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(decoded);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < encoded.len) {
        if (encoded[input_index] == '%' and input_index + 2 < encoded.len) {
            const high = std.fmt.charToDigit(
                encoded[input_index + 1],
                16,
            ) catch {
                decoded[output_index] = encoded[input_index];
                input_index += 1;
                output_index += 1;
                continue;
            };
            const low = std.fmt.charToDigit(
                encoded[input_index + 2],
                16,
            ) catch {
                decoded[output_index] = encoded[input_index];
                input_index += 1;
                output_index += 1;
                continue;
            };
            decoded[output_index] = high * 16 + low;
            input_index += 3;
        } else {
            decoded[output_index] = encoded[input_index];
            input_index += 1;
        }
        output_index += 1;
    }
    return allocator.realloc(decoded, output_index);
}

fn containsDirectSensitiveScalar(
    allocator: std.mem.Allocator,
    value: []const u8,
) !bool {
    return containsPrivateKeyMarker(value) or
        try containsSensitiveAssignment(allocator, value) or
        containsSasCredential(value) or
        containsIgnoreCase(value, "Bearer ") or
        containsIgnoreCase(value, "SharedKey ") or
        containsIgnoreCase(value, "SharedKeyLite ") or
        try containsJwtToken(allocator, value);
}

fn containsSasCredential(value: []const u8) bool {
    return containsIgnoreCase(value, "SharedAccessSignature") or
        containsIgnoreCase(value, "?sig=") or
        containsIgnoreCase(value, "&sig=") or
        containsIgnoreCase(value, ";sig=") or
        containsIgnoreCase(value, "&amp;sig=") or
        containsIgnoreCase(value, "?aeg-sas-key=") or
        containsIgnoreCase(value, "&aeg-sas-key=") or
        containsIgnoreCase(value, "?aeg-sas-token=") or
        containsIgnoreCase(value, "&aeg-sas-token=") or
        containsIgnoreCase(value, "sig%3d") or
        containsIgnoreCase(value, "sig%253d") or
        (containsIgnoreCase(value, "&e=") and
            containsIgnoreCase(value, "&s="));
}

fn looksLikeJwt(
    allocator: std.mem.Allocator,
    value: []const u8,
) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    var segments = std.mem.splitScalar(u8, trimmed, '.');
    const encoded_header = segments.next() orelse return false;
    const encoded_payload = segments.next() orelse return false;
    const encoded_signature = segments.next() orelse return false;
    if (segments.next() != null or
        encoded_header.len == 0 or
        encoded_payload.len == 0 or
        encoded_signature.len < 16)
    {
        return false;
    }

    const signature = decodeJwtSegment(
        allocator,
        encoded_signature,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(signature);
    if (signature.len < 12) return false;

    const header = decodeJwtSegment(allocator, encoded_header) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(header);
    const payload = decodeJwtSegment(allocator, encoded_payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(payload);
    return try isPlausibleJwtObject(allocator, header, true) and
        try isPlausibleJwtObject(allocator, payload, false);
}

fn containsJwtToken(
    allocator: std.mem.Allocator,
    value: []const u8,
) !bool {
    var tokens = std.mem.tokenizeAny(
        u8,
        value,
        " \t\r\n\"'[](){},;:=<>",
    );
    while (tokens.next()) |token| {
        if (try looksLikeJwt(allocator, token)) return true;
    }
    return false;
}

fn decodeJwtSegment(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) ![]u8 {
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(
        encoded,
    ) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(
        decoded,
        encoded,
    ) catch return error.InvalidBase64;
    return decoded;
}

fn isPlausibleJwtObject(
    allocator: std.mem.Allocator,
    value: []const u8,
    require_alg: bool,
) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        trimmed,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |result| result,
        else => return false,
    };
    if (!require_alg) return true;
    const alg = object.get("alg") orelse return false;
    return switch (alg) {
        .string => |name| name.len != 0,
        else => false,
    };
}

fn isSensitiveBodyContainer(name: []const u8) bool {
    for (sensitive_body_containers) |field| {
        if (normalizedFieldEquals(name, field)) return true;
    }
    return false;
}

fn isSensitiveBodyField(name: []const u8) bool {
    for (sensitive_body_fields) |field| {
        if (normalizedFieldEquals(name, field)) return true;
    }
    return normalizedFieldEndsWith(name, "password") or
        normalizedFieldEndsWith(name, "secret") or
        normalizedFieldEndsWith(name, "connectionstring") or
        normalizedFieldEndsWith(name, "apikey") or
        normalizedFieldEndsWith(name, "accountkey") or
        normalizedFieldEndsWith(name, "masterkey") or
        normalizedFieldEndsWith(name, "accesskey") or
        normalizedFieldEndsWith(name, "encryptionkey") or
        normalizedFieldEndsWith(name, "privatekey") or
        normalizedFieldEndsWith(name, "sharedkey") or
        normalizedFieldEndsWith(name, "secretkey");
}

fn normalizedFieldEquals(name: []const u8, normalized: []const u8) bool {
    var normalized_index: usize = 0;
    var index: usize = 0;
    while (index < name.len) : (index += 1) {
        const byte = name[index];
        if (!std.ascii.isAlphanumeric(byte)) continue;
        if (normalized_index >= normalized.len or
            std.ascii.toLower(byte) != normalized[normalized_index])
        {
            return false;
        }
        normalized_index += 1;
    }
    return normalized_index == normalized.len;
}

fn normalizedFieldEndsWith(name: []const u8, suffix: []const u8) bool {
    var name_index = name.len;
    var suffix_index = suffix.len;
    while (suffix_index != 0) {
        while (name_index != 0 and
            !std.ascii.isAlphanumeric(name[name_index - 1]))
        {
            name_index -= 1;
        }
        if (name_index == 0) return false;
        name_index -= 1;
        suffix_index -= 1;
        if (std.ascii.toLower(name[name_index]) != suffix[suffix_index])
            return false;
    }
    return true;
}

fn containsSensitiveAssignment(
    allocator: std.mem.Allocator,
    body: []const u8,
) !bool {
    var start: usize = 0;
    var index: usize = 0;
    while (index <= body.len) : (index += 1) {
        if (index != body.len and
            body[index] != '&' and
            body[index] != ';' and
            body[index] != ',' and
            body[index] != '\n' and
            body[index] != '\r')
        {
            continue;
        }
        const field = body[start..index];
        start = index + 1;
        var equals_start: usize = 0;
        while (std.mem.indexOfScalarPos(
            u8,
            field,
            equals_start,
            '=',
        )) |equals| {
            var name = std.mem.trim(u8, field[0..equals], " \t\"'{}[]");
            if (std.mem.lastIndexOfAny(u8, name, "?#")) |delimiter| {
                name = name[delimiter + 1 ..];
            }
            if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| {
                name = name[colon + 1 ..];
            }
            if (try encodedQueryNameIsSensitive(allocator, name)) return true;
            equals_start = equals + 1;
        }
    }
    return false;
}

fn percentDecodeFieldName(
    encoded: []const u8,
    buffer: []u8,
) ?[]const u8 {
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < encoded.len) {
        if (output_index >= buffer.len) return null;
        if (encoded[input_index] == '%' and input_index + 2 < encoded.len) {
            const high = std.fmt.charToDigit(encoded[input_index + 1], 16) catch
                return null;
            const low = std.fmt.charToDigit(encoded[input_index + 2], 16) catch
                return null;
            buffer[output_index] = high * 16 + low;
            input_index += 3;
        } else {
            buffer[output_index] = encoded[input_index];
            input_index += 1;
        }
        output_index += 1;
    }
    return buffer[0..output_index];
}

const XmlInspector = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    index: usize = 0,
    sensitive: bool = false,

    fn inspect(self: *XmlInspector) !bool {
        self.skipWhitespace();
        if (std.mem.startsWith(u8, self.bytes[self.index..], "<?xml")) {
            try self.parseProcessingInstruction();
            self.skipWhitespace();
        }
        while (try self.parseMisc()) self.skipWhitespace();
        if (self.index >= self.bytes.len or self.bytes[self.index] != '<')
            return error.UnsupportedBodySanitization;
        try self.parseElement(0);
        self.skipWhitespace();
        while (try self.parseMisc()) self.skipWhitespace();
        if (self.index != self.bytes.len)
            return error.UnsupportedBodySanitization;
        return self.sensitive;
    }

    fn parseElement(self: *XmlInspector, depth: usize) !void {
        if (depth >= 128 or
            self.index >= self.bytes.len or
            self.bytes[self.index] != '<' or
            std.mem.startsWith(u8, self.bytes[self.index..], "</") or
            std.mem.startsWith(u8, self.bytes[self.index..], "<!") or
            std.mem.startsWith(u8, self.bytes[self.index..], "<?"))
        {
            return error.UnsupportedBodySanitization;
        }
        self.index += 1;
        const element_name = try self.parseName();
        if (isSensitiveBodyField(xmlLocalName(element_name)))
            self.sensitive = true;

        var attribute_names: [64][]const u8 = undefined;
        var attribute_count: usize = 0;
        while (true) {
            self.skipWhitespace();
            if (self.consume("/>")) return;
            if (self.consume(">")) break;
            if (attribute_count == attribute_names.len)
                return error.UnsupportedBodySanitization;
            const attribute_name = try self.parseName();
            for (attribute_names[0..attribute_count]) |previous| {
                if (std.mem.eql(u8, previous, attribute_name))
                    return error.UnsupportedBodySanitization;
            }
            attribute_names[attribute_count] = attribute_name;
            attribute_count += 1;
            self.skipWhitespace();
            if (!self.consume("="))
                return error.UnsupportedBodySanitization;
            self.skipWhitespace();
            const attribute_value = try self.parseQuotedValue();
            if (try self.attributeSensitive(
                xmlLocalName(attribute_name),
                attribute_value,
            )) self.sensitive = true;
        }

        while (true) {
            if (self.index >= self.bytes.len)
                return error.UnsupportedBodySanitization;
            if (std.mem.startsWith(u8, self.bytes[self.index..], "</")) {
                self.index += 2;
                const closing_name = try self.parseName();
                self.skipWhitespace();
                if (!self.consume(">") or
                    !std.mem.eql(u8, element_name, closing_name))
                {
                    return error.UnsupportedBodySanitization;
                }
                return;
            }
            if (std.mem.startsWith(
                u8,
                self.bytes[self.index..],
                "<!--",
            )) {
                try self.parseComment();
                continue;
            }
            if (std.mem.startsWith(
                u8,
                self.bytes[self.index..],
                "<![CDATA[",
            )) {
                try self.parseCdata();
                continue;
            }
            if (std.mem.startsWith(u8, self.bytes[self.index..], "<?")) {
                try self.parseProcessingInstruction();
                continue;
            }
            if (std.mem.startsWith(u8, self.bytes[self.index..], "<!"))
                return error.UnsupportedBodySanitization;
            if (self.bytes[self.index] == '<') {
                try self.parseElement(depth + 1);
                continue;
            }
            const text_start = self.index;
            while (self.index < self.bytes.len and
                self.bytes[self.index] != '<')
            {
                self.index += 1;
            }
            try self.inspectText(self.bytes[text_start..self.index]);
        }
    }

    fn parseMisc(self: *XmlInspector) !bool {
        if (std.mem.startsWith(u8, self.bytes[self.index..], "<!--")) {
            try self.parseComment();
            return true;
        }
        if (std.mem.startsWith(u8, self.bytes[self.index..], "<?")) {
            try self.parseProcessingInstruction();
            return true;
        }
        return false;
    }

    fn parseComment(self: *XmlInspector) !void {
        if (!self.consume("<!--"))
            return error.UnsupportedBodySanitization;
        const end = std.mem.indexOfPos(
            u8,
            self.bytes,
            self.index,
            "-->",
        ) orelse return error.UnsupportedBodySanitization;
        const value = self.bytes[self.index..end];
        if (std.mem.indexOf(u8, value, "--") != null)
            return error.UnsupportedBodySanitization;
        try self.inspectText(value);
        self.index = end + 3;
    }

    fn parseCdata(self: *XmlInspector) !void {
        if (!self.consume("<![CDATA["))
            return error.UnsupportedBodySanitization;
        const end = std.mem.indexOfPos(
            u8,
            self.bytes,
            self.index,
            "]]>",
        ) orelse return error.UnsupportedBodySanitization;
        try self.inspectText(self.bytes[self.index..end]);
        self.index = end + 3;
    }

    fn parseProcessingInstruction(self: *XmlInspector) !void {
        if (!self.consume("<?"))
            return error.UnsupportedBodySanitization;
        const end = std.mem.indexOfPos(
            u8,
            self.bytes,
            self.index,
            "?>",
        ) orelse return error.UnsupportedBodySanitization;
        try self.inspectText(self.bytes[self.index..end]);
        self.index = end + 2;
    }

    fn parseName(self: *XmlInspector) ![]const u8 {
        if (self.index >= self.bytes.len or
            !isXmlNameStart(self.bytes[self.index]))
        {
            return error.UnsupportedBodySanitization;
        }
        const start = self.index;
        self.index += 1;
        while (self.index < self.bytes.len and
            isXmlNameByte(self.bytes[self.index]))
        {
            self.index += 1;
        }
        return self.bytes[start..self.index];
    }

    fn parseQuotedValue(self: *XmlInspector) ![]const u8 {
        if (self.index >= self.bytes.len or
            (self.bytes[self.index] != '"' and
                self.bytes[self.index] != '\''))
        {
            return error.UnsupportedBodySanitization;
        }
        const quote = self.bytes[self.index];
        self.index += 1;
        const start = self.index;
        while (self.index < self.bytes.len and
            self.bytes[self.index] != quote)
        {
            if (self.bytes[self.index] == '<' or
                self.bytes[self.index] == '&')
            {
                return error.UnsupportedBodySanitization;
            }
            self.index += 1;
        }
        if (self.index >= self.bytes.len)
            return error.UnsupportedBodySanitization;
        const value = self.bytes[start..self.index];
        self.index += 1;
        return value;
    }

    fn attributeSensitive(
        self: *XmlInspector,
        name: []const u8,
        value: []const u8,
    ) !bool {
        return isSensitiveBodyField(name) or
            ((normalizedFieldEquals(name, "key") or
                normalizedFieldEquals(name, "name") or
                normalizedFieldEquals(name, "field") or
                normalizedFieldEquals(name, "property")) and
                isSensitiveBodyField(value)) or
            try containsSensitiveAssignment(self.allocator, value) or
            try containsSensitiveScalar(self.allocator, value) or
            containsPrivateKeyMarker(value);
    }

    fn inspectText(self: *XmlInspector, value: []const u8) !void {
        if (std.mem.indexOfScalar(u8, value, '&') != null)
            return error.UnsupportedBodySanitization;
        if (try containsSensitiveAssignment(self.allocator, value) or
            try containsSensitiveScalar(self.allocator, value) or
            containsPrivateKeyMarker(value))
        {
            self.sensitive = true;
        }
    }

    fn skipWhitespace(self: *XmlInspector) void {
        while (self.index < self.bytes.len and
            (self.bytes[self.index] == ' ' or
                self.bytes[self.index] == '\t' or
                self.bytes[self.index] == '\r' or
                self.bytes[self.index] == '\n'))
        {
            self.index += 1;
        }
    }

    fn consume(self: *XmlInspector, value: []const u8) bool {
        if (!std.mem.startsWith(u8, self.bytes[self.index..], value))
            return false;
        self.index += value.len;
        return true;
    }
};

fn inspectXmlDocument(
    allocator: std.mem.Allocator,
    body: []const u8,
) !bool {
    var inspector = XmlInspector{
        .allocator = allocator,
        .bytes = body,
    };
    return inspector.inspect();
}

fn xmlLocalName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon|
        return name[colon + 1 ..];
    return name;
}

fn isXmlNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or
        byte == '_' or byte == ':' or byte >= 0x80;
}

fn isXmlNameByte(byte: u8) bool {
    return isXmlNameStart(byte) or
        std.ascii.isDigit(byte) or byte == '-' or byte == '.';
}

fn containsSensitiveXml(
    allocator: std.mem.Allocator,
    body: []const u8,
) !bool {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, index, '<')) |open| {
        index = open + 1;
        if (index >= body.len) break;
        if (body[index] == '/' or body[index] == '?' or body[index] == '!') {
            index += 1;
        }
        const name_start = index;
        while (index < body.len and
            body[index] != '>' and
            body[index] != '/' and
            body[index] != ' ' and
            body[index] != '\t' and
            body[index] != '\r' and
            body[index] != '\n')
        {
            index += 1;
        }
        var name = body[name_start..index];
        if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| {
            name = name[colon + 1 ..];
        }
        if (isSensitiveBodyField(name)) return true;

        while (index < body.len and body[index] != '>') {
            while (index < body.len and
                (body[index] == ' ' or
                    body[index] == '\t' or
                    body[index] == '\r' or
                    body[index] == '\n' or
                    body[index] == '/'))
            {
                index += 1;
            }
            if (index >= body.len or body[index] == '>') break;
            const attribute_start = index;
            while (index < body.len and
                body[index] != '=' and
                body[index] != '>' and
                body[index] != ' ' and
                body[index] != '\t' and
                body[index] != '\r' and
                body[index] != '\n')
            {
                index += 1;
            }
            var attribute_name = body[attribute_start..index];
            if (std.mem.lastIndexOfScalar(u8, attribute_name, ':')) |colon| {
                attribute_name = attribute_name[colon + 1 ..];
            }
            while (index < body.len and
                (body[index] == ' ' or
                    body[index] == '\t' or
                    body[index] == '\r' or
                    body[index] == '\n'))
            {
                index += 1;
            }
            if (index >= body.len or body[index] != '=') continue;
            index += 1;
            while (index < body.len and
                (body[index] == ' ' or
                    body[index] == '\t' or
                    body[index] == '\r' or
                    body[index] == '\n'))
            {
                index += 1;
            }
            if (index >= body.len) break;
            const quote = if (body[index] == '"' or body[index] == '\'')
                body[index]
            else
                0;
            if (quote != 0) index += 1;
            const value_start = index;
            while (index < body.len and
                if (quote != 0)
                    body[index] != quote
                else
                    body[index] != ' ' and
                        body[index] != '\t' and
                        body[index] != '\r' and
                        body[index] != '\n' and
                        body[index] != '>')
            {
                index += 1;
            }
            const attribute_value = body[value_start..index];
            if (isSensitiveBodyField(attribute_name) or
                ((normalizedFieldEquals(attribute_name, "key") or
                    normalizedFieldEquals(attribute_name, "name") or
                    normalizedFieldEquals(attribute_name, "field") or
                    normalizedFieldEquals(attribute_name, "property")) and
                    isSensitiveBodyField(attribute_value)) or
                try containsSensitiveAssignment(allocator, attribute_value) or
                containsPrivateKeyMarker(attribute_value))
            {
                return true;
            }
            if (quote != 0 and index < body.len) index += 1;
        }
    }
    return false;
}

fn writeHeaders(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    options: RecordingOptions,
    exchange: OwnedExchange,
    direction: BodyDirection,
) !void {
    const headers = switch (direction) {
        .request => exchange.request_headers,
        .response => exchange.response_headers,
    };
    try writer.writeByte('[');
    for (headers, 0..) |header, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try writeMetadataBytes(writer, allocator, header.name);
        try writer.writeAll(",\"value\":");
        const context = HeaderSafetyContext{
            .direction = direction,
            .method = exchange.request_method,
            .url = exchange.request_url,
            .name = header.name,
            .value = header.value,
        };
        const decision = if (options.headerPolicyFn) |policy|
            policy(options.header_policy_context, context)
        else
            .inspect;
        var sanitized_url: ?[]u8 = null;
        defer if (sanitized_url) |url| allocator.free(url);
        var sanitized_template: ?[]u8 = null;
        defer if (sanitized_template) |template|
            allocator.free(template);
        var redact = header.redacted;
        if (!redact) switch (decision) {
            .redact => redact = true,
            .preserve => {},
            .inspect => if (isSanitizedUrlHeader(header.name)) {
                sanitized_url = sanitizeLocationUrlAlloc(
                    allocator,
                    header.value,
                ) catch |err| switch (err) {
                    error.SensitiveUrlRequiresSanitization => null,
                    else => return err,
                };
                redact = sanitized_url == null;
                if (sanitized_url) |url| {
                    if (!std.mem.eql(u8, header.value, url)) {
                        const template =
                            try sanitizeLocationUrlAllocWithMarker(
                                allocator,
                                header.value,
                                "\x00",
                            );
                        if (std.mem.indexOfScalar(u8, template, 0) != null) {
                            sanitized_template = template;
                        } else {
                            allocator.free(template);
                        }
                    }
                }
            } else {
                redact = try shouldRedactHeader(
                    allocator,
                    direction,
                    header.name,
                    header.value,
                );
            },
        };
        if (redact) {
            try writeJsonString(writer, redacted_value);
        } else if (sanitized_url) |url| {
            try writeMetadataBytes(writer, allocator, url);
        } else {
            try writeMetadataBytes(writer, allocator, header.value);
        }
        try writer.print(",\"redacted\":{}", .{redact});
        try writer.writeAll(",\"url_redaction_template\":");
        if (!redact) {
            if (sanitized_template) |template|
                try writeMetadataBytes(writer, allocator, template)
            else
                try writer.writeAll("null");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn sanitizeUrlAlloc(
    allocator: std.mem.Allocator,
    url: []const u8,
) ![]u8 {
    return sanitizeUrlAllocWithMarker(allocator, url, redacted_value);
}

fn sanitizeUrlAllocWithMarker(
    allocator: std.mem.Allocator,
    url: []const u8,
    marker: []const u8,
) ![]u8 {
    return sanitizeUrlAllocDepth(allocator, url, 0, marker);
}

fn sanitizeLocationUrlAlloc(
    allocator: std.mem.Allocator,
    url: []const u8,
) ![]u8 {
    return sanitizeLocationUrlAllocWithMarker(
        allocator,
        url,
        redacted_value,
    );
}

fn sanitizeLocationUrlAllocWithMarker(
    allocator: std.mem.Allocator,
    url: []const u8,
    marker: []const u8,
) ![]u8 {
    if (std.mem.indexOfScalar(u8, url, '#')) |fragment| {
        if (try encodedComponentIsSensitive(
            allocator,
            url[fragment + 1 ..],
            false,
            true,
            0,
        )) {
            return sanitizeUrlAllocWithMarker(
                allocator,
                url[0..fragment],
                marker,
            );
        }
    }
    return sanitizeUrlAllocWithMarker(allocator, url, marker);
}

const max_url_decode_depth = 3;
const max_nested_url_depth = 4;
const max_sanitized_url_length = 256 * 1024;

fn canonicalUrlComponentAlloc(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    plus_as_space: bool,
) ![]u8 {
    if (encoded.len > max_sanitized_url_length)
        return error.SensitiveBodyRequiresSanitization;
    var current: ?[]u8 = try allocator.dupe(u8, encoded);
    errdefer if (current) |bytes| allocator.free(bytes);
    var decode_count: usize = 0;
    while (decode_count < max_url_decode_depth) : (decode_count += 1) {
        const decoded = percentDecodeAlloc(
            allocator,
            current.?,
            plus_as_space and decode_count == 0,
        ) catch |err| switch (err) {
            error.SensitiveUrlRequiresSanitization => return error.SensitiveBodyRequiresSanitization,
            else => return err,
        };
        const changed = !std.mem.eql(u8, current.?, decoded);
        allocator.free(current.?);
        current = decoded;
        if (std.mem.indexOfAny(u8, decoded, "\x00\r\n") != null)
            return error.SensitiveBodyRequiresSanitization;
        if (!changed) {
            const result = current.?;
            current = null;
            return result;
        }
    }
    if (containsPercentEscape(current.?))
        return error.SensitiveBodyRequiresSanitization;
    const result = current.?;
    current = null;
    return result;
}

fn sanitizeUrlAllocDepth(
    allocator: std.mem.Allocator,
    url: []const u8,
    nesting: usize,
    marker: []const u8,
) anyerror![]u8 {
    if (nesting > max_nested_url_depth or
        url.len == 0 or
        url.len > max_sanitized_url_length or
        std.mem.indexOfAny(u8, url, "\x00\r\n") != null)
    {
        return error.SensitiveUrlRequiresSanitization;
    }

    const fragment = std.mem.indexOfScalar(u8, url, '#');
    const reference_end = fragment orelse url.len;
    const question = std.mem.indexOfScalar(u8, url[0..reference_end], '?');
    var path_start: usize = 0;
    var authority_range: ?struct { start: usize, end: usize } = null;
    const scheme_end_value = schemeEndAtReferenceStart(url, reference_end);
    if (scheme_end_value) |scheme_end| {
        const scheme = url[0..scheme_end];
        if (!std.ascii.eqlIgnoreCase(scheme, "https") and
            !std.ascii.eqlIgnoreCase(scheme, "http"))
        {
            return error.SensitiveUrlRequiresSanitization;
        }
        if (!std.mem.startsWith(u8, url[scheme_end + 1 ..], "//"))
            return error.SensitiveUrlRequiresSanitization;
        const authority_start = scheme_end + 3;
        const authority_end = std.mem.indexOfAnyPos(
            u8,
            url,
            authority_start,
            "/?#",
        ) orelse url.len;
        authority_range = .{ .start = authority_start, .end = authority_end };
        path_start = authority_end;
    } else if (std.mem.startsWith(u8, url, "//")) {
        const authority_start = 2;
        const authority_end = std.mem.indexOfAnyPos(
            u8,
            url,
            authority_start,
            "/?#",
        ) orelse url.len;
        authority_range = .{ .start = authority_start, .end = authority_end };
        path_start = authority_end;
    }
    if (authority_range) |range| {
        if (range.end < range.start or range.end > reference_end)
            return error.SensitiveUrlRequiresSanitization;
        const authority = url[range.start..range.end];
        if (authority.len == 0 or
            try encodedAuthorityIsSensitive(
                allocator,
                authority,
            ))
        {
            return error.SensitiveUrlRequiresSanitization;
        }
    }

    const query_start = question orelse reference_end;
    if (path_start > query_start)
        return error.SensitiveUrlRequiresSanitization;
    if (try encodedComponentIsSensitive(
        allocator,
        url[path_start..query_start],
        false,
        false,
        nesting,
    )) return error.SensitiveUrlRequiresSanitization;
    if (fragment) |fragment_start| {
        if (try encodedComponentIsSensitive(
            allocator,
            url[fragment_start + 1 ..],
            false,
            true,
            nesting,
        )) return error.SensitiveUrlRequiresSanitization;
    }

    if (question == null) return allocator.dupe(u8, url);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(url[0 .. query_start + 1]);
    var first = true;
    var iterator = std.mem.splitScalar(
        u8,
        url[query_start + 1 .. reference_end],
        '&',
    );
    while (iterator.next()) |parameter| {
        if (!first) try output.writer.writeByte('&');
        first = false;
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse {
            if (try encodedQueryNameIsSensitive(
                allocator,
                parameter,
            ) or try encodedComponentIsSensitive(
                allocator,
                parameter,
                true,
                true,
                nesting,
            )) {
                try output.writer.writeAll(parameter);
                try output.writer.writeAll("=");
                try output.writer.writeAll(marker);
            } else {
                try output.writer.writeAll(parameter);
            }
            continue;
        };
        const encoded_name = parameter[0..equals];
        const encoded_value = parameter[equals + 1 ..];
        const redact_name = try encodedQueryNameIsSensitive(
            allocator,
            encoded_name,
        );
        try output.writer.writeAll(encoded_name);
        try output.writer.writeByte('=');
        if (redact_name) {
            try output.writer.writeAll(marker);
        } else {
            const sanitized_value = try sanitizeQueryValueAlloc(
                allocator,
                encoded_value,
                nesting,
                marker,
            );
            defer allocator.free(sanitized_value);
            try output.writer.writeAll(sanitized_value);
        }
    }
    if (fragment) |fragment_start| {
        try output.writer.writeAll(url[fragment_start..]);
    }
    return output.toOwnedSlice();
}

fn sanitizeQueryValueAlloc(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    nesting: usize,
    marker: []const u8,
) ![]u8 {
    if (encoded.len > max_sanitized_url_length)
        return allocator.dupe(u8, marker);
    var current = try allocator.dupe(u8, encoded);
    defer allocator.free(current);
    var decoded_layers: usize = 0;
    while (true) {
        if (looksLikeNestedUriReference(current)) {
            if (nesting >= max_nested_url_depth)
                return allocator.dupe(u8, marker);
            const sanitized_nested = sanitizeUrlAllocDepth(
                allocator,
                current,
                nesting + 1,
                marker,
            ) catch |err| switch (err) {
                error.SensitiveUrlRequiresSanitization => {
                    return allocator.dupe(u8, marker);
                },
                else => return err,
            };
            defer allocator.free(sanitized_nested);
            if (std.mem.eql(u8, current, sanitized_nested))
                return allocator.dupe(u8, encoded);
            var result = try allocator.dupe(u8, sanitized_nested);
            errdefer allocator.free(result);
            for (0..decoded_layers) |_| {
                const next = try percentEncodeQueryValueAlloc(
                    allocator,
                    result,
                    marker,
                );
                allocator.free(result);
                result = next;
            }
            return result;
        }
        if (decoded_layers == max_url_decode_depth) break;
        const decoded = try percentDecodeAlloc(
            allocator,
            current,
            false,
        );
        const changed = !std.mem.eql(u8, current, decoded);
        allocator.free(current);
        current = decoded;
        if (!changed) break;
        decoded_layers += 1;
    }
    if (containsPercentEscape(current))
        return allocator.dupe(u8, marker);
    if (try containsSensitiveScalar(allocator, current))
        return allocator.dupe(u8, marker);
    if (std.mem.indexOfScalar(u8, current, '+') != null) {
        const form_value = try allocator.dupe(u8, current);
        defer allocator.free(form_value);
        std.mem.replaceScalar(u8, form_value, '+', ' ');
        if (try containsSensitiveScalar(allocator, form_value))
            return allocator.dupe(u8, marker);
    }
    return allocator.dupe(u8, encoded);
}

fn percentEncodeQueryValueAlloc(
    allocator: std.mem.Allocator,
    value: []const u8,
    marker: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const hex = "0123456789ABCDEF";
    var index: usize = 0;
    while (index < value.len) {
        if (marker.len != 0 and
            std.mem.startsWith(u8, value[index..], marker))
        {
            try output.writer.writeAll(marker);
            index += marker.len;
            continue;
        }
        const byte = value[index];
        index += 1;
        if (std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '.' or byte == '_' or byte == '~')
        {
            try output.writer.writeByte(byte);
        } else {
            try output.writer.writeByte('%');
            try output.writer.writeByte(hex[byte >> 4]);
            try output.writer.writeByte(hex[byte & 0x0f]);
        }
    }
    return output.toOwnedSlice();
}

fn encodedAuthorityIsSensitive(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !bool {
    if (encoded.len > max_sanitized_url_length) return true;
    var current = try allocator.dupe(u8, encoded);
    defer allocator.free(current);
    var decode_count: usize = 0;
    while (decode_count < max_url_decode_depth) : (decode_count += 1) {
        const decoded = try percentDecodeAlloc(allocator, current, false);
        const changed = !std.mem.eql(u8, current, decoded);
        allocator.free(current);
        current = decoded;
        if (std.mem.indexOfAny(u8, current, "@\x00\r\n") != null or
            try containsSensitiveScalar(allocator, current))
        {
            return true;
        }
        if (!changed) return false;
    }
    return containsPercentEscape(current);
}

fn encodedQueryNameIsSensitive(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !bool {
    if (encoded.len > max_sanitized_url_length) return true;
    var current = try allocator.dupe(u8, encoded);
    defer allocator.free(current);
    var decode_count: usize = 0;
    while (decode_count < max_url_decode_depth) : (decode_count += 1) {
        const decoded = try percentDecodeAlloc(
            allocator,
            current,
            decode_count == 0,
        );
        const changed = !std.mem.eql(u8, current, decoded);
        allocator.free(current);
        current = decoded;
        if (isSensitiveQueryField(current)) return true;
        if (!changed) return false;
    }
    return containsPercentEscape(current);
}

fn encodedComponentIsSensitive(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    plus_as_space: bool,
    inspect_uri: bool,
    nesting: usize,
) anyerror!bool {
    if (encoded.len > max_sanitized_url_length) return true;
    var current = try allocator.dupe(u8, encoded);
    defer allocator.free(current);
    var decode_count: usize = 0;
    while (decode_count < max_url_decode_depth) : (decode_count += 1) {
        const decoded = try percentDecodeAlloc(
            allocator,
            current,
            plus_as_space and decode_count == 0,
        );
        const changed = !std.mem.eql(u8, current, decoded);
        allocator.free(current);
        current = decoded;
        if (try containsSensitiveScalar(allocator, current)) return true;
        if (inspect_uri and looksLikeNestedUriReference(current)) {
            if (nesting >= max_nested_url_depth) return true;
            const sanitized = sanitizeUrlAllocDepth(
                allocator,
                current,
                nesting + 1,
                redacted_value,
            ) catch |err| switch (err) {
                error.SensitiveUrlRequiresSanitization => return true,
                else => return err,
            };
            defer allocator.free(sanitized);
            if (!std.mem.eql(u8, current, sanitized)) return true;
        }
        if (!changed) return false;
    }
    return containsPercentEscape(current);
}

fn looksLikeNestedUriReference(value: []const u8) bool {
    if (value.len == 0) return false;
    return value[0] == '/' or
        std.mem.indexOfAny(u8, value, "?#") != null or
        schemeEndAtReferenceStart(value, value.len) != null;
}

fn containsPercentEscape(value: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, value, index, '%')) |percent| {
        if (percent + 2 < value.len) {
            _ = std.fmt.charToDigit(value[percent + 1], 16) catch {
                index = percent + 1;
                continue;
            };
            _ = std.fmt.charToDigit(value[percent + 2], 16) catch {
                index = percent + 1;
                continue;
            };
            return true;
        }
        index = percent + 1;
    }
    return false;
}

fn schemeEndAtReferenceStart(url: []const u8, reference_end: usize) ?usize {
    const colon = std.mem.indexOfScalar(u8, url[0..reference_end], ':') orelse
        return null;
    const first_delimiter = std.mem.indexOfAny(u8, url[0..reference_end], "/") orelse
        reference_end;
    if (colon > first_delimiter or colon == 0 or
        !std.ascii.isAlphabetic(url[0]))
    {
        return null;
    }
    for (url[1..colon]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '+' and byte != '-' and byte != '.')
        {
            return null;
        }
    }
    return colon;
}

fn percentDecodeAlloc(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    plus_as_space: bool,
) ![]u8 {
    const decoded = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(decoded);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < encoded.len) {
        if (encoded[input_index] == '%') {
            if (input_index + 2 >= encoded.len)
                return error.SensitiveUrlRequiresSanitization;
            const high = std.fmt.charToDigit(
                encoded[input_index + 1],
                16,
            ) catch return error.SensitiveUrlRequiresSanitization;
            const low = std.fmt.charToDigit(
                encoded[input_index + 2],
                16,
            ) catch return error.SensitiveUrlRequiresSanitization;
            decoded[output_index] = high * 16 + low;
            input_index += 3;
        } else {
            decoded[output_index] = if (plus_as_space and
                encoded[input_index] == '+')
                ' '
            else
                encoded[input_index];
            input_index += 1;
        }
        output_index += 1;
    }
    return allocator.realloc(decoded, output_index);
}

fn isSensitiveQueryField(name: []const u8) bool {
    var decoded_buffer: [256]u8 = undefined;
    const candidate = percentDecodeFieldName(name, &decoded_buffer) orelse
        name;
    for (sensitive_query_fields) |sensitive| {
        if (std.ascii.eqlIgnoreCase(candidate, sensitive)) return true;
    }
    for ([_][]const u8{
        "xamzsignature",
        "xamzcredential",
        "xamzsecuritytoken",
        "awsaccesskeyid",
        "securitytoken",
        "xgoogsignature",
        "xgoogcredential",
        "googleaccessid",
    }) |vendor_credential| {
        if (normalizedFieldEquals(candidate, vendor_credential)) return true;
    }
    return isSensitiveBodyField(candidate);
}

fn isFullyRedactedUrlHeader(name: []const u8) bool {
    for (fully_redacted_url_headers) |header| {
        if (std.ascii.eqlIgnoreCase(name, header)) return true;
    }
    return false;
}

fn isSanitizedUrlHeader(name: []const u8) bool {
    for (sanitized_url_headers) |header| {
        if (std.ascii.eqlIgnoreCase(name, header)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCasePos(haystack, 0, needle) != null;
}

fn indexOfIgnoreCasePos(
    haystack: []const u8,
    start: usize,
    needle: []const u8,
) ?usize {
    if (needle.len > haystack.len or start > haystack.len) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(
            haystack[index .. index + needle.len],
            needle,
        )) return index;
    }
    return null;
}

fn methodToString(method: core.http.Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
    };
}

fn writeOptionalBody(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !void {
    if (value) |bytes| {
        try writeBody(writer, allocator, bytes);
    } else {
        try writer.writeAll("null");
    }
}

fn writeBody(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    const encoded_length = std.base64.standard.Encoder.calcSize(value.len);
    const encoded = try allocator.alloc(u8, encoded_length);
    defer allocator.free(encoded);
    const result = std.base64.standard.Encoder.encode(encoded, value);
    try writer.writeAll("{\"encoding\":\"base64\",\"data\":");
    try writeJsonString(writer, result);
    try writer.writeByte('}');
}

fn writeMetadataBytes(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    if (std.unicode.utf8ValidateSlice(value)) {
        try writeJsonString(writer, value);
    } else {
        try writeBody(writer, allocator, value);
    }
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (byte < 0x20) {
                const hex = "0123456789abcdef";
                try writer.writeAll("\\u00");
                try writer.writeByte(hex[byte >> 4]);
                try writer.writeByte(hex[byte & 0x0f]);
            } else {
                try writer.writeByte(byte);
            },
        }
    }
    try writer.writeByte('"');
}

pub fn expectSuccess(response: core.http.Response) !void {
    if (!response.isSuccess()) return error.UnexpectedStatus;
}

pub fn expectStatus(response: core.http.Response, expected: u16) !void {
    try std.testing.expectEqual(expected, response.status_code);
}

const BufferedOnlyTransport = struct {
    inner: *core.http.MockTransport,

    const vtable: core.http.HttpTransport.VTable = .{
        .send = &send,
    };

    fn asTransport(self: *BufferedOnlyTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(
        context: *anyopaque,
        request: *core.http.Request,
    ) !core.http.Response {
        const self: *BufferedOnlyTransport = @ptrCast(@alignCast(context));
        const transport = self.inner.asTransport();
        return transport.vtable.send(transport.context, request);
    }
};

const GuardedAllocator = struct {
    child: std.mem.Allocator,
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    overlap: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = &alloc,
        .resize = &resize,
        .remap = &remap,
        .free = &free,
    };

    fn allocator(self: *GuardedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn enter(self: *GuardedAllocator) void {
        if (self.active.swap(true, .acquire))
            self.overlap.store(true, .release);
        for (0..10_000) |_| std.atomic.spinLoopHint();
    }

    fn leave(self: *GuardedAllocator) void {
        self.active.store(false, .release);
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *GuardedAllocator = @ptrCast(@alignCast(context));
        self.enter();
        defer self.leave();
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *GuardedAllocator = @ptrCast(@alignCast(context));
        self.enter();
        defer self.leave();
        return self.child.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *GuardedAllocator = @ptrCast(@alignCast(context));
        self.enter();
        defer self.leave();
        return self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *GuardedAllocator = @ptrCast(@alignCast(context));
        self.enter();
        defer self.leave();
        self.child.rawFree(memory, alignment, return_address);
    }
};

const ThreadSafeEmptyTransport = struct {
    const vtable: core.http.HttpTransport.VTable = .{ .send = &send };

    fn asTransport(self: *ThreadSafeEmptyTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(
        _: *anyopaque,
        request: *core.http.Request,
    ) !core.http.Response {
        const body = try request.allocator.alloc(u8, 0);
        return .{
            .status_code = 200,
            .headers = std.StringHashMap([]const u8).init(request.allocator),
            .body = body,
            .allocator = request.allocator,
            .response_headers = core.http.ResponseHeaders.init(request.allocator),
        };
    }
};

const ConcurrentRecorderWorker = struct {
    recorder: *RecordingTransport,
    start: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),

    fn run(self: *ConcurrentRecorderWorker) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        var request = core.http.Request.init(
            std.heap.page_allocator,
            .GET,
            "https://example.test/concurrent",
        );
        defer request.deinit();
        var response = self.recorder.asTransport().send(&request) catch {
            self.failed.store(true, .release);
            return;
        };
        response.deinit();
    }
};

const FailureStageTransport = struct {
    allocator: std.mem.Allocator,
    inner: *core.http.MockTransport,
    mode: enum {
        transport,
        open,
        body,
        finish,
        cancel_open,
        cancel_body,
    },
    call_count: usize = 0,

    const vtable: core.http.HttpTransport.VTable = .{
        .send = &send,
        .open = &open,
    };

    fn asTransport(self: *FailureStageTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(
        context: *anyopaque,
        request: *core.http.Request,
    ) !core.http.Response {
        const self: *FailureStageTransport =
            @ptrCast(@alignCast(context));
        self.call_count += 1;
        if (self.mode == .transport and self.call_count == 1)
            return error.ConnectionResetByPeer;
        const transport = self.inner.asTransport();
        return transport.vtable.send(transport.context, request);
    }

    fn open(
        context: *anyopaque,
        request: *core.http.Request,
        options: core.http.OpenOptions,
    ) !*core.http.HttpOperation {
        const self: *FailureStageTransport =
            @ptrCast(@alignCast(context));
        self.call_count += 1;
        if (self.mode == .open and self.call_count == 1)
            return error.ConnectionResetByPeer;
        if (self.mode == .cancel_open and self.call_count == 1) {
            var prefix: [3]u8 = undefined;
            try options.body.?.reader.readSliceAll(&prefix);
            return error.OperationCancelled;
        }
        if (self.call_count == 1 and
            (self.mode == .body or
                self.mode == .finish or
                self.mode == .cancel_body))
        {
            return FailureStageOperation.create(
                self.allocator,
                self.mode == .body or self.mode == .cancel_body,
                self.mode == .finish,
                if (self.mode == .cancel_body)
                    error.OperationCancelled
                else
                    error.ConnectionResetByPeer,
            );
        }
        const transport = self.inner.asTransport();
        return transport.vtable.open.?(
            transport.context,
            request,
            options,
        );
    }
};

const FailureStageOperation = struct {
    operation: core.http.HttpOperation,
    allocator: std.mem.Allocator,
    reader: FailureStageReader,
    fail_body: bool,
    fail_finish: bool,
    failure: anyerror,

    fn create(
        allocator: std.mem.Allocator,
        fail_body: bool,
        fail_finish: bool,
        failure: anyerror,
    ) !*core.http.HttpOperation {
        const self = try allocator.create(FailureStageOperation);
        errdefer allocator.destroy(self);
        var headers = std.StringHashMap([]const u8).init(allocator);
        errdefer headers.deinit();
        var response_headers = core.http.ResponseHeaders.init(allocator);
        errdefer response_headers.deinit();
        self.* = .{
            .operation = undefined,
            .allocator = allocator,
            .reader = undefined,
            .fail_body = fail_body,
            .fail_finish = fail_finish,
            .failure = failure,
        };
        self.reader.init(if (fail_body) "partial" else "", fail_body);
        self.operation = .{
            .status_code = 200,
            .headers = headers,
            .response_headers = response_headers,
            .body_reader = &self.reader.interface,
            .finishFn = &finish,
            .abortFn = &abort,
            .cancelFn = &abort,
            .deinitFn = &deinit,
            .bodyErrorFn = &bodyError,
        };
        return &self.operation;
    }

    fn finish(operation: *core.http.HttpOperation) !void {
        const self: *FailureStageOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        if (self.fail_finish) return self.failure;
    }

    fn abort(_: *core.http.HttpOperation) void {}

    fn bodyError(operation: *const core.http.HttpOperation) ?anyerror {
        const self: *const FailureStageOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        return if (self.fail_body) self.failure else null;
    }

    fn deinit(operation: *core.http.HttpOperation) void {
        const self: *FailureStageOperation =
            @alignCast(@fieldParentPtr("operation", operation));
        self.operation.headers.deinit();
        self.operation.response_headers.deinit();
        self.allocator.destroy(self);
    }
};

const FailureStageReader = struct {
    interface: std.Io.Reader,
    bytes: []const u8,
    offset: usize = 0,
    buffer: [32]u8 = undefined,

    fn init(
        self: *FailureStageReader,
        bytes: []const u8,
        _: bool,
    ) void {
        self.* = .{
            .interface = undefined,
            .bytes = bytes,
        };
        self.interface = .{
            .vtable = &.{
                .stream = &stream,
                .readVec = &readVec,
            },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(
        interface: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *FailureStageReader =
            @alignCast(@fieldParentPtr("interface", interface));
        if (self.offset != self.bytes.len) {
            const count = @min(
                limit.minInt(self.bytes.len - self.offset),
                self.bytes.len - self.offset,
            );
            if (count == 0) return 0;
            try writer.writeAll(self.bytes[self.offset..][0..count]);
            self.offset += count;
            return count;
        }
        return error.EndOfStream;
    }

    fn readVec(
        interface: *std.Io.Reader,
        data: [][]u8,
    ) std.Io.Reader.Error!usize {
        const self: *FailureStageReader =
            @alignCast(@fieldParentPtr("interface", interface));
        var total: usize = 0;
        for (data) |destination| {
            const count = @min(
                destination.len,
                self.bytes.len - self.offset,
            );
            @memcpy(
                destination[0..count],
                self.bytes[self.offset..][0..count],
            );
            self.offset += count;
            total += count;
            if (self.offset == self.bytes.len) break;
        }
        if (total != 0) return total;
        return error.EndOfStream;
    }
};

const ReplayableRequestBody = struct {
    bytes: []const u8,
    reader: std.Io.Reader,
    rewind_count: usize = 0,

    fn init(bytes: []const u8) ReplayableRequestBody {
        return .{
            .bytes = bytes,
            .reader = std.Io.Reader.fixed(bytes),
        };
    }

    fn streaming(self: *ReplayableRequestBody) core.http.StreamingRequestBody {
        return core.http.StreamingRequestBody.chunked(&self.reader).withRewind(
            self,
            &rewind,
        );
    }

    fn rewind(context: *anyopaque) !*std.Io.Reader {
        const self: *ReplayableRequestBody =
            @ptrCast(@alignCast(context));
        self.rewind_count += 1;
        self.reader = std.Io.Reader.fixed(self.bytes);
        return &self.reader;
    }
};

const CooperativeCancellingReader = struct {
    interface: std.Io.Reader,
    bytes: []const u8,
    offset: usize = 0,
    cancellation: *core.http.CancellationToken,

    fn init(
        self: *CooperativeCancellingReader,
        bytes: []const u8,
        cancellation: *core.http.CancellationToken,
    ) void {
        self.* = .{
            .interface = undefined,
            .bytes = bytes,
            .cancellation = cancellation,
        };
        self.interface = .{
            .vtable = &.{
                .stream = &stream,
                .readVec = &readVec,
            },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(
        interface: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *CooperativeCancellingReader =
            @alignCast(@fieldParentPtr("interface", interface));
        const count = @min(
            limit.minInt(self.bytes.len - self.offset),
            self.bytes.len - self.offset,
        );
        if (count == 0) return error.EndOfStream;
        try writer.writeAll(self.bytes[self.offset..][0..count]);
        self.offset += count;
        if (self.offset == self.bytes.len) self.cancellation.cancel();
        return count;
    }

    fn readVec(
        interface: *std.Io.Reader,
        data: [][]u8,
    ) std.Io.Reader.Error!usize {
        const self: *CooperativeCancellingReader =
            @alignCast(@fieldParentPtr("interface", interface));
        var total: usize = 0;
        for (data) |destination| {
            const count = @min(
                destination.len,
                self.bytes.len - self.offset,
            );
            @memcpy(
                destination[0..count],
                self.bytes[self.offset..][0..count],
            );
            self.offset += count;
            total += count;
            if (self.offset == self.bytes.len) break;
        }
        if (self.offset == self.bytes.len) self.cancellation.cancel();
        if (total != 0) return total;
        return error.EndOfStream;
    }
};

fn allowKnownSafeOpaqueBody(
    _: ?*anyopaque,
    body: BodySafetyContext,
) BodyPolicyDecision {
    return if (containsIgnoreCase(body.url, "example.com/invalid") or
        containsIgnoreCase(body.url, "example.com/nul"))
        .allow_opaque
    else
        .inspect;
}

fn inspectKnownSafeBody(
    _: ?*anyopaque,
    _: BodySafetyContext,
) BodyPolicyDecision {
    return .inspect;
}

fn allowOpaqueBody(
    _: ?*anyopaque,
    _: BodySafetyContext,
) BodyPolicyDecision {
    return .allow_opaque;
}

fn preserveKnownSafeMetadata(
    _: ?*anyopaque,
    header: HeaderSafetyContext,
) HeaderPolicyDecision {
    if (std.ascii.eqlIgnoreCase(header.name, "x-ms-meta-pwd"))
        return .preserve;
    if (std.ascii.eqlIgnoreCase(header.name, "x-stable"))
        return .preserve;
    if (std.ascii.eqlIgnoreCase(header.name, "x-application-auth-material"))
        return .redact;
    return .inspect;
}

fn preserveRequestDate(
    _: ?*anyopaque,
    header: HeaderSafetyContext,
) HeaderPolicyDecision {
    return if (std.ascii.eqlIgnoreCase(header.name, "x-ms-date"))
        .preserve
    else
        .inspect;
}

fn expectRejectedSerializationExcludes(
    recorder: *RecordingTransport,
    expected_error: anyerror,
    secrets: []const []const u8,
) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(
        expected_error,
        recorder.writeJson(&output.writer, std.testing.allocator),
    );
    for (secrets) |secret| {
        try std.testing.expect(
            std.mem.indexOf(u8, output.written(), secret) == null,
        );
    }
}

test "playback validates request and preserves duplicate response headers" {
    const recordings = [_]RecordedExchange{.{
        .request_method = .POST,
        .request_url = "https://example.com/items",
        .request_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .request_body = "{}",
        .response_status = 201,
        .response_body = "created",
        .response_headers = &.{
            .{ .name = "X-Value", .value = "first" },
            .{ .name = "x-value", .value = "second" },
        },
    }};
    var playback = PlaybackTransport.init(std.testing.allocator, &recordings);
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/items",
    );
    defer request.deinit();
    request.body = "{}";
    try request.setHeader("Content-Type", "application/json");
    try request.setHeader("User-Agent", "volatile");

    var response = try playback.asTransport().send(&request);
    defer response.deinit();
    const values = try response.getHeaderValues(std.testing.allocator, "X-VALUE");
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("first", values[0]);
    try std.testing.expectEqualStrings("second", values[1]);
}

test "playback supports streaming upload and response lifecycle" {
    const recordings = [_]RecordedExchange{.{
        .request_method = .PUT,
        .request_url = "https://example.com/stream",
        .request_body = "streaming",
        .response_status = 200,
        .response_body = "response",
    }};
    var playback = PlaybackTransport.init(std.testing.allocator, &recordings);
    var request = core.http.Request.init(
        std.testing.allocator,
        .PUT,
        "https://example.com/stream",
    );
    defer request.deinit();
    var source = std.Io.Reader.fixed("streaming");
    var operation = try playback.asTransport().open(&request, .{
        .body = core.http.StreamingRequestBody.knownLength(&source, 9),
    });
    const response = try (try operation.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("response", response);
    try operation.finish();
    operation.deinit();
    try std.testing.expectEqual(@as(usize, 1), playback.finish_count);
    try std.testing.expectEqual(@as(usize, 1), playback.deinit_count);
}

test "playback preserves abort and cancellation semantics" {
    const recordings = [_]RecordedExchange{
        .{
            .request_method = .GET,
            .request_url = "https://example.com/abort",
            .response_status = 200,
            .response_body = "abort",
        },
        .{
            .request_method = .GET,
            .request_url = "https://example.com/cancel",
            .response_status = 200,
            .response_body = "cancel",
        },
    };
    var playback = PlaybackTransport.init(std.testing.allocator, &recordings);
    var abort_request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/abort",
    );
    defer abort_request.deinit();
    var aborted = try playback.asTransport().open(&abort_request, .{});
    aborted.abort();
    aborted.deinit();
    try std.testing.expectEqual(@as(usize, 1), playback.index);

    var cancel_request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/cancel",
    );
    defer cancel_request.deinit();
    var cancelled = try playback.asTransport().open(&cancel_request, .{});
    cancelled.cancel();
    cancelled.deinit();
    try std.testing.expectEqual(@as(usize, 2), playback.index);
    try std.testing.expectEqual(@as(usize, 1), playback.abort_count);
    try std.testing.expectEqual(@as(usize, 1), playback.cancel_count);
    try std.testing.expectEqual(@as(usize, 0), playback.finish_count);
    try std.testing.expectEqual(@as(usize, 2), playback.deinit_count);
}

test "playback follows redirects and cleans intermediate operations" {
    const recordings = [_]RecordedExchange{
        .{
            .request_method = .GET,
            .request_url = "https://example.com/start",
            .response_status = 302,
            .response_body = "",
            .response_headers = &.{
                .{ .name = "Location", .value = "/final" },
            },
        },
        .{
            .request_method = .GET,
            .request_url = "https://example.com/final",
            .response_status = 200,
            .response_body = "done",
        },
    };
    var playback = PlaybackTransport.init(std.testing.allocator, &recordings);
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/start",
    );
    defer request.deinit();
    var operation = try playback.asTransport().open(&request, .{});
    const body = try (try operation.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("done", body);
    try operation.finish();
    operation.deinit();
    try std.testing.expectEqual(@as(usize, 2), playback.index);
    try std.testing.expectEqual(@as(usize, 1), playback.abort_count);
    try std.testing.expectEqual(@as(usize, 1), playback.finish_count);
    try std.testing.expectEqual(@as(usize, 2), playback.deinit_count);
}

test "playback cancellation does not consume a recording" {
    const recordings = [_]RecordedExchange{.{
        .request_method = .POST,
        .request_url = "https://example.com/cancel",
        .request_body = "part",
        .response_status = 200,
        .response_body = "",
    }};
    var playback = PlaybackTransport.init(std.testing.allocator, &recordings);
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/cancel",
    );
    defer request.deinit();
    var token = core.http.CancellationToken{};
    const CancellingReader = struct {
        interface: std.Io.Reader,
        token: *core.http.CancellationToken,
        emitted: bool = false,

        fn init(value: *@This(), cancellation: *core.http.CancellationToken) void {
            value.* = .{
                .interface = .{
                    .vtable = &.{ .stream = &stream },
                    .buffer = &.{},
                    .seek = 0,
                    .end = 0,
                },
                .token = cancellation,
            };
        }

        fn stream(
            interface: *std.Io.Reader,
            writer: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            const self: *@This() =
                @alignCast(@fieldParentPtr("interface", interface));
            if (self.emitted) return error.EndOfStream;
            const bytes = limit.sliceConst("part");
            try writer.writeAll(bytes);
            self.emitted = true;
            self.token.cancel();
            return bytes.len;
        }
    };
    var source: CancellingReader = undefined;
    source.init(&token);
    try std.testing.expectError(
        error.OperationCancelled,
        playback.asTransport().open(&request, .{
            .body = core.http.StreamingRequestBody.chunked(&source.interface),
            .cancellation = &token,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), playback.index);
}

test "playback detects URL body and header mismatches without advancing" {
    const recordings = [_]RecordedExchange{.{
        .request_method = .POST,
        .request_url = "https://example.com/expected",
        .request_headers = &.{.{ .name = "X-Expected", .value = "yes" }},
        .request_body = "expected",
        .response_status = 200,
        .response_body = "",
    }};
    var playback = PlaybackTransport.init(std.testing.allocator, &recordings);
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/wrong",
    );
    defer request.deinit();
    request.body = "expected";
    try std.testing.expectError(
        error.UrlMismatch,
        playback.asTransport().send(&request),
    );
    request.url = "https://example.com/expected";
    request.body = "wrong";
    try std.testing.expectError(
        error.BodyMismatch,
        playback.asTransport().send(&request),
    );
    request.body = "expected";
    try std.testing.expectError(
        error.HeaderMismatch,
        playback.asTransport().send(&request),
    );
    try std.testing.expectEqual(@as(usize, 0), playback.index);
}

test "playback allocation failures do not consume buffered exchanges" {
    const recordings = [_]RecordedExchange{.{
        .request_method = .GET,
        .request_url = "https://example.test/retry",
        .response_status = 200,
        .response_body = "response",
        .response_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
    }};
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    var playback = PlaybackTransport.init(fixed.allocator(), &recordings);
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/retry",
    );
    defer request.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        playback.asTransport().send(&request),
    );
    try std.testing.expectEqual(@as(usize, 0), playback.index);

    playback.allocator = std.testing.allocator;
    var response = try playback.asTransport().send(&request);
    defer response.deinit();
    try std.testing.expectEqualStrings("response", response.body);
    try std.testing.expectEqual(@as(usize, 1), playback.index);
}

test "playback allocation failures do not consume streaming exchanges" {
    const recordings = [_]RecordedExchange{.{
        .request_method = .GET,
        .request_url = "https://example.test/retry-stream",
        .response_status = 200,
        .response_body = "stream-response",
    }};
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    var playback = PlaybackTransport.init(fixed.allocator(), &recordings);
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/retry-stream",
    );
    defer request.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        playback.asTransport().open(&request, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), playback.index);
    try std.testing.expectEqual(@as(usize, 0), playback.open_count);

    playback.allocator = std.testing.allocator;
    var operation = try playback.asTransport().open(&request, .{});
    defer operation.deinit();
    const body = try (try operation.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("stream-response", body);
    try operation.finish();
    try std.testing.expectEqual(@as(usize, 1), playback.index);
    try std.testing.expectEqual(@as(usize, 1), playback.open_count);
}

test "buffered redirect OOM consumes its raw playback attempt" {
    const recordings = [_]RecordedExchange{
        .{
            .request_method = .GET,
            .request_url = "https://example.test/start",
            .response_status = 302,
            .response_body = "",
            .response_headers = &.{
                .{ .name = "Location", .value = "/final" },
            },
        },
        .{
            .request_method = .GET,
            .request_url = "https://example.test/start",
            .response_status = 302,
            .response_body = "",
            .response_headers = &.{
                .{ .name = "Location", .value = "/final" },
            },
        },
        .{
            .request_method = .GET,
            .request_url = "https://example.test/final",
            .response_status = 200,
            .response_body = "done",
        },
    };
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        &recordings,
    );
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var request = core.http.Request.init(
        failing.allocator(),
        .GET,
        "https://example.test/start",
    );
    defer request.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        playback.asTransport().send(&request),
    );
    try std.testing.expectEqual(@as(usize, 1), playback.index);

    failing.fail_index = std.math.maxInt(usize);
    var response = try playback.asTransport().send(&request);
    defer response.deinit();
    try std.testing.expectEqualStrings("done", response.body);
    try std.testing.expectEqual(@as(usize, 3), playback.index);
}

test "streaming redirect OOM consumes its raw playback attempt" {
    const recordings = [_]RecordedExchange{
        .{
            .request_method = .GET,
            .request_url = "https://example.test/start-stream",
            .response_status = 302,
            .response_body = "",
            .response_headers = &.{
                .{ .name = "Location", .value = "/final-stream" },
            },
        },
        .{
            .request_method = .GET,
            .request_url = "https://example.test/start-stream",
            .response_status = 302,
            .response_body = "",
            .response_headers = &.{
                .{ .name = "Location", .value = "/final-stream" },
            },
        },
        .{
            .request_method = .GET,
            .request_url = "https://example.test/final-stream",
            .response_status = 200,
            .response_body = "stream-done",
        },
    };
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        &recordings,
    );
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var request = core.http.Request.init(
        failing.allocator(),
        .GET,
        "https://example.test/start-stream",
    );
    defer request.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        playback.asTransport().open(&request, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), playback.index);
    try std.testing.expectEqual(@as(usize, 1), playback.abort_count);

    failing.fail_index = std.math.maxInt(usize);
    var operation = try playback.asTransport().open(&request, .{});
    defer operation.deinit();
    const body = try (try operation.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("stream-done", body);
    try operation.finish();
    try std.testing.expectEqual(@as(usize, 3), playback.index);
}

test "recording wraps streaming operations and copies descriptor by value" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        202,
        "stream-response",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "X-Duplicate", .value = "first" },
        .{ .name = "x-duplicate", .value = "second" },
    };
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    const copied = recorder.asTransport();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/record",
    );
    defer request.deinit();
    var source = std.Io.Reader.fixed("stream-request");
    var operation = try copied.open(&request, .{
        .body = core.http.StreamingRequestBody.chunked(&source),
    });
    var first: [6]u8 = undefined;
    try (try operation.reader()).readSliceAll(&first);
    try operation.finish();
    operation.deinit();

    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 1), exchanges.len);
    try std.testing.expectEqualStrings("stream-request", exchanges[0].request_body.?);
    try std.testing.expectEqualStrings("stream-response", exchanges[0].response_body);
    try std.testing.expectEqual(@as(usize, 2), exchanges[0].response_headers.len);
    try std.testing.expectEqual(@as(usize, 1), mock.stream_finish_count);
    try std.testing.expectEqual(@as(usize, 1), mock.stream_deinit_count);
}

test "overlapping attempts retain dispatch order and block serialization" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();

    var request_a = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/a",
    );
    defer request_a.deinit();
    var request_b = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/b",
    );
    defer request_b.deinit();
    var request_c = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/c",
    );
    defer request_c.deinit();

    var operation_a = try recorder.asTransport().open(&request_a, .{});
    var operation_b = try recorder.asTransport().open(&request_b, .{});
    var response_c = try recorder.asTransport().send(&request_c);
    response_c.deinit();

    var slots = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 3), slots.len);
    try std.testing.expectEqualStrings(request_a.url, slots[0].request_url);
    try std.testing.expectEqualStrings(request_b.url, slots[1].request_url);
    try std.testing.expectEqualStrings(request_c.url, slots[2].request_url);
    try std.testing.expect(!slots[0].resolved);
    try std.testing.expect(!slots[1].resolved);
    try std.testing.expect(slots[2].resolved);
    try std.testing.expect(!recorder.isComplete());
    try std.testing.expectError(
        error.IncompleteRecording,
        recorder.toJson(std.testing.allocator),
    );

    try operation_b.finish();
    operation_b.deinit();
    slots = recorder.getExchanges();
    try std.testing.expect(!slots[0].resolved);
    try std.testing.expect(slots[1].resolved);
    try std.testing.expect(slots[2].resolved);
    try std.testing.expect(!recorder.isComplete());

    try operation_a.finish();
    operation_a.deinit();
    try std.testing.expect(recorder.isComplete());
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        request_a.url,
        parsed.asSlice()[0].request_url,
    );
    try std.testing.expectEqualStrings(
        request_b.url,
        parsed.asSlice()[1].request_url,
    );
    try std.testing.expectEqualStrings(
        request_c.url,
        parsed.asSlice()[2].request_url,
    );
}

test "recorder serializes backing allocator across threads" {
    const worker_count = 12;
    var guarded = GuardedAllocator{ .child = std.heap.page_allocator };
    var inner = ThreadSafeEmptyTransport{};
    var recorder = RecordingTransport.init(
        guarded.allocator(),
        inner.asTransport(),
    );
    var recorder_owned = true;
    errdefer if (recorder_owned) recorder.deinit();
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var workers: [worker_count]ConcurrentRecorderWorker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&workers, &threads) |*worker, *thread| {
        worker.* = .{
            .recorder = &recorder,
            .start = &start,
            .failed = &failed,
        };
        thread.* = try std.Thread.spawn(.{}, ConcurrentRecorderWorker.run, .{
            worker,
        });
        spawned += 1;
    }
    start.store(true, .release);
    for (threads) |thread| thread.join();
    spawned = 0;

    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(recorder.isComplete());
    try std.testing.expectEqual(
        @as(usize, worker_count),
        recorder.getExchanges().len,
    );
    recorder.deinit();
    recorder_owned = false;
    try std.testing.expect(!guarded.overlap.load(.acquire));
}

test "recording preserves buffered open fallback" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "buffered-response",
    );
    defer mock.deinit();
    var buffered_only = BufferedOnlyTransport{ .inner = &mock };
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        buffered_only.asTransport(),
    );
    defer recorder.deinit();

    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/buffered",
    );
    defer request.deinit();
    request.body = "buffered-request";
    var operation = try recorder.asTransport().open(&request, .{});
    const response = try (try operation.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("buffered-response", response);
    try operation.finish();
    operation.deinit();
    try std.testing.expectEqual(@as(usize, 1), recorder.getExchanges().len);
    try std.testing.expectEqualStrings(
        "buffered-request",
        recorder.getExchanges()[0].request_body.?,
    );

    var streamed_request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/streamed",
    );
    defer streamed_request.deinit();
    var source = std.Io.Reader.fixed("streamed");
    try std.testing.expectError(
        error.StreamingRequestUnsupported,
        recorder.asTransport().open(&streamed_request, .{
            .body = core.http.StreamingRequestBody.chunked(&source),
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "transport errors record and replay before retry success" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "done",
    );
    defer mock.deinit();
    var failing = FailureStageTransport{
        .allocator = std.testing.allocator,
        .inner = &mock,
        .mode = .transport,
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        failing.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/transport-error",
    );
    defer request.deinit();
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        recorder.asTransport().send(&request),
    );
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"version\":3") != null,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"outcome\":\"transport_error\"",
    ) != null);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "ConnectionResetByPeer") == null,
    );
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(
        RecordedOutcome.transport_error,
        parsed.asSlice()[0].outcome,
    );
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    try std.testing.expectError(
        error.RecordedConnectionFailure,
        playback.asTransport().send(&request),
    );
    var replayed = try playback.asTransport().send(&request);
    defer replayed.deinit();
    try std.testing.expectEqualStrings("done", replayed.body);
}

test "open errors record and replay before retry success" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "done",
    );
    defer mock.deinit();
    var failing = FailureStageTransport{
        .allocator = std.testing.allocator,
        .inner = &mock,
        .mode = .open,
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        failing.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/open-error",
    );
    defer request.deinit();
    var failed_source = std.Io.Reader.fixed("request-body");
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        recorder.asTransport().open(&request, .{
            .body = core.http.StreamingRequestBody.chunked(&failed_source),
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), failed_source.seek);
    var retry_source = std.Io.Reader.fixed("request-body");
    var operation = try recorder.asTransport().open(&request, .{
        .body = core.http.StreamingRequestBody.chunked(&retry_source),
    });
    const body = try (try operation.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(body);
    try operation.finish();
    operation.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(
        RecordedOutcome.open_error,
        parsed.asSlice()[0].outcome,
    );
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replayed_failed_source = std.Io.Reader.fixed("request-body");
    try std.testing.expectError(
        error.RecordedConnectionFailure,
        playback.asTransport().open(&request, .{
            .body = core.http.StreamingRequestBody.chunked(
                &replayed_failed_source,
            ),
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        replayed_failed_source.seek,
    );
    var replayed_retry_source = std.Io.Reader.fixed("request-body");
    var replayed = try playback.asTransport().open(&request, .{
        .body = core.http.StreamingRequestBody.chunked(
            &replayed_retry_source,
        ),
    });
    const replayed_body = try (try replayed.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(replayed_body);
    try std.testing.expectEqualStrings("done", replayed_body);
    try replayed.finish();
    replayed.deinit();
}

test "partial body errors record and replay before retry success" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "done",
    );
    defer mock.deinit();
    var failing = FailureStageTransport{
        .allocator = std.testing.allocator,
        .inner = &mock,
        .mode = .body,
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        failing.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/body-error",
    );
    defer request.deinit();
    var failed = try recorder.asTransport().open(&request, .{});
    var partial: [7]u8 = undefined;
    try (try failed.reader()).readSliceAll(&partial);
    try std.testing.expectEqualStrings("partial", &partial);
    var extra: [1]u8 = undefined;
    try std.testing.expectError(
        error.ReadFailed,
        (try failed.reader()).readSliceAll(&extra),
    );
    try std.testing.expectEqual(
        error.ConnectionResetByPeer,
        failed.bodyError().?,
    );
    failed.abort();
    failed.deinit();

    var retry = try recorder.asTransport().open(&request, .{});
    const retry_body = try (try retry.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(retry_body);
    try retry.finish();
    retry.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(
        RecordedOutcome.body_error,
        parsed.asSlice()[0].outcome,
    );
    try std.testing.expectEqualStrings(
        "partial",
        parsed.asSlice()[0].response_body,
    );
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replayed_failure = try playback.asTransport().open(&request, .{});
    var replayed_partial: [7]u8 = undefined;
    try (try replayed_failure.reader()).readSliceAll(&replayed_partial);
    try std.testing.expectEqualStrings("partial", &replayed_partial);
    try std.testing.expectError(
        error.ReadFailed,
        (try replayed_failure.reader()).readSliceAll(&extra),
    );
    try std.testing.expectEqual(
        error.RecordedConnectionFailure,
        replayed_failure.bodyError().?,
    );
    replayed_failure.abort();
    replayed_failure.deinit();
    var replayed_retry = try playback.asTransport().open(&request, .{});
    const replayed_body = try (try replayed_retry.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(replayed_body);
    try std.testing.expectEqualStrings("done", replayed_body);
    try replayed_retry.finish();
    replayed_retry.deinit();
}

test "finish errors record and replay before retry success" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "done",
    );
    defer mock.deinit();
    var failing = FailureStageTransport{
        .allocator = std.testing.allocator,
        .inner = &mock,
        .mode = .finish,
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        failing.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/finish-error",
    );
    defer request.deinit();
    var failed = try recorder.asTransport().open(&request, .{});
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        failed.finish(),
    );
    failed.deinit();
    var retry = try recorder.asTransport().open(&request, .{});
    const retry_body = try (try retry.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(retry_body);
    try retry.finish();
    retry.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(
        RecordedOutcome.finish_error,
        parsed.asSlice()[0].outcome,
    );
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replayed_failure = try playback.asTransport().open(&request, .{});
    try std.testing.expectError(
        error.RecordedConnectionFailure,
        replayed_failure.finish(),
    );
    replayed_failure.deinit();
    var replayed_retry = try playback.asTransport().open(&request, .{});
    const replayed_body = try (try replayed_retry.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(replayed_body);
    try std.testing.expectEqualStrings("done", replayed_body);
    try replayed_retry.finish();
    replayed_retry.deinit();
}

test "mid-upload cancellation remains terminal through playback retry policy" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var cancelling = FailureStageTransport{
        .allocator = std.testing.allocator,
        .inner = &mock,
        .mode = .cancel_open,
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        cancelling.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var retry = core.http.RetryPolicy.init();
    retry.initial_delay_ms = 0;
    retry.max_delay_ms = 0;
    retry.max_retries = 2;
    var policies = [_]*core.http.HttpPolicy{retry.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(recorder.asTransport(), crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.test/upload-cancel",
    );
    defer request.deinit();
    var upload = ReplayableRequestBody.init("payload");
    try std.testing.expectError(
        error.OperationCancelled,
        pipeline.open(&request, .{ .body = upload.streaming() }),
    );
    try std.testing.expectEqual(@as(usize, 1), cancelling.call_count);
    try std.testing.expectEqual(@as(usize, 0), upload.rewind_count);

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(
        RecordedOutcome.open_error,
        parsed.asSlice()[0].outcome,
    );
    try std.testing.expectEqual(
        RecordedErrorCategory.cancelled,
        parsed.asSlice()[0].error_category.?,
    );
    try std.testing.expectEqualStrings(
        "pay",
        parsed.asSlice()[0].request_body.?,
    );

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var playback_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var playback_retry = core.http.RetryPolicy.init();
    playback_retry.initial_delay_ms = 0;
    playback_retry.max_delay_ms = 0;
    playback_retry.max_retries = 2;
    var playback_policies = [_]*core.http.HttpPolicy{
        playback_retry.asPolicy(),
    };
    var playback_pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(
            playback.asTransport(),
            playback_crypto.asProvider(),
        ),
        &playback_policies,
    );
    var replay_upload = ReplayableRequestBody.init("payload");
    try std.testing.expectError(
        error.OperationCancelled,
        playback_pipeline.open(
            &request,
            .{ .body = replay_upload.streaming() },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), playback.index);
    try std.testing.expectEqual(@as(usize, 0), replay_upload.rewind_count);
    try std.testing.expectEqual(@as(usize, 3), replay_upload.reader.seek);
}

test "cooperative upload cancellation consumes only matching cancelled attempt" {
    const cancelled_recording = RecordedExchange{
        .request_method = .POST,
        .request_url = "https://example.test/cancelled-upload",
        .request_body = "pay",
        .outcome = .open_error,
        .error_category = .cancelled,
    };
    const next_recording = RecordedExchange{
        .request_method = .GET,
        .request_url = "https://example.test/next",
        .response_status = 200,
        .response_body = "next",
    };
    const recordings = [_]RecordedExchange{
        cancelled_recording,
        next_recording,
    };
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        &recordings,
    );
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        cancelled_recording.request_url,
    );
    defer request.deinit();
    var cancellation = core.http.CancellationToken{};
    var reader: CooperativeCancellingReader = undefined;
    reader.init("pay", &cancellation);
    try std.testing.expectError(
        error.OperationCancelled,
        playback.asTransport().open(
            &request,
            .{
                .body = core.http.StreamingRequestBody.chunked(
                    &reader.interface,
                ),
                .cancellation = &cancellation,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), playback.index);

    var next_request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        next_recording.request_url,
    );
    defer next_request.deinit();
    var next_response = try playback.asTransport().send(&next_request);
    defer next_response.deinit();
    try std.testing.expectEqualStrings("next", next_response.body);
    try std.testing.expectEqual(@as(usize, 2), playback.index);

    var preflight_playback = PlaybackTransport.init(
        std.testing.allocator,
        &recordings,
    );
    var preflight_cancellation = core.http.CancellationToken{};
    preflight_cancellation.cancel();
    var preflight_reader = std.Io.Reader.fixed("pay");
    try std.testing.expectError(
        error.OperationCancelled,
        preflight_playback.asTransport().open(
            &request,
            .{
                .body = core.http.StreamingRequestBody.chunked(
                    &preflight_reader,
                ),
                .cancellation = &preflight_cancellation,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), preflight_playback.index);

    const successful_recording = [_]RecordedExchange{.{
        .request_method = .POST,
        .request_url = cancelled_recording.request_url,
        .request_body = "pay",
        .response_status = 200,
    }};
    var successful_playback = PlaybackTransport.init(
        std.testing.allocator,
        &successful_recording,
    );
    var live_cancellation = core.http.CancellationToken{};
    var live_reader: CooperativeCancellingReader = undefined;
    live_reader.init("pay", &live_cancellation);
    try std.testing.expectError(
        error.OperationCancelled,
        successful_playback.asTransport().open(
            &request,
            .{
                .body = core.http.StreamingRequestBody.chunked(
                    &live_reader.interface,
                ),
                .cancellation = &live_cancellation,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), successful_playback.index);
}

test "response body cancellation replays exact terminal error once" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var cancelling = FailureStageTransport{
        .allocator = std.testing.allocator,
        .inner = &mock,
        .mode = .cancel_body,
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        cancelling.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/body-cancel",
    );
    defer request.deinit();
    var operation = try recorder.asTransport().open(&request, .{});
    var partial: [7]u8 = undefined;
    try (try operation.reader()).readSliceAll(&partial);
    var extra: [1]u8 = undefined;
    try std.testing.expectError(
        error.ReadFailed,
        (try operation.reader()).readSliceAll(&extra),
    );
    try std.testing.expectEqual(
        error.OperationCancelled,
        operation.bodyError().?,
    );
    operation.abort();
    operation.deinit();
    try std.testing.expectEqual(@as(usize, 1), cancelling.call_count);

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(
        RecordedErrorCategory.cancelled,
        parsed.asSlice()[0].error_category.?,
    );
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replayed = try playback.asTransport().open(&request, .{});
    var replayed_partial: [7]u8 = undefined;
    try (try replayed.reader()).readSliceAll(&replayed_partial);
    try std.testing.expectEqualStrings("partial", &replayed_partial);
    try std.testing.expectError(
        error.ReadFailed,
        (try replayed.reader()).readSliceAll(&extra),
    );
    try std.testing.expectEqual(
        error.OperationCancelled,
        replayed.bodyError().?,
    );
    replayed.abort();
    replayed.deinit();
    try std.testing.expectEqual(@as(usize, 1), playback.index);
}

test "recording stores abort and cancel as completed raw attempts" {
    var mock = core.http.MockTransport.init(std.testing.allocator, 200, "body");
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();

    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/abort",
    );
    defer request.deinit();
    var aborted = try recorder.asTransport().open(&request, .{});
    aborted.abort();
    aborted.deinit();
    var cancelled = try recorder.asTransport().open(&request, .{});
    cancelled.cancel();
    cancelled.deinit();
    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 2), exchanges.len);
    try std.testing.expectEqual(@as(usize, 0), exchanges[0].response_body.len);
    try std.testing.expectEqual(@as(usize, 0), exchanges[1].response_body.len);
    try std.testing.expectEqual(@as(usize, 1), mock.stream_abort_count);
    try std.testing.expectEqual(@as(usize, 1), mock.stream_cancel_count);
    try std.testing.expectEqual(@as(usize, 2), mock.stream_deinit_count);
}

test "recording cancellation preserves redirect and terminal raw attempts" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 200, .body = "body" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start",
    );
    defer request.deinit();
    var operation = try recorder.asTransport().open(&request, .{});
    operation.cancel();
    operation.deinit();
    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 2), exchanges.len);
    try std.testing.expectEqual(@as(u16, 302), exchanges[0].response_status);
    try std.testing.expectEqual(@as(u16, 200), exchanges[1].response_status);
    try std.testing.expectEqual(@as(usize, 0), exchanges[1].response_body.len);
}

test "recording and playback preserve streaming redirect sequences" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "ignored",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 200, .body = "done" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/start",
    );
    defer request.deinit();
    var operation = try recorder.asTransport().open(&request, .{});
    try operation.finish();
    operation.deinit();
    try std.testing.expectEqual(@as(usize, 2), recorder.getExchanges().len);

    const owned = recorder.getExchanges();
    var recordings: [2]RecordedExchange = undefined;
    for (owned, &recordings) |exchange, *recording| {
        recording.* = .{
            .request_method = exchange.request_method,
            .request_url = exchange.request_url,
            .request_headers = exchange.request_headers,
            .request_body = exchange.request_body,
            .response_status = exchange.response_status,
            .response_body = exchange.response_body,
            .response_headers = exchange.response_headers,
        };
    }
    var playback = PlaybackTransport.init(std.testing.allocator, &recordings);
    var replay_request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/start",
    );
    defer replay_request.deinit();
    var replay = try playback.asTransport().open(&replay_request, .{});
    const body = try (try replay.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("done", body);
    try replay.finish();
    replay.deinit();
}

test "buffered recorder and playback preserve raw redirect retry attempts" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 503, .body = "retry" },
            .{
                .status = 302,
                .body = "",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 200, .body = "done" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var retry = core.http.RetryPolicy.init();
    retry.initial_delay_ms = 0;
    retry.max_delay_ms = 0;
    var policies = [_]*core.http.HttpPolicy{retry.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(recorder.asTransport(), crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start",
    );
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
    try std.testing.expectEqualStrings("done", response.body);

    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 4), exchanges.len);
    try std.testing.expectEqual(@as(u16, 302), exchanges[0].response_status);
    try std.testing.expectEqual(@as(u16, 503), exchanges[1].response_status);
    try std.testing.expectEqual(@as(u16, 302), exchanges[2].response_status);
    try std.testing.expectEqual(@as(u16, 200), exchanges[3].response_status);
    var recordings: [4]RecordedExchange = undefined;
    for (exchanges, &recordings) |exchange, *recording| {
        recording.* = .{
            .request_method = exchange.request_method,
            .request_url = exchange.request_url,
            .request_headers = exchange.request_headers,
            .request_body = exchange.request_body,
            .response_status = exchange.response_status,
            .response_body = exchange.response_body,
            .response_headers = exchange.response_headers,
        };
    }
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        &recordings,
    );
    var playback_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var playback_retry = core.http.RetryPolicy.init();
    playback_retry.initial_delay_ms = 0;
    playback_retry.max_delay_ms = 0;
    var playback_policies = [_]*core.http.HttpPolicy{
        playback_retry.asPolicy(),
    };
    var playback_pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(
            playback.asTransport(),
            playback_crypto.asProvider(),
        ),
        &playback_policies,
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start",
    );
    defer live.deinit();
    var replayed = try playback_pipeline.send(&live);
    defer replayed.deinit();
    try std.testing.expectEqualStrings("done", replayed.body);
    try std.testing.expectEqual(@as(usize, 4), playback.index);
}

test "streaming recorder and playback preserve raw redirect retry attempts" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "ignored-redirect",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 503, .body = "ignored-retry" },
            .{
                .status = 302,
                .body = "ignored-redirect",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 200, .body = "done" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var retry = core.http.RetryPolicy.init();
    retry.initial_delay_ms = 0;
    retry.max_delay_ms = 0;
    var policies = [_]*core.http.HttpPolicy{retry.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(recorder.asTransport(), crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start",
    );
    defer request.deinit();
    var operation = try pipeline.open(&request, .{});
    const body = try (try operation.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("done", body);
    try operation.finish();
    operation.deinit();

    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 4), exchanges.len);
    try std.testing.expectEqual(@as(u16, 302), exchanges[0].response_status);
    try std.testing.expectEqual(@as(usize, 0), exchanges[0].response_body.len);
    try std.testing.expectEqual(@as(u16, 503), exchanges[1].response_status);
    try std.testing.expectEqual(@as(usize, 0), exchanges[1].response_body.len);
    try std.testing.expectEqual(@as(u16, 302), exchanges[2].response_status);
    try std.testing.expectEqual(@as(usize, 0), exchanges[2].response_body.len);
    try std.testing.expectEqual(@as(u16, 200), exchanges[3].response_status);
    try std.testing.expectEqualStrings("done", exchanges[3].response_body);
    var recordings: [4]RecordedExchange = undefined;
    for (exchanges, &recordings) |exchange, *recording| {
        recording.* = .{
            .request_method = exchange.request_method,
            .request_url = exchange.request_url,
            .request_headers = exchange.request_headers,
            .request_body = exchange.request_body,
            .response_status = exchange.response_status,
            .response_body = exchange.response_body,
            .response_headers = exchange.response_headers,
        };
    }
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        &recordings,
    );
    var playback_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var playback_retry = core.http.RetryPolicy.init();
    playback_retry.initial_delay_ms = 0;
    playback_retry.max_delay_ms = 0;
    var playback_policies = [_]*core.http.HttpPolicy{
        playback_retry.asPolicy(),
    };
    var playback_pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(
            playback.asTransport(),
            playback_crypto.asProvider(),
        ),
        &playback_policies,
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start",
    );
    defer live.deinit();
    var replayed = try playback_pipeline.open(&live, .{});
    const replayed_body = try (try replayed.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(replayed_body);
    try std.testing.expectEqualStrings("done", replayed_body);
    try replayed.finish();
    replayed.deinit();
    try std.testing.expectEqual(@as(usize, 4), playback.index);
}

test "buffered recorder preserves redirect attempt consumed before OOM" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{
                .status = 302,
                .body = "",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 200, .body = "done" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var request = core.http.Request.init(
        failing.allocator(),
        .GET,
        "https://example.test/start",
    );
    defer request.deinit();
    const transport = recorder.asTransport();
    try std.testing.expectError(error.OutOfMemory, transport.send(&request));
    try std.testing.expectEqual(@as(usize, 1), recorder.getExchanges().len);

    failing.fail_index = std.math.maxInt(usize);
    var response = try transport.send(&request);
    defer response.deinit();
    try std.testing.expectEqualStrings("done", response.body);
    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 3), exchanges.len);
    try std.testing.expectEqual(@as(u16, 302), exchanges[0].response_status);
    try std.testing.expectEqual(@as(u16, 302), exchanges[1].response_status);
    try std.testing.expectEqual(@as(u16, 200), exchanges[2].response_status);
}

test "streaming recorder preserves redirect attempt aborted after OOM" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "ignored",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{
                .status = 302,
                .body = "ignored",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 200, .body = "done" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var request = core.http.Request.init(
        failing.allocator(),
        .GET,
        "https://example.test/start",
    );
    defer request.deinit();
    const transport = recorder.asTransport();
    try std.testing.expectError(error.OutOfMemory, transport.open(&request, .{}));
    const first = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(@as(usize, 0), first[0].response_body.len);

    failing.fail_index = std.math.maxInt(usize);
    var operation = try transport.open(&request, .{});
    const body = try (try operation.reader()).allocRemaining(
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("done", body);
    try operation.finish();
    operation.deinit();
    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 3), exchanges.len);
    try std.testing.expectEqual(@as(u16, 302), exchanges[0].response_status);
    try std.testing.expectEqual(@as(u16, 302), exchanges[1].response_status);
    try std.testing.expectEqual(@as(u16, 200), exchanges[2].response_status);
}

test "recorder and playback preserve retry backoff timeout attempts" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{.{ .status = 503, .body = "unavailable" }},
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var retry = core.http.RetryPolicy.init();
    retry.initial_delay_ms = 100;
    var policies = [_]*core.http.HttpPolicy{retry.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(recorder.asTransport(), crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/timeout",
    );
    request.operation_timeout_ms = 1;
    defer request.deinit();
    try std.testing.expectError(error.OperationTimedOut, pipeline.send(&request));
    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 1), exchanges.len);
    try std.testing.expectEqual(@as(u16, 503), exchanges[0].response_status);

    const recordings = [_]RecordedExchange{.{
        .request_method = exchanges[0].request_method,
        .request_url = exchanges[0].request_url,
        .request_headers = exchanges[0].request_headers,
        .request_body = exchanges[0].request_body,
        .response_status = exchanges[0].response_status,
        .response_body = exchanges[0].response_body,
        .response_headers = exchanges[0].response_headers,
    }};
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        &recordings,
    );
    var playback_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var playback_retry = core.http.RetryPolicy.init();
    playback_retry.initial_delay_ms = 100;
    var playback_policies = [_]*core.http.HttpPolicy{
        playback_retry.asPolicy(),
    };
    var playback_pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(
            playback.asTransport(),
            playback_crypto.asProvider(),
        ),
        &playback_policies,
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/timeout",
    );
    live.operation_timeout_ms = 1;
    defer live.deinit();
    try std.testing.expectError(
        error.OperationTimedOut,
        playback_pipeline.send(&live),
    );
    try std.testing.expectEqual(@as(usize, 1), playback.index);
}

test "terminal retryable response records every configured attempt" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{.{ .status = 503, .body = "unavailable" }},
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var retry = core.http.RetryPolicy.init();
    retry.initial_delay_ms = 0;
    retry.max_delay_ms = 0;
    retry.max_retries = 2;
    var policies = [_]*core.http.HttpPolicy{retry.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(recorder.asTransport(), crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/unavailable",
    );
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 503), response.status_code);
    const exchanges = recorder.getExchanges();
    try std.testing.expectEqual(@as(usize, 3), exchanges.len);
    for (exchanges) |exchange| {
        try std.testing.expectEqual(@as(u16, 503), exchange.response_status);
    }

    var recordings: [3]RecordedExchange = undefined;
    for (exchanges, &recordings) |exchange, *recording| {
        recording.* = .{
            .request_method = exchange.request_method,
            .request_url = exchange.request_url,
            .request_headers = exchange.request_headers,
            .request_body = exchange.request_body,
            .response_status = exchange.response_status,
            .response_body = exchange.response_body,
            .response_headers = exchange.response_headers,
        };
    }
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        &recordings,
    );
    var playback_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var playback_retry = core.http.RetryPolicy.init();
    playback_retry.initial_delay_ms = 0;
    playback_retry.max_delay_ms = 0;
    playback_retry.max_retries = 2;
    var playback_policies = [_]*core.http.HttpPolicy{
        playback_retry.asPolicy(),
    };
    var playback_pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(
            playback.asTransport(),
            playback_crypto.asProvider(),
        ),
        &playback_policies,
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/unavailable",
    );
    defer live.deinit();
    var replayed = try playback_pipeline.send(&live);
    defer replayed.deinit();
    try std.testing.expectEqual(@as(u16, 503), replayed.status_code);
    try std.testing.expectEqual(@as(usize, 3), playback.index);
}

test "recording JSON redacts headers and URL query credentials" {
    var mock = core.http.MockTransport.init(std.testing.allocator, 200, "ok");
    defer mock.deinit();
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/items?sig=secret&version=1",
    );
    defer request.deinit();
    try request.setHeader("Authorization", "Bearer secret");
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "REDACTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Bearer secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sig=secret") == null);
}

test "sensitive Azure headers are classified case-insensitively" {
    for ([_][]const u8{
        "Authorization",
        "X-MS-AUTHORIZATION-AUXILIARY",
        "x-ms-copy-source-authorization",
        "X-MS-SOURCE-AUTHORIZATION",
        "x-ms-encryption-key",
        "X-MS-SOURCE-ENCRYPTION-KEY-SHA256",
        "X-MS-COPY-SOURCE",
        "X-MS-FILE-RENAME-SOURCE",
        "x-ms-file-rename-source-authorization",
        "OCP-APIM-SUBSCRIPTION-KEY",
        "x-functions-key",
        "X-Auth-Token",
        "AeG-SaS-KeY",
        "aEg-SaS-ToKeN",
        "Set-Cookie",
    }) |name| {
        try std.testing.expect(isSensitiveHeader(name));
    }
    try std.testing.expect(!isSensitiveHeader("Content-Type"));
    try std.testing.expect(!isSensitiveHeader("x-opt-partition-key"));
    try std.testing.expect(!isSensitiveHeader("x-ms-documentdb-partitionkey"));
    try std.testing.expect(!isSensitiveHeader("x-ms-continuation-token"));
}

test "sensitive metadata headers redact with configurable exact overrides" {
    const jwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ++
        "." ++
        "eyJzdWIiOiJoZWFkZXIiLCJleHAiOjQxMDI0NDQ4MDB9" ++
        "." ++
        "c2lnbmF0dXJlLWJ5dGVzLXZhbHVl";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "response",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "X-MS-META-PASSWORD", .value = "response-password-value" },
        .{ .name = "x-ms-meta-private-key", .value = "cmVzcG9uc2Uta2V5" },
        .{
            .name = "x-ms-meta-source-uri",
            .value = "https://storage.example/blob?sig=response-source-sas",
        },
        .{ .name = "ETag", .value = jwt },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{
            .bodyPolicyFn = &inspectKnownSafeBody,
            .headerPolicyFn = &preserveKnownSafeMetadata,
        },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://storage.example/container/blob",
    );
    defer request.deinit();
    try request.setHeader("x-Ms-MeTa-PaSsWoRd", "request-password-value");
    try request.setHeader("X-MS-META-PRIVATE-KEY", "cmVxdWVzdC1rZXk=");
    try request.setHeader(
        "x-ms-meta-connection-string",
        "RW5kcG9pbnQ9eDtBY2NvdW50S2V5PXk=",
    );
    try request.setHeader("X-MS-META-PWD", "known-safe-label");
    try request.setHeader(
        "x-ms-meta-source-uri",
        "https://storage.example/blob?sig=request-source-sas",
    );
    try request.setHeader("x-ms-meta-label", "unknown-metadata-value");
    try request.setHeader("ETag", jwt);
    try request.setHeader(
        "Content-Language",
        "Endpoint=https://example;AccountKey=header-account-key",
    );
    try request.setHeader("User-Agent", "service.production.contoso");
    try request.setHeader(
        "X-Application-Auth-Material",
        "custom-sensitive-value",
    );
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    for ([_][]const u8{
        "response-password-value",
        "cmVzcG9uc2Uta2V5",
        "request-password-value",
        "cmVxdWVzdC1rZXk=",
        "RW5kcG9pbnQ9eDtBY2NvdW50S2V5PXk=",
        "custom-sensitive-value",
        "response-source-sas",
        "request-source-sas",
        "unknown-metadata-value",
        "header-account-key",
        jwt,
    }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, json, secret) == null);
    }
    try std.testing.expect(
        std.mem.indexOf(u8, json, "known-safe-label") != null,
    );

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    for (parsed.asSlice()[0].request_headers) |header| {
        if (header.redacted) {
            try std.testing.expectEqualStrings(redacted_value, header.value);
        } else {
            try std.testing.expect(
                std.mem.eql(u8, header.value, "known-safe-label") or
                    std.mem.eql(
                        u8,
                        header.value,
                        "service.production.contoso",
                    ),
            );
        }
    }
    for (parsed.asSlice()[0].response_headers) |header| {
        try std.testing.expect(header.redacted);
        try std.testing.expectEqualStrings(redacted_value, header.value);
    }
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://storage.example/container/blob",
    );
    defer live.deinit();
    try live.setHeader("x-ms-meta-password", "rotated-password");
    try live.setHeader("x-ms-meta-private-key", "rotated-private-key");
    try live.setHeader(
        "x-ms-meta-connection-string",
        "rotated-connection-string",
    );
    try live.setHeader("x-ms-meta-pwd", "known-safe-label");
    try live.setHeader(
        "x-ms-meta-source-uri",
        "https://storage.example/blob?sig=rotated-source-sas",
    );
    try live.setHeader("x-ms-meta-label", "rotated-metadata");
    try live.setHeader("ETag", "rotated-jwt");
    try live.setHeader(
        "Content-Language",
        "Endpoint=https://example;AccountKey=rotated-account-key",
    );
    try live.setHeader("User-Agent", "service.production.contoso");
    try live.setHeader("x-application-auth-material", "rotated-custom-value");
    var replayed = try playback.asTransport().send(&live);
    replayed.deinit();

    var mismatch = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    try live.setHeader("x-ms-meta-pwd", "different-safe-label");
    try std.testing.expectError(
        error.HeaderMismatch,
        mismatch.asTransport().send(&live),
    );
}

test "Core request ID pipeline replays with changed volatile headers" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var recording_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var recording_request_id = core.http.RequestIdPolicy.init();
    var recording_policies = [_]*core.http.HttpPolicy{
        recording_request_id.asPolicy(),
    };
    var recording_pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(
            recorder.asTransport(),
            recording_crypto.asProvider(),
        ),
        &recording_policies,
    );
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/volatile",
    );
    defer request.deinit();
    try request.setHeader("x-ms-date", "Sat, 29 Aug 2026 05:00:00 GMT");
    try request.setHeader("Date", "Sat, 29 Aug 2026 05:00:00 GMT");
    try request.setHeader(
        "traceparent",
        "00-11111111111111111111111111111111-2222222222222222-01",
    );
    try request.setHeader("tracestate", "vendor=first");
    try request.setHeader("x-correlation-id", "first-correlation");
    var response = try recording_pipeline.send(&request);
    response.deinit();
    const recorded_id = try std.testing.allocator.dupe(
        u8,
        request.getHeader("x-ms-client-request-id").?,
    );
    defer std.testing.allocator.free(recorded_id);

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    for (parsed.asSlice()[0].request_headers) |header| {
        try std.testing.expect(header.redacted);
        try std.testing.expectEqualStrings(redacted_value, header.value);
    }

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var playback_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var playback_request_id = core.http.RequestIdPolicy.init();
    var playback_policies = [_]*core.http.HttpPolicy{
        playback_request_id.asPolicy(),
    };
    var playback_pipeline = core.http.HttpPipeline.init(
        initHttpRuntime(
            playback.asTransport(),
            playback_crypto.asProvider(),
        ),
        &playback_policies,
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/volatile",
    );
    defer live.deinit();
    try live.setHeader("x-ms-date", "Sat, 29 Aug 2026 06:00:00 GMT");
    try live.setHeader("Date", "Sat, 29 Aug 2026 06:00:00 GMT");
    try live.setHeader(
        "traceparent",
        "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01",
    );
    try live.setHeader("tracestate", "vendor=second");
    try live.setHeader("x-correlation-id", "second-correlation");
    var replayed = try playback_pipeline.send(&live);
    replayed.deinit();
    try std.testing.expect(!std.mem.eql(
        u8,
        recorded_id,
        live.getHeader("x-ms-client-request-id").?,
    ));

    var exact_mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer exact_mock.deinit();
    var exact_recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        exact_mock.asTransport(),
        .{ .headerPolicyFn = &preserveRequestDate },
    );
    defer exact_recorder.deinit();
    var exact_request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/exact-date",
    );
    defer exact_request.deinit();
    try exact_request.setHeader(
        "x-ms-date",
        "Sat, 29 Aug 2026 05:00:00 GMT",
    );
    var exact_response = try exact_recorder.asTransport().send(&exact_request);
    exact_response.deinit();
    const exact_json = try exact_recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(exact_json);
    var exact_parsed = try parseJson(std.testing.allocator, exact_json);
    defer exact_parsed.deinit();
    var exact_playback = PlaybackTransport.init(
        std.testing.allocator,
        exact_parsed.asSlice(),
    );
    try exact_request.setHeader(
        "x-ms-date",
        "Sat, 29 Aug 2026 06:00:00 GMT",
    );
    try std.testing.expectError(
        error.HeaderMismatch,
        exact_playback.asTransport().send(&exact_request),
    );
}

test "Event Grid key and SAS token redactions roundtrip" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "response",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "aEg-SaS-KeY", .value = "response-event-grid-key" },
        .{ .name = "AEG-SAS-TOKEN", .value = "response-event-grid-token" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://topic.eventgrid.azure.net/api/events?AeG-SaS-KeY=query-event-grid-key&AeG-SaS-ToKeN=query-event-grid-token&mode=one",
    );
    defer request.deinit();
    request.body = "event";
    try request.setHeader("AeG-SaS-KeY", "header-event-grid-key");
    try request.setHeader("aEg-SaS-ToKeN", "header-event-grid-token");
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    for ([_][]const u8{
        "query-event-grid-key",
        "query-event-grid-token",
        "header-event-grid-key",
        "header-event-grid-token",
        "response-event-grid-key",
        "response-event-grid-token",
    }) |credential| {
        try std.testing.expect(std.mem.indexOf(u8, json, credential) == null);
    }

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://topic.eventgrid.azure.net/api/events?AeG-SaS-KeY=live-query-key&AeG-SaS-ToKeN=live-query-token&mode=one",
    );
    defer live.deinit();
    live.body = "event";
    try live.setHeader("aeg-sas-key", "live-header-key");
    try live.setHeader("AEG-SAS-TOKEN", "live-header-token");
    var replayed = try playback.asTransport().send(&live);
    replayed.deinit();
}

test "Azure Files rename source URL redactions roundtrip" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        202,
        "accepted",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .PUT,
        "https://account.file.core.windows.net/share/destination",
    );
    defer request.deinit();
    try request.setHeader(
        "X-Ms-FiLe-ReNaMe-SoUrCe",
        "https://account.file.core.windows.net/share/source?sig=file-rename-secret&sv=2026-01-01",
    );
    try request.setHeader(
        "x-ms-file-rename-source-authorization",
        "Bearer file-rename-auth-secret",
    );
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "file-rename-secret") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, json, "file-rename-auth-secret") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, json, "account.file.core.windows.net/share/source") == null,
    );

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .PUT,
        "https://account.file.core.windows.net/share/destination",
    );
    defer live.deinit();
    try live.setHeader(
        "x-ms-file-rename-source",
        "https://rotated.file.core.windows.net/other/source?sig=rotated-key",
    );
    try live.setHeader(
        "X-MS-FILE-RENAME-SOURCE-AUTHORIZATION",
        "Bearer rotated-auth-key",
    );
    var replayed = try playback.asTransport().send(&live);
    replayed.deinit();
}

test "App Configuration key query remains exact" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "setting",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://config.azconfig.io/kv?key=prod*&api-version=1.0",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "key=prod*") != null);

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var different = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://config.azconfig.io/kv?key=dev*&api-version=1.0",
    );
    defer different.deinit();
    try std.testing.expectError(
        error.UrlMismatch,
        playback.asTransport().send(&different),
    );
}

test "URL sanitization inspects decoded query path and fragment components" {
    const recorded_jwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ++
        "." ++
        "eyJzdWIiOiJyZWNvcmRlZCIsImV4cCI6NDEwMjQ0NDgwMH0" ++
        "." ++
        "c2lnbmF0dXJlLWJ5dGVzLXZhbHVl";
    const live_jwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ++
        "." ++
        "eyJzdWIiOiJsaXZlIiwiZXhwIjo0MTAyNDQ0ODAwfQ" ++
        "." ++
        "cm90YXRlZC1zaWduYXR1cmUtdmFsdWU";
    const recorded_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "https://example.test/callback?token={s}&payload=Endpoint%3Dhttps%3A%2F%2Fexample%3BAccountKey%3Dquery-key&return=https%3A%2F%2Fsafe.example%2Fnext",
        .{recorded_jwt},
    );
    defer std.testing.allocator.free(recorded_url);
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        recorded_url,
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, recorded_jwt) == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "query-key") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "token=REDACTED") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, json, "payload=REDACTED") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            json,
            "return=https%3A%2F%2Fsafe.example%2Fnext",
        ) != null,
    );

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    const live_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "https://example.test/callback?token={s}&payload=Endpoint%3Dhttps%3A%2F%2Fexample%3BAccountKey%3Drotated-key&return=https%3A%2F%2Fsafe.example%2Fnext",
        .{live_jwt},
    );
    defer std.testing.allocator.free(live_url);
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        live_url,
    );
    defer live.deinit();
    var replayed = try playback.asTransport().send(&live);
    replayed.deinit();

    for ([_][]const u8{
        "https%253A%252F%252Fother.example%252Fblob%253F" ++
            "%252573%252569%252567%253Drotated-sas-secret",
        "https%253A%252F%252Fstorage.example%252Fother-blob%253F" ++
            "%252573%252569%252567%253Drotated-sas-secret",
    }) |different_nested| {
        var mismatch_playback = PlaybackTransport.init(
            std.testing.allocator,
            parsed.asSlice(),
        );
        const mismatch_url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://example.test/callback?return={s}&" ++
                "%252573%252569%252567=rotated-top-level-sas&stable=one",
            .{different_nested},
        );
        defer std.testing.allocator.free(mismatch_url);
        var mismatch = core.http.Request.init(
            std.testing.allocator,
            .GET,
            mismatch_url,
        );
        defer mismatch.deinit();
        try std.testing.expectError(
            error.UrlMismatch,
            mismatch_playback.asTransport().send(&mismatch),
        );
    }

    for ([_][]const u8{
        "https://example.test/callback/Bearer%20path-secret",
        "https://example.test/callback#access_token=fragment-secret",
    }) |unsafe_url| {
        var unsafe_mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "",
        );
        defer unsafe_mock.deinit();
        var unsafe_recorder = RecordingTransport.init(
            std.testing.allocator,
            unsafe_mock.asTransport(),
        );
        defer unsafe_recorder.deinit();
        var unsafe_request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            unsafe_url,
        );
        defer unsafe_request.deinit();
        var unsafe_response =
            try unsafe_recorder.asTransport().send(&unsafe_request);
        unsafe_response.deinit();
        try expectRejectedSerializationExcludes(
            &unsafe_recorder,
            error.SensitiveUrlRequiresSanitization,
            &.{ "path-secret", "fragment-secret" },
        );
    }
}

test "URL sanitization recursively decodes nested URI credentials" {
    const recorded_url =
        "https://example.test/callback?return=" ++
        "https%253A%252F%252Fstorage.example%252Fblob%253F" ++
        "%252573%252569%252567%253Dnested-sas-secret&" ++
        "%252573%252569%252567=top-level-sas-secret&stable=one";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        recorded_url,
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "nested-sas-secret") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, json, "top-level-sas-secret") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, json, "storage.example") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "blob") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "REDACTED") != null);

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/callback?return=" ++
            "https%253A%252F%252Fstorage.example%252Fblob%253F" ++
            "%252573%252569%252567%253Drotated-sas-secret&" ++
            "%252573%252569%252567=rotated-top-level-sas&stable=one",
    );
    defer live.deinit();
    var replayed = try playback.asTransport().send(&live);
    replayed.deinit();

    for ([_][]const u8{
        "https://example.test/callback?return=%ZZ",
        "https://example.test/callback?return=%2525252573%2525252569%2525252567%253Ddecode-depth-secret",
    }) |unsafe_url| {
        var unsafe_mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "",
        );
        defer unsafe_mock.deinit();
        var unsafe_recorder = RecordingTransport.init(
            std.testing.allocator,
            unsafe_mock.asTransport(),
        );
        defer unsafe_recorder.deinit();
        var unsafe_request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            unsafe_url,
        );
        defer unsafe_request.deinit();
        var unsafe_response =
            try unsafe_recorder.asTransport().send(&unsafe_request);
        unsafe_response.deinit();
        if (std.mem.indexOf(u8, unsafe_url, "%ZZ") != null) {
            try std.testing.expectError(
                error.SensitiveUrlRequiresSanitization,
                unsafe_recorder.toJson(std.testing.allocator),
            );
        } else {
            const unsafe_json =
                try unsafe_recorder.toJson(std.testing.allocator);
            defer std.testing.allocator.free(unsafe_json);
            try std.testing.expect(
                std.mem.indexOf(u8, unsafe_json, "decode-depth-secret") ==
                    null,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, unsafe_json, "return=REDACTED") != null,
            );
        }
    }
}

test "nested signed URI preserves exact host path and nonsensitive fields" {
    const recorded_url =
        "https://example.test/callback?return=" ++
        "https%3A%2F%2Fstorage.example%2Fblob%3F" ++
        "X-Amz-Signature%3Drecorded-secret%26mode%3Done";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        recorded_url,
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "recorded-secret") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, json, "storage.example") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "blob") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "mode") != null);

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var rotated = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/callback?return=" ++
            "https%3A%2F%2Fstorage.example%2Fblob%3F" ++
            "X-Amz-Signature%3Drotated-secret%26mode%3Done",
    );
    defer rotated.deinit();
    var replayed = try playback.asTransport().send(&rotated);
    replayed.deinit();

    for ([_][]const u8{
        "https%3A%2F%2Fother.example%2Fblob%3F" ++
            "X-Amz-Signature%3Drotated-secret%26mode%3Done",
        "https%3A%2F%2Fstorage.example%2Fother%3F" ++
            "X-Amz-Signature%3Drotated-secret%26mode%3Done",
        "https%3A%2F%2Fstorage.example%2Fblob%3F" ++
            "X-Amz-Signature%3Drotated-secret%26mode%3Dtwo",
    }) |different_nested| {
        var mismatch_playback = PlaybackTransport.init(
            std.testing.allocator,
            parsed.asSlice(),
        );
        const mismatch_url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://example.test/callback?return={s}",
            .{different_nested},
        );
        defer std.testing.allocator.free(mismatch_url);
        var mismatch = core.http.Request.init(
            std.testing.allocator,
            .GET,
            mismatch_url,
        );
        defer mismatch.deinit();
        try std.testing.expectError(
            error.UrlMismatch,
            mismatch_playback.asTransport().send(&mismatch),
        );
    }
}

test "nested URI redaction preserves outer encoding depth" {
    const recorded =
        "https://example.test/callback?return=" ++
        "https%3A%2F%2Fstorage.example%2Fa%25252Fb%3F" ++
        "sig%3Drecorded-secret";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        recorded,
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var rotated = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/callback?return=" ++
            "https%3A%2F%2Fstorage.example%2Fa%25252Fb%3F" ++
            "sig%3Drotated-secret",
    );
    defer rotated.deinit();
    var replayed = try playback.asTransport().send(&rotated);
    replayed.deinit();

    var mismatch_playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var mismatch = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/callback?return=" ++
            "https%3A%2F%2Fstorage.example%2Fa%252Fb%3F" ++
            "sig%3Drotated-secret",
    );
    defer mismatch.deinit();
    try std.testing.expectError(
        error.UrlMismatch,
        mismatch_playback.asTransport().send(&mismatch),
    );
}

test "literal redaction marker remains exact beside credential wildcard" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/item?mode=REDACTED&sig=recorded-secret",
    );
    defer request.deinit();
    try request.setHeader(
        "Operation-Location",
        "https://next.example/item?mode=REDACTED&sig=recorded-header",
    );
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var rotated = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/item?mode=REDACTED&sig=rotated-secret",
    );
    defer rotated.deinit();
    try rotated.setHeader(
        "Operation-Location",
        "https://next.example/item?mode=REDACTED&sig=rotated-header",
    );
    var replayed = try playback.asTransport().send(&rotated);
    replayed.deinit();

    var mismatch_playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var mismatch = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/item?mode=Bearer%20live-secret&sig=rotated-secret",
    );
    defer mismatch.deinit();
    try mismatch.setHeader(
        "Operation-Location",
        "https://next.example/item?mode=Bearer%20live-secret&sig=rotated-header",
    );
    try std.testing.expectError(
        error.UrlMismatch,
        mismatch_playback.asTransport().send(&mismatch),
    );

    var header_mismatch_playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var header_mismatch = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/item?mode=REDACTED&sig=rotated-secret",
    );
    defer header_mismatch.deinit();
    try header_mismatch.setHeader(
        "Operation-Location",
        "https://next.example/item?mode=Bearer%20live-secret&sig=rotated-header",
    );
    try std.testing.expectError(
        error.HeaderMismatch,
        header_mismatch_playback.asTransport().send(&header_mismatch),
    );
}

test "legacy recordings never infer URL wildcards from marker text" {
    const recordings = [_][]const u8{
        "{\"version\":2,\"exchanges\":[{" ++
            "\"request_method\":\"GET\"," ++
            "\"request_url\":\"https://example.test/item?mode=REDACTED\"," ++
            "\"request_headers\":[],\"request_body\":null," ++
            "\"response_status\":200,\"response_headers\":[]," ++
            "\"response_body\":{\"encoding\":\"base64\",\"data\":\"\"}}]}",
        "{\"version\":3,\"exchanges\":[{" ++
            "\"request_method\":\"GET\"," ++
            "\"request_url\":\"https://example.test/item?mode=REDACTED\"," ++
            "\"request_headers\":[],\"request_body\":null," ++
            "\"outcome\":\"response\",\"response_status\":200," ++
            "\"response_headers\":[]," ++
            "\"response_body\":{\"encoding\":\"base64\",\"data\":\"\"}}]}",
    };
    for (recordings) |json| {
        var parsed = try parseJson(std.testing.allocator, json);
        defer parsed.deinit();
        var exact_playback = PlaybackTransport.init(
            std.testing.allocator,
            parsed.asSlice(),
        );
        var exact = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/item?mode=REDACTED",
        );
        defer exact.deinit();
        var response = try exact_playback.asTransport().send(&exact);
        response.deinit();

        var mismatch_playback = PlaybackTransport.init(
            std.testing.allocator,
            parsed.asSlice(),
        );
        var mismatch = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/item?mode=Bearer%20live-secret",
        );
        defer mismatch.deinit();
        try std.testing.expectError(
            error.UrlMismatch,
            mismatch_playback.asTransport().send(&mismatch),
        );
    }
}

test "non UTF-8 URL and header metadata roundtrip as encoded bytes" {
    const recorded_url = "https://example.test/\xff";
    const rotated_url = "https://example.test/\xfe";
    const recorded_header = [_]u8{ 0xff, 'a', 0x80 };
    const different_header = [_]u8{ 0xfe, 'a', 0x80 };
    const response_header = [_]u8{ 'b', 0xff, 0x81 };
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "ETag", .value = &response_header },
    };
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        recorded_url,
    );
    defer request.deinit();
    try request.setHeader("ETag", &recorded_header);
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.unicode.utf8ValidateSlice(json));
    try std.testing.expect(std.mem.indexOfScalar(u8, json, 0xff) == null);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"encoding\":\"base64\"") != null,
    );

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    const exchange = parsed.asSlice()[0];
    try std.testing.expectEqualSlices(
        u8,
        recorded_url,
        exchange.request_url,
    );
    try std.testing.expectEqualSlices(
        u8,
        &recorded_header,
        getHeaderPair(exchange.request_headers, "ETag").?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &response_header,
        getHeaderPair(exchange.response_headers, "ETag").?,
    );

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var exact = core.http.Request.init(
        std.testing.allocator,
        .GET,
        recorded_url,
    );
    defer exact.deinit();
    try exact.setHeader("ETag", &recorded_header);
    var replayed = try playback.asTransport().send(&exact);
    defer replayed.deinit();
    try std.testing.expectEqualSlices(
        u8,
        &response_header,
        replayed.getHeader("ETag").?,
    );

    var header_mismatch_playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var header_mismatch = core.http.Request.init(
        std.testing.allocator,
        .GET,
        recorded_url,
    );
    defer header_mismatch.deinit();
    try header_mismatch.setHeader("ETag", &different_header);
    try std.testing.expectError(
        error.HeaderMismatch,
        header_mismatch_playback.asTransport().send(&header_mismatch),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        header_mismatch_playback.index,
    );

    var url_mismatch_playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var url_mismatch = core.http.Request.init(
        std.testing.allocator,
        .GET,
        rotated_url,
    );
    defer url_mismatch.deinit();
    try url_mismatch.setHeader("ETag", &recorded_header);
    try std.testing.expectError(
        error.UrlMismatch,
        url_mismatch_playback.asTransport().send(&url_mismatch),
    );
    try std.testing.expectEqual(@as(usize, 0), url_mismatch_playback.index);
}

test "safe nested URI preserves caller encoding exactly" {
    const urls = [_][]const u8{
        "https://example.test/callback?return=" ++
            "https%3a%2f%2fstorage.example%2fitem",
        "https://example.test/callback?return=" ++
            "https%3A%2F%2Fstorage.example%2F%7Euser",
        "https://example.test/callback?return=" ++
            "https%3A%2F%2Fstorage.example%2Fitem%3Flabel%3Da+b",
        "https://example.test/callback?return=" ++
            "https%3A%2F%2Fstorage.example%2Fitem%3Flabel%3Da%20b",
    };
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{ .status = 200, .body = "" },
            .{ .status = 200, .body = "" },
            .{ .status = 200, .body = "" },
            .{ .status = 200, .body = "" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    for (urls) |url| {
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
    }
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    for (urls, parsed.asSlice()) |expected, exchange| {
        try std.testing.expectEqualStrings(expected, exchange.request_url);
    }

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    for (urls) |url| {
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            url,
        );
        defer request.deinit();
        var response = try playback.asTransport().send(&request);
        response.deinit();
    }

    for ([_]struct {
        index: usize,
        different: []const u8,
    }{
        .{
            .index = 0,
            .different = "https://example.test/callback?return=" ++
                "https%3A%2F%2Fstorage.example%2Fitem",
        },
        .{
            .index = 1,
            .different = "https://example.test/callback?return=" ++
                "https%3A%2F%2Fstorage.example%2F~user",
        },
        .{
            .index = 2,
            .different = urls[3],
        },
    }) |case| {
        var mismatch_playback = PlaybackTransport.init(
            std.testing.allocator,
            parsed.asSlice()[case.index..],
        );
        var mismatch = core.http.Request.init(
            std.testing.allocator,
            .GET,
            case.different,
        );
        defer mismatch.deinit();
        try std.testing.expectError(
            error.UrlMismatch,
            mismatch_playback.asTransport().send(&mismatch),
        );
    }
}

test "pathless absolute and network-path URLs sanitize without range failures" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        302,
        "",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{
            .name = "Location",
            .value = "https://next.example?sig=location-secret&mode=one",
        },
        .{
            .name = "Operation-Location",
            .value = "//next.example/final?sig=network-secret#section",
        },
        .{
            .name = "Content-Location",
            .value = "//user:password@next.example/final",
        },
        .{
            .name = "Azure-AsyncOperation",
            .value = "//user%40next.example/final",
        },
    };
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test?sig=request-secret&return=" ++
            "https%3A%2F%2Fnested.example%3Fsig%3Dnested-secret&mode=one",
    );
    request.redirect_policy = .not_allowed;
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    for ([_][]const u8{
        "request-secret",
        "nested-secret",
        "location-secret",
        "network-secret",
        "password",
        "user%40",
    }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, json, secret) == null);
    }
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    const exchange = parsed.asSlice()[0];
    try std.testing.expectEqualStrings(
        "https://example.test?sig=REDACTED&" ++
            "return=https%3A%2F%2Fnested.example%3Fsig%3DREDACTED&mode=one",
        exchange.request_url,
    );
    try std.testing.expectEqualStrings(
        "https://next.example?sig=REDACTED&mode=one",
        getHeaderPair(exchange.response_headers, "Location").?,
    );
    try std.testing.expectEqualStrings(
        "//next.example/final?sig=REDACTED#section",
        getHeaderPair(exchange.response_headers, "Operation-Location").?,
    );
    for (exchange.response_headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Content-Location") or
            std.ascii.eqlIgnoreCase(header.name, "Azure-AsyncOperation"))
        {
            try std.testing.expect(header.redacted);
        }
    }

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test?sig=rotated-request&return=" ++
            "https%3A%2F%2Fnested.example%3Fsig%3Drotated-nested&mode=one",
    );
    live.redirect_policy = .not_allowed;
    defer live.deinit();
    var replayed = try playback.asTransport().send(&live);
    replayed.deinit();
}

test "vendor signed URL credentials redact across nested and header URLs" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{
            .name = "Location",
            .value = "https://download.example/object?" ++
                "X-Amz-Credential=header-credential&" ++
                "X-Goog-Signature=header-signature&mode=one",
        },
    };
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start?" ++
            "X-AmZ-SiGnAtUrE=request-signature&" ++
            "X-Amz-Credential=request-credential&" ++
            "X-Amz-Security-Token=request-token&" ++
            "AWSAccessKeyId=request-access-id&" ++
            "SecurityToken=request-security-token&" ++
            "X-Goog-Signature=request-goog-signature&" ++
            "GoogleAccessId=request-google-access-id&" ++
            "return=https%253A%252F%252Fdownload.example%252Fobject" ++
            "%253FX-Amz-Signature%253Dnested-signature&mode=one",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    for ([_][]const u8{
        "request-signature",
        "request-credential",
        "request-token",
        "request-access-id",
        "request-security-token",
        "request-goog-signature",
        "request-google-access-id",
        "nested-signature",
        "header-credential",
        "header-signature",
    }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, json, secret) == null);
    }

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start?" ++
            "X-AmZ-SiGnAtUrE=rotated-signature&" ++
            "X-Amz-Credential=rotated-credential&" ++
            "X-Amz-Security-Token=rotated-token&" ++
            "AWSAccessKeyId=rotated-access-id&" ++
            "SecurityToken=rotated-security-token&" ++
            "X-Goog-Signature=rotated-goog-signature&" ++
            "GoogleAccessId=rotated-google-access-id&" ++
            "return=https%253A%252F%252Fdownload.example%252Fobject" ++
            "%253FX-Amz-Signature%253Drotated-nested&mode=one",
    );
    defer live.deinit();
    var replayed = try playback.asTransport().send(&live);
    replayed.deinit();
}

test "vendor names near credentials remain exact" {
    const url =
        "https://example.test/filter?signatureVersion=4&" ++
        "credentialMode=default&x-goog-algorithm=GOOG4-RSA-SHA256&" ++
        "codecs=h264";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        url,
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "signatureVersion=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "credentialMode=default") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "codecs=h264") != null);

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var different = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/filter?signatureVersion=2&" ++
            "credentialMode=default&x-goog-algorithm=GOOG4-RSA-SHA256&" ++
            "codecs=h264",
    );
    defer different.deinit();
    try std.testing.expectError(
        error.UrlMismatch,
        playback.asTransport().send(&different),
    );
}

test "bare encoded and nested query assignments are sensitive in bodies" {
    for ([_][]const u8{
        "sig=bare-signature",
        "signature=bare-signature",
        "code=bare-code",
        "https://example.test/path#sig=fragment-signature",
        "https://example.test/path#%73%69%67=encoded-fragment",
        "return=https://download.example/object?X-Amz-Signature=nested-signature",
        "https%253A%252F%252Fdownload.example%252Fobject" ++
            "%253FX-Goog-Signature%253Dencoded-vendor-signature",
    }) |body| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            body,
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        };
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &inspectKnownSafeBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/body",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{body},
        );
    }
}

test "credential query fields in request fragments are rejected" {
    for ([_][]const u8{
        "https://example.test/final#sig=fragment-secret",
        "https://example.test/final#%73%69%67%6E%61%74%75%72%65=encoded-secret",
        "https://example.test/final#return=https%253A%252F%252Fdownload.example" ++
            "%252Fobject%253Fcode%253Dnested-secret",
    }) |url| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            error.SensitiveUrlRequiresSanitization,
            recorder.toJson(std.testing.allocator),
        );
    }
}

test "authenticated recording JSON roundtrips with structured redactions" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "response",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Set-Cookie", .value = "session=response-cookie-secret" },
        .{ .name = "X-MS-ENCRYPTION-KEY", .value = "response-key-secret" },
        .{
            .name = "x-ms-copy-source-authorization",
            .value = "Bearer response-copy-auth-secret",
        },
        .{
            .name = "Location",
            .value = "https://example.com/next?sig=response-sas-secret&next=1",
        },
        .{
            .name = "x-ms-copy-source",
            .value = "https://storage.example/source?sig=response-copy-secret",
        },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{
            .bodyPolicyFn = &inspectKnownSafeBody,
            .headerPolicyFn = &preserveKnownSafeMetadata,
        },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/items?sig=request-sas-secret&version=1",
    );
    defer request.deinit();
    request.body = "safe request";
    try request.setHeader("Authorization", "Bearer bearer-secret");
    try request.setHeader("X-MS-ENCRYPTION-KEY", "encryption-secret");
    try request.setHeader(
        "x-ms-source-encryption-key",
        "source-encryption-secret",
    );
    try request.setHeader(
        "x-ms-source-encryption-key-sha256",
        "source-encryption-hash",
    );
    try request.setHeader(
        "x-ms-source-authorization",
        "Bearer source-auth-secret",
    );
    try request.setHeader(
        "x-Ms-CoPy-SoUrCe-AuThOrIzAtIoN",
        "Bearer copy-auth-secret",
    );
    try request.setHeader(
        "X-MS-COPY-SOURCE",
        "https://storage.example/source?sig=copy-sas-secret&sp=r",
    );
    try request.setHeader(
        "Ocp-Apim-Subscription-Key",
        "subscription-secret",
    );
    try request.setHeader("x-functions-key", "function-secret");
    try request.setHeader("X-Stable", "stable-value");
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    for ([_][]const u8{
        "request-sas-secret",
        "bearer-secret",
        "encryption-secret",
        "copy-auth-secret",
        "copy-sas-secret",
        "subscription-secret",
        "function-secret",
        "response-cookie-secret",
        "response-key-secret",
        "response-copy-auth-secret",
        "response-sas-secret",
        "response-copy-secret",
        "source-encryption-secret",
        "source-encryption-hash",
        "source-auth-secret",
    }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, json, secret) == null);
    }

    try std.testing.expect(
        std.mem.indexOf(u8, json, "https://storage.example/source") == null,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "sp=r") == null);

    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var live = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/items?sig=different-sas&version=1",
    );
    defer live.deinit();
    live.body = "safe request";
    try live.setHeader("Authorization", "Bearer different-bearer");
    try live.setHeader("x-ms-encryption-key", "different-key");
    try live.setHeader(
        "X-MS-SOURCE-ENCRYPTION-KEY",
        "different-source-key",
    );
    try live.setHeader(
        "X-MS-SOURCE-ENCRYPTION-KEY-SHA256",
        "different-source-key-hash",
    );
    try live.setHeader(
        "X-MS-SOURCE-AUTHORIZATION",
        "Bearer different-source-auth",
    );
    try live.setHeader(
        "X-MS-COPY-SOURCE-AUTHORIZATION",
        "Bearer different-copy-auth",
    );
    try live.setHeader(
        "x-ms-copy-source",
        "https://elsewhere.example/object?sig=different-copy-sas",
    );
    try live.setHeader("ocp-apim-subscription-key", "different-subscription");
    try live.setHeader("X-FUNCTIONS-KEY", "different-function-key");
    try live.setHeader("X-Stable", "stable-value");
    var replayed = try playback.asTransport().send(&live);
    replayed.deinit();

    var header_mismatch = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    try live.setHeader("X-Stable", "changed");
    try std.testing.expectError(
        error.HeaderMismatch,
        header_mismatch.asTransport().send(&live),
    );

    var url_mismatch = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    try live.setHeader("X-Stable", "stable-value");
    live.url = "https://example.com/items?sig=different-sas&version=2";
    try std.testing.expectError(
        error.UrlMismatch,
        url_mismatch.asTransport().send(&live),
    );

    var body_mismatch = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    live.url = "https://example.com/items?sig=different-sas&version=1";
    live.body = "changed request";
    try std.testing.expectError(
        error.BodyMismatch,
        body_mismatch.asTransport().send(&live),
    );
}

test "location headers preserve replayable URLs and rotated SAS next exchanges" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "",
                .headers = &.{
                    .{
                        .name = "Location",
                        .value = "https://example.test/final?sig=first-location-sas&mode=one",
                    },
                    .{
                        .name = "Content-Location",
                        .value = "/content/item?%73ig=content-sas&view=full",
                    },
                    .{
                        .name = "Operation-Location",
                        .value = "https://user:userinfo-secret@example.test/unsafe",
                    },
                },
            },
            .{
                .status = 202,
                .body = "",
                .headers = &.{
                    .{
                        .name = "Operation-Location",
                        .value = "https://example.test/operations/1?sig=operation-sas&api-version=1",
                    },
                    .{
                        .name = "Azure-AsyncOperation",
                        .value = "/operations/1/status?sig=async-sas&api-version=1",
                    },
                    .{
                        .name = "Content-Location",
                        .value = "/callback?return=https://safe.example/next&mode=one",
                    },
                },
            },
            .{ .status = 200, .body = "" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    for ([_][]const u8{
        "https://example.test/start",
        "https://example.test/final?sig=first-location-sas&mode=one",
        "https://example.test/operations/1?sig=operation-sas&api-version=1",
    }) |url| {
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
    }

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    for ([_][]const u8{
        "first-location-sas",
        "content-sas",
        "operation-sas",
        "async-sas",
        "userinfo-secret",
    }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, json, secret) == null);
    }
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    const recordings = parsed.asSlice();
    try std.testing.expectEqualStrings(
        "https://example.test/final?sig=REDACTED&mode=one",
        getHeaderPair(recordings[0].response_headers, "Location").?,
    );
    try std.testing.expectEqualStrings(
        "/content/item?%73ig=REDACTED&view=full",
        getHeaderPair(recordings[0].response_headers, "Content-Location").?,
    );
    try std.testing.expectEqualStrings(
        redacted_value,
        getHeaderPair(recordings[0].response_headers, "Operation-Location").?,
    );
    try std.testing.expectEqualStrings(
        "https://example.test/operations/1?sig=REDACTED&api-version=1",
        getHeaderPair(
            recordings[1].response_headers,
            "Operation-Location",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "/operations/1/status?sig=REDACTED&api-version=1",
        getHeaderPair(
            recordings[1].response_headers,
            "Azure-AsyncOperation",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "/callback?return=https://safe.example/next&mode=one",
        getHeaderPair(
            recordings[1].response_headers,
            "Content-Location",
        ).?,
    );
    for (recordings[0].response_headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Operation-Location")) {
            try std.testing.expect(header.redacted);
        } else {
            try std.testing.expect(!header.redacted);
        }
    }
    for (recordings[1].response_headers) |header| {
        try std.testing.expect(!header.redacted);
    }

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        recordings,
    );
    for ([_][]const u8{
        "https://example.test/start",
        "https://example.test/final?sig=rotated-location-sas&mode=one",
        "https://example.test/operations/1?sig=rotated-operation-sas&api-version=1",
    }) |url| {
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            url,
        );
        defer request.deinit();
        var response = try playback.asTransport().send(&request);
        response.deinit();
    }
}

test "safe Location fragments remain replayable through Core redirects" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "",
                .headers = &.{
                    .{
                        .name = "Location",
                        .value = "//example.test/final#section",
                    },
                },
            },
            .{ .status = 200, .body = "" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status_code);

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "//example.test/final#section",
        getHeaderPair(
            parsed.asSlice()[0].response_headers,
            "Location",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "https://example.test/final",
        parsed.asSlice()[1].request_url,
    );

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replayed = try playback.asTransport().send(&request);
    defer replayed.deinit();
    try std.testing.expectEqual(@as(u16, 200), replayed.status_code);
    try std.testing.expectEqual(@as(usize, 2), playback.index);
}

test "sensitive Location fragments strip to replayable redirect targets" {
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{
                .status = 302,
                .body = "",
                .headers = &.{
                    .{
                        .name = "Location",
                        .value = "/final?mode=one#sig=fragment-secret",
                    },
                },
            },
            .{ .status = 200, .body = "" },
        },
    );
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        sequence.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/start-sensitive-fragment",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "fragment-secret") == null,
    );
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "/final?mode=one",
        getHeaderPair(
            parsed.asSlice()[0].response_headers,
            "Location",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "https://example.test/final?mode=one",
        parsed.asSlice()[1].request_url,
    );

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replayed = try playback.asTransport().send(&request);
    defer replayed.deinit();
    try std.testing.expectEqual(@as(u16, 200), replayed.status_code);
    try std.testing.expectEqual(@as(usize, 2), playback.index);
}

test "recording JSON base64 bodies roundtrip arbitrary bytes" {
    const urls = [_][]const u8{
        "https://example.com/invalid",
        "https://example.com/nul",
        "https://example.com/empty",
        "https://example.com/utf8",
    };
    const request_bodies = [_][]const u8{
        "\xff\xfe\x80",
        "\x00request\x00",
        "",
        "snowman: \xe2\x98\x83",
    };
    const response_bodies = [_][]const u8{
        "\x80\xff\x00",
        "response\x00body",
        "",
        "lambda: \xce\xbb",
    };
    var sequence = core.http.SequenceMockTransport.init(
        std.testing.allocator,
        &.{
            .{ .status = 200, .body = response_bodies[0] },
            .{ .status = 200, .body = response_bodies[1] },
            .{ .status = 200, .body = response_bodies[2] },
            .{ .status = 200, .body = response_bodies[3] },
        },
    );
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        sequence.asTransport(),
        .{ .bodyPolicyFn = &allowKnownSafeOpaqueBody },
    );
    defer recorder.deinit();
    for (urls, request_bodies) |url, body| {
        var request = core.http.Request.init(std.testing.allocator, .POST, url);
        defer request.deinit();
        request.body = body;
        var response = try recorder.asTransport().send(&request);
        response.deinit();
    }

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.unicode.utf8ValidateSlice(json));
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    for (urls, request_bodies, response_bodies) |url, request_body, expected| {
        var request = core.http.Request.init(std.testing.allocator, .POST, url);
        defer request.deinit();
        request.body = request_body;
        var response = try playback.asTransport().send(&request);
        defer response.deinit();
        try std.testing.expectEqualSlices(u8, expected, response.body);
    }
}

fn expectSensitiveResponseBodyRejected(body: []const u8) !void {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        body,
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/token",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    try expectRejectedSerializationExcludes(
        &recorder,
        error.SensitiveBodyRequiresSanitization,
        &.{body},
    );
}

fn expectSensitiveRequestBodyRejected(body: []const u8) !void {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "{\"message\":\"safe\"}",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/request",
    );
    defer request.deinit();
    request.body = body;
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    try expectRejectedSerializationExcludes(
        &recorder,
        error.SensitiveBodyRequiresSanitization,
        &.{body},
    );
}

test "recording JSON rejects structural JSON form XML and connection secrets" {
    for ([_][]const u8{
        "{\"primaryKey\":\"primary-value\"}",
        "{\"listKeys\":{\"Secondary_Key\":{\"value\":\"secondary-value\"}}}",
        "{\"keys\":[{\"name\":\"primary\",\"value\":\"nested-key-value\"}]}",
        "{\"List-Keys\":{\"value\":\"nested-list-key-value\"}}",
        "{\"result\":{\"connectionString\":\"Endpoint=x;SharedAccessKey=y\"}}",
        "{\"outer\":[{\"Api-Key\":{\"value\":\"api-value\"}}]}",
        "{\"applicationSecret\":\"application-value\"}",
        "{\"properties\":{\"vCenterPassword\":\"vcenter-value\",\"NSXT-PASSWORD\":{\"value\":\"nsxt-value\"}}}",
        "client_secret=form-value&grant_type=client_credentials",
        "Endpoint=https://example;AccountKey=account-value",
        "<ListKeys><PrimaryKey>xml-value</PrimaryKey></ListKeys>",
        "<ns:Credentials><ns:Value>nested-value</ns:Value></ns:Credentials>",
        "-----BEGIN PRIVATE KEY-----\nprivate-value\n-----END PRIVATE KEY-----",
    }) |body| {
        try expectSensitiveResponseBodyRejected(body);
    }
    try expectSensitiveRequestBodyRejected(
        "{\"outer\":{\"CLIENT-ASSERTION\":{\"value\":\"request-value\"}}}",
    );
}

test "Key Vault root value bodies are endpoint-sensitive" {
    {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"value\":\"response-key-vault-value\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.vault.azure.net/secrets/name?api-version=7.6",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"response-key-vault-value"},
        );
    }
    {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"id\":\"safe\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .PUT,
            "https://example.vault.azure.net/secrets/name?api-version=7.6",
        );
        defer request.deinit();
        request.body = "{\"VaLuE\":\"request-key-vault-value\"}";
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"request-key-vault-value"},
        );
    }
}

test "Key Vault path text on App Configuration hosts stays recordable and exact" {
    const body = "{\"key\":\"team/vault/secrets/name\",\"value\":\"ordinary-setting\"}";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        body,
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://store.azconfig.io/kv/team/vault/secrets/name?api-version=1.0",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "ordinary-setting") == null);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(
        u8,
        body,
        parsed.asSlice()[0].response_body,
    );

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replayed = try playback.asTransport().send(&request);
    defer replayed.deinit();
    try std.testing.expectEqualSlices(u8, body, replayed.body);

    var mismatch = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var different = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://store.azconfig.io/kv/team/vault/secrets/other?api-version=1.0",
    );
    defer different.deinit();
    try std.testing.expectError(
        error.UrlMismatch,
        mismatch.asTransport().send(&different),
    );
}

test "Key Vault exchange rules ignore untrusted origins" {
    for ([_][]const u8{
        "https://example.vault.azure.net.attacker.test/secrets/name",
        "https://vault.azure.cn.attacker.test/certificates/name",
        "http://example.vault.azure.net/secrets/name",
    }) |url| {
        const body = "{\"value\":\"ordinary-non-vault-value\"}";
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            body,
        );
        defer mock.deinit();
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &inspectKnownSafeBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        const json = try recorder.toJson(std.testing.allocator);
        defer std.testing.allocator.free(json);
        var parsed = try parseJson(std.testing.allocator, json);
        defer parsed.deinit();
        try std.testing.expectEqualSlices(
            u8,
            body,
            parsed.asSlice()[0].response_body,
        );
    }
}

test "Key Vault private JWK and certificate import schemas are rejected" {
    {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"key\":{\"kty\":\"RSA\",\"n\":\"public\",\"e\":\"AQAB\",\"D\":\"ZC1wcml2YXRl\",\"p\":\"cA==\",\"q\":\"cQ==\",\"dP\":\"ZHA=\",\"dq\":\"ZHE=\",\"QI\":\"cWk=\"}}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.vault.azure.net/keys/name/version?api-version=7.6",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{ "ZC1wcml2YXRl", "ZHA=", "cWk=" },
        );
    }
    {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"id\":\"safe\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            "https://example.vault.azure.net/certificates/name/import?api-version=7.6",
        );
        defer request.deinit();
        request.body =
            "{\"value\":\"UEZYLUJBU0U2NC1WQUxVRQ==\",\"PwD\":\"certificate-password\"}";
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{ "UEZYLUJBU0U2NC1WQUxVRQ==", "certificate-password" },
        );
    }
}

test "Key Vault key operation root values are rejected" {
    for ([_][]const u8{
        "/keys/name/version/encrypt",
        "/keys/name/version/decrypt",
        "/keys/name/version/wrapkey",
        "/keys/name/version/unwrapkey",
        "/keys/name/backup",
        "/keys/restore",
        "/keys/name/version/release",
    }) |path| {
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://example.vault.azure.net{s}?api-version=7.6",
            .{path},
        );
        defer std.testing.allocator.free(url);
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"value\":\"operation-secret-value\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"operation-secret-value"},
        );
    }

    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var restore = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.vault.azure.net/keys/restore?api-version=7.6",
    );
    defer restore.deinit();
    restore.body = "{\"value\":\"backup-blob-secret\"}";
    var response = try recorder.asTransport().send(&restore);
    response.deinit();
    try expectRejectedSerializationExcludes(
        &recorder,
        error.SensitiveBodyRequiresSanitization,
        &.{"backup-blob-secret"},
    );

    var opaque_mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "{\"value\":\"mislabelled-backup-secret\"}",
    );
    defer opaque_mock.deinit();
    opaque_mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/pdf" },
    };
    var opaque_recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        opaque_mock.asTransport(),
        .{ .bodyPolicyFn = &allowOpaqueBody },
    );
    defer opaque_recorder.deinit();
    var backup = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.vault.azure.net/keys/name/backup?api-version=7.6",
    );
    defer backup.deinit();
    var opaque_response = try opaque_recorder.asTransport().send(&backup);
    opaque_response.deinit();
    try expectRejectedSerializationExcludes(
        &opaque_recorder,
        error.SensitiveBodyRequiresSanitization,
        &.{"mislabelled-backup-secret"},
    );
}

test "encoded Managed HSM key paths are rejected on every sovereign host" {
    const hosts = [_][]const u8{
        "example.managedhsm.azure.net",
        "example.managedhsm.usgovcloudapi.net",
        "example.managedhsm.azure.cn",
        "example.managedhsm.microsoftazure.de",
    };
    for (hosts) |host| {
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://{s}/key%73/name/backup?api-version=7.6",
            .{host},
        );
        defer std.testing.allocator.free(url);
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"value\":\"managed-hsm-backup-secret\"}",
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        };
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"managed-hsm-backup-secret"},
        );
    }
}

test "trusted service hosts decode labels and normalize terminal root dots" {
    const key_hosts = [_][]const u8{
        "example%2Ev%61ult%2Eazure%2Enet.",
        "example%2Evault%2Eazure%2Ecn.",
        "example%2Evault%2Eusgovcloudapi%2Enet.",
        "example%2Evault%2Emicrosoftazure%2Ede.",
        "example%2Em%61nagedhsm%2Eazure%2Enet.",
        "example%2Emanagedhsm%2Eazure%2Ecn.",
        "example%2Emanagedhsm%2Eusgovcloudapi%2Enet.",
        "example%2Emanagedhsm%2Emicrosoftazure%2Ede.",
    };
    for (key_hosts) |host| {
        const path = if (containsIgnoreCase(host, "managedhsm"))
            "/keys/name/backup"
        else
            "/secrets/name";
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://{s}{s}",
            .{ host, path },
        );
        defer std.testing.allocator.free(url);
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"value\":\"host-normalization-secret\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"host-normalization-secret"},
        );
    }

    const management_hosts = [_][]const u8{
        "m%61nagement%2Eazure%2Ecom.",
        "management%2Eusgovcloudapi%2Enet.",
        "management%2Echinacloudapi%2Ecn.",
        "management%2Emicrosoftazure%2Ede.",
    };
    for (management_hosts) |host| {
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://{s}/subscriptions/s/providers/" ++
                "Microsoft.Batch/batchAccounts/a/listKeys",
            .{host},
        );
        defer std.testing.allocator.free(url);
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"primary\":\"arm-host-secret\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"arm-host-secret"},
        );
    }

    const storage_hosts = [_][]const u8{
        "account%2Ebl%6Fb%2Ecore%2Ewindows%2Enet.",
        "account%2Eblob%2Ecore%2Eusgovcloudapi%2Enet.",
        "account%2Eblob%2Ecore%2Echinacloudapi%2Ecn.",
        "account%2Eblob%2Ecore%2Ecloudapi%2Ede.",
    };
    for (storage_hosts) |host| {
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://{s}/?restype=service&comp=userdelegationkey",
            .{host},
        );
        defer std.testing.allocator.free(url);
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "<UserDelegationKey><Value>storage-host-secret</Value>" ++
                "</UserDelegationKey>",
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "application/xml" },
        };
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"storage-host-secret"},
        );
    }

    const kusto_hosts = [_][]const u8{
        "cluster%2Ek%75sto%2Ewindows%2Enet.",
        "cluster%2Ekusto%2Echinacloudapi%2Ecn.",
        "cluster%2Ekusto%2Eusgovcloudapi%2Enet.",
        "cluster%2Ekusto%2Ecloudapi%2Ede.",
        "cluster%2Ekusto%2Efabric%2Emicrosoft%2Ecom.",
    };
    for (kusto_hosts) |host| {
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://{s}/v2/rest/query",
            .{host},
        );
        defer std.testing.allocator.free(url);
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"sourceUri\":\"ordinary-kusto-value\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"ordinary-kusto-value"},
        );
    }
}

test "endpoint host parsing rejects malformed and userinfo authorities" {
    for ([_][]const u8{
        "https://user@example.vault.azure.net/secrets/name",
        "https://example%ZZ.vault.azure.net/secrets/name",
        "https://example.vault.azure.net../secrets/name",
        "https://example%2F.vault.azure.net/secrets/name",
    }) |url| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"ordinary\":\"safe\"}",
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        };
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &inspectKnownSafeBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        if (recorder.toJson(std.testing.allocator)) |json| {
            std.testing.allocator.free(json);
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expect(
                err == error.SensitiveBodyRequiresSanitization or
                    err == error.SensitiveUrlRequiresSanitization,
            );
        }
    }
}

test "malformed or over-depth credential endpoint encodings fail closed" {
    for ([_][]const u8{
        "https://example.vault.azure.net/key%ZZ/name/backup",
        "https://example.vault.azure.net/key%25252573/name/backup",
    }) |url| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"ordinary\":\"safe\"}",
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        };
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &inspectKnownSafeBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            error.SensitiveBodyRequiresSanitization,
            recorder.toJson(std.testing.allocator),
        );
    }
}

test "Azure key management key1 and key2 responses are rejected" {
    for ([_][]const u8{
        "https://management.azure.com/subscriptions/s/resourceGroups/r/providers/Microsoft.EventGrid/topics/t/listKeys?api-version=2025-02-15",
        "https://management.azure.com/subscriptions/s/resourceGroups/r/providers/Microsoft.CognitiveServices/accounts/a/regenerateKey?api-version=2024-10-01",
    }) |url| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"KeY1\":\"first-service-key\",\"key2\":\"second-service-key\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{ "first-service-key", "second-service-key" },
        );
    }
}

test "Cosmos and Container Registry credential schemas are rejected" {
    const cases = [_]struct {
        url: []const u8,
        body: []const u8,
        secrets: []const []const u8,
    }{
        .{
            .url = "https://management.azure.com/subscriptions/s/resourceGroups/r/providers/Microsoft.DocumentDB/databaseAccounts/a/listKeys?api-version=2025-04-15",
            .body = "{\"primaryMasterKey\":\"cosmos-primary\",\"secondaryMasterKey\":\"cosmos-secondary\",\"primaryReadonlyMasterKey\":\"cosmos-read-primary\",\"secondaryReadonlyMasterKey\":\"cosmos-read-secondary\"}",
            .secrets = &.{
                "cosmos-primary",
                "cosmos-secondary",
                "cosmos-read-primary",
                "cosmos-read-secondary",
            },
        },
        .{
            .url = "https://management.azure.com/subscriptions/s/resourceGroups/r/providers/Microsoft.ContainerRegistry/registries/a/listCredentials?api-version=2025-04-01",
            .body = "{\"username\":\"registry-user\",\"passwords\":[{\"name\":\"password\",\"value\":\"registry-password-one\"},{\"name\":\"password2\",\"value\":\"registry-password-two\"}]}",
            .secrets = &.{ "registry-password-one", "registry-password-two" },
        },
    };
    for (cases) |case| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            case.body,
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            case.url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            case.secrets,
        );
    }
}

test "ARM credential schemas cover every trusted sovereign management host" {
    const hosts = [_][]const u8{
        "management.azure.com",
        "management.usgovcloudapi.net",
        "management.chinacloudapi.cn",
        "management.microsoftazure.de",
    };
    const schemas = [_]struct {
        path: []const u8,
        body: []const u8,
        secrets: []const []const u8,
    }{
        .{
            .path = "/subscriptions/s/resourceGroups/r/providers/Microsoft.Batch/batchAccounts/a/list%4Beys?api-version=2024-07-01",
            .body = "{\"primary\":\"batch-primary\",\"secondary\":\"batch-secondary\"}",
            .secrets = &.{ "batch-primary", "batch-secondary" },
        },
        .{
            .path = "/subscriptions/s/resourceGroups/r/providers/Microsoft.Search/searchServices/a/listQuery%4Beys?api-version=2024-03-01-preview",
            .body = "{\"value\":[{\"name\":\"query-key\",\"key\":\"search-query-secret\"}]}",
            .secrets = &.{"search-query-secret"},
        },
        .{
            .path = "/subscriptions/s/resourceGroups/r/providers/Microsoft.EventGrid/topics/t/list%4Beys?api-version=2025-02-15",
            .body = "{\"key1\":\"event-grid-one\",\"key2\":\"event-grid-two\"}",
            .secrets = &.{ "event-grid-one", "event-grid-two" },
        },
        .{
            .path = "/subscriptions/s/resourceGroups/r/providers/Microsoft.DocumentDB/databaseAccounts/a/list%4Beys?api-version=2025-04-15",
            .body = "{\"primaryMasterKey\":\"cosmos-one\",\"secondaryMasterKey\":\"cosmos-two\"}",
            .secrets = &.{ "cosmos-one", "cosmos-two" },
        },
        .{
            .path = "/subscriptions/s/resourceGroups/r/providers/Microsoft.ContainerRegistry/registries/a/list%43redentials?api-version=2025-04-01",
            .body = "{\"passwords\":[{\"name\":\"password\",\"value\":\"acr-secret\"}]}",
            .secrets = &.{"acr-secret"},
        },
    };
    for (hosts) |host| {
        for (schemas) |schema| {
            const url = try std.fmt.allocPrint(
                std.testing.allocator,
                "https://{s}{s}",
                .{ host, schema.path },
            );
            defer std.testing.allocator.free(url);
            var mock = core.http.MockTransport.init(
                std.testing.allocator,
                200,
                schema.body,
            );
            defer mock.deinit();
            mock.response_headers_list = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            };
            var recorder = RecordingTransport.init(
                std.testing.allocator,
                mock.asTransport(),
            );
            defer recorder.deinit();
            var request = core.http.Request.init(
                std.testing.allocator,
                .POST,
                url,
            );
            defer request.deinit();
            var response = try recorder.asTransport().send(&request);
            response.deinit();
            try expectRejectedSerializationExcludes(
                &recorder,
                error.SensitiveBodyRequiresSanitization,
                schema.secrets,
            );
        }
    }
}

test "legacy China management hostname does not activate ARM schemas" {
    const body = "{\"primary\":\"ordinary\",\"secondary\":\"setting\"}";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        body,
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://management.azure.cn/subscriptions/s/providers/Microsoft.Batch/batchAccounts/a/listKeys",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(
        u8,
        body,
        parsed.asSlice()[0].response_body,
    );
}

test "ARM key-shaped fields remain safe outside trusted credential actions" {
    const body =
        "{\"primary\":\"one\",\"secondary\":\"two\"," ++
        "\"value\":[{\"name\":\"setting\",\"key\":\"ordinary\"}]}";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        body,
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://store.azconfig.io/kv/schema-regression?api-version=1.0",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(
        u8,
        body,
        parsed.asSlice()[0].response_body,
    );
}

test "Storage user delegation key XML is rejected on trusted blob hosts" {
    const hosts = [_][]const u8{
        "account.blob.core.windows.net",
        "account.blob.core.usgovcloudapi.net",
        "account.blob.core.chinacloudapi.cn",
        "account.blob.core.cloudapi.de",
    };
    const body =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>" ++
        "<UserDelegationKey><SignedOid>oid</SignedOid>" ++
        "<Value>delegation-key-secret</Value></UserDelegationKey>";
    for (hosts) |host| {
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "https://{s}/?restype=service&co%6dp=user%64elegationkey",
            .{host},
        );
        defer std.testing.allocator.free(url);
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            body,
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "application/xml" },
        };
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            url,
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{"delegation-key-secret"},
        );
    }
}

test "Storage delegation XML schema ignores untrusted hosts" {
    const body =
        "<UserDelegationKey><Value>ordinary-value</Value>" ++
        "</UserDelegationKey>";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        body,
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://account.blob.core.windows.net.attacker.test/" ++
            "?restype=service&comp=userdelegationkey",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(
        u8,
        body,
        parsed.asSlice()[0].response_body,
    );
}

test "malformed Storage delegation action encoding fails closed" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "<Document><Value>ordinary</Value></Document>",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://account.blob.core.windows.net/" ++
            "?restype=service&comp=user%25252564elegationkey",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    try std.testing.expectError(
        error.SensitiveBodyRequiresSanitization,
        recorder.toJson(std.testing.allocator),
    );
}

test "Kusto source URIs and tabular credential scalars are rejected" {
    const jwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ++
        "." ++
        "eyJzdWIiOiJpZGVudGl0eSIsImV4cCI6NDEwMjQ0NDgwMH0" ++
        "." ++
        "c2lnbmF0dXJlLWJ5dGVzLXZhbHVl";
    const jwt_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"Tables\":[{{\"Rows\":[[\"{s}\"]]}}]}}",
        .{jwt},
    );
    defer std.testing.allocator.free(jwt_body);
    for ([_][]const u8{
        "{\"sourceUri\":\"https://storage.example/container?sig=kusto-source-sas\"}",
        "{\"Tables\":[{\"Rows\":[[\"https://storage.example/blob?sig=row-sas\"]]}]}",
        "{\"Tables\":[{\"Rows\":[[\"https%3A%2F%2Fstorage.example%2Fblob%3Fsv%3D1%26sig%3Dencoded-sas\"]]}]}",
        jwt_body,
    }) |body| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            body,
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            "https://cluster.kusto.windows.net/v2/rest/query",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{
                "kusto-source-sas",
                "row-sas",
                "encoded-sas",
                jwt,
            },
        );
    }
}

test "plain text signed URLs and structurally valid JWTs are rejected" {
    const jwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ++
        "." ++
        "eyJzdWIiOiJpZGVudGl0eSIsImV4cCI6NDEwMjQ0NDgwMH0" ++
        "." ++
        "c2lnbmF0dXJlLWJ5dGVzLXZhbHVl";
    const jwt_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "identity token: {s}",
        .{jwt},
    );
    defer std.testing.allocator.free(jwt_text);
    for ([_][]const u8{
        "https://storage.example/container/blob?sv=2026-01-01&sig=plain-sas",
        jwt_text,
    }) |body| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            body,
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        };
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &inspectKnownSafeBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/plain",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{body},
        );
    }
}

test "multipart token fields and XML credential attributes are rejected" {
    {
        const multipart_body =
            "--boundary\r\n" ++
            "Content-Disposition: form-data; name=\"refreshToken\"\r\n\r\n" ++
            "registry-refresh-value\r\n" ++
            "--boundary\r\n" ++
            "Content-Disposition: form-data; name=\"accessToken\"\r\n\r\n" ++
            "registry-access-value\r\n" ++
            "--boundary--\r\n";
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "{\"message\":\"safe\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            "https://registry.azurecr.io/oauth2/exchange",
        );
        defer request.deinit();
        request.body = multipart_body;
        try request.setHeader(
            "Content-Type",
            "multipart/form-data; boundary=boundary",
        );
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            error.SensitiveBodyRequiresSanitization,
            recorder.toJson(std.testing.allocator),
        );
    }
    {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "<settings><add key=\"Password\" value=\"xml-attribute-value\"/></settings>",
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "application/xml" },
        };
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.com/settings",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            error.SensitiveBodyRequiresSanitization,
            recorder.toJson(std.testing.allocator),
        );
    }
}

test "multipart application http credentials cannot bypass allow opaque" {
    const jwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ++
        "." ++
        "eyJzdWIiOiJiYXRjaCIsImV4cCI6NDEwMjQ0NDgwMH0" ++
        "." ++
        "c2lnbmF0dXJlLWJ5dGVzLXZhbHVl";
    const jwt_batch = try std.fmt.allocPrint(
        std.testing.allocator,
        "--batch\r\nContent-Type: application/http\r\n\r\n" ++
            "GET /table HTTP/1.1\r\nx-token: {s}\r\n\r\n--batch--\r\n",
        .{jwt},
    );
    defer std.testing.allocator.free(jwt_batch);
    for ([_][]const u8{
        "--batch\r\nContent-Type: application/http\r\n" ++
            "Content-Transfer-Encoding: binary\r\n\r\n" ++
            "GET /table HTTP/1.1\r\n" ++
            "Authorization: SharedKey account:shared-key-value\r\n\r\n" ++
            "--batch--\r\n",
        "--batch\r\nContent-Type: application/http\r\n\r\n" ++
            "GET /table HTTP/1.1\r\n" ++
            "Authorization: Bearer bearer-token-value\r\n\r\n" ++
            "--batch--\r\n",
        "--batch\r\nContent-Type: application/http\r\n\r\n" ++
            "GET https://storage.example/table?sv=1&sig=batch-sas HTTP/1.1\r\n\r\n" ++
            "--batch--\r\n",
        "legal MIME preamble\r\n" ++
            "--batch\r\nContent-Type: application/json\r\n\r\n" ++
            "{\"accessToken\":\"nested-json-token\"}\r\n" ++
            "--batch--\r\n",
        "legal MIME preamble\r\n" ++
            "--batch\r\nContent-Type: multipart/mixed; boundary=inner\r\n\r\n" ++
            "--inner\r\nContent-Type: application/json\r\n\r\n" ++
            "{\"refreshToken\":\"recursive-json-token\"}\r\n" ++
            "--inner--\r\n--batch--\r\n",
        jwt_batch,
    }) |body| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            body,
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{
                .name = "Content-Type",
                .value = "multipart/mixed; boundary=batch",
            },
        };
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &allowOpaqueBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .POST,
            "https://account.table.core.windows.net/$batch",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            error.SensitiveBodyRequiresSanitization,
            &.{body},
        );
    }
}

test "multipart preamble and epilogue structures fail closed" {
    const cases = [_]struct {
        body: []const u8,
        secret: []const u8,
        expected_error: anyerror,
    }{
        .{
            .body = "notice\r\n{\"clientSecret\":\"preamble-secret\"}\r\n" ++
                "--batch\r\nContent-Type: text/plain\r\n\r\nsafe\r\n" ++
                "--batch--\r\n",
            .secret = "preamble-secret",
            .expected_error = error.SensitiveBodyRequiresSanitization,
        },
        .{
            .body = "--batch\r\nContent-Type: text/plain\r\n\r\nsafe\r\n" ++
                "--batch--\r\nnotice\r\n" ++
                "<add key=\"Password\" value=\"epilogue-secret\"/>",
            .secret = "epilogue-secret",
            .expected_error = error.SensitiveBodyRequiresSanitization,
        },
    };
    for (cases) |case| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            case.body,
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{
                .name = "Content-Type",
                .value = "multipart/mixed; boundary=batch",
            },
        };
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &allowOpaqueBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/multipart-envelope",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try expectRejectedSerializationExcludes(
            &recorder,
            case.expected_error,
            &.{case.secret},
        );
    }
}

test "folded multipart headers fail closed before credential persistence" {
    const folded_parts = [_][]const u8{
        "--batch\r\nContent-Disposition: form-data;\r\n" ++
            " name=\"password\"\r\n\r\nfolded-space-secret\r\n" ++
            "--batch--\r\n",
        "--batch\r\nContent-Disposition: form-data;\r\n" ++
            "\tname=\"accessToken\"\r\n\r\nfolded-tab-secret\r\n" ++
            "--batch--\r\n",
        "--batch\r\nContent-Type: application/http\r\n\r\n" ++
            "POST /resource HTTP/1.1\r\nAuthorization:\r\n" ++
            "\tBearer embedded-auth-secret\r\n" ++
            "Content-Type: text/plain\r\n\r\nsafe\r\n" ++
            "--batch--\r\n",
    };
    for (folded_parts[0..2]) |body| {
        try std.testing.expectError(
            error.UnsupportedBodySanitization,
            containsSensitiveMultipartContent(
                std.testing.allocator,
                "multipart/mixed; boundary=batch",
                body,
                0,
            ),
        );
    }
    try std.testing.expect(try containsSensitiveMultipartContent(
        std.testing.allocator,
        "multipart/mixed; boundary=batch",
        folded_parts[2],
        0,
    ));

    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        folded_parts[2],
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{
            .name = "Content-Type",
            .value = "multipart/mixed; boundary=batch",
        },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &allowOpaqueBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/folded-multipart",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    if (recorder.writeJson(
        &output.writer,
        std.testing.allocator,
    )) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(
            err == error.UnsupportedBodySanitization or
                err == error.SensitiveBodyRequiresSanitization,
        );
    }
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "embedded-auth-secret") ==
            null,
    );
}

test "malformed and trailing mixed XML structures fail closed" {
    const malformed = [_][]const u8{
        "<notice>{\"token\":\"malformed-prefix-secret\"}",
        "<notice/>{\"token\":\"trailing-json-secret\"}",
        "<notice><child>safe</notice>",
        "<notice>safe</notice><trailing/>",
    };
    for (malformed) |body| {
        try std.testing.expectError(
            error.UnsupportedBodySanitization,
            inspectXmlDocument(std.testing.allocator, body),
        );
    }

    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        malformed[0],
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/malformed-xml",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    if (recorder.writeJson(
        &output.writer,
        std.testing.allocator,
    )) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(
            err == error.UnsupportedBodySanitization or
                err == error.SensitiveBodyRequiresSanitization,
        );
    }
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            output.written(),
            "malformed-prefix-secret",
        ) == null,
    );
}

test "safe multipart application http batch roundtrips explicitly" {
    const body =
        "legal MIME preamble\r\n" ++
        "--batch\r\nContent-Type: application/http\r\n" ++
        "Content-Transfer-Encoding: binary\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" ++
        "{\"PartitionKey\":\"p\",\"RowKey\":\"r\",\"value\":\"safe\"}\r\n" ++
        "--batch--\r\n";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        body,
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{
            .name = "Content-Type",
            .value = "multipart/mixed; charset=utf-8; boundary=\"batch\"",
        },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &allowOpaqueBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://account.table.core.windows.net/$batch",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(
        u8,
        body,
        parsed.asSlice()[0].response_body,
    );
}

test "declared malformed multipart fails closed despite allow opaque" {
    for ([_]struct {
        content_type: []const u8,
        body: []const u8,
    }{
        .{
            .content_type = "multipart/mixed",
            .body = "--batch\r\nContent-Type: text/plain\r\n\r\nsafe\r\n--batch--\r\n",
        },
        .{
            .content_type = "multipart/mixed; boundary=batch",
            .body = "--batch\r\nContent-Type: text/plain\r\n\r\nsafe\r\n",
        },
        .{
            .content_type = "multipart/mixed; boundary=\"batch",
            .body = "--batch\r\nContent-Type: text/plain\r\n\r\nsafe\r\n--batch--\r\n",
        },
    }) |case| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            case.body,
        );
        defer mock.deinit();
        mock.response_headers_list = &.{
            .{ .name = "Content-Type", .value = case.content_type },
        };
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &allowOpaqueBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/multipart",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            error.UnsupportedBodySanitization,
            recorder.toJson(std.testing.allocator),
        );
    }
}

test "multipart boundaries require exact delimiter line syntax" {
    const malformed =
        "--batch\r\nContent-Type: text/plain\r\n\r\nsafe\r\n" ++
        "--batch--invalid\r\n" ++
        "--batch\r\nContent-Type: text/plain\r\n\r\nlater\r\n" ++
        "--batch--\r\n";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        malformed,
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{
            .name = "Content-Type",
            .value = "multipart/mixed; boundary=batch",
        },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &allowOpaqueBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://account.table.core.windows.net/$batch",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    try expectRejectedSerializationExcludes(
        &recorder,
        error.UnsupportedBodySanitization,
        &.{"later"},
    );

    const credential_after_fake_close =
        "--batch\r\nContent-Type: text/plain\r\n\r\nsafe\r\n" ++
        "--batch--invalid\r\n" ++
        "--batch\r\nContent-Type: application/http\r\n\r\n" ++
        "GET / HTTP/1.1\r\nAuthorization: SharedKey account:later-secret\r\n\r\n" ++
        "--batch--\r\n";
    var secret_mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        credential_after_fake_close,
    );
    defer secret_mock.deinit();
    secret_mock.response_headers_list = mock.response_headers_list;
    var secret_recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        secret_mock.asTransport(),
        .{ .bodyPolicyFn = &allowOpaqueBody },
    );
    defer secret_recorder.deinit();
    var secret_response =
        try secret_recorder.asTransport().send(&request);
    secret_response.deinit();
    try expectRejectedSerializationExcludes(
        &secret_recorder,
        error.SensitiveBodyRequiresSanitization,
        &.{"later-secret"},
    );
}

test "opaque bodies reject by default and require an explicit safe policy" {
    const opaque_bodies = [_]struct {
        body: []const u8,
        expected_error: anyerror = error.OpaqueBodyNotAllowed,
    }{
        .{ .body = "\x30\x82\xff\x00pkcs12-like" },
        .{ .body = "\xff\xfeP\x00a\x00s\x00s\x00w\x00o\x00r\x00d\x00" },
        .{
            .body = "A\x00c\x00c\x00o\x00u\x00n\x00t\x00K\x00e\x00y\x00=\x00v\x00a\x00l\x00u\x00e\x00",
            .expected_error = error.SensitiveBodyRequiresSanitization,
        },
        .{
            .body = "A\x00\x00\x00c\x00\x00\x00c\x00\x00\x00o\x00\x00\x00u\x00\x00\x00n\x00\x00\x00t\x00\x00\x00K\x00\x00\x00e\x00\x00\x00y\x00\x00\x00=\x00\x00\x00v\x00\x00\x00",
            .expected_error = error.SensitiveBodyRequiresSanitization,
        },
        .{ .body = "\xef\xbb\xbf{\"message\":\"utf8-bom\"}" },
        .{ .body = "{\"message\":\"malformed\xff\"}" },
    };
    for (opaque_bodies) |case| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            case.body,
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.com/opaque",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            case.expected_error,
            recorder.toJson(std.testing.allocator),
        );
    }
}

test "common private key markers cannot be allowed as opaque" {
    for ([_][]const u8{
        "-----BEGIN PRIVATE KEY-----\nvalue\n-----END PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----\nvalue\n-----END RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----\nvalue\n-----END EC PRIVATE KEY-----",
        "-----BEGIN ENCRYPTED PRIVATE KEY-----\nvalue\n-----END ENCRYPTED PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nvalue\n-----END OPENSSH PRIVATE KEY-----",
    }) |body| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            body,
        );
        defer mock.deinit();
        var recorder = RecordingTransport.initWithOptions(
            std.testing.allocator,
            mock.asTransport(),
            .{ .bodyPolicyFn = &allowKnownSafeOpaqueBody },
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.com/invalid",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            error.SensitiveBodyRequiresSanitization,
            recorder.toJson(std.testing.allocator),
        );
    }
}

test "recording JSON rejects malformed structured bodies explicitly" {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "{\"primaryKey\":\"unterminated\"",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/malformed",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    try std.testing.expectError(
        error.UnsupportedBodySanitization,
        recorder.toJson(std.testing.allocator),
    );
}

test "declared encodings and opaque MIME bodies require explicit approval" {
    const cases = [_]struct {
        content_type: []const u8,
        content_encoding: ?[]const u8 = null,
        body: []const u8,
        expected_error: anyerror,
    }{
        .{
            .content_type = "application/json",
            .body = "not-json",
            .expected_error = error.UnsupportedBodySanitization,
        },
        .{
            .content_type = "application/json; charset=utf-16le",
            .body = "{\x00\"\x00v\x00a\x00l\x00u\x00e\x00\"\x00:\x00\"\x00x\x00\"\x00}\x00",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
        .{
            .content_type = "application/json; charset=utf-32",
            .body = "{\x00\x00\x00}\x00\x00\x00",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
        .{
            .content_type = "application/octet-stream",
            .body = "printable-but-opaque",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
        .{
            .content_type = "application/pdf",
            .body = "%PDF-printable-fixture",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
        .{
            .content_type = "application/cbor",
            .body = "cbor-container-fixture",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
        .{
            .content_type = "application/pkcs7-mime",
            .body = "pkcs7-container-fixture",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
        .{
            .content_type = "application/x-protobuf",
            .body = "protobuf-container-fixture",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
        .{
            .content_type = "application/vnd.contoso.binary",
            .body = "vendor-container-fixture",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
        .{
            .content_type = "application/json",
            .content_encoding = "gzip",
            .body = "compressed-looking-body",
            .expected_error = error.OpaqueBodyNotAllowed,
        },
    };
    for (cases) |case| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            case.body,
        );
        defer mock.deinit();
        if (case.content_encoding) |encoding| {
            mock.response_headers_list = &.{
                .{ .name = "Content-Type", .value = case.content_type },
                .{ .name = "Content-Encoding", .value = encoding },
            };
        } else {
            mock.response_headers_list = &.{
                .{ .name = "Content-Type", .value = case.content_type },
            };
        }
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/encoding",
        );
        defer request.deinit();
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            case.expected_error,
            recorder.toJson(std.testing.allocator),
        );
    }
}

test "non-empty bodies require an explicit caller policy" {
    for ([_]bool{ false, true }) |request_has_body| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            if (request_has_body) "" else "{\"message\":\"ordinary\"}",
        );
        defer mock.deinit();
        var recorder = RecordingTransport.init(
            std.testing.allocator,
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            if (request_has_body) .POST else .GET,
            "https://example.test/default-policy",
        );
        defer request.deinit();
        if (request_has_body) request.body = "{\"message\":\"ordinary\"}";
        var response = try recorder.asTransport().send(&request);
        response.deinit();
        try std.testing.expectError(
            error.BodyPolicyRequired,
            recorder.toJson(std.testing.allocator),
        );
    }
}

test "App Configuration dotted values are not mistaken for JWTs" {
    const body =
        "{\"key\":\"endpoint\",\"key1\":\"configuration-label\",\"value\":\"service.production.contoso\",\"passwords\":[{\"name\":\"password\",\"value\":\"ordinary-schema-example\"}]}";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        body,
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://store.azconfig.io/kv/endpoint?api-version=1.0",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(
        u8,
        body,
        parsed.asSlice()[0].response_body,
    );

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replayed = try playback.asTransport().send(&request);
    replayed.deinit();
}

test "recording JSON decodes safe structured bodies losslessly" {
    const request_body =
        "{\"key\":\"prod*\",\"value\":\"nonsensitive\",\"nested\":{\"kind\":\"filter\"}}";
    const response_body =
        "{\"items\":[{\"key\":\"prod\",\"value\":\"enabled\"}],\"continuationToken\":\"next\"}";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        response_body,
    );
    defer mock.deinit();
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://config.azconfig.io/kv?key=prod*&api-version=1.0",
    );
    defer request.deinit();
    request.body = request_body;
    var response = try recorder.asTransport().send(&request);
    response.deinit();

    const json = try recorder.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.asSlice().len);
    try std.testing.expectEqualSlices(
        u8,
        request_body,
        parsed.asSlice()[0].request_body.?,
    );
    try std.testing.expectEqualSlices(
        u8,
        response_body,
        parsed.asSlice()[0].response_body,
    );

    var playback = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    var replay_request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://config.azconfig.io/kv?key=prod*&api-version=1.0",
    );
    defer replay_request.deinit();
    replay_request.body = request_body;
    var replayed = try playback.asTransport().send(&replay_request);
    defer replayed.deinit();
    try std.testing.expectEqualSlices(u8, response_body, replayed.body);

    var mismatch = PlaybackTransport.init(
        std.testing.allocator,
        parsed.asSlice(),
    );
    replay_request.body =
        "{\"key\":\"prod*\",\"value\":\"changed\",\"nested\":{\"kind\":\"filter\"}}";
    try std.testing.expectError(
        error.BodyMismatch,
        mismatch.asTransport().send(&replay_request),
    );
}

fn playbackAllocationFixture(allocator: std.mem.Allocator) !void {
    const recordings = [_]RecordedExchange{.{
        .request_method = .GET,
        .request_url = "https://example.com",
        .response_status = 200,
        .response_body = "response",
        .response_headers = &.{.{ .name = "X-Test", .value = "value" }},
    }};
    var playback = PlaybackTransport.init(allocator, &recordings);
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com",
    );
    defer request.deinit();
    var operation = try playback.asTransport().open(&request, .{});
    defer operation.deinit();
    try operation.finish();
}

fn recordingAllocationFixture(allocator: std.mem.Allocator) !void {
    var mock = core.http.MockTransport.init(allocator, 200, "response");
    defer mock.deinit();
    var recorder = RecordingTransport.init(allocator, mock.asTransport());
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com",
    );
    defer request.deinit();
    var source = std.Io.Reader.fixed("request");
    var operation = try recorder.asTransport().open(&request, .{
        .body = core.http.StreamingRequestBody.chunked(&source),
    });
    defer operation.deinit();
    try operation.finish();
}

fn recordingRedirectAllocationFixture(allocator: std.mem.Allocator) !void {
    var sequence = core.http.SequenceMockTransport.init(
        allocator,
        &.{
            .{
                .status = 302,
                .body = "ignored",
                .headers = &.{.{ .name = "Location", .value = "/final" }},
            },
            .{ .status = 200, .body = "done" },
        },
    );
    var recorder = RecordingTransport.init(allocator, sequence.asTransport());
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/start",
    );
    defer request.deinit();
    var operation = try recorder.asTransport().open(&request, .{});
    defer operation.deinit();
    try operation.finish();
}

fn recordingBufferedFallbackAllocationFixture(
    allocator: std.mem.Allocator,
) !void {
    var mock = core.http.MockTransport.init(allocator, 200, "response");
    defer mock.deinit();
    var buffered_only = BufferedOnlyTransport{ .inner = &mock };
    var recorder = RecordingTransport.init(
        allocator,
        buffered_only.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/buffered",
    );
    defer request.deinit();
    request.body = "request";
    var operation = try recorder.asTransport().open(&request, .{});
    defer operation.deinit();
    try operation.finish();
}

fn serializationAllocationFixture(allocator: std.mem.Allocator) !void {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "{\"message\":\"response\"}",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{
            .name = "Location",
            .value = "https://example.com/next?sig=allocation-secret&mode=one",
        },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/items?sig=secret&version=1",
    );
    defer request.deinit();
    request.body = "{\"message\":\"request\"}";
    try request.setHeader("Authorization", "Bearer secret");
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(allocator);
    allocator.free(json);
}

fn binaryMetadataSerializationAllocationFixture(
    allocator: std.mem.Allocator,
) !void {
    const header_value = [_]u8{ 0xff, 'a' };
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "ETag", .value = &header_value },
    };
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.test/\xff",
    );
    defer request.deinit();
    try request.setHeader("ETag", &header_value);
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(allocator);
    allocator.free(json);
}

fn multipartSerializationAllocationFixture(
    allocator: std.mem.Allocator,
) !void {
    const body =
        "--batch\r\nContent-Type: application/http\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" ++
        "{\"PartitionKey\":\"p\",\"RowKey\":\"r\",\"value\":\"safe\"}\r\n" ++
        "--batch--\r\n";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        body,
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "multipart/mixed; boundary=batch" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &allowOpaqueBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .POST,
        "https://account.table.core.windows.net/$batch",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(allocator);
    allocator.free(json);
}

fn jwtHeaderAllocationFixture(allocator: std.mem.Allocator) !void {
    const jwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ++
        "." ++
        "eyJzdWIiOiJoZWFkZXIiLCJleHAiOjQxMDI0NDQ4MDB9" ++
        "." ++
        "c2lnbmF0dXJlLWJ5dGVzLXZhbHVl";
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "",
    );
    defer mock.deinit();
    var recorder = RecordingTransport.init(
        std.testing.allocator,
        mock.asTransport(),
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com",
    );
    defer request.deinit();
    try request.setHeader("ETag", jwt);
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(allocator);
    allocator.free(json);
}

fn endpointSchemaAllocationFixture(allocator: std.mem.Allocator) !void {
    var mock = core.http.MockTransport.init(
        std.testing.allocator,
        200,
        "{\"ordinary\":\"safe\"}",
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var recorder = RecordingTransport.initWithOptions(
        std.testing.allocator,
        mock.asTransport(),
        .{ .bodyPolicyFn = &inspectKnownSafeBody },
    );
    defer recorder.deinit();
    var request = core.http.Request.init(
        std.testing.allocator,
        .GET,
        "https://management.azure.com/subscriptions/s/" ++
            "providers/Microsoft.Batch/resources/ordinary",
    );
    defer request.deinit();
    var response = try recorder.asTransport().send(&request);
    response.deinit();
    const json = try recorder.toJson(allocator);
    allocator.free(json);
}

const allocation_fixture_json =
    \\{"version":2,"exchanges":[{"request_method":"POST","request_url":"https://example.com","request_headers":[],"request_body":{"encoding":"base64","data":"cmVxdWVzdA=="},"response_status":200,"response_headers":[],"response_body":{"encoding":"base64","data":"cmVzcG9uc2U="}}]}
;

fn parsingAllocationFixture(allocator: std.mem.Allocator) !void {
    var parsed = try parseJson(allocator, allocation_fixture_json);
    parsed.deinit();
}

const failure_allocation_fixture_json =
    \\{"version":3,"exchanges":[
    \\{"request_method":"GET","request_url":"https://example.com/open","request_url_redacted":false,"request_headers":[],"request_body":null,"outcome":"open_error","error_category":"connection"},
    \\{"request_method":"GET","request_url":"https://example.com/body","request_url_redacted":false,"request_headers":[],"request_body":null,"outcome":"body_error","error_category":"io","response_status":200,"response_headers":[],"response_body":{"encoding":"base64","data":"cGFydGlhbA=="}}
    \\]}
;

fn failureParsingAllocationFixture(allocator: std.mem.Allocator) !void {
    var parsed = try parseJson(allocator, failure_allocation_fixture_json);
    parsed.deinit();
}

const redaction_template_allocation_fixture_json =
    \\{"version":3,"exchanges":[{
    \\"request_method":"GET",
    \\"request_url":"https://example.test/item?sig=REDACTED",
    \\"request_url_redaction_template":"https://example.test/item?sig=\u0000",
    \\"request_headers":[{
    \\"name":"Operation-Location",
    \\"value":"https://next.example/item?sig=REDACTED",
    \\"redacted":false,
    \\"url_redaction_template":"https://next.example/item?sig=\u0000"
    \\}],
    \\"request_body":null,
    \\"outcome":"response",
    \\"response_status":200,
    \\"response_headers":[],
    \\"response_body":{"encoding":"base64","data":""}
    \\}]}
;

fn redactionTemplateParsingAllocationFixture(
    allocator: std.mem.Allocator,
) !void {
    var parsed = try parseJson(
        allocator,
        redaction_template_allocation_fixture_json,
    );
    parsed.deinit();
}

const binary_metadata_allocation_fixture_json =
    \\{"version":3,"exchanges":[{
    \\"request_method":"GET",
    \\"request_url":{"encoding":"base64","data":"aHR0cHM6Ly9leGFtcGxlLnRlc3Qv/w=="},
    \\"request_url_redaction_template":null,
    \\"request_headers":[{
    \\"name":"ETag",
    \\"value":{"encoding":"base64","data":"/2E="},
    \\"redacted":false,
    \\"url_redaction_template":null
    \\}],
    \\"request_body":null,
    \\"outcome":"response",
    \\"response_status":200,
    \\"response_headers":[],
    \\"response_body":{"encoding":"base64","data":""}
    \\}]}
;

fn binaryMetadataParsingAllocationFixture(
    allocator: std.mem.Allocator,
) !void {
    var parsed = try parseJson(
        allocator,
        binary_metadata_allocation_fixture_json,
    );
    parsed.deinit();
}

test "transport allocation failures clean up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        playbackAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordingAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordingRedirectAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordingBufferedFallbackAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        serializationAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        binaryMetadataSerializationAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        multipartSerializationAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        jwtHeaderAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        endpointSchemaAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parsingAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        failureParsingAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        redactionTemplateParsingAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        binaryMetadataParsingAllocationFixture,
        .{},
    );
}

test "post-dispatch recorder allocation failure poisons serialization" {
    var found_post_dispatch_failure = false;
    for (0..64) |fail_index| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "response",
        );
        defer mock.deinit();
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var recorder = RecordingTransport.init(
            failing.allocator(),
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/bookkeeping",
        );
        defer request.deinit();
        if (recorder.asTransport().send(&request)) |response_value| {
            var response = response_value;
            response.deinit();
        } else |err| {
            if (err == error.OutOfMemory and mock.call_count != 0) {
                found_post_dispatch_failure = true;
                try std.testing.expect(!recorder.isComplete());
                try std.testing.expectError(
                    error.IncompleteRecording,
                    recorder.toJson(std.testing.allocator),
                );
                try std.testing.expectError(
                    error.IncompleteRecording,
                    recorder.asTransport().send(&request),
                );
                break;
            }
        }
    }
    try std.testing.expect(found_post_dispatch_failure);
}

test "stream capture allocation failure poisons serialization" {
    var found_capture_failure = false;
    for (0..96) |fail_index| {
        var mock = core.http.MockTransport.init(
            std.testing.allocator,
            200,
            "response body large enough to allocate capture storage",
        );
        defer mock.deinit();
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var recorder = RecordingTransport.init(
            failing.allocator(),
            mock.asTransport(),
        );
        defer recorder.deinit();
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://example.test/stream-bookkeeping",
        );
        defer request.deinit();
        const opened = recorder.asTransport().open(&request, .{}) catch
            continue;
        var operation = opened;
        const read_result = (try operation.reader()).allocRemaining(
            std.testing.allocator,
            .unlimited,
        );
        if (read_result) |body| {
            std.testing.allocator.free(body);
            operation.finish() catch {};
            operation.deinit();
        } else |err| {
            const body_error = operation.bodyError();
            if (err == error.ReadFailed and body_error != null and
                body_error.? == error.OutOfMemory)
            {
                operation.abort();
                operation.deinit();
                found_capture_failure = true;
                try std.testing.expect(!recorder.isComplete());
                try std.testing.expectError(
                    error.IncompleteRecording,
                    recorder.toJson(std.testing.allocator),
                );
                break;
            }
            operation.abort();
            operation.deinit();
        }
    }
    try std.testing.expect(found_capture_failure);
}

test "version 2 success recordings remain readable" {
    const json =
        \\{"version":2,"exchanges":[{
        \\  "request_method":"GET",
        \\  "request_url":"https://example.test/v2",
        \\  "request_headers":[],
        \\  "request_body":null,
        \\  "response_status":200,
        \\  "response_headers":[],
        \\  "response_body":{"encoding":"base64","data":""}
        \\}]}
    ;
    var parsed = try parseJson(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(
        RecordedOutcome.response,
        parsed.asSlice()[0].outcome,
    );
    try std.testing.expect(parsed.asSlice()[0].error_category == null);
}

test "recording parser reports version encoding and base64 errors" {
    try std.testing.expectError(
        error.UnsupportedRecordingVersion,
        parseJson(
            std.testing.allocator,
            "{\"version\":1,\"exchanges\":[]}",
        ),
    );
    try std.testing.expectError(
        error.UnsupportedBodyEncoding,
        parseJson(
            std.testing.allocator,
            "{\"version\":2,\"exchanges\":[{\"request_method\":\"GET\",\"request_url\":\"https://example.com\",\"request_headers\":[],\"request_body\":null,\"response_status\":200,\"response_headers\":[],\"response_body\":{\"encoding\":\"raw\",\"data\":\"value\"}}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidRecordingBody,
        parseJson(
            std.testing.allocator,
            "{\"version\":2,\"exchanges\":[{\"request_method\":\"GET\",\"request_url\":\"https://example.com\",\"request_headers\":[],\"request_body\":null,\"response_status\":200,\"response_headers\":[],\"response_body\":{\"encoding\":\"base64\",\"data\":\"***\"}}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidRecordingJson,
        parseJson(
            std.testing.allocator,
            "{\"version\":2,\"exchanges\":[{\"request_method\":\"GET\",\"request_url\":\"https://example.com\",\"request_headers\":[{\"name\":\"x-test\",\"value\":\"value\",\"redacted\":\"yes\"}],\"request_body\":null,\"response_status\":200,\"response_headers\":[],\"response_body\":{\"encoding\":\"base64\",\"data\":\"\"}}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidRecordingOutcome,
        parseJson(
            std.testing.allocator,
            "{\"version\":3,\"exchanges\":[{\"request_method\":\"GET\",\"request_url\":\"https://example.com\",\"request_url_redacted\":false,\"request_headers\":[],\"request_body\":null,\"outcome\":\"backend_specific\"}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidRecordingJson,
        parseJson(
            std.testing.allocator,
            "{\"version\":3,\"exchanges\":[{\"request_method\":\"GET\",\"request_url\":\"https://example.com\",\"request_url_redacted\":false,\"request_headers\":[],\"request_body\":null,\"outcome\":\"transport_error\"}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidRecordingJson,
        parseJson(
            std.testing.allocator,
            "{\"version\":3,\"exchanges\":[{\"request_method\":\"GET\",\"request_url\":\"https://example.com\",\"request_url_redacted\":false,\"request_headers\":[],\"request_body\":null,\"outcome\":\"response\",\"error_category\":\"unknown\",\"response_status\":200,\"response_headers\":[],\"response_body\":{\"encoding\":\"base64\",\"data\":\"\"}}]}",
        ),
    );
}

test "initHttpRuntime preserves selected transport and crypto provider" {
    var playback = PlaybackTransport.init(std.testing.allocator, &.{});
    const Spy = struct {
        fn random(_: *anyopaque, out: []u8) !void {
            @memset(out, 0x5a);
        }
        fn md5(_: *anyopaque, _: []const u8, out: *core.crypto.Md5Digest) !void {
            @memset(out, 0x5a);
        }
        fn sha256(
            _: *anyopaque,
            _: []const u8,
            out: *core.crypto.Sha256Digest,
        ) !void {
            @memset(out, 0x5a);
        }
        fn hmac(
            _: *anyopaque,
            _: []const u8,
            _: []const u8,
            out: *core.crypto.HmacSha256Digest,
        ) !void {
            @memset(out, 0x5a);
        }
        fn sha256Init(
            _: *anyopaque,
            _: std.mem.Allocator,
        ) !core.crypto.Sha256Operation {
            return error.Unused;
        }
        const vtable: core.crypto.CryptoProvider.VTable = .{
            .random_bytes = &random,
            .md5 = &md5,
            .sha256 = &sha256,
            .hmac_sha256 = &hmac,
            .sha256_init = &sha256Init,
        };
    };
    var context: u8 = 0;
    const provider = core.crypto.CryptoProvider{
        .context = &context,
        .vtable = &Spy.vtable,
    };
    const runtime = initHttpRuntime(playback.asTransport(), provider);
    var bytes: [2]u8 = undefined;
    try runtime.crypto.randomBytes(&bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x5a, 0x5a }, &bytes);
    try std.testing.expectEqual(
        playback.asTransport().context,
        runtime.transport.context,
    );
}

test "initHttpRuntime propagates selected provider failures" {
    var playback = PlaybackTransport.init(std.testing.allocator, &.{});
    const Fault = struct {
        fn failRandom(_: *anyopaque, _: []u8) !void {
            return error.ProviderFailure;
        }
        fn failMd5(
            _: *anyopaque,
            _: []const u8,
            _: *core.crypto.Md5Digest,
        ) !void {
            return error.ProviderFailure;
        }
        fn failSha256(
            _: *anyopaque,
            _: []const u8,
            _: *core.crypto.Sha256Digest,
        ) !void {
            return error.ProviderFailure;
        }
        fn failHmac(
            _: *anyopaque,
            _: []const u8,
            _: []const u8,
            _: *core.crypto.HmacSha256Digest,
        ) !void {
            return error.ProviderFailure;
        }
        fn failSha256Init(
            _: *anyopaque,
            _: std.mem.Allocator,
        ) !core.crypto.Sha256Operation {
            return error.ProviderFailure;
        }
        const vtable: core.crypto.CryptoProvider.VTable = .{
            .random_bytes = &failRandom,
            .md5 = &failMd5,
            .sha256 = &failSha256,
            .hmac_sha256 = &failHmac,
            .sha256_init = &failSha256Init,
        };
    };
    var context: u8 = 0;
    const runtime = initHttpRuntime(playback.asTransport(), .{
        .context = &context,
        .vtable = &Fault.vtable,
    });
    var bytes: [1]u8 = undefined;
    try std.testing.expectError(
        error.ProviderFailure,
        runtime.crypto.randomBytes(&bytes),
    );
}
