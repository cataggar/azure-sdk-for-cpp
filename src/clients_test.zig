const std = @import("std");
const core = @import("azure_sdk_core");
const clients = @import("clients.zig");
const models = @import("models.zig");

test "all fourteen stable Tables operations are directly accessible" {
    try expectPublicMethods(clients.TablesClient, &.{ "table", "service" });
    try expectPublicMethods(clients.Table, &.{
        "query",
        "create",
        "delete",
        "queryEntities",
        "queryEntityWithPartitionAndRowKey",
        "updateEntity",
        "mergeEntity",
        "deleteEntity",
        "insertEntity",
        "getAccessPolicy",
        "setAccessPolicy",
    });
    try expectPublicMethods(clients.Service, &.{
        "setProperties",
        "getProperties",
        "getStatistics",
    });
    try std.testing.expect(@hasDecl(models, "TableServiceProperties"));
    try std.testing.expect(@hasDecl(models, "TableServiceStats"));
}

fn expectPublicMethods(comptime Client: type, comptime methods: []const []const u8) !void {
    inline for (methods) |method| {
        try std.testing.expect(@hasDecl(Client, method));
    }
}

const tracing_user_agent = "azsdk-zig-azure_rest_data_tables/0.2.0";
const tracing_parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";

const TraceProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = exportBatch },
    traced: bool,
    fail_transport: bool,
    calls: usize = 0,
    exported: usize = 0,
    wire_context: ?core.tracing.TraceContext = null,

    fn asTransport(self: *@This()) core.http.HttpTransport {
        return .{ .context = self, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: *core.http.Request) !core.http.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        try std.testing.expectEqual(core.http.Method.DELETE, request.method);
        try std.testing.expectEqualStrings(tracing_user_agent, request.getHeader("User-Agent").?);
        try std.testing.expectEqual(self.traced, request.getHeader("traceparent") != null);
        if (self.traced) {
            self.wire_context = core.tracing.TraceContext.parseTraceparent(request.getHeader("traceparent").?).?;
            try std.testing.expectEqualStrings("vendor=caller", request.getHeader("tracestate").?);
        } else {
            try std.testing.expect(request.getHeader("tracestate") == null);
        }
        if (self.fail_transport) return error.TestTransportFailure;
        var headers = core.http.ResponseHeaders.init(std.testing.allocator);
        errdefer headers.deinit();
        try headers.append("x-ms-version", "2019-02-02");
        try headers.append("Date", "Sat, 12 Sep 2026 00:00:00 GMT");
        return .{
            .status_code = 204,
            .headers = std.StringHashMap([]const u8).init(std.testing.allocator),
            .response_headers = headers,
            .body = try std.testing.allocator.alloc(u8, 0),
            .allocator = std.testing.allocator,
        };
    }

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *@This() = @fieldParentPtr("exporter", exporter);
        for (batch) |span| {
            try std.testing.expectEqualStrings("caller.scope", span.scope_name);
            try std.testing.expectEqualStrings("caller-version", span.scope_version);
            try std.testing.expectEqualStrings("HTTP", span.name);
            try std.testing.expectEqual(core.tracing.SpanKind.client, span.kind);
            try std.testing.expectEqual(if (self.fail_transport) core.tracing.SpanStatus.@"error" else .unset, span.status);
            try std.testing.expectEqualStrings("b7ad6b7169203331", &span.parent_span_id.?);
            try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &span.context.trace_id);
            try std.testing.expectEqualStrings(&self.wire_context.?.span_id, &span.context.span_id);
            var namespace = false;
            var method = false;
            var outcome = false;
            for (span.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.key, "az.namespace")) {
                    try std.testing.expectEqualStrings("Caller.Namespace", attribute.value.string);
                    namespace = true;
                }
                if (std.mem.eql(u8, attribute.key, "http.request.method")) {
                    try std.testing.expectEqualStrings("DELETE", attribute.value.string);
                    method = true;
                }
                if (std.mem.eql(u8, attribute.key, "http.response.status_code")) {
                    try std.testing.expect(!self.fail_transport);
                    try std.testing.expectEqual(@as(i64, 204), attribute.value.int);
                    outcome = true;
                }
                if (std.mem.eql(u8, attribute.key, "error.type")) {
                    try std.testing.expect(self.fail_transport);
                    try std.testing.expectEqualStrings("TestTransportFailure", attribute.value.string);
                    outcome = true;
                }
                try std.testing.expect(!std.mem.eql(u8, attribute.key, "url.full"));
            }
            try std.testing.expect(namespace and method and outcome);
            self.exported += 1;
        }
    }
};

fn expectPipelineCopies(comptime Client: type, client: *Client, expected: core.http.HttpPipeline) !usize {
    try std.testing.expectEqualDeep(expected, client.pipeline);
    var descendants: usize = 0;
    inline for (comptime std.meta.declarations(Client)) |decl| {
        const method = @field(Client, decl.name);
        const info = @typeInfo(@TypeOf(method));
        if (info == .@"fn" and info.@"fn".params.len == 1 and
            info.@"fn".params[0].type == *Client)
        {
            const Result = info.@"fn".return_type.?;
            if (@typeInfo(Result) == .@"struct" and @hasField(Result, "pipeline")) {
                var child = @call(.auto, method, .{client});
                try std.testing.expectEqualStrings(client.endpoint, child.endpoint);
                try std.testing.expectEqualStrings(client.api_version, child.api_version);
                descendants += 1 + try expectPipelineCopies(Result, &child, expected);
            }
        }
    }
    return descendants;
}

fn tracedOperation(client: *clients.TablesClient) !void {
    var table = client.table();
    const result = try table.delete(std.testing.allocator, null, "example");
    const headers = result.status_204.headers;
    defer std.testing.allocator.free(headers.api_version);
    defer std.testing.allocator.free(headers.date);
    defer if (headers.request_id) |value| std.testing.allocator.free(value);
    defer if (headers.client_request_id) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("2019-02-02", headers.api_version);
}

test "caller pipeline instrumentation survives constructors and descendants with real automatic spans" {
    const Mode = enum { default, enabled, disabled, transport_error };
    for ([_]Mode{ .default, .enabled, .disabled, .transport_error }) |mode| {
        var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
        var probe: TraceProbe = .{
            .traced = mode == .enabled or mode == .transport_error,
            .fail_transport = mode == .transport_error,
        };
        const runtime = core.http.HttpRuntime.init(probe.asTransport(), crypto.asProvider());
        var provider = try core.tracing.ExportingTracerProvider.init(
            std.testing.allocator,
            std.testing.io,
            runtime.crypto,
            &probe.exporter,
            .{},
        );
        defer provider.deinit() catch unreachable;
        var telemetry = core.http.TelemetryPolicy.init(tracing_user_agent);
        var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
        var pipeline = core.http.HttpPipeline.init(runtime, &policies);
        try std.testing.expect(pipeline.instrumentation == null);
        var parent = core.tracing.TraceContext.parseTraceparent(tracing_parent).?;
        parent.trace_state = "vendor=caller";
        if (mode != .default) pipeline.setInstrumentation(.{
            .provider = provider.asProvider(),
            .scope_name = "caller.scope",
            .scope_version = "caller-version",
            .namespace = "Caller.Namespace",
            .parent_context = parent,
        });
        if (mode == .disabled) pipeline.setInstrumentation(null);
        var client = clients.TablesClient.init(pipeline, .{ .endpoint = "https://service.example" });
        try std.testing.expectEqual(@as(usize, 2), try expectPipelineCopies(clients.TablesClient, &client, pipeline));
        // Clients hold a value copy; changing the caller's pipeline must not reconfigure it.
        pipeline.setInstrumentation(null);
        if (probe.fail_transport) {
            try std.testing.expectError(error.TestTransportFailure, tracedOperation(&client));
        } else {
            try tracedOperation(&client);
        }
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        const expected: u64 = if (probe.traced) 1 else 0;
        try std.testing.expectEqual(expected, provider.stats().started);
        try std.testing.expectEqual(expected, provider.stats().ended);
        try std.testing.expectEqual(@as(usize, 0), provider.stats().active_spans);
        try std.testing.expectEqual(@as(usize, 0), probe.exported);
        try std.testing.expect(!provider.closed);
        // Only the caller exports and shuts down, after generated request storage is gone.
        try provider.forceFlush(1000);
        try std.testing.expectEqual(@as(usize, @intCast(expected)), probe.exported);
        try provider.shutdown(1000);
    }
}
