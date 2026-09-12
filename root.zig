const std = @import("std");
const core = @import("azure_sdk_core");
const serde = @import("serde");

// ─────────────────────────── Models ───────────────────────────

pub const AttestationResult = struct {
    token: ?[]const u8 = null,
    is_debuggable: ?bool = null,

    pub fn deinit(self: AttestationResult, allocator: std.mem.Allocator) void {
        if (self.token) |t| allocator.free(t);
    }
};

// ──────────────────── AttestationClient ───────────────────────

pub const AttestationClientOptions = struct {
    runtime: core.http.HttpRuntime,
    api_version: []const u8 = "2022-08-01",
    /// Disabled by default. The provider, scope strings, and parent tracestate
    /// are borrowed and must outlive the client and its operations.
    instrumentation: ?core.tracing.InstrumentationOptions = null,
};

pub const attestation_scopes: []const []const u8 = &.{
    "https://attest.azure.net/.default",
};

pub const AttestationClient = struct {
    allocator: std.mem.Allocator,
    endpoint: []u8,
    api_version: []u8,
    auth_policy: *core.http.BearerTokenAuthPolicy,
    request_id_policy: *core.http.RequestIdPolicy,
    policy_ptrs: []*core.http.HttpPolicy,
    pipeline: core.http.HttpPipeline,

    /// Constructs a client with the canonical HTTP runtime.
    ///
    /// Runtime descriptors are copied by value. Their transport and crypto
    /// backend contexts, and `credential`, remain borrowed and must outlive
    /// this client and every operation on it. The selected crypto provider is
    /// used for request IDs without falling back to the standard provider.
    pub fn init(
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        credential: *core.credentials.TokenCredential,
        options: AttestationClientOptions,
    ) !AttestationClient {
        const owned_endpoint = try allocator.dupe(u8, endpoint);
        errdefer allocator.free(owned_endpoint);
        const owned_api_version = try allocator.dupe(u8, options.api_version);
        errdefer allocator.free(owned_api_version);

        const request_id_policy = try allocator.create(core.http.RequestIdPolicy);
        errdefer allocator.destroy(request_id_policy);
        request_id_policy.* = .init();

        const auth_policy = try allocator.create(core.http.BearerTokenAuthPolicy);
        errdefer allocator.destroy(auth_policy);
        auth_policy.* = .init(allocator, credential, attestation_scopes);
        errdefer auth_policy.deinit();

        const policy_ptrs = try allocator.alloc(*core.http.HttpPolicy, 2);
        errdefer allocator.free(policy_ptrs);
        policy_ptrs[0] = request_id_policy.asPolicy();
        policy_ptrs[1] = auth_policy.asPolicy();

        var pipeline = core.http.HttpPipeline.init(options.runtime, policy_ptrs);
        pipeline.setInstrumentation(options.instrumentation);
        return .{
            .allocator = allocator,
            .endpoint = owned_endpoint,
            .api_version = owned_api_version,
            .auth_policy = auth_policy,
            .request_id_policy = request_id_policy,
            .policy_ptrs = policy_ptrs,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(self: *AttestationClient) void {
        self.allocator.free(self.policy_ptrs);
        self.auth_policy.deinit();
        self.allocator.destroy(self.auth_policy);
        self.allocator.destroy(self.request_id_policy);
        self.allocator.free(self.api_version);
        self.allocator.free(self.endpoint);
        self.* = undefined;
    }

    /// Returns a copy of the runtime descriptor used by every operation.
    ///
    /// The returned descriptor borrows the same backend contexts as the
    /// client.
    pub fn runtime(self: *const AttestationClient) core.http.HttpRuntime {
        return self.pipeline.runtime;
    }

    /// POST /attest/SgxEnclave?api-version=...
    pub fn attestSgxEnclave(
        self: *AttestationClient,
        allocator: std.mem.Allocator,
        quote: []const u8,
    ) !AttestationResult {
        return self.attest(allocator, "SgxEnclave", quote);
    }

    /// POST /attest/OpenEnclave?api-version=...
    pub fn attestOpenEnclave(
        self: *AttestationClient,
        allocator: std.mem.Allocator,
        report: []const u8,
    ) !AttestationResult {
        return self.attest(allocator, "OpenEnclave", report);
    }

    /// `Result(...)` variants — branch on `AzureError.error_code` when
    /// the attestation backend is unavailable, the enclave evidence is
    /// invalid, etc.
    pub fn attestSgxEnclaveResult(
        self: *AttestationClient,
        allocator: std.mem.Allocator,
        quote: []const u8,
    ) !core.errors.Result(AttestationResult) {
        return self.attestResult(allocator, "SgxEnclave", quote);
    }

    pub fn attestOpenEnclaveResult(
        self: *AttestationClient,
        allocator: std.mem.Allocator,
        report: []const u8,
    ) !core.errors.Result(AttestationResult) {
        return self.attestResult(allocator, "OpenEnclave", report);
    }

    fn attest(
        self: *AttestationClient,
        allocator: std.mem.Allocator,
        enclave_type: []const u8,
        evidence: []const u8,
    ) !AttestationResult {
        var result = try self.attestResult(allocator, enclave_type, evidence);
        return result.unwrap(error.AttestationFailed);
    }

    fn attestResult(
        self: *AttestationClient,
        allocator: std.mem.Allocator,
        enclave_type: []const u8,
        evidence: []const u8,
    ) !core.errors.Result(AttestationResult) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/attest/{s}?api-version={s}",
            .{ self.endpoint, enclave_type, self.api_version },
        );
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"quote\":\"{s}\"}}",
            .{evidence},
        );
        defer allocator.free(body);

        var request = core.http.Request.init(allocator, .POST, url);
        defer request.deinit();
        try request.setHeader("Content-Type", "application/json");
        try request.setHeader("Accept", "application/json");
        request.body = body;

        var response = try self.pipeline.send(&request);
        defer response.deinit();

        if (!response.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, response)) |azure_error| {
                return .{ .err = azure_error };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try parseAttestationResult(allocator, response.body) };
    }
};

// ─────────────────────────── Parsing ──────────────────────────

fn parseAttestationResult(allocator: std.mem.Allocator, body: []const u8) !AttestationResult {
    const Schema = struct {
        token: ?[]const u8 = null,
        isDebuggable: ?bool = null,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(Schema, arena.allocator(), body) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{},
    };

    var result = AttestationResult{};
    if (parsed.token) |value| result.token = try allocator.dupe(u8, value);
    result.is_debuggable = parsed.isDebuggable;
    return result;
}

// ─────────────────────────── Tests ────────────────────────────

const TestCredential = struct {
    credential: core.credentials.TokenCredential = .{ .getTokenFn = &getToken },
    calls: usize = 0,
    transport_context: ?*anyopaque = null,
    crypto_context: ?*anyopaque = null,
    scope: ?[]const u8 = null,

    fn asCredential(self: *@This()) *core.credentials.TokenCredential {
        return &self.credential;
    }

    fn getToken(
        credential: *core.credentials.TokenCredential,
        request_context: core.credentials.TokenRequestContext,
        _: core.context.Context,
        runtime_value: core.http.HttpRuntime,
    ) anyerror!core.credentials.AccessToken {
        const self: *@This() = @alignCast(@fieldParentPtr("credential", credential));
        self.calls += 1;
        self.transport_context = runtime_value.transport.context;
        self.crypto_context = runtime_value.crypto.context;
        self.scope = request_context.scopes[0];
        return .{
            .token = "test-token",
            .expires_on = std.math.maxInt(i64),
        };
    }
};

const TestCryptoProvider = struct {
    random_calls: usize = 0,
    fail_random: bool = false,

    const vtable: core.crypto.CryptoProvider.VTable = .{
        .random_bytes = &randomBytes,
        .md5 = &md5,
        .sha256 = &sha256,
        .hmac_sha256 = &hmacSha256,
        .sha256_init = &sha256Init,
    };

    fn asProvider(self: *@This()) core.crypto.CryptoProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    fn randomBytes(context: *anyopaque, out: []u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.random_calls += 1;
        if (self.fail_random) return error.ProviderFailure;
        for (out, 0..) |*byte, index| byte.* = @truncate(index);
    }

    fn md5(_: *anyopaque, _: []const u8, _: *core.crypto.Md5Digest) !void {
        return error.Unused;
    }

    fn sha256(_: *anyopaque, _: []const u8, _: *core.crypto.Sha256Digest) !void {
        return error.Unused;
    }

    fn hmacSha256(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: *core.crypto.HmacSha256Digest,
    ) !void {
        return error.Unused;
    }

    fn sha256Init(
        _: *anyopaque,
        _: std.mem.Allocator,
    ) !core.crypto.Sha256Operation {
        return error.Unused;
    }
};

fn attestationAllocationFixture(allocator: std.mem.Allocator, instrumented: bool) !void {
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"token":"attestation-token","isDebuggable":false}
    );
    defer mock.deinit();
    var provider = TestCryptoProvider{};
    var credential = TestCredential{};
    var tracing = FailingTracingProvider{};
    var client = try AttestationClient.init(
        allocator,
        "https://myattestation.attest.azure.net",
        credential.asCredential(),
        .{
            .runtime = .init(mock.asTransport(), provider.asProvider()),
            .instrumentation = if (instrumented) .{
                .provider = &tracing.provider,
                .scope_name = "allocation-fixture",
            } else null,
        },
    );
    defer client.deinit();

    const result = try client.attestSgxEnclave(allocator, "base64-encoded-quote");
    defer result.deinit(allocator);
}

test "AttestationClient preserves runtime providers across operations" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"token":"attestation-token","isDebuggable":false}
    );
    defer mock.deinit();
    var provider = TestCryptoProvider{};
    var credential = TestCredential{};
    const runtime_value = core.http.HttpRuntime.init(
        mock.asTransport(),
        provider.asProvider(),
    );
    var client = try AttestationClient.init(
        allocator,
        "https://myattestation.attest.azure.net",
        credential.asCredential(),
        .{ .runtime = runtime_value },
    );
    defer client.deinit();

    const result = try client.attestSgxEnclave(allocator, "base64-encoded-quote");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("attestation-token", result.token.?);
    try std.testing.expectEqual(false, result.is_debuggable.?);
    try std.testing.expectEqual(core.http.Method.POST, mock.last_method.?);
    try std.testing.expect(std.mem.find(
        u8,
        mock.last_url.?,
        "attest/SgxEnclave?api-version=",
    ) != null);
    try std.testing.expectEqualStrings(
        "Bearer test-token",
        mock.last_headers.get("Authorization").?,
    );
    try std.testing.expectEqualStrings(
        "00010203-0405-4607-8809-0a0b0c0d0e0f",
        mock.last_headers.get("x-ms-client-request-id").?,
    );
    try std.testing.expectEqual(@as(usize, 1), provider.random_calls);
    try std.testing.expectEqual(@as(usize, 1), credential.calls);
    try std.testing.expectEqual(runtime_value.transport.context, credential.transport_context.?);
    try std.testing.expectEqual(runtime_value.crypto.context, credential.crypto_context.?);
    try std.testing.expectEqualStrings(attestation_scopes[0], credential.scope.?);
    try std.testing.expectEqual(runtime_value.transport.context, client.runtime().transport.context);
    try std.testing.expectEqual(runtime_value.crypto.context, client.runtime().crypto.context);
}

test "AttestationClient propagates selected provider failure before transport" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var provider = TestCryptoProvider{ .fail_random = true };
    var credential = TestCredential{};
    var trace_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var probe = TracingProbe{};
    var tracing = try probe.createProvider(trace_crypto.asProvider());
    defer tracing.deinit() catch unreachable;
    var client = try AttestationClient.init(
        allocator,
        "https://myattestation.attest.azure.net",
        credential.asCredential(),
        .{
            .runtime = .init(mock.asTransport(), provider.asProvider()),
            .instrumentation = TracingProbe.options(&tracing),
        },
    );
    defer client.deinit();

    try std.testing.expectError(
        error.ProviderFailure,
        client.attestSgxEnclave(allocator, "base64-encoded-quote"),
    );
    try std.testing.expectEqual(@as(usize, 1), provider.random_calls);
    try std.testing.expectEqual(@as(usize, 0), credential.calls);
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
    try tracing.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(core.tracing.SpanStatus.@"error", probe.statuses[0]);
}

test "AttestationClient releases every allocation failure path" {
    for ([_]bool{ false, true }) |instrumented| {
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            attestationAllocationFixture,
            .{instrumented},
        );
    }
}

const TracingProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = exportBatch },
    count: usize = 0,
    ids: [8][16]u8 = undefined,
    statuses: [8]core.tracing.SpanStatus = undefined,

    const parent: core.tracing.TraceContext = .{
        .trace_id = "0af7651916cd43dd8448eb211c80319c".*,
        .span_id = "b7ad6b7169203331".*,
        .trace_flags = 1,
        .trace_state = "vendor=value",
    };

    fn createProvider(self: *TracingProbe, crypto: core.crypto.CryptoProvider) !core.tracing.ExportingTracerProvider {
        return .init(std.testing.allocator, std.testing.io, crypto, &self.exporter, .{
            .max_spans = 8,
            .max_queued_spans = 8,
        });
    }

    fn options(provider: *core.tracing.ExportingTracerProvider) core.tracing.InstrumentationOptions {
        return .{
            .provider = provider.asProvider(),
            .scope_name = "caller.attestation",
            .scope_version = "caller-version",
            .namespace = "Caller.Attestation",
            .parent_context = parent,
        };
    }

    fn wireId(mock: *core.http.MockTransport) ![16]u8 {
        const context = core.tracing.TraceContext.parseTraceparent(
            mock.last_headers.get("traceparent") orelse return error.MissingTraceparent,
        ) orelse return error.InvalidTraceparent;
        try std.testing.expectEqualStrings(&parent.trace_id, &context.trace_id);
        try std.testing.expect(!std.mem.eql(u8, &parent.span_id, &context.span_id));
        try std.testing.expectEqualStrings(parent.trace_state.?, mock.last_headers.get("tracestate").?);
        return context.span_id;
    }

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *TracingProbe = @fieldParentPtr("exporter", exporter);
        for (batch) |data| {
            try std.testing.expect(self.count < self.ids.len);
            try std.testing.expectEqualStrings("caller.attestation", data.scope_name);
            try std.testing.expectEqualStrings("caller-version", data.scope_version);
            try std.testing.expectEqualStrings(&parent.trace_id, &data.context.trace_id);
            try std.testing.expectEqualStrings(&parent.span_id, &data.parent_span_id.?);
            var namespace_seen = false;
            for (data.attributes) |attribute| {
                if (attribute.value == .string and std.mem.eql(u8, attribute.value.string, "Caller.Attestation"))
                    namespace_seen = true;
            }
            try std.testing.expect(namespace_seen);
            self.ids[self.count] = data.context.span_id;
            self.statuses[self.count] = data.status;
            self.count += 1;
        }
    }
};

const FailingTracingProvider = struct {
    provider: core.tracing.TracerProvider = .{ .getTracerFn = getTracer },
    tracer: core.tracing.Tracer = .{ .startSpanFn = startSpan },
    attempts: usize = 0,

    fn getTracer(provider: *core.tracing.TracerProvider, _: []const u8, _: []const u8) *core.tracing.Tracer {
        const self: *FailingTracingProvider = @fieldParentPtr("provider", provider);
        return &self.tracer;
    }

    fn startSpan(tracer: *core.tracing.Tracer, _: []const u8, _: core.tracing.SpanKind) !*core.tracing.Span {
        const self: *FailingTracingProvider = @fieldParentPtr("tracer", tracer);
        self.attempts += 1;
        return error.InjectedTracingFailure;
    }
};

test "attestation automatic spans preserve parent scope and survive client teardown" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{\"token\":\"attestation-token\"}");
    defer mock.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime_value = core.http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
    var probe = TracingProbe{};
    var tracing = try probe.createProvider(runtime_value.crypto);
    defer tracing.deinit() catch unreachable;
    var ids: [2][16]u8 = undefined;
    {
        const scope = try allocator.dupe(u8, "caller.attestation");
        defer allocator.free(scope);
        const state = try allocator.dupe(u8, TracingProbe.parent.trace_state.?);
        defer allocator.free(state);
        var instrumentation = TracingProbe.options(&tracing);
        instrumentation.scope_name = scope;
        instrumentation.parent_context.?.trace_state = state;
        var credential = TestCredential{};
        var client = try AttestationClient.init(
            allocator,
            "https://myattestation.attest.azure.net",
            credential.asCredential(),
            .{ .runtime = runtime_value, .instrumentation = instrumentation },
        );
        defer client.deinit();

        const sgx = try client.attestSgxEnclave(allocator, "test-quote");
        defer sgx.deinit(allocator);
        try std.testing.expectEqualStrings("attestation-token", sgx.token.?);
        ids[0] = try TracingProbe.wireId(&mock);
        const open = try client.attestOpenEnclave(allocator, "test-report");
        defer open.deinit(allocator);
        try std.testing.expectEqualStrings("attestation-token", open.token.?);
        ids[1] = try TracingProbe.wireId(&mock);
        try std.testing.expectEqual(@as(usize, 2), mock.call_count);
        try std.testing.expectEqualStrings(attestation_scopes[0], credential.scope.?);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expectEqual(@as(usize, 0), tracing.stats().active_spans);
    try std.testing.expectEqual(@as(usize, 2), tracing.stats().queued_spans);
    try tracing.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    for (ids, 0..) |id, i| try std.testing.expectEqualStrings(&id, &probe.ids[i]);
    try std.testing.expect(!std.mem.eql(u8, &ids[0], &ids[1]));
    try tracing.shutdown(1000);
}

test "disabled or failing tracing preserves attestation responses and request counts" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |instrumented| {
        for ([_]u16{ 200, 403 }) |status| {
            var mock = core.http.MockTransport.init(allocator, status, "{\"token\":\"token\"}");
            defer mock.deinit();
            var crypto = TestCryptoProvider{};
            var credential = TestCredential{};
            var tracing = FailingTracingProvider{};
            var client = try AttestationClient.init(
                allocator,
                "https://myattestation.attest.azure.net",
                credential.asCredential(),
                .{
                    .runtime = .init(mock.asTransport(), crypto.asProvider()),
                    .instrumentation = if (instrumented) .{
                        .provider = &tracing.provider,
                        .scope_name = "caller.attestation",
                    } else null,
                },
            );
            defer client.deinit();
            if (status == 200) {
                const result = try client.attestSgxEnclave(allocator, "quote");
                defer result.deinit(allocator);
                try std.testing.expectEqualStrings("token", result.token.?);
            } else {
                try std.testing.expectError(error.AttestationFailed, client.attestSgxEnclave(allocator, "quote"));
            }
            try std.testing.expectEqual(@as(usize, 1), mock.call_count);
            try std.testing.expectEqual(@as(usize, @intFromBool(instrumented)), tracing.attempts);
            try std.testing.expect(mock.last_headers.get("traceparent") == null);
            try std.testing.expect(mock.last_headers.get("tracestate") == null);
        }
    }
}
