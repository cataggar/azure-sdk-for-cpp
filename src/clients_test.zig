//! Tests for the generated `clients.zig`.
//!
//! Kept in a separate file so the emitter can overwrite
//! `clients.zig` without losing test coverage. Wired into the
//! package's test step via `root.zig`.
//!
//! This file is **operator-owned**: `codegen/scripts/sync.sh`
//! marks it as operator-managed and never overwrites an
//! existing copy. Add tests freely.

const std = @import("std");
const core = @import("azure_sdk_core");
const clients = @import("clients.zig");

const SpanProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = exportBatch },
    transport: *core.http.MockTransport,
    count: usize = 0,

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *@This() = @fieldParentPtr("exporter", exporter);
        for (batch) |span| {
            const wire = core.tracing.TraceContext.parseTraceparent(self.transport.last_headers.get("traceparent").?).?;
            try std.testing.expectEqualStrings("caller.avs", span.scope_name);
            try std.testing.expectEqualStrings("caller-version", span.scope_version);
            try std.testing.expectEqualStrings("HTTP", span.name);
            try std.testing.expectEqual(core.tracing.SpanKind.client, span.kind);
            try std.testing.expectEqual(core.tracing.SpanStatus.unset, span.status);
            try std.testing.expectEqualStrings("b7ad6b7169203331", &span.parent_span_id.?);
            try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &span.context.trace_id);
            try std.testing.expectEqualStrings(&wire.span_id, &span.context.span_id);
            var namespace = false;
            var status = false;
            for (span.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.key, "az.namespace")) {
                    try std.testing.expectEqualStrings("Caller.Namespace", attribute.value.string);
                    namespace = true;
                }
                if (std.mem.eql(u8, attribute.key, "http.response.status_code")) {
                    try std.testing.expectEqual(@as(i64, 204), attribute.value.int);
                    status = true;
                }
            }
            try std.testing.expect(namespace and status);
            self.count += 1;
        }
    }
};

fn expectDescendantPipelines(client: *clients.AVSClient, expected: core.http.HttpPipeline) !void {
    try std.testing.expectEqualDeep(expected, client.pipeline);
    var count: usize = 0;
    inline for (comptime std.meta.declarations(clients.AVSClient)) |decl| {
        const accessor = @field(clients.AVSClient, decl.name);
        const info = @typeInfo(@TypeOf(accessor));
        if (info == .@"fn" and info.@"fn".params.len == 1 and
            info.@"fn".params[0].type == *clients.AVSClient)
        {
            const Result = info.@"fn".return_type.?;
            if (@typeInfo(Result) == .@"struct" and @hasField(Result, "pipeline")) {
                const child = @call(.auto, accessor, .{client});
                try std.testing.expectEqualDeep(expected, child.pipeline);
                try std.testing.expectEqualStrings(client.endpoint, child.endpoint);
                try std.testing.expectEqualStrings(client.api_version, child.api_version);
                if (@hasField(Result, "subscription_id"))
                    try std.testing.expectEqualStrings(client.subscription_id, child.subscription_id);
                count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 24), count);
}

test "AVS constructor and all subgroups retain optional tracing with real automatic spans" {
    const Mode = enum { default, enabled, disabled };
    for ([_]Mode{ .default, .enabled, .disabled }) |mode| {
        var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
        var mock = core.http.MockTransport.init(std.testing.allocator, 204, "");
        defer mock.deinit();
        const runtime = core.http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
        var probe: SpanProbe = .{ .transport = &mock };
        var provider = try core.tracing.ExportingTracerProvider.init(
            std.testing.allocator,
            std.testing.io,
            runtime.crypto,
            &probe.exporter,
            .{},
        );
        defer provider.deinit() catch unreachable;
        var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_arm_avs/0.3.0");
        var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
        var pipeline = core.http.HttpPipeline.init(runtime, &policies);
        try std.testing.expect(pipeline.instrumentation == null);
        var parent = core.tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
        parent.trace_state = "vendor=caller";
        if (mode != .default) pipeline.setInstrumentation(.{
            .provider = provider.asProvider(),
            .scope_name = "caller.avs",
            .scope_version = "caller-version",
            .namespace = "Caller.Namespace",
            .parent_context = parent,
        });
        if (mode == .disabled) pipeline.setInstrumentation(null);
        var client = clients.AVSClient.init(pipeline, .{ .subscription_id = "subscription" });
        try expectDescendantPipelines(&client, pipeline);
        pipeline.setInstrumentation(null);
        var sites = client.hcxEnterpriseSites();
        try sites.delete(std.testing.allocator, "group", "cloud", "site");
        try std.testing.expectEqual(@as(usize, 1), mock.call_count);
        try std.testing.expectEqual(core.http.Method.DELETE, mock.last_method.?);
        try std.testing.expectEqualStrings(
            "https://management.azure.com/subscriptions/subscription/resourceGroups/group/providers/Microsoft.AVS/privateClouds/cloud/hcxEnterpriseSites/site?api-version=2025-09-01",
            mock.last_url.?,
        );
        try std.testing.expectEqualStrings("azsdk-zig-azure_rest_arm_avs/0.3.0", mock.last_headers.get("User-Agent").?);
        try std.testing.expectEqual(mode == .enabled, mock.last_headers.contains("traceparent"));
        if (mode == .enabled) {
            try std.testing.expectEqualStrings("vendor=caller", mock.last_headers.get("tracestate").?);
        } else {
            try std.testing.expect(!mock.last_headers.contains("tracestate"));
        }
        const expected: u64 = if (mode == .enabled) 1 else 0;
        try std.testing.expectEqual(expected, provider.stats().started);
        try std.testing.expectEqual(expected, provider.stats().ended);
        try std.testing.expectEqual(@as(usize, 0), provider.stats().active_spans);
        try std.testing.expectEqual(@as(usize, 0), probe.count);
        try std.testing.expect(!provider.closed);
        try provider.forceFlush(1000);
        try std.testing.expectEqual(@as(usize, @intCast(expected)), probe.count);
        try provider.shutdown(1000);
    }
}
