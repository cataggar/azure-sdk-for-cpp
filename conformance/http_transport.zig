const std = @import("std");
const core = @import("azure_sdk_core");
pub const scripted = @import("scripted_http_server.zig");
pub const fakes = @import("azure_sdk_core_conformance_fakes");

pub const CancellationGrade = enum {
    none,
    preflight,
    cooperative_upload,
};

/// Stronger interruption is orthogonal to the legacy cooperative grade.
/// Claim only phases proved by an adapter-local, bounded integration fixture.
pub const InterruptionPhase = enum { connect, upload_read, upload_write, response_headers, response_body, finish_drain };
pub const InterruptionTrigger = enum { token, deadline };
pub const InterruptionPhases = std.enums.EnumSet(InterruptionPhase);
pub const InterruptionCapabilities = struct {
    token: InterruptionPhases = .initEmpty(),
    deadline: InterruptionPhases = .initEmpty(),
};

pub const InterruptionEvidence = struct {
    phase_entered: bool,
    transport_started: bool,
    outcome: anyerror,
    /// Measured from signalling cancellation / expiry, not fixture startup.
    elapsed_ms: u64,
    cleanup_count: usize,
    live_operations: usize,
    leased_connections: usize,
};

pub const Capabilities = struct {
    streaming: bool = true,
    ordered_duplicate_response_headers: bool = true,
    request_framing_validation: bool = true,
    response_framing_validation: bool = false,
    response_body_limit: bool = false,
    decompression: bool = false,
    cancellation: CancellationGrade = .preflight,
    lifecycle_observable: bool = false,
    automatic_request_headers: bool = false,
    bounded_memory_logical_large_upload: bool = false,
    bounded_memory_logical_large_download: bool = false,
    scripted_attempts: bool = false,
    /// The factory serves trusted HTTPS URLs, required for positive redirects.
    https_redirects: bool = false,
    allocation_failure_cleanup: bool = false,
    interruption: InterruptionCapabilities = .{},
};

pub const BackendOptions = struct {
    response: scripted.Response = .{},
    expect_request: bool = true,
    allow_peer_failure: bool = false,
    max_response_body: ?usize = null,
    /// Harness allocations must not use an allocator under test on a peer thread.
    fixture_allocator: ?std.mem.Allocator = null,
    /// Borrowed until backend deinit. Empty retains the original one-response API.
    responses: []const scripted.Response = &.{},
};

pub const Observation = struct {
    request_count: usize = 0,
    body: []const u8 = "",
    body_length: usize = 0,
    user_agent_count: usize = 0,
    accept_encoding_count: usize = 0,
    host_count: usize = 0,
    connection_count: usize = 0,
    accept_count: usize = 0,
    finish_count: usize = 0,
    abort_count: usize = 0,
    cancel_count: usize = 0,
    deinit_count: usize = 0,
    request_line: []const u8 = "",
    authorization: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    proxy_authorization: ?[]const u8 = null,
    policy_marker: ?[]const u8 = null,
    content_length: ?[]const u8 = null,
    host: ?[]const u8 = null,
    body_hash: u64 = 0,
};

pub const BackendInstance = struct {
    transport: core.http.HttpTransport,
    url: []const u8,
    context: *anyopaque,
    finishFn: *const fn (context: *anyopaque) anyerror!void,
    observeFn: *const fn (context: *anyopaque) Observation,
    deinitFn: *const fn (context: *anyopaque) void,
    attemptFn: ?*const fn (context: *anyopaque, index: usize) ?Observation = null,
    /// Optional adapter-native pool/operation assertion after operation teardown.
    assertQuiescentFn: ?*const fn (context: *anyopaque) anyerror!void = null,

    pub fn finish(self: *BackendInstance) !void {
        return self.finishFn(self.context);
    }

    pub fn observe(self: *const BackendInstance) Observation {
        return self.observeFn(self.context);
    }

    pub fn deinit(self: *BackendInstance) void {
        self.deinitFn(self.context);
        self.* = undefined;
    }

    pub fn attempt(self: *const BackendInstance, index: usize) !Observation {
        const observe_attempt = self.attemptFn orelse return error.AttemptObservationRequired;
        return observe_attempt(self.context, index) orelse error.MissingAttempt;
    }

    pub fn assertQuiescent(self: *const BackendInstance) !void {
        if (self.assertQuiescentFn) |check| try check(self.context);
    }
};

pub const BackendFactory = struct {
    name: []const u8,
    capabilities: Capabilities,
    context: ?*anyopaque = null,
    createFn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: BackendOptions,
    ) anyerror!BackendInstance,
    /// Called by the failure runner with a fresh allocator for each scenario.
    /// Must release all resources even on error, preserve OutOfMemory, and
    /// assert adapter-native operation/pool cleanup before returning.
    allocationFixtureFn: ?*const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        fixture_allocator: std.mem.Allocator,
        io: std.Io,
        scenario: AllocationScenario,
    ) anyerror!void = null,
    interruptionFixtureFn: ?*const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        phase: InterruptionPhase,
        trigger: InterruptionTrigger,
    ) anyerror!InterruptionEvidence = null,

    pub fn create(
        self: BackendFactory,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: BackendOptions,
    ) !BackendInstance {
        return self.createFn(self.context, allocator, io, options);
    }
};

/// Run raw transport contracts against a backend factory.
///
/// Capabilities explicitly distinguish unsupported contracts from failures,
/// including build-only backends whose runtime host is unavailable.
pub fn runRawTransportContracts(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    try runBufferedContract(allocator, io, factory);
    if (factory.capabilities.streaming) {
        try runStreamingContract(allocator, io, factory, true);
        try runStreamingContract(allocator, io, factory, false);
        try runLifecycleContract(allocator, io, factory);
    }
    if (factory.capabilities.request_framing_validation) {
        try runRequestFramingContracts(allocator, io, factory);
    }
    if (factory.capabilities.cancellation != .none) {
        try runCancellationContracts(allocator, io, factory);
    }
    if (factory.capabilities.response_framing_validation) {
        try runResponseFramingContract(allocator, io, factory);
    }
    if (factory.capabilities.response_body_limit) {
        try runResponseLimitContract(allocator, io, factory);
    }
    if (factory.capabilities.decompression) {
        try runDecompressionContract(allocator, io, factory, false);
        try runDecompressionContract(allocator, io, factory, true);
    }
    if (factory.capabilities.bounded_memory_logical_large_upload) {
        try runLogicalLargeUploadContract(allocator, io, factory);
        if (factory.capabilities.request_framing_validation)
            try runWideLengthContract(allocator, io, factory);
    }
    if (factory.capabilities.bounded_memory_logical_large_download)
        try runLogicalLargeDownloadContracts(allocator, io, factory);
    try runInterruptionContracts(allocator, io, factory);
}

/// Run Core pipeline ownership, redirect, replay, retry, and decompression
/// contracts. Adapter packages should invoke this with their backend factory.
pub fn runPipelineContracts(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    if (factory.capabilities.https_redirects and !factory.capabilities.scripted_attempts)
        return error.ScriptedAttemptsRequired;
    try runPipelineDispatchContract(allocator, io, factory);
    try runRedirectContracts(allocator);
    try runRetryContracts(allocator);
    if (factory.capabilities.scripted_attempts) {
        try runBackendAttemptContracts(allocator, io, factory);
    }
    if (factory.capabilities.decompression) {
        try runPipelineDecompressionContract(allocator, io, factory);
    }
}

/// Exhaustively fail allocator calls in the reusable fake streaming,
/// redirect, and retry fixtures.
pub fn runAllocationFailureContracts() !void {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        mockStreamingAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        redirectAllocationFixture,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        retryAllocationFixture,
        .{},
    );
}

pub const AllocationScenario = enum { buffered, finish, abort, redirect, retry };

/// Unlike runAllocationFailureContracts, this exercises the supplied adapter.
/// Capability absence is a skip, never evidence of adapter allocation coverage.
pub fn runBackendAllocationFailureContracts(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    if (!factory.capabilities.allocation_failure_cleanup) return;
    if (factory.allocationFixtureFn == null) return error.AllocationFixtureRequired;
    inline for (std.meta.tags(AllocationScenario)) |scenario| {
        var baseline = std.testing.FailingAllocator.init(allocator, .{});
        try backendAllocationFixture(&baseline, allocator, io, factory, scenario);
        for (0..baseline.alloc_index) |fail_index| {
            var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
            if (backendAllocationFixture(&failing, allocator, io, factory, scenario)) |_| {
                return if (failing.has_induced_failure)
                    error.SwallowedOutOfMemoryError
                else
                    error.NondeterministicMemoryUsage;
            } else |err| switch (err) {
                error.OutOfMemory => {
                    if (!failing.has_induced_failure) return error.UninjectedOutOfMemory;
                },
                else => return err,
            }
        }
    }
}

fn backendAllocationFixture(
    failing: *std.testing.FailingAllocator,
    fixture_allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
    scenario: AllocationScenario,
) !void {
    const result = factory.allocationFixtureFn.?(factory.context, failing.allocator(), fixture_allocator, io, scenario);
    if (failing.allocated_bytes != failing.freed_bytes) return error.MemoryLeakDetected;
    result catch |err| {
        // std.Io.Writer hides allocation errors behind WriteFailed. Only the
        // runner-owned allocator can prove this iteration injected a failure.
        if (err == error.WriteFailed and failing.has_induced_failure) return error.OutOfMemory;
        return err;
    };
}

/// Adapter fixtures must synchronize entry into the blocked phase, then signal
/// cancellation or let the deadline expire, with a watchdog that always joins.
/// Preflight rejection and an abort after unblocking do not qualify.
pub fn runInterruptionContracts(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    for (std.meta.tags(InterruptionTrigger)) |trigger| {
        const phases = switch (trigger) {
            .token => factory.capabilities.interruption.token,
            .deadline => factory.capabilities.interruption.deadline,
        };
        for (std.meta.tags(InterruptionPhase)) |phase| {
            if (!phases.contains(phase)) continue;
            const fixture = factory.interruptionFixtureFn orelse return error.InterruptionFixtureRequired;
            const evidence = try fixture(factory.context, allocator, io, phase, trigger);
            try validateInterruptionEvidence(evidence, trigger);
        }
    }
}

fn validateInterruptionEvidence(evidence: InterruptionEvidence, trigger: InterruptionTrigger) !void {
    if (!evidence.phase_entered or !evidence.transport_started) return error.InterruptionNotObserved;
    const expected: anyerror = if (trigger == .token) error.OperationCancelled else error.OperationTimedOut;
    if (evidence.outcome != expected) return error.InterruptionOutcomeMismatch;
    if (evidence.elapsed_ms > 1000) return error.InterruptionBudgetExceeded;
    if (evidence.cleanup_count != 1 or evidence.live_operations != 0 or evidence.leased_connections != 0)
        return error.InterruptionCleanupIncomplete;
}

fn runBufferedContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    const headers = [_]scripted.Header{
        .{ .name = "X-Duplicate", .value = "first" },
        .{ .name = "x-duplicate", .value = "second" },
    };
    var backend = try factory.create(allocator, io, .{
        .response = .{
            .status_code = 201,
            .reason = "Created",
            .headers = &headers,
            .body = "buffered-response",
        },
    });
    defer backend.deinit();

    const copied = backend.transport;
    var request = core.http.Request.init(allocator, .GET, backend.url);
    defer request.deinit();
    try request.setHeader("User-Agent", "azsdk-zig-conformance/0.3.0");
    try request.setHeader("Accept-Encoding", "identity");
    try request.setHeader("Accept", "application/json");

    var response = try copied.send(&request);
    defer response.deinit();
    try backend.finish();
    try std.testing.expectEqual(@as(u16, 201), response.status_code);
    try std.testing.expectEqualStrings("buffered-response", response.body);
    if (factory.capabilities.ordered_duplicate_response_headers) {
        const values = try response.getHeaderValues(allocator, "X-DUPLICATE");
        defer allocator.free(values);
        try std.testing.expectEqual(@as(usize, 2), values.len);
        try std.testing.expectEqualStrings("first", values[0]);
        try std.testing.expectEqualStrings("second", values[1]);
    }

    const observation = backend.observe();
    try std.testing.expectEqual(@as(usize, 1), observation.request_count);
    if (factory.capabilities.automatic_request_headers) {
        try std.testing.expectEqual(@as(usize, 1), observation.user_agent_count);
        try std.testing.expectEqual(@as(usize, 1), observation.accept_encoding_count);
        try std.testing.expectEqual(@as(usize, 1), observation.host_count);
        try std.testing.expectEqual(@as(usize, 1), observation.connection_count);
        try std.testing.expectEqual(@as(usize, 1), observation.accept_count);
    }
}

fn runStreamingContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
    known_length: bool,
) !void {
    var backend = try factory.create(allocator, io, .{
        .response = .{ .status_code = 202, .reason = "Accepted", .body = "stream-response" },
    });
    defer backend.deinit();

    var request = core.http.Request.init(allocator, .POST, backend.url);
    defer request.deinit();
    var reader = std.Io.Reader.fixed("stream-upload");
    const body = if (known_length)
        core.http.StreamingRequestBody.knownLength(&reader, "stream-upload".len)
    else
        core.http.StreamingRequestBody.chunked(&reader);
    {
        var operation = try backend.transport.open(&request, .{ .body = body });
        defer operation.deinit();
        const response = try (try operation.reader()).allocRemaining(allocator, .unlimited);
        defer allocator.free(response);
        try std.testing.expectEqualStrings("stream-response", response);
        try operation.finish();
        try std.testing.expectError(error.HttpOperationNotActive, operation.finish());
        operation.abort();
        operation.cancel();
    }
    try backend.finish();
    try backend.assertQuiescent();

    const observation = backend.observe();
    try std.testing.expectEqual(@as(usize, 1), observation.request_count);
    try std.testing.expectEqualStrings("stream-upload", observation.body);
    try std.testing.expectEqual(@as(usize, "stream-upload".len), observation.body_length);
    if (factory.capabilities.lifecycle_observable) {
        try std.testing.expectEqual(@as(usize, 1), observation.finish_count);
        try std.testing.expectEqual(@as(usize, 0), observation.abort_count);
        try std.testing.expectEqual(@as(usize, 0), observation.cancel_count);
        try std.testing.expectEqual(@as(usize, 1), observation.deinit_count);
    }
}

fn runLifecycleContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    const Completion = enum { finish, abort, cancel, deinit };
    for (std.meta.tags(Completion)) |completion| {
        var backend = try factory.create(allocator, io, .{
            .response = .{ .body = "partially consumed response" },
        });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .GET, backend.url);
        defer request.deinit();
        {
            var operation = try backend.transport.open(&request, .{});
            defer operation.deinit();
            var prefix: [1]u8 = undefined;
            try (try operation.reader()).readSliceAll(&prefix);
            try std.testing.expectEqual(@as(u8, 'p'), prefix[0]);
            switch (completion) {
                .finish => try operation.finish(),
                .abort => operation.abort(),
                .cancel => operation.cancel(),
                .deinit => {},
            }
            if (completion != .deinit) {
                const expected: core.http.OperationState = switch (completion) {
                    .finish => .finished,
                    .abort => .aborted,
                    .cancel => .cancelled,
                    .deinit => unreachable,
                };
                try std.testing.expectEqual(expected, operation.state);
                try std.testing.expectError(error.HttpOperationNotActive, operation.reader());
                try std.testing.expectError(error.HttpOperationNotActive, operation.finish());
                operation.abort();
                operation.cancel();
                try std.testing.expectEqual(expected, operation.state);
            }
        }
        try backend.finish();
        try backend.assertQuiescent();
        if (factory.capabilities.lifecycle_observable) {
            const observation = backend.observe();
            try std.testing.expectEqual(@as(usize, if (completion == .finish) 1 else 0), observation.finish_count);
            try std.testing.expectEqual(@as(usize, if (completion == .abort or completion == .deinit) 1 else 0), observation.abort_count);
            try std.testing.expectEqual(@as(usize, if (completion == .cancel) 1 else 0), observation.cancel_count);
            try std.testing.expectEqual(@as(usize, 1), observation.deinit_count);
        }
    }
}

fn runRequestFramingContracts(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    {
        var backend = try factory.create(allocator, io, .{ .expect_request = false });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .POST, backend.url);
        defer request.deinit();
        try request.setHeader("Content-Length", "99");
        var source = std.Io.Reader.fixed("body");
        try std.testing.expectError(
            error.ConflictingRequestFraming,
            backend.transport.open(&request, .{
                .body = core.http.StreamingRequestBody.knownLength(&source, 4),
            }),
        );
        try backend.finish();
        try std.testing.expect(request.transport_started);
    }
    {
        var backend = try factory.create(allocator, io, .{
            .allow_peer_failure = true,
        });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .POST, backend.url);
        defer request.deinit();
        var source = std.Io.Reader.fixed("short");
        try std.testing.expectError(
            error.RequestBodyTooShort,
            backend.transport.open(&request, .{
                .body = core.http.StreamingRequestBody.knownLength(&source, 6),
            }),
        );
        try backend.finish();
    }
    {
        var backend = try factory.create(allocator, io, .{
            .allow_peer_failure = true,
        });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .POST, backend.url);
        defer request.deinit();
        var source = std.Io.Reader.fixed("long");
        try std.testing.expectError(
            error.RequestBodyTooLong,
            backend.transport.open(&request, .{
                .body = core.http.StreamingRequestBody.knownLength(&source, 3),
            }),
        );
        try backend.finish();
    }
    {
        var backend = try factory.create(allocator, io, .{ .expect_request = false });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .POST, backend.url);
        defer request.deinit();
        request.body = "buffered";
        var source = std.Io.Reader.fixed("streamed");
        try std.testing.expectError(
            error.MultipleRequestBodies,
            backend.transport.open(&request, .{
                .body = core.http.StreamingRequestBody.chunked(&source),
            }),
        );
        try backend.finish();
    }
}

fn runCancellationContracts(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    {
        var backend = try factory.create(allocator, io, .{ .expect_request = false });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .GET, backend.url);
        defer request.deinit();
        var token = core.http.CancellationToken{};
        token.cancel();
        try std.testing.expectError(
            error.OperationCancelled,
            backend.transport.open(&request, .{ .cancellation = &token }),
        );
        try backend.finish();
        try std.testing.expect(!request.transport_started);
        try std.testing.expectEqual(@as(usize, 0), backend.observe().request_count);
        try backend.assertQuiescent();
    }
    if (factory.capabilities.cancellation == .cooperative_upload) {
        var backend = try factory.create(allocator, io, .{
            .allow_peer_failure = true,
        });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .POST, backend.url);
        defer request.deinit();
        var token = core.http.CancellationToken{};
        var source = fakes.CancellingReader.init(&token);
        try std.testing.expectError(
            error.OperationCancelled,
            backend.transport.open(&request, .{
                .body = core.http.StreamingRequestBody.chunked(&source.interface),
                .cancellation = &token,
            }),
        );
        try backend.finish();
        try std.testing.expect(source.emitted);
        try std.testing.expect(request.transport_started);
        try backend.assertQuiescent();
    }
}

fn runResponseFramingContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    {
        var backend = try factory.create(allocator, io, .{
            .response = .{
                .body = "short",
                .advertised_content_length = 12,
            },
        });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .GET, backend.url);
        defer request.deinit();
        {
            var operation = try backend.transport.open(&request, .{});
            defer operation.deinit();
            try std.testing.expectError(
                error.HttpContentLengthTruncated,
                operation.finish(),
            );
            try std.testing.expectEqual(core.http.OperationState.aborted, operation.state);
            try std.testing.expectError(error.HttpOperationNotActive, operation.reader());
            try std.testing.expectError(error.HttpOperationNotActive, operation.finish());
            operation.abort();
            operation.cancel();
        }
        try backend.finish();
        try backend.assertQuiescent();
        if (factory.capabilities.lifecycle_observable) {
            const observation = backend.observe();
            try std.testing.expectEqual(@as(usize, 1), observation.finish_count);
            try std.testing.expectEqual(@as(usize, 1), observation.abort_count);
            try std.testing.expectEqual(@as(usize, 0), observation.cancel_count);
            try std.testing.expectEqual(@as(usize, 1), observation.deinit_count);
        }
    }
    {
        var backend = try factory.create(allocator, io, .{
            .response = .{
                .body = "short",
                .advertised_content_length = 12,
            },
        });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .GET, backend.url);
        defer request.deinit();
        try std.testing.expectError(
            error.HttpContentLengthTruncated,
            backend.transport.send(&request),
        );
        try backend.finish();
        try backend.assertQuiescent();
    }
    {
        const malformed_headers = [_]scripted.Header{
            .{ .name = "Content-Length", .value = "not-a-number" },
        };
        var backend = try factory.create(allocator, io, .{
            .response = .{ .headers = &malformed_headers },
        });
        defer backend.deinit();
        var request = core.http.Request.init(allocator, .GET, backend.url);
        defer request.deinit();
        try std.testing.expectError(
            error.HttpHeadersInvalid,
            backend.transport.open(&request, .{}),
        );
        try backend.finish();
        try backend.assertQuiescent();
    }
}

fn runResponseLimitContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    var backend = try factory.create(allocator, io, .{
        .response = .{ .body = "0123456789abcdef" },
        .max_response_body = 8,
    });
    defer backend.deinit();
    var request = core.http.Request.init(allocator, .GET, backend.url);
    defer request.deinit();
    try std.testing.expectError(
        error.StreamTooLong,
        backend.transport.send(&request),
    );
    try backend.finish();
    try backend.assertQuiescent();
}

const gzip_conformance_body =
    "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff" ++
    "\x4b\xce\xcf\x4b\xcb\x2f\xca\x4d\xcc\x4b" ++
    "\x4e\x05\x00\xe7\x15\x15\xe8\x0b\x00\x00\x00";

fn runDecompressionContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
    chunked: bool,
) !void {
    const headers = [_]scripted.Header{
        .{ .name = "Content-Encoding", .value = "gzip" },
    };
    var backend = try factory.create(allocator, io, .{
        .response = .{
            .headers = &headers,
            .body = gzip_conformance_body,
            .chunked = chunked,
        },
    });
    defer backend.deinit();
    var request = core.http.Request.init(allocator, .GET, backend.url);
    defer request.deinit();
    var response = try backend.transport.send(&request);
    defer response.deinit();
    try backend.finish();
    try std.testing.expectEqualStrings("conformance", response.body);
}

fn runLogicalLargeUploadContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    for ([_]bool{ false, true }) |chunked| {
        const storage = try allocator.alloc(u8, streaming_allocation_budget);
        defer allocator.free(storage);
        var budget = std.heap.FixedBufferAllocator.init(storage);
        var backend = try factory.create(budget.allocator(), io, .{ .fixture_allocator = allocator });
        defer backend.deinit();
        var request = core.http.Request.init(budget.allocator(), .PUT, backend.url);
        defer request.deinit();
        var source = fakes.RepeatingReader.init('x', logical_stream_length);
        {
            var operation = try backend.transport.open(&request, .{
                .body = if (chunked)
                    core.http.StreamingRequestBody.chunked(&source.interface)
                else
                    core.http.StreamingRequestBody.knownLength(&source.interface, logical_stream_length),
            });
            defer operation.deinit();
            try operation.finish();
        }
        try backend.finish();
        try backend.assertQuiescent();
        const observation = backend.observe();
        try std.testing.expectEqual(@as(usize, logical_stream_length), observation.body_length);
        try std.testing.expectEqual(@as(usize, 0), source.remaining);
        try std.testing.expectEqual(@as(usize, 4096), observation.body.len);
        for (observation.body) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
        try std.testing.expectEqual(repeatedBodyHash('x', logical_stream_length), observation.body_hash);
    }
}

pub const streaming_allocation_budget = 2 * 1024 * 1024;
pub const logical_stream_length = 32 * 1024 * 1024 + 257;

fn repeatedBodyHash(byte: u8, length: usize) u64 {
    var bytes: [4096]u8 = undefined;
    @memset(&bytes, byte);
    var hash = std.hash.Wyhash.init(0);
    var remaining = length;
    while (remaining > 0) {
        const count = @min(remaining, bytes.len);
        hash.update(bytes[0..count]);
        remaining -= count;
    }
    return hash.final();
}

fn runWideLengthContract(allocator: std.mem.Allocator, io: std.Io, factory: BackendFactory) !void {
    // Exercise the u64 framing boundary without pretending to transfer 4 GiB.
    var backend = try factory.create(allocator, io, .{ .allow_peer_failure = true });
    defer backend.deinit();
    var request = core.http.Request.init(allocator, .PUT, backend.url);
    defer request.deinit();
    var source = fakes.RepeatingReader.init('w', 65537);
    try std.testing.expectError(error.RequestBodyTooShort, backend.transport.open(&request, .{
        .body = core.http.StreamingRequestBody.knownLength(&source.interface, (@as(u64, 1) << 32) + 65537),
    }));
    try std.testing.expect(request.transport_started);
    try std.testing.expectEqual(@as(usize, 0), source.remaining);
    try backend.finish();
    try backend.assertQuiescent();
    try std.testing.expectEqualStrings("4295032833", backend.observe().content_length orelse "");
}

fn runLogicalLargeDownloadContracts(allocator: std.mem.Allocator, io: std.Io, factory: BackendFactory) !void {
    for ([_]bool{ false, true }) |chunked| {
        for ([_]enum { consume, drain, abort }{ .consume, .drain, .abort }) |mode| {
            const storage = try allocator.alloc(u8, streaming_allocation_budget);
            defer allocator.free(storage);
            var budget = std.heap.FixedBufferAllocator.init(storage);
            var backend = try factory.create(budget.allocator(), io, .{
                .fixture_allocator = allocator,
                .response = .{
                    .generated_body = .{ .byte = 'd', .length = logical_stream_length },
                    .chunked = chunked,
                },
                .allow_peer_failure = mode == .abort,
                // A buffered-response ceiling must not become a streaming limit.
                .max_response_body = 1024,
            });
            defer backend.deinit();
            var request = core.http.Request.init(budget.allocator(), .GET, backend.url);
            defer request.deinit();
            {
                var operation = try backend.transport.open(&request, .{});
                defer operation.deinit();
                const reader = try operation.reader();
                var bytes: [8191]u8 = undefined;
                var total: usize = 0;
                while (true) {
                    const count = try reader.readSliceShort(&bytes);
                    if (count == 0) break;
                    for (bytes[0..count]) |byte| try std.testing.expectEqual(@as(u8, 'd'), byte);
                    total += count;
                    if (mode != .consume) break;
                }
                if (mode == .consume)
                    try std.testing.expectEqual(@as(usize, logical_stream_length), total);
                if (mode == .abort) {
                    operation.abort();
                    try std.testing.expectEqual(core.http.OperationState.aborted, operation.state);
                } else {
                    try operation.finish();
                    try std.testing.expectEqual(core.http.OperationState.finished, operation.state);
                }
                try std.testing.expectError(error.HttpOperationNotActive, operation.reader());
                try std.testing.expectError(error.HttpOperationNotActive, operation.finish());
                operation.abort();
                operation.cancel();
            }
            try backend.finish();
            try backend.assertQuiescent();
            if (factory.capabilities.lifecycle_observable) {
                const observation = backend.observe();
                try std.testing.expectEqual(@as(usize, if (mode == .abort) 0 else 1), observation.finish_count);
                try std.testing.expectEqual(@as(usize, if (mode == .abort) 1 else 0), observation.abort_count);
                try std.testing.expectEqual(@as(usize, 0), observation.cancel_count);
                try std.testing.expectEqual(@as(usize, 1), observation.deinit_count);
            }
        }
    }
}

fn runPipelineDispatchContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    var backend = try factory.create(allocator, io, .{
        .response = .{ .body = "pipeline" },
    });
    defer backend.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(io);
    var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-conformance/0.3.0");
    var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(backend.transport, crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(allocator, .GET, backend.url);
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
    try backend.finish();
    try std.testing.expectEqualStrings("pipeline", response.body);
    try std.testing.expectEqualStrings(
        "azsdk-zig-conformance/0.3.0",
        request.getHeader("User-Agent").?,
    );
}

fn runRedirectContracts(allocator: std.mem.Allocator) !void {
    var sequence = core.http.SequenceMockTransport.init(allocator, &.{
        .{
            .status = 307,
            .body = "",
            .headers = &.{.{ .name = "Location", .value = "https://storage.example/blob#fragment" }},
        },
        .{ .status = 200, .body = "ok" },
    });
    var request = core.http.Request.init(
        allocator,
        .POST,
        "https://registry.example/upload",
    );
    defer request.deinit();
    try request.setHeader("Authorization", "******");
    try request.setHeader("Cookie", "secret");
    try request.setHeader("Proxy-Authorization", "secret");
    try request.setHeader("Host", "registry.example");
    var replay = core.http.ReplayableBytes.init("payload");
    var operation = try sequence.asTransport().open(
        &request,
        .{ .body = replay.body() },
    );
    defer operation.deinit();
    try std.testing.expectEqual(@as(usize, 2), sequence.call_count);
    try std.testing.expect(sequence.captured_authorization[0]);
    try std.testing.expect(!sequence.captured_authorization[1]);
    try std.testing.expect(sequence.captured_cookie[0]);
    try std.testing.expect(!sequence.captured_cookie[1]);
    try std.testing.expect(sequence.captured_proxy_authorization[0]);
    try std.testing.expect(!sequence.captured_proxy_authorization[1]);
    try std.testing.expect(sequence.captured_host[0]);
    try std.testing.expect(!sequence.captured_host[1]);
    try std.testing.expectEqualStrings("payload", sequence.capturedBody(0));
    try std.testing.expectEqualStrings("payload", sequence.capturedBody(1));
    try std.testing.expectEqualStrings(
        "https://storage.example/blob",
        sequence.capturedUrl(1),
    );
    try operation.finish();

    var one_shot_sequence = core.http.SequenceMockTransport.init(allocator, &.{
        .{
            .status = 308,
            .body = "",
            .headers = &.{.{ .name = "Location", .value = "/continued" }},
        },
        .{ .status = 200, .body = "unexpected" },
    });
    var one_shot_request = core.http.Request.init(
        allocator,
        .PUT,
        "https://registry.example/upload",
    );
    defer one_shot_request.deinit();
    var source = std.Io.Reader.fixed("one-shot");
    var one_shot = try one_shot_sequence.asTransport().open(
        &one_shot_request,
        .{
            .body = core.http.StreamingRequestBody.knownLength(
                &source,
                "one-shot".len,
            ),
        },
    );
    defer one_shot.deinit();
    try std.testing.expectEqual(@as(u16, 308), one_shot.status_code);
    try std.testing.expectEqual(@as(usize, 1), one_shot_sequence.call_count);
    one_shot.abort();
}

fn runRetryContracts(allocator: std.mem.Allocator) !void {
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var retry = core.http.RetryPolicy.init();
    retry.initial_delay_ms = 0;
    var policies = [_]*core.http.HttpPolicy{retry.asPolicy()};

    var sequence = core.http.SequenceMockTransport.init(allocator, &.{
        .{ .status = 503, .body = "retry" },
        .{ .status = 200, .body = "ok" },
    });
    var pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(sequence.asTransport(), crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(
        allocator,
        .POST,
        "https://example.com/upload",
    );
    defer request.deinit();
    var replay = core.http.ReplayableBytes.init("replayable");
    var operation = try pipeline.open(&request, .{ .body = replay.body() });
    defer operation.deinit();
    try std.testing.expectEqual(@as(u16, 200), operation.status_code);
    try std.testing.expectEqual(@as(usize, 2), sequence.call_count);
    try std.testing.expectEqualStrings("replayable", sequence.capturedBody(0));
    try std.testing.expectEqualStrings("replayable", sequence.capturedBody(1));
    try operation.finish();

    var one_shot_sequence = core.http.SequenceMockTransport.init(allocator, &.{
        .{ .status = 503, .body = "retry" },
        .{ .status = 200, .body = "unexpected" },
    });
    var one_shot_pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(one_shot_sequence.asTransport(), crypto.asProvider()),
        &policies,
    );
    var one_shot_request = core.http.Request.init(
        allocator,
        .POST,
        "https://example.com/upload",
    );
    defer one_shot_request.deinit();
    var source = std.Io.Reader.fixed("one-shot");
    var one_shot = try one_shot_pipeline.open(&one_shot_request, .{
        .body = core.http.StreamingRequestBody.chunked(&source),
    });
    defer one_shot.deinit();
    try std.testing.expectEqual(@as(u16, 503), one_shot.status_code);
    try std.testing.expectEqual(@as(usize, 1), one_shot_sequence.call_count);
    one_shot.abort();
}

const CountingPolicy = struct {
    calls: usize = 0,
    policy: core.http.HttpPolicy = .{ .processFn = &process, .prepareFn = &prepare },

    fn prepare(policy: *core.http.HttpPolicy, request: *core.http.Request, _: core.http.HttpRuntime) !void {
        const self: *CountingPolicy = @fieldParentPtr("policy", policy);
        self.calls += 1;
        const marker = switch (self.calls) {
            1 => "1",
            2 => "2",
            else => "unexpected",
        };
        try request.setHeader("X-Conformance-Policy", marker);
    }

    fn process(
        policy: *core.http.HttpPolicy,
        request: *core.http.Request,
        next: []*core.http.HttpPolicy,
        runtime: core.http.HttpRuntime,
    ) !core.http.Response {
        try prepare(policy, request, runtime);
        return if (next.len == 0) runtime.transport.send(request) else next[0].process(request, next[1..], runtime);
    }
};

const CountingReplay = struct {
    reader: std.Io.Reader = std.Io.Reader.fixed("attempt-body"),
    rewinds: usize = 0,
    fail_rewind: bool = false,

    fn body(self: *CountingReplay) core.http.StreamingRequestBody {
        return core.http.StreamingRequestBody.knownLength(&self.reader, "attempt-body".len)
            .withRewind(self, &rewind);
    }

    fn rewind(context: *anyopaque) !*std.Io.Reader {
        const self: *CountingReplay = @ptrCast(@alignCast(context));
        self.rewinds += 1;
        if (self.fail_rewind) return error.ConformanceRewindFailed;
        self.reader = std.Io.Reader.fixed("attempt-body");
        return &self.reader;
    }
};

fn runBackendAttemptContracts(allocator: std.mem.Allocator, io: std.Io, factory: BackendFactory) !void {
    const RetryCase = enum { raw, buffered, replayable, one_shot, disabled, exhausted, rewind_failure };
    for (std.meta.tags(RetryCase)) |case| {
        if (!factory.capabilities.streaming and case != .raw and case != .buffered) continue;
        const responses = [_]scripted.Response{
            .{ .status_code = 503, .reason = "Retry", .body = "retry" },
            .{
                .status_code = if (case == .exhausted) 503 else 200,
                .body = "last",
            },
            .{ .status_code = 200, .body = "must not be reached" },
        };
        var backend = try factory.create(allocator, io, .{ .responses = &responses });
        defer backend.deinit();
        var crypto = core.crypto.StdCryptoProvider.init(io);
        var outer = CountingPolicy{};
        var inner = CountingPolicy{};
        var retry = core.http.RetryPolicy.init();
        retry.initial_delay_ms = 0;
        retry.max_retries = 1;
        var policies = [_]*core.http.HttpPolicy{ &outer.policy, retry.asPolicy(), &inner.policy };
        var pipeline = core.http.HttpPipeline.init(
            core.http.HttpRuntime.init(backend.transport, crypto.asProvider()),
            &policies,
        );
        var request = core.http.Request.init(allocator, .POST, backend.url);
        defer request.deinit();
        request.retryable = case != .disabled;
        var replay = CountingReplay{ .fail_rewind = case == .rewind_failure };
        const expected_attempts: usize = switch (case) {
            .buffered, .replayable, .exhausted => 2,
            else => 1,
        };
        const expected_status: u16 = switch (case) {
            .buffered, .replayable => 200,
            else => 503,
        };
        if (case == .raw or case == .buffered) {
            request.body = "attempt-body";
            var response = try if (case == .raw) backend.transport.send(&request) else pipeline.send(&request);
            defer response.deinit();
            try std.testing.expectEqual(expected_status, response.status_code);
        } else {
            var options = core.http.OpenOptions{ .body = replay.body() };
            if (case == .one_shot) options.body = core.http.StreamingRequestBody.knownLength(&replay.reader, "attempt-body".len);
            if (case == .rewind_failure) {
                try std.testing.expectError(error.ConformanceRewindFailed, pipeline.open(&request, options));
            } else {
                var operation = try pipeline.open(&request, options);
                defer operation.deinit();
                try std.testing.expectEqual(expected_status, operation.status_code);
                try operation.finish();
            }
            try std.testing.expectEqual(
                @as(usize, if (case == .replayable or case == .exhausted or case == .rewind_failure) 1 else 0),
                replay.rewinds,
            );
        }
        try backend.finish();
        try backend.assertQuiescent();
        try std.testing.expect(request.transport_started);
        try std.testing.expectEqual(expected_attempts, backend.observe().request_count);
        try std.testing.expectEqual(@as(usize, if (case == .raw) 0 else 1), outer.calls);
        try std.testing.expectEqual(if (case == .raw) @as(usize, 0) else expected_attempts, inner.calls);
        if (factory.capabilities.lifecycle_observable and case != .raw and case != .buffered) {
            const observation = backend.observe();
            try std.testing.expectEqual(@as(usize, if (case == .rewind_failure) 0 else 1), observation.finish_count);
            try std.testing.expectEqual(
                @as(usize, if (case == .replayable or case == .exhausted or case == .rewind_failure) 1 else 0),
                observation.abort_count,
            );
            try std.testing.expectEqual(@as(usize, 0), observation.cancel_count);
            try std.testing.expectEqual(expected_attempts, observation.deinit_count);
        }
        for (0..expected_attempts) |index| {
            const attempt = try backend.attempt(index);
            try std.testing.expectEqualStrings("attempt-body", attempt.body);
            try std.testing.expectEqual(@as(usize, "attempt-body".len), attempt.body_length);
            try std.testing.expect(std.mem.startsWith(u8, attempt.request_line, "POST "));
            if (case != .raw)
                try std.testing.expectEqualStrings(if (index == 0) "1" else "2", attempt.policy_marker orelse "");
        }
    }
    if (factory.capabilities.streaming)
        try runBackendRedirectContracts(allocator, io, factory);
}

fn runBackendRedirectContracts(allocator: std.mem.Allocator, io: std.Io, factory: BackendFactory) !void {
    const RedirectCase = enum { same_origin, cross_origin, forbidden, one_shot, rewind_failure, see_other, insecure_target };
    for (std.meta.tags(RedirectCase)) |case| {
        if (!factory.capabilities.https_redirects and
            case != .forbidden and case != .one_shot and case != .insecure_target) continue;
        const destination_responses = [_]scripted.Response{.{ .body = "destination" }};
        var destination = try factory.create(allocator, io, .{ .responses = &destination_responses });
        defer destination.deinit();
        const cross_origin = case != .same_origin;
        const location = if (case == .insecure_target)
            "http://127.0.0.1:1/not-contacted"
        else if (cross_origin)
            destination.url
        else
            "/continued#fragment";
        const headers = [_]scripted.Header{.{ .name = "Location", .value = location }};
        const responses = [_]scripted.Response{
            .{ .status_code = if (case == .see_other) 303 else 307, .headers = &headers },
            .{ .body = "same-origin" },
        };
        var backend = try factory.create(allocator, io, .{ .responses = &responses });
        defer backend.deinit();
        if (factory.capabilities.https_redirects) {
            try std.testing.expect(std.mem.startsWith(u8, backend.url, "https://"));
            try std.testing.expect(std.mem.startsWith(u8, destination.url, "https://"));
        }
        var crypto = core.crypto.StdCryptoProvider.init(io);
        var policy = CountingPolicy{};
        var policies = [_]*core.http.HttpPolicy{&policy.policy};
        var pipeline = core.http.HttpPipeline.init(
            core.http.HttpRuntime.init(backend.transport, crypto.asProvider()),
            &policies,
        );
        var request = core.http.Request.init(allocator, .POST, backend.url);
        defer request.deinit();
        if (case == .forbidden) request.redirect_policy = .not_allowed;
        try request.setHeader("Authorization", "conformance-token");
        try request.setHeader("Cookie", "conformance-cookie");
        try request.setHeader("Proxy-Authorization", "conformance-proxy");
        try request.setHeader("Host", "conformance-origin");
        var replay = CountingReplay{ .fail_rewind = case == .rewind_failure };
        var body = replay.body();
        if (case == .one_shot or case == .see_other)
            body = core.http.StreamingRequestBody.knownLength(&replay.reader, "attempt-body".len);
        if (case == .rewind_failure) {
            try std.testing.expectError(error.ConformanceRewindFailed, pipeline.open(&request, .{ .body = body }));
        } else if (case == .insecure_target) {
            try std.testing.expectError(error.HttpsRequired, pipeline.open(&request, .{ .body = body }));
        } else {
            var operation = try pipeline.open(&request, .{ .body = body });
            defer operation.deinit();
            try std.testing.expectEqual(
                @as(u16, if (case == .forbidden or case == .one_shot) 307 else 200),
                operation.status_code,
            );
            try operation.finish();
        }
        try backend.finish();
        try destination.finish();
        try backend.assertQuiescent();
        try destination.assertQuiescent();
        try std.testing.expect(request.transport_started);
        const followed = case == .same_origin or case == .cross_origin or case == .see_other;
        try std.testing.expectEqual(@as(usize, if (case == .same_origin) 2 else 1), backend.observe().request_count);
        try std.testing.expectEqual(@as(usize, if (followed and cross_origin) 1 else 0), destination.observe().request_count);
        try std.testing.expectEqual(@as(usize, 1), policy.calls);
        try std.testing.expectEqual(
            @as(usize, if (case == .same_origin or case == .cross_origin or case == .rewind_failure) 1 else 0),
            replay.rewinds,
        );
        const first = try backend.attempt(0);
        try std.testing.expectEqualStrings("attempt-body", first.body);
        try std.testing.expectEqualStrings("conformance-token", first.authorization orelse "");
        try std.testing.expectEqualStrings("conformance-cookie", first.cookie orelse "");
        try std.testing.expectEqualStrings("conformance-proxy", first.proxy_authorization orelse "");
        try std.testing.expectEqualStrings("conformance-origin", first.host orelse "");
        if (followed) {
            const second = if (cross_origin) try destination.attempt(0) else try backend.attempt(1);
            try std.testing.expectEqualStrings(if (case == .see_other) "" else "attempt-body", second.body);
            try std.testing.expect(std.mem.startsWith(u8, second.request_line, if (case == .see_other) "GET " else "POST "));
            if (case == .same_origin)
                try std.testing.expectEqualStrings("POST /continued HTTP/1.1", second.request_line);
            try std.testing.expectEqualStrings("1", second.policy_marker orelse "");
            if (cross_origin) {
                try std.testing.expectEqual(@as(?[]const u8, null), second.authorization);
                try std.testing.expectEqual(@as(?[]const u8, null), second.cookie);
                try std.testing.expectEqual(@as(?[]const u8, null), second.proxy_authorization);
                try std.testing.expect(!std.mem.eql(u8, "conformance-origin", second.host orelse ""));
            } else {
                try std.testing.expectEqualStrings("conformance-token", second.authorization orelse "");
                try std.testing.expectEqualStrings("conformance-cookie", second.cookie orelse "");
                try std.testing.expectEqualStrings("conformance-proxy", second.proxy_authorization orelse "");
                try std.testing.expectEqualStrings("conformance-origin", second.host orelse "");
            }
        }
        try std.testing.expectEqualStrings("conformance-token", request.getHeader("Authorization").?);
        try std.testing.expectEqualStrings(backend.url, request.url);
        if (factory.capabilities.lifecycle_observable) {
            const observation = backend.observe();
            const failed = case == .rewind_failure or case == .insecure_target;
            try std.testing.expectEqual(@as(usize, if (failed) 0 else 1), observation.finish_count);
            try std.testing.expectEqual(@as(usize, if (followed or failed) 1 else 0), observation.abort_count);
            try std.testing.expectEqual(@as(usize, 0), observation.cancel_count);
            try std.testing.expectEqual(@as(usize, if (followed) 2 else 1), observation.deinit_count);
        }
    }
}

fn runPipelineDecompressionContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
) !void {
    const headers = [_]scripted.Header{
        .{ .name = "Content-Encoding", .value = "gzip" },
    };
    var backend = try factory.create(allocator, io, .{
        .response = .{ .headers = &headers, .body = gzip_conformance_body },
    });
    defer backend.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(io);
    var decompression = core.http.DecompressionPolicy.init();
    var policies = [_]*core.http.HttpPolicy{decompression.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(backend.transport, crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(allocator, .GET, backend.url);
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
    try backend.finish();
    try std.testing.expectEqualStrings("conformance", response.body);
    try std.testing.expectEqualStrings(
        "gzip, deflate",
        request.getHeader("Accept-Encoding").?,
    );
}

fn mockStreamingAllocationFixture(allocator: std.mem.Allocator) !void {
    var mock = core.http.MockTransport.init(allocator, 200, "response");
    defer mock.deinit();
    mock.response_headers_list = &.{.{ .name = "x-test", .value = "value" }};
    var request = core.http.Request.init(allocator, .POST, "https://example.com");
    defer request.deinit();
    try request.setHeader("content-type", "application/octet-stream");
    var source = std.Io.Reader.fixed("request");
    var operation = try mock.asTransport().open(&request, .{
        .body = core.http.StreamingRequestBody.knownLength(&source, 7),
    });
    defer operation.deinit();
    try operation.finish();
}

fn redirectAllocationFixture(allocator: std.mem.Allocator) !void {
    var sequence = core.http.SequenceMockTransport.init(allocator, &.{
        .{
            .status = 307,
            .body = "",
            .headers = &.{.{ .name = "Location", .value = "https://storage.example/blob" }},
        },
        .{ .status = 200, .body = "ok" },
    });
    var request = core.http.Request.init(
        allocator,
        .PUT,
        "https://registry.example/upload",
    );
    defer request.deinit();
    request.body = "body";
    try request.setHeader("Authorization", "******");
    var response = sequence.asTransport().send(&request) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    defer response.deinit();
}

fn retryAllocationFixture(allocator: std.mem.Allocator) !void {
    var sequence = core.http.SequenceMockTransport.init(allocator, &.{
        .{ .status = 503, .body = "retry" },
        .{ .status = 200, .body = "ok" },
    });
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var retry = core.http.RetryPolicy.init();
    retry.initial_delay_ms = 0;
    var policies = [_]*core.http.HttpPolicy{retry.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(sequence.asTransport(), crypto.asProvider()),
        &policies,
    );
    var request = core.http.Request.init(allocator, .GET, "https://example.com");
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
}

/// Reusable factory scenario for adapter allocationFixtureFn implementations.
/// Native error normalization, persistent pool teardown and externally allocated
/// resource accounting remain the adapter hook's responsibility.
pub fn runBackendAllocationScenario(
    allocator: std.mem.Allocator,
    fixture_allocator: std.mem.Allocator,
    io: std.Io,
    factory: BackendFactory,
    scenario: AllocationScenario,
) !void {
    const headers = [_]scripted.Header{.{ .name = "Location", .value = "/allocated" }};
    const responses = [_]scripted.Response{
        .{
            .status_code = switch (scenario) {
                .redirect => 307,
                .retry => 503,
                else => 200,
            },
            .headers = if (scenario == .redirect) &headers else &.{},
            .body = "allocation-response",
        },
        .{ .body = "final-response" },
    };
    var backend = try factory.create(allocator, io, .{
        .response = responses[0],
        .responses = if (scenario == .redirect or scenario == .retry) &responses else &.{},
        .fixture_allocator = fixture_allocator,
        .allow_peer_failure = true,
    });
    defer backend.deinit();
    const result = exerciseAllocationBackend(allocator, io, &backend, scenario, factory.capabilities.https_redirects);
    try backend.assertQuiescent();
    try result;
    try backend.finish();
}

fn exerciseAllocationBackend(
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: *BackendInstance,
    scenario: AllocationScenario,
    https_redirects: bool,
) !void {
    var request = core.http.Request.init(allocator, .POST, backend.url);
    defer request.deinit();
    try request.setHeader("X-Allocation-Contract", "owned-header");
    var crypto = core.crypto.StdCryptoProvider.init(io);
    var retry = core.http.RetryPolicy.init();
    retry.max_retries = 1;
    retry.initial_delay_ms = 0;
    var policies = [_]*core.http.HttpPolicy{retry.asPolicy()};
    var pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(backend.transport, crypto.asProvider()),
        &policies,
    );
    if (scenario == .buffered) {
        request.body = "allocation-upload";
        var response = try backend.transport.send(&request);
        defer response.deinit();
        try std.testing.expectEqualStrings("allocation-response", response.body);
        return;
    }
    var replay = core.http.ReplayableBytes.init("allocation-upload");
    if (scenario == .redirect and !https_redirects) {
        var unexpected = backend.transport.open(&request, .{ .body = replay.body() }) catch |err| {
            if (err == error.HttpsRequired) return;
            return err;
        };
        unexpected.deinit();
        return error.ExpectedHttpsRequired;
    }
    var operation = try if (scenario == .retry)
        pipeline.open(&request, .{ .body = replay.body() })
    else
        backend.transport.open(&request, .{ .body = replay.body() });
    defer operation.deinit();
    if (scenario == .abort) {
        operation.abort();
    } else {
        var prefix: [3]u8 = undefined;
        try (try operation.reader()).readSliceAll(&prefix);
        try operation.finish();
    }
}

fn standardAllocationFixture(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    fixture_allocator: std.mem.Allocator,
    io: std.Io,
    scenario: AllocationScenario,
) !void {
    try runBackendAllocationScenario(allocator, fixture_allocator, io, standardBackendFactory(), scenario);
}

const StdBackendState = struct {
    allocator: std.mem.Allocator,
    transport: core.http.StdHttpTransport,
    server: scripted.ScriptedHttpServer = undefined,
    server_started: bool = false,
    server_joined: bool = false,
    url: []u8,

    fn finish(context: *anyopaque) !void {
        const self: *StdBackendState = @ptrCast(@alignCast(context));
        if (self.server_started and !self.server_joined) {
            if (self.server.responses.len > 0) {
                try self.server.stopAndJoin();
                if (self.server.failure) |err| {
                    if (!self.server.allow_peer_failure) return err;
                }
            } else {
                try self.server.join();
            }
            self.server_joined = true;
        }
    }

    fn observe(context: *anyopaque) Observation {
        const self: *StdBackendState = @ptrCast(@alignCast(context));
        if (!self.server_started) return .{};
        if (self.server.responses.len > 0) {
            const count = self.server.requests.items.len;
            var result = if (count > 0) attempt(context, count - 1).? else Observation{};
            result.request_count = count;
            return result;
        }
        return .{
            .request_count = if (self.server.request_line.len > 0) 1 else 0,
            .body = self.server.body(),
            .body_length = self.server.body_length,
            .user_agent_count = self.server.headerCount("user-agent"),
            .accept_encoding_count = self.server.headerCount("accept-encoding"),
            .host_count = self.server.headerCount("host"),
            .connection_count = self.server.headerCount("connection"),
            .accept_count = self.server.headerCount("accept"),
            .request_line = self.server.request_line,
            .authorization = self.server.headerValue("authorization"),
            .cookie = self.server.headerValue("cookie"),
            .proxy_authorization = self.server.headerValue("proxy-authorization"),
            .policy_marker = self.server.headerValue("x-conformance-policy"),
            .content_length = self.server.headerValue("content-length"),
            .host = self.server.headerValue("host"),
            .body_hash = self.server.body_hasher.final(),
        };
    }

    fn attempt(context: *anyopaque, index: usize) ?Observation {
        const self: *StdBackendState = @ptrCast(@alignCast(context));
        if (!self.server_started) return null;
        if (self.server.responses.len == 0)
            return if (index == 0 and self.server.request_line.len > 0) observe(context) else null;
        if (index >= self.server.requests.items.len) return null;
        const request = &self.server.requests.items[index];
        return .{
            .request_count = 1,
            .request_line = request.request_line,
            .body = request.body_prefix[0..request.body_prefix_len],
            .body_length = request.body_length,
            .body_hash = request.body_hash,
            .authorization = request.headerValue("authorization"),
            .cookie = request.headerValue("cookie"),
            .proxy_authorization = request.headerValue("proxy-authorization"),
            .policy_marker = request.headerValue("x-conformance-policy"),
            .content_length = request.headerValue("content-length"),
            .host = request.headerValue("host"),
        };
    }

    fn assertQuiescent(context: *anyopaque) !void {
        const self: *StdBackendState = @ptrCast(@alignCast(context));
        if (self.transport.shared_client) |shared| {
            try std.testing.expectEqual(@as(usize, 1), shared.references.load(.acquire));
            try std.testing.expect(shared.client.connection_pool.used.first == null);
            // The deterministic fixture always sends Connection: close.
            try std.testing.expect(shared.client.connection_pool.free.first == null);
            try std.testing.expectEqual(@as(usize, 0), shared.client.connection_pool.free_len);
        }
    }

    fn destroy(context: *anyopaque) void {
        const self: *StdBackendState = @ptrCast(@alignCast(context));
        if (self.server_started) {
            self.server.deinit();
        }
        self.transport.deinit();
        self.allocator.free(self.url);
        self.allocator.destroy(self);
    }
};

fn createStdBackend(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    options: BackendOptions,
) !BackendInstance {
    const state = try allocator.create(StdBackendState);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .transport = core.http.StdHttpTransport.init(allocator, io),
        .url = undefined,
    };
    errdefer state.transport.deinit();
    if (options.max_response_body) |limit| {
        state.transport.max_response_body = .limited(limit);
    }
    if (options.expect_request) {
        state.server = try scripted.ScriptedHttpServer.init(
            options.fixture_allocator orelse allocator,
            io,
            options.response,
        );
        state.server.allow_peer_failure = options.allow_peer_failure;
        state.server.responses = options.responses;
        errdefer state.server.deinit();
        try state.server.start();
        state.server_started = true;
        state.url = try state.server.allocUrl(allocator, "/conformance");
    } else {
        state.url = try allocator.dupe(u8, "http://127.0.0.1:1/conformance");
    }
    return .{
        .transport = state.transport.asTransport(),
        .url = state.url,
        .context = state,
        .finishFn = &StdBackendState.finish,
        .observeFn = &StdBackendState.observe,
        .deinitFn = &StdBackendState.destroy,
        .attemptFn = &StdBackendState.attempt,
        .assertQuiescentFn = &StdBackendState.assertQuiescent,
    };
}

pub fn standardBackendFactory() BackendFactory {
    return .{
        .name = "std.http.Client",
        .capabilities = .{
            .response_framing_validation = true,
            .response_body_limit = true,
            .decompression = true,
            .cancellation = .cooperative_upload,
            .automatic_request_headers = true,
            .bounded_memory_logical_large_upload = true,
            .bounded_memory_logical_large_download = true,
            .scripted_attempts = true,
            .allocation_failure_cleanup = true,
        },
        .createFn = &createStdBackend,
        .allocationFixtureFn = &standardAllocationFixture,
    };
}

const MockBackendState = struct {
    allocator: std.mem.Allocator,
    transport: core.http.MockTransport,
    response_headers: []core.http.MockTransport.HeaderPair,
    url: []u8,

    fn finish(_: *anyopaque) !void {}

    fn observe(context: *anyopaque) Observation {
        const self: *MockBackendState = @ptrCast(@alignCast(context));
        return .{
            .request_count = self.transport.call_count,
            .body = self.transport.last_body orelse "",
            .body_length = if (self.transport.last_body) |body| body.len else 0,
            .user_agent_count = if (self.transport.last_headers.get("User-Agent") != null) 1 else 0,
            .accept_encoding_count = if (self.transport.last_headers.get("Accept-Encoding") != null) 1 else 0,
            .accept_count = if (self.transport.last_headers.get("Accept") != null) 1 else 0,
            .finish_count = self.transport.stream_finish_count,
            .abort_count = self.transport.stream_abort_count,
            .cancel_count = self.transport.stream_cancel_count,
            .deinit_count = self.transport.stream_deinit_count,
        };
    }

    fn destroy(context: *anyopaque) void {
        const self: *MockBackendState = @ptrCast(@alignCast(context));
        self.transport.deinit();
        self.allocator.free(self.response_headers);
        self.allocator.free(self.url);
        self.allocator.destroy(self);
    }
};

fn createMockBackend(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: std.Io,
    options: BackendOptions,
) !BackendInstance {
    const state = try allocator.create(MockBackendState);
    errdefer allocator.destroy(state);
    const pairs = try allocator.alloc(
        core.http.MockTransport.HeaderPair,
        options.response.headers.len,
    );
    errdefer allocator.free(pairs);
    for (options.response.headers, pairs) |header, *pair| {
        pair.* = .{ .name = header.name, .value = header.value };
    }
    const url = try allocator.dupe(u8, "https://example.com/conformance");
    errdefer allocator.free(url);
    state.* = .{
        .allocator = allocator,
        .transport = core.http.MockTransport.init(
            allocator,
            options.response.status_code,
            options.response.body,
        ),
        .response_headers = pairs,
        .url = url,
    };
    state.transport.response_headers_list = pairs;
    return .{
        .transport = state.transport.asTransport(),
        .url = state.url,
        .context = state,
        .finishFn = &MockBackendState.finish,
        .observeFn = &MockBackendState.observe,
        .deinitFn = &MockBackendState.destroy,
    };
}

pub fn mockBackendFactory() BackendFactory {
    return .{
        .name = "MockTransport",
        .capabilities = .{
            .cancellation = .cooperative_upload,
            .lifecycle_observable = true,
        },
        .createFn = &createMockBackend,
    };
}

test "standard HTTP transport conforms" {
    try runRawTransportContracts(
        std.testing.allocator,
        std.testing.io,
        standardBackendFactory(),
    );
}

test "mock HTTP transport conforms" {
    try runRawTransportContracts(
        std.testing.allocator,
        std.testing.io,
        mockBackendFactory(),
    );
}

test "Core pipeline contracts conform through standard transport" {
    try runPipelineContracts(
        std.testing.allocator,
        std.testing.io,
        standardBackendFactory(),
    );
}

test "Core pipeline contracts conform through mock transport" {
    try runPipelineContracts(
        std.testing.allocator,
        std.testing.io,
        mockBackendFactory(),
    );
}

test "HTTP conformance allocation failures are leak-free" {
    try runAllocationFailureContracts();
}

test "standard backend allocation failures clean up actual operations and connections" {
    try runBackendAllocationFailureContracts(
        std.testing.allocator,
        std.testing.io,
        standardBackendFactory(),
    );
}

test "backend allocation runner rejects uninjected writer and normalized OOM errors" {
    const Fixture = struct {
        calls: usize = 0,
        outcome: anyerror,

        fn run(
            context: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: std.mem.Allocator,
            _: std.Io,
            _: AllocationScenario,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            const first = try allocator.create(u8);
            defer allocator.destroy(first);
            // The baseline allocates twice. On fail_index=1, an unrelated
            // error occurs before the second allocation can actually fail.
            if (self.calls == 3) return self.outcome;
            const second = try allocator.create(u8);
            defer allocator.destroy(second);
        }
    };
    inline for (.{ error.WriteFailed, error.OutOfMemory }) |outcome| {
        var fixture = Fixture{ .outcome = outcome };
        var factory = standardBackendFactory();
        factory.context = &fixture;
        factory.allocationFixtureFn = &Fixture.run;
        try std.testing.expectError(
            if (outcome == error.OutOfMemory) error.UninjectedOutOfMemory else error.WriteFailed,
            runBackendAllocationFailureContracts(std.testing.allocator, std.testing.io, factory),
        );
        try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    }
}

test "backend allocation runner accepts writer errors only after induced allocation failure" {
    const Fixture = struct {
        fn run(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: std.mem.Allocator,
            _: std.Io,
            _: AllocationScenario,
        ) !void {
            const value = allocator.create(u8) catch return error.WriteFailed;
            allocator.destroy(value);
        }
    };
    var factory = standardBackendFactory();
    factory.allocationFixtureFn = &Fixture.run;
    try runBackendAllocationFailureContracts(std.testing.allocator, std.testing.io, factory);
}

test "claimed adapter capabilities require integration evidence hooks" {
    var factory = mockBackendFactory();
    factory.capabilities.allocation_failure_cleanup = true;
    try std.testing.expectError(error.AllocationFixtureRequired, runBackendAllocationFailureContracts(
        std.testing.allocator,
        std.testing.io,
        factory,
    ));
    factory.capabilities.interruption.token.insert(.response_body);
    try std.testing.expectError(error.InterruptionFixtureRequired, runInterruptionContracts(
        std.testing.allocator,
        std.testing.io,
        factory,
    ));
    try std.testing.expect(standardBackendFactory().capabilities.interruption.token.count() == 0);
    try std.testing.expect(standardBackendFactory().capabilities.interruption.deadline.count() == 0);
    factory.capabilities.https_redirects = true;
    try std.testing.expectError(error.ScriptedAttemptsRequired, runPipelineContracts(
        std.testing.allocator,
        std.testing.io,
        factory,
    ));
}

test "interruption evidence rejects preflight, wrong outcomes, late completion and incomplete cleanup" {
    const valid = InterruptionEvidence{
        .phase_entered = true,
        .transport_started = true,
        .outcome = error.OperationCancelled,
        .elapsed_ms = 10,
        .cleanup_count = 1,
        .live_operations = 0,
        .leased_connections = 0,
    };
    try validateInterruptionEvidence(valid, .token);
    var evidence = valid;
    evidence.phase_entered = false;
    try std.testing.expectError(error.InterruptionNotObserved, validateInterruptionEvidence(evidence, .token));
    evidence = valid;
    evidence.transport_started = false;
    try std.testing.expectError(error.InterruptionNotObserved, validateInterruptionEvidence(evidence, .token));
    try std.testing.expectError(error.InterruptionOutcomeMismatch, validateInterruptionEvidence(valid, .deadline));
    evidence = valid;
    evidence.outcome = error.OperationTimedOut;
    try validateInterruptionEvidence(evidence, .deadline);
    evidence = valid;
    evidence.elapsed_ms = 1001;
    try std.testing.expectError(error.InterruptionBudgetExceeded, validateInterruptionEvidence(evidence, .token));
    inline for (.{ "cleanup_count", "live_operations", "leased_connections" }) |field| {
        evidence = valid;
        @field(evidence, field) = 2;
        try std.testing.expectError(error.InterruptionCleanupIncomplete, validateInterruptionEvidence(evidence, .token));
    }
    evidence = valid;
    evidence.cleanup_count = 0;
    try std.testing.expectError(error.InterruptionCleanupIncomplete, validateInterruptionEvidence(evidence, .token));
}

test "large stream factories receive a fixed budget, not the harness allocator" {
    const EagerBackend = struct {
        fn create(_: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, _: BackendOptions) !BackendInstance {
            const buffer = try allocator.alloc(u8, logical_stream_length);
            allocator.free(buffer);
            return error.ExpectedAllocationBudget;
        }
    };
    var factory = standardBackendFactory();
    factory.createFn = &EagerBackend.create;
    try std.testing.expectError(error.OutOfMemory, runLogicalLargeUploadContract(
        std.testing.allocator,
        std.testing.io,
        factory,
    ));
    try std.testing.expectError(error.OutOfMemory, runLogicalLargeDownloadContracts(
        std.testing.allocator,
        std.testing.io,
        factory,
    ));
}
