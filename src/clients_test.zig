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
            try std.testing.expectEqualStrings("caller.keyvault", span.scope_name);
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
                try std.testing.expect(!std.mem.eql(u8, attribute.key, "url.full"));
                if (attribute.value == .string)
                    try std.testing.expect(std.mem.indexOf(u8, attribute.value.string, "sensitive-secret-name") == null);
            }
            try std.testing.expect(namespace and status);
            self.count += 1;
        }
    }
};

test "Key Vault preserves optional caller instrumentation and automatically traces a real request" {
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
        var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_keyvault_secrets/0.3.0");
        var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
        var pipeline = core.http.HttpPipeline.init(runtime, &policies);
        try std.testing.expect(pipeline.instrumentation == null);
        var parent = core.tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
        parent.trace_state = "vendor=caller";
        if (mode != .default) pipeline.setInstrumentation(.{
            .provider = provider.asProvider(),
            .scope_name = "caller.keyvault",
            .scope_version = "caller-version",
            .namespace = "Caller.Namespace",
            .parent_context = parent,
        });
        if (mode == .disabled) pipeline.setInstrumentation(null);
        var client = clients.KeyVaultClient.init(pipeline, .{ .endpoint = "https://vault.example" });
        try std.testing.expectEqualDeep(pipeline, client.pipeline);
        pipeline.setInstrumentation(null);
        try client.purgeDeletedSecret(std.testing.allocator, "sensitive-secret-name");
        try std.testing.expectEqual(@as(usize, 1), mock.call_count);
        try std.testing.expectEqual(core.http.Method.DELETE, mock.last_method.?);
        try std.testing.expectEqualStrings(
            "https://vault.example/deletedsecrets/sensitive-secret-name?api-version=2026-03-01-preview",
            mock.last_url.?,
        );
        try std.testing.expectEqualStrings("azsdk-zig-azure_rest_keyvault_secrets/0.3.0", mock.last_headers.get("User-Agent").?);
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
