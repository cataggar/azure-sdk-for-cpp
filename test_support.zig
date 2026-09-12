const std = @import("std");
const core = @import("azure_sdk_core");

var standard_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);

pub fn runtime(transport: core.http.HttpTransport) core.http.HttpRuntime {
    return .init(transport, standard_crypto.asProvider());
}

pub const StaticCredential = struct {
    credential: core.credentials.TokenCredential = .{ .getTokenFn = &getToken },
    calls: usize = 0,
    last_scope: ?[]const u8 = null,

    pub fn asCredential(self: *StaticCredential) *core.credentials.TokenCredential {
        return &self.credential;
    }

    fn getToken(
        credential: *core.credentials.TokenCredential,
        request_context: core.credentials.TokenRequestContext,
        _: core.context.Context,
        _: core.http.HttpRuntime,
    ) !core.credentials.AccessToken {
        const self: *StaticCredential = @alignCast(
            @fieldParentPtr("credential", credential),
        );
        self.calls += 1;
        self.last_scope = if (request_context.scopes.len == 0)
            null
        else
            request_context.scopes[0];
        return .{
            .token = "test-token",
            .expires_on = 7_258_118_400,
        };
    }
};

pub const TracingProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = exportBatch },
    count: usize = 0,
    ids: [8][16]u8 = undefined,
    statuses: [8]core.tracing.SpanStatus = undefined,

    pub const parent: core.tracing.TraceContext = .{
        .trace_id = "0af7651916cd43dd8448eb211c80319c".*,
        .span_id = "b7ad6b7169203331".*,
        .trace_flags = 1,
        .trace_state = "vendor=value",
    };

    pub fn createProvider(self: *TracingProbe) !core.tracing.ExportingTracerProvider {
        return .init(std.testing.allocator, std.testing.io, standard_crypto.asProvider(), &self.exporter, .{
            .max_spans = 8,
            .max_queued_spans = 8,
        });
    }

    pub fn options(provider: *core.tracing.ExportingTracerProvider) core.tracing.InstrumentationOptions {
        return .{
            .provider = provider.asProvider(),
            .scope_name = "caller.keyvault",
            .scope_version = "caller-version",
            .namespace = "Caller.KeyVault",
            .parent_context = parent,
        };
    }

    pub fn wireId(mock: *core.http.MockTransport) ![16]u8 {
        const context = core.tracing.TraceContext.parseTraceparent(
            mock.last_headers.get("traceparent") orelse return error.MissingTraceparent,
        ) orelse return error.InvalidTraceparent;
        try std.testing.expectEqualStrings(&parent.trace_id, &context.trace_id);
        try std.testing.expect(!std.mem.eql(u8, &parent.span_id, &context.span_id));
        try std.testing.expectEqualStrings(parent.trace_state.?, mock.last_headers.get("tracestate").?);
        return context.span_id;
    }

    pub fn expectSingleSpan(self: *TracingProbe, provider: *core.tracing.ExportingTracerProvider, mock: *core.http.MockTransport) !void {
        const id = try wireId(mock);
        try std.testing.expectEqual(@as(usize, 1), mock.call_count);
        try std.testing.expectEqual(@as(usize, 0), self.count);
        try provider.forceFlush(1000);
        try std.testing.expectEqual(@as(usize, 1), self.count);
        try std.testing.expectEqualStrings(&id, &self.ids[0]);
    }

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *TracingProbe = @fieldParentPtr("exporter", exporter);
        for (batch) |data| {
            try std.testing.expect(self.count < self.ids.len);
            try std.testing.expectEqualStrings("caller.keyvault", data.scope_name);
            try std.testing.expectEqualStrings("caller-version", data.scope_version);
            try std.testing.expectEqualStrings(&parent.trace_id, &data.context.trace_id);
            try std.testing.expectEqualStrings(&parent.span_id, &data.parent_span_id.?);
            var namespace_seen = false;
            for (data.attributes) |attribute| {
                if (attribute.value == .string and std.mem.eql(u8, attribute.value.string, "Caller.KeyVault"))
                    namespace_seen = true;
            }
            try std.testing.expect(namespace_seen);
            self.ids[self.count] = data.context.span_id;
            self.statuses[self.count] = data.status;
            self.count += 1;
        }
    }
};

pub const FailingTracingProvider = struct {
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
