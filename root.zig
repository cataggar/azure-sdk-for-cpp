const std = @import("std");
const core = @import("azure_sdk_core");
const serde = @import("serde");

/// Microsoft Entra ID scope for the Azure App Configuration data plane.
pub const auth_scopes: []const []const u8 = &.{"https://azconfig.io/.default"};

// ─────────────────────────── Models ───────────────────────────

/// Pager type returned by `listSettings`.
///
/// The pager copies the client's pipeline while borrowing its policy,
/// transport, crypto-provider, and optional instrumentation contexts. Those
/// contexts must outlive the pager and every `next` call.
pub const SettingPager = core.pager.PipelinePager(ConfigurationSetting);

pub const ConfigurationSetting = struct {
    key: []const u8,
    value: ?[]const u8 = null,
    label: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,

    /// Free allocated value/label/content_type/etag/last_modified.
    /// `key` is NOT freed (borrows caller input).
    pub fn deinit(self: ConfigurationSetting, allocator: std.mem.Allocator) void {
        if (self.value) |v| allocator.free(v);
        if (self.label) |l| allocator.free(l);
        if (self.content_type) |c| allocator.free(c);
        if (self.etag) |e| allocator.free(e);
        if (self.last_modified) |lm| allocator.free(lm);
    }
};

// ─────────────────────── ConfigurationClient ──────────────────

pub const ConfigurationClientOptions = struct {
    api_version: []const u8 = "2023-11-01",
};

pub const ConfigurationClient = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,

    /// Constructs a client by copying `pipeline`.
    ///
    /// The endpoint and API version, the pipeline's policy pointers, and its
    /// runtime transport and crypto-provider contexts are borrowed. They must
    /// outlive this client, every pager derived from it, and all operations.
    /// Optional tracing provider/configuration strings have the same lifetime.
    pub fn init(
        endpoint: []const u8,
        pipeline: core.http.HttpPipeline,
        options: ConfigurationClientOptions,
    ) ConfigurationClient {
        return .{
            .endpoint = endpoint,
            .api_version = options.api_version,
            .pipeline = pipeline,
        };
    }

    /// GET /kv/{key}?label={label}&api-version=...
    pub fn getSetting(
        self: *ConfigurationClient,
        allocator: std.mem.Allocator,
        key: []const u8,
        label: ?[]const u8,
    ) !ConfigurationSetting {
        var r = try self.getSettingResult(allocator, key, label);
        return r.unwrap(error.SettingNotFound);
    }

    /// Same as `getSetting` but returns `Result(ConfigurationSetting)`.
    pub fn getSettingResult(
        self: *ConfigurationClient,
        allocator: std.mem.Allocator,
        key: []const u8,
        label: ?[]const u8,
    ) !core.errors.Result(ConfigurationSetting) {
        const url = if (label) |l|
            try std.fmt.allocPrint(
                allocator,
                "{s}/kv/{s}?label={s}&api-version={s}",
                .{ self.endpoint, key, l, self.api_version },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}/kv/{s}?api-version={s}",
                .{ self.endpoint, key, self.api_version },
            );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/vnd.microsoft.appconfig.kv+json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try parseSetting(allocator, key, resp.body) };
    }

    /// PUT /kv/{key}?api-version=...
    pub fn setSetting(
        self: *ConfigurationClient,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
        label: ?[]const u8,
    ) !ConfigurationSetting {
        var r = try self.setSettingResult(allocator, key, value, label);
        return r.unwrap(error.SetSettingFailed);
    }

    /// Same as `setSetting` but returns `Result(ConfigurationSetting)`.
    pub fn setSettingResult(
        self: *ConfigurationClient,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
        label: ?[]const u8,
    ) !core.errors.Result(ConfigurationSetting) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/kv/{s}?api-version={s}",
            .{ self.endpoint, key, self.api_version },
        );
        defer allocator.free(url);

        const body = if (label) |l|
            try std.fmt.allocPrint(allocator, "{{\"value\":\"{s}\",\"label\":\"{s}\"}}", .{ value, l })
        else
            try std.fmt.allocPrint(allocator, "{{\"value\":\"{s}\"}}", .{value});
        defer allocator.free(body);

        var req = core.http.Request.init(allocator, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/vnd.microsoft.appconfig.kv+json");
        try req.setHeader("Accept", "application/vnd.microsoft.appconfig.kv+json");
        req.body = body;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try parseSetting(allocator, key, resp.body) };
    }

    /// DELETE /kv/{key}?api-version=...
    pub fn deleteSetting(
        self: *ConfigurationClient,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !void {
        var r = try self.deleteSettingResult(allocator, key);
        try r.unwrap(error.DeleteSettingFailed);
    }

    /// Same as `deleteSetting` but returns `Result(void)`.
    pub fn deleteSettingResult(
        self: *ConfigurationClient,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/kv/{s}?api-version={s}",
            .{ self.endpoint, key, self.api_version },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// GET /kv?key={filter}&api-version=... — returns a pager over settings.
    ///
    /// Usage:
    ///   var pager = try client.listSettings(allocator, "app.*");
    ///   defer pager.deinit();
    ///   while (try pager.next()) |settings| {
    ///       defer allocator.free(settings);
    ///       for (settings) |s| { ... }
    ///   }
    pub fn listSettings(
        self: *ConfigurationClient,
        allocator: std.mem.Allocator,
        key_filter: ?[]const u8,
    ) !SettingPager {
        const url = if (key_filter) |f|
            try std.fmt.allocPrint(
                allocator,
                "{s}/kv?key={s}&api-version={s}",
                .{ self.endpoint, f, self.api_version },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}/kv?api-version={s}",
                .{ self.endpoint, self.api_version },
            );
        defer allocator.free(url);

        return SettingPager.init(
            self.pipeline,
            url,
            allocator,
            &parseSettingListPage,
            "application/vnd.microsoft.appconfig.kvset+json",
        );
    }
};

// ─────────────────────────── Parsing ──────────────────────────

const SettingSchema = struct {
    value: ?[]const u8 = null,
    label: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
};

fn parseSetting(allocator: std.mem.Allocator, key: []const u8, body: []const u8) !ConfigurationSetting {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(SettingSchema, arena.allocator(), body) catch
        return .{ .key = key };

    var setting = ConfigurationSetting{ .key = key };
    if (parsed.value) |v| setting.value = try allocator.dupe(u8, v);
    if (parsed.label) |v| setting.label = try allocator.dupe(u8, v);
    if (parsed.content_type) |v| setting.content_type = try allocator.dupe(u8, v);
    if (parsed.etag) |v| setting.etag = try allocator.dupe(u8, v);
    if (parsed.last_modified) |v| setting.last_modified = try allocator.dupe(u8, v);
    return setting;
}

const SettingListEntrySchema = struct {
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

const SettingListSchema = struct {
    items: ?[]const SettingListEntrySchema = null,
    @"@nextLink": ?[]const u8 = null,
};

fn parseSettingListPage(allocator: std.mem.Allocator, body: []const u8) !core.pager.PageResult(ConfigurationSetting) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(SettingListSchema, arena.allocator(), body) catch
        return .{ .items = try allocator.alloc(ConfigurationSetting, 0) };

    var next_link: ?[]u8 = null;
    if (parsed.@"@nextLink") |nl| {
        if (nl.len > 0) next_link = try allocator.dupe(u8, nl);
    }

    const entries = parsed.items orelse
        return .{ .items = try allocator.alloc(ConfigurationSetting, 0), .next_link = next_link };

    var result = try allocator.alloc(ConfigurationSetting, entries.len);
    for (entries, 0..) |entry, i| {
        var setting = ConfigurationSetting{ .key = "" };
        if (entry.key) |v| setting.key = try allocator.dupe(u8, v);
        if (entry.value) |v| setting.value = try allocator.dupe(u8, v);
        if (entry.label) |v| setting.label = try allocator.dupe(u8, v);
        result[i] = setting;
    }
    return .{ .items = result, .next_link = next_link };
}

// ─────────────────────────── Tests ────────────────────────────

const RoutingCryptoProvider = struct {
    calls: usize = 0,
    fail: bool = false,

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

    fn record(self: *@This()) !void {
        self.calls += 1;
        if (self.fail) return error.ProviderFailure;
    }

    fn randomBytes(context: *anyopaque, out: []u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        @memset(out, 0x5a);
        try self.record();
    }

    fn md5(
        _: *anyopaque,
        _: []const u8,
        _: *core.crypto.Md5Digest,
    ) !void {
        return error.UnexpectedCryptoOperation;
    }

    fn sha256(
        context: *anyopaque,
        _: []const u8,
        out: *core.crypto.Sha256Digest,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        @memset(out, 0x5a);
        try self.record();
    }

    fn hmacSha256(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: *core.crypto.HmacSha256Digest,
    ) !void {
        return error.UnexpectedCryptoOperation;
    }

    fn sha256Init(
        _: *anyopaque,
        _: std.mem.Allocator,
    ) !core.crypto.Sha256Operation {
        return error.UnexpectedCryptoOperation;
    }
};

const RuntimeCredential = struct {
    credential: core.credentials.TokenCredential = .{ .getTokenFn = &getToken },
    expected_transport_context: *anyopaque,
    expected_crypto_context: *anyopaque,
    calls: usize = 0,

    fn init(runtime: core.http.HttpRuntime) RuntimeCredential {
        return .{
            .expected_transport_context = runtime.transport.context,
            .expected_crypto_context = runtime.crypto.context,
        };
    }

    fn asCredential(self: *@This()) *core.credentials.TokenCredential {
        return &self.credential;
    }

    fn getToken(
        credential: *core.credentials.TokenCredential,
        request_context: core.credentials.TokenRequestContext,
        _: core.context.Context,
        runtime: core.http.HttpRuntime,
    ) anyerror!core.credentials.AccessToken {
        const self: *@This() = @alignCast(
            @fieldParentPtr("credential", credential),
        );
        self.calls += 1;
        if (runtime.transport.context != self.expected_transport_context)
            return error.TransportProviderNotPreserved;
        if (runtime.crypto.context != self.expected_crypto_context)
            return error.CryptoProviderNotPreserved;
        if (request_context.scopes.len != auth_scopes.len or
            !std.mem.eql(u8, request_context.scopes[0], auth_scopes[0]))
        {
            return error.UnexpectedAuthScope;
        }
        _ = try runtime.crypto.sha256("app-configuration-token");
        return .{
            .token = "test-token",
            .expires_on = std.math.maxInt(i64),
        };
    }
};

fn testPipeline(
    transport: core.http.HttpTransport,
    crypto_provider: core.crypto.CryptoProvider,
    policies: []*core.http.HttpPolicy,
) core.http.HttpPipeline {
    return core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(transport, crypto_provider),
        policies,
    );
}

test "ConfigurationClient bearer auth preserves the selected runtime" {
    const allocator = std.testing.allocator;
    const body =
        \\{"key":"mykey","value":"myvalue","label":"prod","etag":"etag-1","last_modified":"2025-01-01T00:00:00Z"}
    ;
    var mock = core.http.MockTransport.init(allocator, 200, body);
    defer mock.deinit();
    var crypto_provider = RoutingCryptoProvider{};
    const runtime = core.http.HttpRuntime.init(
        mock.asTransport(),
        crypto_provider.asProvider(),
    );
    var credential = RuntimeCredential.init(runtime);
    var auth_policy = core.http.BearerTokenAuthPolicy.init(
        allocator,
        credential.asCredential(),
        auth_scopes,
    );
    defer auth_policy.deinit();
    var policies = [_]*core.http.HttpPolicy{auth_policy.asPolicy()};

    var client = ConfigurationClient.init(
        "https://myconfig.azconfig.io",
        core.http.HttpPipeline.init(runtime, &policies),
        .{},
    );

    const setting = try client.getSetting(allocator, "mykey", "prod");
    defer allocator.free(setting.value.?);
    defer allocator.free(setting.label.?);
    defer allocator.free(setting.etag.?);
    defer allocator.free(setting.last_modified.?);

    try std.testing.expectEqualStrings("mykey", setting.key);
    try std.testing.expectEqualStrings("myvalue", setting.value.?);
    try std.testing.expectEqualStrings("prod", setting.label.?);
    try std.testing.expect(std.mem.find(u8, mock.last_url.?, "kv/mykey?label=prod") != null);
    try std.testing.expectEqualStrings("Bearer test-token", mock.last_headers.get("Authorization").?);
    try std.testing.expectEqual(@as(usize, 1), credential.calls);
    try std.testing.expectEqual(@as(usize, 1), crypto_provider.calls);
    try std.testing.expectEqual(
        runtime.transport.context,
        client.pipeline.runtime.transport.context,
    );
    try std.testing.expectEqual(
        runtime.crypto.context,
        client.pipeline.runtime.crypto.context,
    );
}

test "ConfigurationClient auth provider failure is atomic" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var crypto_provider = RoutingCryptoProvider{ .fail = true };
    const runtime = core.http.HttpRuntime.init(
        mock.asTransport(),
        crypto_provider.asProvider(),
    );
    var credential = RuntimeCredential.init(runtime);
    var auth_policy = core.http.BearerTokenAuthPolicy.init(
        allocator,
        credential.asCredential(),
        auth_scopes,
    );
    defer auth_policy.deinit();
    var policies = [_]*core.http.HttpPolicy{auth_policy.asPolicy()};
    var client = ConfigurationClient.init(
        "https://myconfig.azconfig.io",
        core.http.HttpPipeline.init(runtime, &policies),
        .{},
    );

    try std.testing.expectError(
        error.ProviderFailure,
        client.getSetting(allocator, "mykey", null),
    );
    try std.testing.expectEqual(@as(usize, 1), credential.calls);
    try std.testing.expectEqual(@as(usize, 1), crypto_provider.calls);
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
    try std.testing.expect(mock.last_headers.get("Authorization") == null);
}

test "ConfigurationClient setSetting" {
    const allocator = std.testing.allocator;
    var mock_set = core.http.MockTransport.init(allocator, 200,
        \\{"key":"app.color","value":"blue"}
    );
    defer mock_set.deinit();
    var crypto_provider = core.crypto.StdCryptoProvider.init(std.testing.io);

    var client = ConfigurationClient.init(
        "https://myconfig.azconfig.io",
        testPipeline(
            mock_set.asTransport(),
            crypto_provider.asProvider(),
            &.{},
        ),
        .{},
    );

    const setting = try client.setSetting(allocator, "app.color", "blue", null);
    defer allocator.free(setting.value.?);

    try std.testing.expectEqualStrings("blue", setting.value.?);
    try std.testing.expectEqual(core.http.Method.PUT, mock_set.last_method.?);
}

test "SettingPager preserves runtime and propagates provider failure" {
    const allocator = std.testing.allocator;
    var mock_list = core.http.MockTransport.init(allocator, 200,
        \\{"items":[{"key":"app.color","value":"blue"},{"key":"app.size","value":"large"}],"@nextLink":"https://myconfig.azconfig.io/kv?after=2"}
    );
    defer mock_list.deinit();
    var crypto_provider = RoutingCryptoProvider{};
    var request_id_policy = core.http.RequestIdPolicy.init();
    var policies = [_]*core.http.HttpPolicy{request_id_policy.asPolicy()};
    const pipeline = testPipeline(
        mock_list.asTransport(),
        crypto_provider.asProvider(),
        &policies,
    );
    var client = ConfigurationClient.init(
        "https://myconfig.azconfig.io",
        pipeline,
        .{},
    );

    var pager = try client.listSettings(allocator, "app.*");
    defer pager.deinit();
    try std.testing.expectEqual(
        pipeline.runtime.transport.context,
        pager.pipeline.runtime.transport.context,
    );
    try std.testing.expectEqual(
        pipeline.runtime.crypto.context,
        pager.pipeline.runtime.crypto.context,
    );

    const settings = (try pager.next()) orelse return error.ExpectedPage;
    defer {
        for (settings) |s| {
            if (s.key.len > 0) allocator.free(s.key);
            if (s.value) |v| allocator.free(v);
        }
        allocator.free(settings);
    }

    try std.testing.expectEqual(@as(usize, 2), settings.len);
    try std.testing.expectEqualStrings("app.color", settings[0].key);
    try std.testing.expectEqual(@as(usize, 1), crypto_provider.calls);
    try std.testing.expectEqual(@as(usize, 1), mock_list.call_count);
    try std.testing.expect(mock_list.last_headers.get("x-ms-client-request-id") != null);

    crypto_provider.fail = true;
    try std.testing.expectError(error.ProviderFailure, pager.next());
    try std.testing.expectEqual(@as(usize, 2), crypto_provider.calls);
    try std.testing.expectEqual(@as(usize, 1), mock_list.call_count);
}

const TracingProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = &exportBatch },
    span_ids: [8][16]u8 = undefined,
    dispatched: usize = 0,
    exported: usize = 0,

    fn capture(self: *TracingProbe, transport: *core.http.MockTransport, enabled: bool) !void {
        const traceparent = transport.last_headers.get("traceparent");
        const tracestate = transport.last_headers.get("tracestate");
        if (enabled) {
            const context = core.tracing.TraceContext.parseTraceparent(traceparent orelse return error.MissingTraceparent) orelse
                return error.InvalidTraceparent;
            try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &context.trace_id);
            try std.testing.expectEqualStrings("vendor=value", tracestate orelse "");
            try std.testing.expect(!std.mem.eql(u8, "b7ad6b7169203331", &context.span_id));
            for (self.span_ids[0..self.dispatched]) |previous|
                try std.testing.expect(!std.mem.eql(u8, &previous, &context.span_id));
            self.span_ids[self.dispatched] = context.span_id;
        } else {
            try std.testing.expect(traceparent == null and tracestate == null);
        }
        self.dispatched += 1;
    }

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *TracingProbe = @fieldParentPtr("exporter", exporter);
        for (batch) |span| {
            try std.testing.expect(self.exported < self.dispatched);
            try std.testing.expectEqualStrings("caller.scope", span.scope_name);
            try std.testing.expectEqualStrings("caller-version", span.scope_version);
            try std.testing.expectEqual(core.tracing.SpanKind.client, span.kind);
            try std.testing.expectEqualStrings("b7ad6b7169203331", &span.parent_span_id.?);
            try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &span.context.trace_id);
            try std.testing.expectEqualStrings("vendor=value", span.context.trace_state orelse "");
            try std.testing.expectEqualStrings(&self.span_ids[self.exported], &span.context.span_id);
            var namespace_seen = false;
            for (span.attributes) |attribute| {
                if (!std.mem.eql(u8, "az.namespace", attribute.key)) continue;
                try std.testing.expect(attribute.value == .string);
                try std.testing.expectEqualStrings("Caller.Namespace", attribute.value.string);
                namespace_seen = true;
            }
            try std.testing.expect(namespace_seen);
            self.exported += 1;
        }
    }
};

test "caller tracing survives ConfigurationClient and multi-page pager copies, or stays disabled" {
    for ([_]bool{ true, false }) |enabled| {
        const allocator = std.testing.allocator;
        var transport = core.http.MockTransport.init(allocator, 200,
            \\{"key":"app.color","value":"blue"}
        );
        defer transport.deinit();
        var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
        const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
        var probe = TracingProbe{};
        var provider = try core.tracing.ExportingTracerProvider.init(
            allocator,
            std.testing.io,
            runtime.crypto,
            &probe.exporter,
            .{},
        );
        defer provider.deinit() catch unreachable;
        var pipeline = core.http.HttpPipeline.init(runtime, &.{});
        var parent = core.tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
        parent.trace_state = "vendor=value";
        if (enabled) pipeline.setInstrumentation(.{
            .provider = provider.asProvider(),
            .scope_name = "caller.scope",
            .scope_version = "caller-version",
            .namespace = "Caller.Namespace",
            .parent_context = parent,
        });
        var client = ConfigurationClient.init("https://configuration.azconfig.io", pipeline, .{});
        pipeline.setInstrumentation(null);
        const setting = try client.getSetting(allocator, "app.color", null);
        defer setting.deinit(allocator);
        try std.testing.expectEqualStrings("blue", setting.value.?);
        try probe.capture(&transport, enabled);

        var pager = try client.listSettings(allocator, "app.*");
        defer pager.deinit();
        client.pipeline.setInstrumentation(null);
        for (0..2) |index| {
            transport.response_body = if (index == 0)
                \\{"items":[{"key":"app.color","value":"blue"}],"@nextLink":"https://configuration.azconfig.io/kv?after=1"}
            else
                \\{"items":[{"key":"app.size","value":"large"}]}
            ;
            const page = (try pager.next()) orelse return error.ExpectedPage;
            defer {
                for (page) |entry| {
                    allocator.free(entry.key);
                    entry.deinit(allocator);
                }
                allocator.free(page);
            }
            try std.testing.expectEqual(@as(usize, 1), page.len);
            try std.testing.expectEqualStrings(if (index == 0) "app.color" else "app.size", page[0].key);
            try probe.capture(&transport, enabled);
        }
        try std.testing.expect((try pager.next()) == null);
        const expected: usize = if (enabled) 3 else 0;
        try std.testing.expectEqual(@as(usize, 3), transport.call_count);
        try std.testing.expectEqual(@as(usize, 0), probe.exported);
        try std.testing.expectEqual(expected, provider.stats().queued_spans);
        try std.testing.expectEqual(@as(usize, 0), provider.stats().active_spans);
        try std.testing.expect(!provider.closed);
        try provider.forceFlush(1000);
        try std.testing.expectEqual(expected, probe.exported);
        try std.testing.expectEqual(@as(u64, expected), provider.stats().started);
        try std.testing.expectEqual(@as(u64, expected), provider.stats().ended);
        try provider.shutdown(1000);
    }
}
