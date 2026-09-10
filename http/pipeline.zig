const std = @import("std");
const crypto_mod = @import("../crypto.zig");
const transport = @import("transport.zig");
const HttpRuntime = @import("runtime.zig").HttpRuntime;
const tracing = @import("../tracing/root.zig");
const trace_http = @import("../tracing/http.zig");

const Request = transport.Request;
const Response = transport.Response;
const HttpTransport = transport.HttpTransport;
const HttpOperation = transport.HttpOperation;
const OpenOptions = transport.OpenOptions;

var testing_crypto_provider = crypto_mod.StdCryptoProvider.init(std.testing.io);

fn testingRuntime(http_transport: HttpTransport) HttpRuntime {
    return .init(http_transport, testing_crypto_provider.asProvider());
}

fn nanoTimestamp() i128 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return std.Io.Timestamp.now(threaded.io(), .real).toNanoseconds();
}

fn monotonicNanoTimestamp() i128 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return std.Io.Timestamp.now(threaded.io(), .awake).toNanoseconds();
}

fn unixTimestampSeconds() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_s));
}

fn sleepMs(ms: u64) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const nanoseconds = @as(i96, ms) * std.time.ns_per_ms;
    threaded.io().sleep(.fromNanoseconds(nanoseconds), .awake) catch {};
}

/// A single stage in the HTTP pipeline.
///
/// Policies form a chain: each receives the request, may modify it,
/// then calls `next` to pass it down the pipeline.
pub const HttpPolicy = struct {
    processFn: *const fn (
        self: *HttpPolicy,
        request: *Request,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) anyerror!Response,
    prepareFn: ?*const fn (
        self: *HttpPolicy,
        request: *Request,
        runtime: HttpRuntime,
    ) anyerror!void = null,
    openFn: ?*const fn (
        self: *HttpPolicy,
        request: *Request,
        options: OpenOptions,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) anyerror!*HttpOperation = null,

    pub fn process(
        self: *HttpPolicy,
        request: *Request,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !Response {
        return self.processFn(self, request, next, runtime);
    }

    pub fn prepare(self: *HttpPolicy, request: *Request, runtime: HttpRuntime) !void {
        const prepareFn = self.prepareFn orelse return error.StreamingPolicyUnsupported;
        return prepareFn(self, request, runtime);
    }

    pub fn open(
        self: *HttpPolicy,
        request: *Request,
        options: OpenOptions,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !*HttpOperation {
        if (self.openFn) |openFn| return openFn(self, request, options, next, runtime);
        try self.prepare(request, runtime);
        return callNextOpen(request, options, next, runtime);
    }
};

/// Ordered policy chain with an explicit runtime copied by value.
pub const HttpPipeline = struct {
    policies: []*HttpPolicy,
    runtime: HttpRuntime,
    instrumentation: ?tracing.InstrumentationOptions = null,

    pub fn init(runtime: HttpRuntime, policies: []*HttpPolicy) HttpPipeline {
        return .{
            .policies = policies,
            .runtime = runtime,
        };
    }

    /// Configure once before copying the pipeline into clients. Provider,
    /// scope strings, and default-parent tracestate must outlive those copies.
    pub fn setInstrumentation(self: *HttpPipeline, options: ?tracing.InstrumentationOptions) void {
        self.instrumentation = options;
    }

    pub fn send(self: *HttpPipeline, request: *Request) !Response {
        request.transport_started = false;
        var scope = trace_http.Scope.begin(request, self.instrumentation);
        defer scope.end();
        const response = callNext(request, self.policies, self.runtime) catch |err| {
            scope.recordError(err);
            return err;
        };
        scope.recordResponse(response.status_code);
        return response;
    }

    /// Opens a streaming operation through the same ordered policy chain used
    /// by buffered requests.
    pub fn open(
        self: *HttpPipeline,
        request: *Request,
        options: OpenOptions,
    ) !*HttpOperation {
        request.transport_started = false;
        try checkOpenCancelled(options);
        var scope = trace_http.Scope.begin(request, self.instrumentation);
        defer scope.end();
        const operation = callNextOpen(request, options, self.policies, self.runtime) catch |err| {
            scope.recordError(err);
            return err;
        };
        scope.recordResponse(operation.status_code);
        return operation;
    }
};

fn checkOpenCancelled(options: OpenOptions) !void {
    if (options.cancellation) |token| {
        if (token.isCancelled()) return error.OperationCancelled;
    }
}

/// Advance through the remaining policies, calling the transport at the end.
fn callNext(request: *Request, next: []*HttpPolicy, runtime: HttpRuntime) !Response {
    if (next.len == 0) {
        return runtime.transport.send(request);
    }
    return next[0].process(request, next[1..], runtime);
}

fn callNextOpen(
    request: *Request,
    options: OpenOptions,
    next: []*HttpPolicy,
    runtime: HttpRuntime,
) !*HttpOperation {
    try checkOpenCancelled(options);
    if (next.len == 0) return runtime.transport.open(request, options);
    return next[0].open(request, options, next[1..], runtime);
}

// ───────────────────────────── Policies ─────────────────────────────

/// Injects `User-Agent` header.
pub const TelemetryPolicy = struct {
    user_agent: []const u8,
    policy: HttpPolicy,

    pub fn init(user_agent: []const u8) TelemetryPolicy {
        return .{
            .user_agent = user_agent,
            .policy = .{ .processFn = &processImpl, .prepareFn = &prepareImpl },
        };
    }

    pub fn asPolicy(self: *TelemetryPolicy) *HttpPolicy {
        return &self.policy;
    }

    fn processImpl(
        policy: *HttpPolicy,
        request: *Request,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !Response {
        try prepareImpl(policy, request, runtime);
        return callNext(request, next, runtime);
    }

    fn prepareImpl(policy: *HttpPolicy, request: *Request, _: HttpRuntime) !void {
        const self: *TelemetryPolicy = @alignCast(@fieldParentPtr("policy", policy));
        try request.setHeader("User-Agent", self.user_agent);
    }
};

/// Logs request method + URL via `std.log`.
pub const LoggingPolicy = struct {
    policy: HttpPolicy,

    pub fn init() LoggingPolicy {
        return .{ .policy = .{ .processFn = &processImpl, .prepareFn = &prepareImpl } };
    }

    pub fn asPolicy(self: *LoggingPolicy) *HttpPolicy {
        return &self.policy;
    }

    fn processImpl(
        policy: *HttpPolicy,
        request: *Request,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !Response {
        try prepareImpl(policy, request, runtime);
        const response = try callNext(request, next, runtime);
        std.log.info("azure-sdk: {d} {s}", .{ response.status_code, request.url });
        return response;
    }

    fn prepareImpl(_: *HttpPolicy, request: *Request, _: HttpRuntime) !void {
        std.log.info("azure-sdk: {s} {s}", .{ @tagName(request.method), request.url });
    }
};

/// Retries failed requests with exponential back-off and jitter.
///
/// Retries on server errors (5xx) and throttling (429). Honors the
/// `Retry-After` response header when present. For retryable requests,
/// `Request.operation_timeout_ms` limits attempts and backoff, but blocking
/// transports cannot interrupt an in-flight send. Non-retryable requests
/// always make one send, which is likewise not interruptible. Streaming
/// requests are retried only when their body exposes an explicit rewind.
pub const RetryPolicy = struct {
    max_retries: u32 = 3,
    initial_delay_ms: u64 = 800,
    max_delay_ms: u64 = 60_000,
    policy: HttpPolicy,

    pub fn init() RetryPolicy {
        return .{
            .policy = .{
                .processFn = &processImpl,
                .prepareFn = &prepareImpl,
                .openFn = &openImpl,
            },
        };
    }

    pub fn asPolicy(self: *RetryPolicy) *HttpPolicy {
        return &self.policy;
    }

    fn isRetryable(status: u16) bool {
        return status == 429 or status == 408 or status == 500 or
            status == 502 or status == 503 or status == 504;
    }

    fn prepareImpl(_: *HttpPolicy, _: *Request, _: HttpRuntime) !void {}

    fn processImpl(
        policy: *HttpPolicy,
        request: *Request,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !Response {
        if (!request.retryable) return callNext(request, next, runtime);
        const self: *RetryPolicy = @alignCast(@fieldParentPtr("policy", policy));
        const deadline_ns: ?i128 = if (request.operation_timeout_ms) |timeout_ms|
            std.math.add(
                i128,
                monotonicNanoTimestamp(),
                @as(i128, timeout_ms) * std.time.ns_per_ms,
            ) catch std.math.maxInt(i128)
        else
            null;
        var attempt: u32 = 0;
        var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(nanoTimestamp()))));
        while (true) {
            if (deadlineExpired(deadline_ns)) return error.OperationTimedOut;

            const result = callNext(request, next, runtime);
            if (result) |resp| {
                if (!isRetryable(resp.status_code) or attempt >= self.max_retries) return resp;

                // Check for Retry-After header (seconds).
                const retry_after_ms = retryAfterDelayMs(resp);

                var r = resp;
                r.deinit();

                attempt += 1;
                if (retry_after_ms > 0) {
                    // Honor server's Retry-After, capped at max_delay.
                    const delay = @min(retry_after_ms, self.max_delay_ms);
                    if (!sleepWithinBudget(delay, deadline_ns)) return error.OperationTimedOut;
                } else {
                    const base_delay = exponentialDelayMs(
                        self.initial_delay_ms,
                        self.max_delay_ms,
                        attempt,
                    );
                    const jitter = prng.random().uintLessThan(u64, @max(base_delay, 1));
                    const delay = base_delay / 2 + jitter / 2;
                    if (!sleepWithinBudget(delay, deadline_ns)) return error.OperationTimedOut;
                }
            } else |err| {
                if (attempt >= self.max_retries) return err;
                attempt += 1;
                const base_delay = exponentialDelayMs(
                    self.initial_delay_ms,
                    self.max_delay_ms,
                    attempt,
                );
                const jitter = prng.random().uintLessThan(u64, @max(base_delay, 1));
                const delay = base_delay / 2 + jitter / 2;
                if (!sleepWithinBudget(delay, deadline_ns)) return error.OperationTimedOut;
            }
        }
    }

    fn openImpl(
        policy: *HttpPolicy,
        request: *Request,
        options: OpenOptions,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !*HttpOperation {
        if (!request.retryable or !options.isReplayable())
            return callNextOpen(request, options, next, runtime);

        const self: *RetryPolicy = @alignCast(@fieldParentPtr("policy", policy));
        const deadline_ns: ?i128 = if (request.operation_timeout_ms) |timeout_ms|
            std.math.add(
                i128,
                monotonicNanoTimestamp(),
                @as(i128, timeout_ms) * std.time.ns_per_ms,
            ) catch std.math.maxInt(i128)
        else
            null;
        var current_options = options;
        var attempt: u32 = 0;
        var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(nanoTimestamp()))));

        while (true) {
            try checkOpenCancelled(current_options);
            if (deadlineExpired(deadline_ns)) return error.OperationTimedOut;
            if (attempt > 0) {
                try checkOpenCancelled(current_options);
                if (current_options.body) |*body| try body.rewind();
            }

            const result = callNextOpen(request, current_options, next, runtime);
            if (result) |operation| {
                if (!isRetryable(operation.status_code) or attempt >= self.max_retries)
                    return operation;

                const retry_after_ms = retryAfterOperationDelayMs(operation);
                operation.abort();
                operation.deinit();
                try checkOpenCancelled(current_options);
                attempt += 1;
                const delay = if (retry_after_ms > 0)
                    @min(retry_after_ms, self.max_delay_ms)
                else
                    retryDelay(self, &prng, attempt);
                if (!sleepWithinBudget(delay, deadline_ns)) return error.OperationTimedOut;
            } else |err| {
                if (err == error.OperationCancelled) return err;
                try checkOpenCancelled(current_options);
                if (attempt >= self.max_retries) return err;
                attempt += 1;
                const delay = retryDelay(self, &prng, attempt);
                if (!sleepWithinBudget(delay, deadline_ns)) return error.OperationTimedOut;
            }
        }
    }

    fn retryDelay(self: *const RetryPolicy, prng: *std.Random.DefaultPrng, attempt: u32) u64 {
        const base_delay = exponentialDelayMs(
            self.initial_delay_ms,
            self.max_delay_ms,
            attempt,
        );
        const jitter = prng.random().uintLessThan(u64, @max(base_delay, 1));
        return base_delay / 2 + jitter / 2;
    }

    fn deadlineExpired(deadline_ns: ?i128) bool {
        const deadline = deadline_ns orelse return false;
        return monotonicNanoTimestamp() >= deadline;
    }

    fn sleepWithinBudget(delay_ms: u64, deadline_ns: ?i128) bool {
        const deadline = deadline_ns orelse {
            sleepMs(delay_ms);
            return true;
        };
        const now = monotonicNanoTimestamp();
        if (now >= deadline) return false;

        const remaining_ns = deadline - now;
        const delay_ns = @as(i128, delay_ms) * std.time.ns_per_ms;
        if (delay_ns >= remaining_ns) {
            var threaded: std.Io.Threaded = .init_single_threaded;
            threaded.io().sleep(
                .fromNanoseconds(@intCast(remaining_ns)),
                .awake,
            ) catch {};
            return false;
        }
        sleepMs(delay_ms);
        return true;
    }

    fn exponentialDelayMs(initial_delay_ms: u64, max_delay_ms: u64, attempt: u32) u64 {
        if (initial_delay_ms == 0 or max_delay_ms == 0) return 0;
        const shift = attempt -| 1;
        if (shift >= 64) return max_delay_ms;
        const multiplier = @as(u64, 1) << @intCast(shift);
        const scaled = std.math.mul(u64, initial_delay_ms, multiplier) catch
            std.math.maxInt(u64);
        return @min(scaled, max_delay_ms);
    }

    fn parseRetryAfter(resp: Response) ?u64 {
        const value = resp.getHeader("Retry-After") orelse return null;
        return std.fmt.parseInt(u64, value, 10) catch null;
    }

    fn retryAfterDelayMs(resp: Response) u64 {
        const seconds = parseRetryAfter(resp) orelse return 0;
        return std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
    }

    fn retryAfterOperationDelayMs(operation: *const HttpOperation) u64 {
        const value = operation.getHeader("Retry-After") orelse return 0;
        const seconds = std.fmt.parseInt(u64, value, 10) catch return 0;
        return std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
    }
};

/// Injects `Authorization: Bearer <token>` using a `TokenCredential`.
///
/// Caches the token and only refreshes when within 5 minutes of expiry.
pub const BearerTokenAuthPolicy = struct {
    const creds = @import("../credentials/token.zig");

    credential: *creds.TokenCredential,
    scopes: []const []const u8,
    policy: HttpPolicy,
    allocator: std.mem.Allocator,
    cached_token: ?[]const u8 = null,
    cached_expires_on: i64 = 0,
    cached_auth_value: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        credential: *creds.TokenCredential,
        scopes: []const []const u8,
    ) BearerTokenAuthPolicy {
        return .{
            .allocator = allocator,
            .credential = credential,
            .scopes = scopes,
            .policy = .{ .processFn = &processImpl, .prepareFn = &prepareImpl },
        };
    }

    pub fn asPolicy(self: *BearerTokenAuthPolicy) *HttpPolicy {
        return &self.policy;
    }

    pub fn deinit(self: *BearerTokenAuthPolicy) void {
        if (self.cached_token) |t| self.allocator.free(t);
        if (self.cached_auth_value) |v| self.allocator.free(v);
    }

    fn processImpl(
        policy: *HttpPolicy,
        request: *Request,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !Response {
        try prepareImpl(policy, request, runtime);
        return callNext(request, next, runtime);
    }

    fn prepareImpl(policy: *HttpPolicy, request: *Request, runtime: HttpRuntime) !void {
        const self: *BearerTokenAuthPolicy = @alignCast(@fieldParentPtr("policy", policy));
        const now = unixTimestampSeconds();
        const refresh_buffer: i64 = 300; // 5 minutes before expiry

        // Use cached token if still valid.
        var token_str = self.cached_token;
        if (token_str == null or now >= self.cached_expires_on - refresh_buffer) {
            const ctx = @import("../context.zig").Context.none;
            var fresh = try self.credential.getToken(
                .{ .scopes = self.scopes },
                ctx,
                runtime,
            );
            defer fresh.deinit();
            const replacement = try self.allocator.dupe(u8, fresh.token);
            if (self.cached_token) |old| self.allocator.free(old);
            self.cached_token = replacement;
            self.cached_expires_on = fresh.expires_on;
            token_str = self.cached_token;
        }

        // Build and cache the "Bearer {token}" header value.
        const old_auth_value = self.cached_auth_value;
        {
            self.cached_auth_value = null;
            errdefer self.cached_auth_value = old_auth_value;
            self.cached_auth_value = try std.fmt.allocPrint(
                self.allocator,
                "Bearer {s}",
                .{token_str.?},
            );
        }
        if (old_auth_value) |old| self.allocator.free(old);
        try request.setHeader("Authorization", self.cached_auth_value.?);
    }
};

/// Ensures a request has a caller-preserving unique client request ID.
pub fn ensureRequestId(request: *Request, runtime: HttpRuntime) !void {
    if (request.getHeader("x-ms-client-request-id") != null) return;
    const uuid_mod = @import("../uuid.zig");
    const id = try uuid_mod.Uuid.init(runtime.crypto);
    const id_str = id.toString();
    try request.setHeader("x-ms-client-request-id", &id_str);
}

/// Injects `x-ms-client-request-id` with a unique UUID per request.
pub const RequestIdPolicy = struct {
    policy: HttpPolicy,

    pub fn init() RequestIdPolicy {
        return .{ .policy = .{ .processFn = &processImpl, .prepareFn = &prepareImpl } };
    }

    pub fn asPolicy(self: *RequestIdPolicy) *HttpPolicy {
        return &self.policy;
    }

    fn processImpl(
        policy: *HttpPolicy,
        request: *Request,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !Response {
        try prepareImpl(policy, request, runtime);
        return callNext(request, next, runtime);
    }

    fn prepareImpl(_: *HttpPolicy, request: *Request, runtime: HttpRuntime) !void {
        try ensureRequestId(request, runtime);
    }
};

/// Legacy manually placed tracing policy. Automatic pipeline instrumentation
/// supersedes it without double spans. URLs and headers are never attributes.
pub const TracingPolicy = struct {
    tracer: *tracing.Tracer,
    az_namespace: []const u8,
    policy: HttpPolicy,

    pub fn init(tracer: *tracing.Tracer, az_namespace: []const u8) TracingPolicy {
        return .{
            .tracer = tracer,
            .az_namespace = az_namespace,
            .policy = .{ .processFn = &processImpl, .openFn = &openImpl },
        };
    }

    pub fn asPolicy(self: *TracingPolicy) *HttpPolicy {
        return &self.policy;
    }

    fn processImpl(
        policy: *HttpPolicy,
        request: *Request,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !Response {
        const self: *TracingPolicy = @alignCast(@fieldParentPtr("policy", policy));
        if (request.context.tracing_suppressed) return callNext(request, next, runtime);

        const span = self.tracer.startSpan("HTTP", .client) catch {
            return callNext(request, next, runtime);
        };

        // Set standard Azure SDK span attributes.
        span.setAttribute("http.method", @tagName(request.method)) catch {};
        span.setAttribute("az.namespace", self.az_namespace) catch {};
        trace_http.safeAttributes(span, request, self.az_namespace);

        // Execute the rest of the pipeline.
        const response = callNext(request, next, runtime) catch |err| {
            span.setStatus(.@"error");
            span.end();
            return err;
        };

        // Record response status.
        if (response.isSuccess()) {
            span.setStatus(.ok);
        } else {
            span.setStatus(.@"error");
        }

        span.end();
        return response;
    }

    fn openImpl(
        policy: *HttpPolicy,
        request: *Request,
        options: OpenOptions,
        next: []*HttpPolicy,
        runtime: HttpRuntime,
    ) !*HttpOperation {
        const self: *TracingPolicy = @alignCast(@fieldParentPtr("policy", policy));
        if (request.context.tracing_suppressed) return callNextOpen(request, options, next, runtime);
        const span = self.tracer.startSpan("HTTP", .client) catch
            return callNextOpen(request, options, next, runtime);
        span.setAttribute("http.method", @tagName(request.method)) catch {};
        span.setAttribute("az.namespace", self.az_namespace) catch {};
        trace_http.safeAttributes(span, request, self.az_namespace);
        const operation = callNextOpen(request, options, next, runtime) catch |err| {
            span.setStatus(.@"error");
            span.end();
            return err;
        };
        span.setStatus(if (operation.isSuccess()) .ok else .@"error");
        span.end();
        return operation;
    }
};

test "pipeline prepares streaming policies without retrying" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 200, "stream");
    defer mock.deinit();
    var telemetry = TelemetryPolicy.init("stream-agent");
    var request_id = RequestIdPolicy.init();
    var retry = RetryPolicy.init();
    var policy_ptrs = [_]*HttpPolicy{
        telemetry.asPolicy(),
        request_id.asPolicy(),
        retry.asPolicy(),
    };
    var pipeline_inst = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);
    var request = Request.init(allocator, .GET, "https://example.com");
    defer request.deinit();
    var operation = try pipeline_inst.open(&request, .{});
    defer operation.deinit();
    try std.testing.expectEqualStrings("stream-agent", mock.last_headers.get("User-Agent").?);
    try std.testing.expect(mock.last_headers.get("x-ms-client-request-id") != null);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try operation.finish();

    var token = transport.CancellationToken{};
    token.cancel();
    var cancelled_request = Request.init(allocator, .GET, "https://example.com/cancelled");
    defer cancelled_request.deinit();
    try std.testing.expectError(
        error.OperationCancelled,
        pipeline_inst.open(&cancelled_request, .{ .cancellation = &token }),
    );
    try std.testing.expect(cancelled_request.getHeader("User-Agent") == null);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "RetryPolicy replays only explicitly rewindable streaming bodies" {
    const allocator = std.testing.allocator;
    var retry = RetryPolicy.init();
    retry.initial_delay_ms = 0;
    var policies = [_]*HttpPolicy{retry.asPolicy()};

    var replay_sequence = transport.SequenceMockTransport.init(allocator, &.{
        .{ .status = 503, .body = "retry" },
        .{ .status = 200, .body = "ok" },
    });
    var replay_pipeline = HttpPipeline.init(
        testingRuntime(replay_sequence.asTransport()),
        &policies,
    );
    var replay_request = Request.init(allocator, .POST, "https://example.com/upload");
    defer replay_request.deinit();
    var replay = transport.ReplayableBytes.init("replayable");
    var replay_operation = try replay_pipeline.open(&replay_request, .{ .body = replay.body() });
    defer replay_operation.deinit();
    try std.testing.expectEqual(@as(u16, 200), replay_operation.status_code);
    try std.testing.expectEqual(@as(usize, 2), replay_sequence.call_count);
    try std.testing.expectEqualStrings("replayable", replay_sequence.capturedBody(0));
    try std.testing.expectEqualStrings("replayable", replay_sequence.capturedBody(1));
    try replay_operation.finish();

    var one_shot_sequence = transport.SequenceMockTransport.init(allocator, &.{
        .{ .status = 503, .body = "retry" },
        .{ .status = 200, .body = "unexpected" },
    });
    var one_shot_pipeline = HttpPipeline.init(
        testingRuntime(one_shot_sequence.asTransport()),
        &policies,
    );
    var one_shot_request = Request.init(allocator, .POST, "https://example.com/upload");
    defer one_shot_request.deinit();
    var source = std.Io.Reader.fixed("one-shot");
    var one_shot_operation = try one_shot_pipeline.open(&one_shot_request, .{
        .body = transport.StreamingRequestBody.chunked(&source),
    });
    defer one_shot_operation.deinit();
    try std.testing.expectEqual(@as(u16, 503), one_shot_operation.status_code);
    try std.testing.expectEqual(@as(usize, 1), one_shot_sequence.call_count);
    one_shot_operation.abort();
}

test "RetryPolicy propagates streaming cancellation without retry or rewind" {
    const RewindSource = struct {
        reader: std.Io.Reader,
        bytes: []const u8,
        rewind_count: usize = 0,

        fn init(bytes: []const u8) @This() {
            return .{ .reader = std.Io.Reader.fixed(bytes), .bytes = bytes };
        }

        fn rewind(context: *anyopaque) !*std.Io.Reader {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.rewind_count += 1;
            self.reader = std.Io.Reader.fixed(self.bytes);
            return &self.reader;
        }
    };

    const CancellingTransport = struct {
        call_count: usize = 0,

        const vtable: HttpTransport.VTable = .{
            .send = &send,
            .open = &open,
        };

        fn asTransport(self: *@This()) HttpTransport {
            return .{ .context = self, .vtable = &vtable };
        }

        fn send(_: *anyopaque, _: *Request) anyerror!Response {
            return error.UnexpectedBufferedSend;
        }

        fn open(
            context: *anyopaque,
            _: *Request,
            options: OpenOptions,
        ) anyerror!*HttpOperation {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.call_count += 1;
            if (options.body) |body| {
                var byte: [1]u8 = undefined;
                _ = try body.reader.readSliceShort(&byte);
            }
            if (options.cancellation) |token| @constCast(token).cancel();
            return error.OperationCancelled;
        }
    };

    const allocator = std.testing.allocator;
    var cancelling = CancellingTransport{};
    var retry = RetryPolicy.init();
    retry.initial_delay_ms = 0;
    var policies = [_]*HttpPolicy{retry.asPolicy()};
    var pipeline_inst = HttpPipeline.init(testingRuntime(cancelling.asTransport()), &policies);
    var request = Request.init(allocator, .POST, "https://example.com/upload");
    defer request.deinit();
    var token = transport.CancellationToken{};
    var source = RewindSource.init("body");
    const body = transport.StreamingRequestBody.knownLength(
        &source.reader,
        source.bytes.len,
    ).withRewind(&source, &RewindSource.rewind);

    try std.testing.expectError(
        error.OperationCancelled,
        pipeline_inst.open(&request, .{ .body = body, .cancellation = &token }),
    );
    try std.testing.expectEqual(@as(usize, 1), cancelling.call_count);
    try std.testing.expectEqual(@as(usize, 0), source.rewind_count);
}

test "pipeline rejects policies without streaming preparation" {
    const UnsupportedPolicy = struct {
        fn process(
            _: *HttpPolicy,
            _: *Request,
            _: []*HttpPolicy,
            _: HttpRuntime,
        ) anyerror!Response {
            return error.UnexpectedPolicyCall;
        }
    };

    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 200, "stream");
    defer mock.deinit();
    var unsupported = HttpPolicy{ .processFn = &UnsupportedPolicy.process };
    var policies = [_]*HttpPolicy{&unsupported};
    var pipeline_inst = HttpPipeline.init(testingRuntime(mock.asTransport()), &policies);
    var request = Request.init(allocator, .GET, "https://example.com");
    defer request.deinit();
    try std.testing.expectError(
        error.StreamingPolicyUnsupported,
        pipeline_inst.open(&request, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "pipeline with no policies" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 404, "not found");
    defer mock.deinit();
    var empty = [_]*HttpPolicy{};
    var pipeline_inst = HttpPipeline.init(testingRuntime(mock.asTransport()), &empty);
    var req = Request.init(allocator, .GET, "https://example.com/missing");
    defer req.deinit();
    var resp = try pipeline_inst.send(&req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "pipeline with multiple policies" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 200, "ok");
    defer mock.deinit();
    var telemetry = TelemetryPolicy.init("azsdk-zig-test/0.1.0");
    var logging = LoggingPolicy.init();
    var policy_ptrs = [_]*HttpPolicy{ telemetry.asPolicy(), logging.asPolicy() };
    var pipeline_inst = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    var resp = try pipeline_inst.send(&req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "RequestIdPolicy injects x-ms-client-request-id" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 200, "ok");
    defer mock.deinit();
    var rid = RequestIdPolicy.init();
    var policy_ptrs = [_]*HttpPolicy{rid.asPolicy()};
    var pipeline_inst = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    var resp = try pipeline_inst.send(&req);
    defer resp.deinit();
    const request_id = req.headers.get("x-ms-client-request-id").?;
    // UUID format: 8-4-4-4-12 = 36 chars.
    try std.testing.expectEqual(@as(usize, 36), request_id.len);
    try std.testing.expectEqual(@as(u8, '-'), request_id[8]);
}

test "RequestIdPolicy preserves caller-provided request ID" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 200, "ok");
    defer mock.deinit();
    var rid = RequestIdPolicy.init();
    var policy_ptrs = [_]*HttpPolicy{rid.asPolicy()};
    var pipeline_inst = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    try req.setHeader("X-MS-Client-Request-Id", "caller-request-id");
    var resp = try pipeline_inst.send(&req);
    defer resp.deinit();
    try std.testing.expectEqualStrings(
        "caller-request-id",
        req.getHeader("x-ms-client-request-id").?,
    );
}

test "RequestIdPolicy provider failure occurs before transport dispatch" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 200, "unexpected");
    defer mock.deinit();
    var failing_crypto = crypto_mod.StdCryptoProvider.init(std.Io.failing);
    const runtime = HttpRuntime.init(mock.asTransport(), failing_crypto.asProvider());
    var request_id = RequestIdPolicy.init();
    var policies = [_]*HttpPolicy{request_id.asPolicy()};
    var pipeline_inst = HttpPipeline.init(runtime, &policies);
    var request = Request.init(allocator, .GET, "https://example.com");
    defer request.deinit();

    try std.testing.expectError(error.EntropyUnavailable, pipeline_inst.send(&request));
    try std.testing.expect(!request.transport_started);
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "BearerTokenAuthPolicy injects Authorization header" {
    const allocator = std.testing.allocator;
    const creds = @import("../credentials/token.zig");

    const Stub = struct {
        fn getTokenFn(
            _: *creds.TokenCredential,
            _: creds.TokenRequestContext,
            _: @import("../context.zig").Context,
            _: HttpRuntime,
        ) anyerror!creds.AccessToken {
            const token = try allocator.dupe(u8, "stub-token");
            return .{
                .token = token,
                .expires_on = unixTimestampSeconds() + 3600,
                .allocator = allocator,
            };
        }
    };
    var credential = creds.TokenCredential{ .getTokenFn = &Stub.getTokenFn };

    var mock = transport.MockTransport.init(allocator, 200, "ok");
    defer mock.deinit();
    var auth = BearerTokenAuthPolicy.init(
        allocator,
        &credential,
        &.{"https://vault.azure.net/.default"},
    );
    defer auth.deinit();
    var policy_ptrs = [_]*HttpPolicy{auth.asPolicy()};
    var pipeline_inst = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    var resp = try pipeline_inst.send(&req);
    defer resp.deinit();
    try std.testing.expectEqualStrings("Bearer stub-token", req.headers.get("Authorization").?);
}

test "RetryPolicy passes through 200 without retry" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 200, "ok");
    defer mock.deinit();
    var retry = RetryPolicy.init();
    var policy_ptrs = [_]*HttpPolicy{retry.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    var resp = try pip.send(&req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "RetryPolicy converts Retry-After seconds to milliseconds" {
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    try headers.put("Retry-After", "10");
    const response = Response{
        .status_code = 429,
        .headers = headers,
        .body = @constCast(&.{}),
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(u64, 10_000), RetryPolicy.retryAfterDelayMs(response));
}

test "RetryPolicy exponential delay saturates without overflow" {
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        RetryPolicy.exponentialDelayMs(std.math.maxInt(u64), std.math.maxInt(u64), 2),
    );
    try std.testing.expectEqual(
        @as(u64, 60_000),
        RetryPolicy.exponentialDelayMs(800, 60_000, std.math.maxInt(u32)),
    );
}

test "RetryPolicy passes through 404 without retry" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 404, "not found");
    defer mock.deinit();
    var retry = RetryPolicy.init();
    var policy_ptrs = [_]*HttpPolicy{retry.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    var resp = try pip.send(&req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "RetryPolicy retries 500 then succeeds" {
    const allocator = std.testing.allocator;
    var seq = transport.SequenceMockTransport.init(allocator, &.{
        .{ .status = 500, .body = "error" },
        .{ .status = 200, .body = "ok" },
    });
    // Retry with zero delay for test speed.
    var retry = RetryPolicy.init();
    retry.initial_delay_ms = 0;
    var policy_ptrs = [_]*HttpPolicy{retry.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(seq.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    var resp = try pip.send(&req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 2), seq.call_count);
}

test "RetryPolicy retries 429 then succeeds" {
    const allocator = std.testing.allocator;
    var seq = transport.SequenceMockTransport.init(allocator, &.{
        .{ .status = 429, .body = "throttled" },
        .{ .status = 200, .body = "ok" },
    });
    var retry = RetryPolicy.init();
    retry.initial_delay_ms = 0;
    var policy_ptrs = [_]*HttpPolicy{retry.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(seq.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    var resp = try pip.send(&req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 2), seq.call_count);
}

test "RetryPolicy bypasses retries for non-retryable requests" {
    const allocator = std.testing.allocator;
    var seq = transport.SequenceMockTransport.init(allocator, &.{
        .{ .status = 500, .body = "error" },
        .{ .status = 200, .body = "ok" },
    });
    var retry = RetryPolicy.init();
    retry.initial_delay_ms = 0;
    var policy_ptrs = [_]*HttpPolicy{retry.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(seq.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .POST, "https://example.com/create");
    defer req.deinit();
    req.retryable = false;
    req.operation_timeout_ms = 0;
    var resp = try pip.send(&req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 500), resp.status_code);
    try std.testing.expectEqual(@as(usize, 1), seq.call_count);
}

test "RetryPolicy zero timeout prevents a retryable send" {
    const allocator = std.testing.allocator;
    var seq = transport.SequenceMockTransport.init(allocator, &.{
        .{ .status = 200, .body = "ok" },
    });
    var retry = RetryPolicy.init();
    var policy_ptrs = [_]*HttpPolicy{retry.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(seq.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    req.operation_timeout_ms = 0;

    try std.testing.expectError(error.OperationTimedOut, pip.send(&req));
    try std.testing.expectEqual(@as(usize, 0), seq.call_count);
}

test "RetryPolicy timeout prevents a second attempt" {
    const allocator = std.testing.allocator;
    var seq = transport.SequenceMockTransport.init(allocator, &.{
        .{ .status = 500, .body = "error" },
        .{ .status = 200, .body = "ok" },
    });
    var retry = RetryPolicy.init();
    retry.initial_delay_ms = 100;
    var policy_ptrs = [_]*HttpPolicy{retry.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(seq.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    req.operation_timeout_ms = 1;

    try std.testing.expectError(error.OperationTimedOut, pip.send(&req));
    try std.testing.expectEqual(@as(usize, 1), seq.call_count);
}

test "RetryPolicy gives up after max retries" {
    const allocator = std.testing.allocator;
    var seq = transport.SequenceMockTransport.init(allocator, &.{
        .{ .status = 503, .body = "unavailable" },
    });
    var retry = RetryPolicy.init();
    retry.initial_delay_ms = 0;
    retry.max_retries = 2;
    var policy_ptrs = [_]*HttpPolicy{retry.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(seq.asTransport()), &policy_ptrs);
    var req = Request.init(allocator, .GET, "https://example.com");
    defer req.deinit();
    var resp = try pip.send(&req);
    defer resp.deinit();
    // After 2 retries (3 total attempts), returns the last 503.
    try std.testing.expectEqual(@as(u16, 503), resp.status_code);
    try std.testing.expectEqual(@as(usize, 3), seq.call_count);
}

test "isRetryable status codes" {
    try std.testing.expect(RetryPolicy.isRetryable(429));
    try std.testing.expect(RetryPolicy.isRetryable(500));
    try std.testing.expect(RetryPolicy.isRetryable(502));
    try std.testing.expect(RetryPolicy.isRetryable(503));
    try std.testing.expect(RetryPolicy.isRetryable(504));
    try std.testing.expect(RetryPolicy.isRetryable(408));
    try std.testing.expect(!RetryPolicy.isRetryable(200));
    try std.testing.expect(!RetryPolicy.isRetryable(400));
    try std.testing.expect(!RetryPolicy.isRetryable(401));
    try std.testing.expect(!RetryPolicy.isRetryable(404));
}

test "TracingPolicy creates span with attributes" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 200, "ok");
    defer mock.deinit();

    var rec_tracer = tracing.RecordingTracer.init(allocator);
    defer rec_tracer.deinit();

    var tracing_policy = TracingPolicy.init(rec_tracer.asTracer(), "KeyVault");
    var policy_ptrs = [_]*HttpPolicy{tracing_policy.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);

    var req = Request.init(allocator, .GET, "https://vault.azure.net/secrets/mysecret");
    defer req.deinit();
    var resp = try pip.send(&req);
    defer resp.deinit();

    // Verify span was created and ended with correct attributes.
    const span = &rec_tracer.last_span.?;
    try std.testing.expectEqualStrings("HTTP", span.name);
    try std.testing.expectEqual(tracing.SpanKind.client, span.kind);
    try std.testing.expectEqual(tracing.SpanStatus.ok, span.status);
    try std.testing.expect(span.ended);
    try std.testing.expectEqualStrings("GET", span.attributes.get("http.method").?);
    try std.testing.expectEqualStrings("KeyVault", span.attributes.get("az.namespace").?);
}

test "TracingPolicy sets error status on failure" {
    const allocator = std.testing.allocator;
    var mock = transport.MockTransport.init(allocator, 500, "error");
    defer mock.deinit();

    var rec_tracer = tracing.RecordingTracer.init(allocator);
    defer rec_tracer.deinit();

    var tracing_policy = TracingPolicy.init(rec_tracer.asTracer(), "Storage");
    var policy_ptrs = [_]*HttpPolicy{tracing_policy.asPolicy()};
    var pip = HttpPipeline.init(testingRuntime(mock.asTransport()), &policy_ptrs);

    var req = Request.init(allocator, .GET, "https://storage.blob.core.windows.net");
    defer req.deinit();
    var resp = try pip.send(&req);
    defer resp.deinit();

    try std.testing.expectEqual(tracing.SpanStatus.@"error", rec_tracer.last_span.?.status);
    try std.testing.expect(rec_tracer.last_span.?.ended);
}

test {
    _ = @import("../tracing/http_test.zig");
}
