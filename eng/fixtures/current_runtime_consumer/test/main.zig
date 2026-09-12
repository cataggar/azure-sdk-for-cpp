const std = @import("std");
const core = @import("azure_sdk_core");
const http_conformance = @import("azure_sdk_core_http_conformance");
const crypto_conformance = @import("azure_sdk_core_crypto_conformance");

test "current immutable Core composes the canonical runtime and pipeline" {
    try std.testing.expectEqualStrings("0.4.0", core.version);
    var transport = core.http.MockTransport.init(std.testing.allocator, 200, "runtime");
    defer transport.deinit();
    var provider = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), provider.asProvider());
    var pipeline = core.http.HttpPipeline.init(runtime, &.{});
    try std.testing.expectEqual(runtime.transport.context, pipeline.runtime.transport.context);
    try std.testing.expectEqual(runtime.crypto.context, pipeline.runtime.crypto.context);

    var request = core.http.Request.init(std.testing.allocator, .GET, "https://example.test/");
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqualStrings("runtime", response.body);
    try std.testing.expect(request.getHeader("traceparent") == null);
}

test "published standard HTTP backend runs raw and pipeline contracts" {
    const factory = http_conformance.standardBackendFactory();
    try http_conformance.runRawTransportContracts(std.testing.allocator, std.testing.io, factory);
    try http_conformance.runPipelineContracts(std.testing.allocator, std.testing.io, factory);
    try http_conformance.runBackendAllocationFailureContracts(std.testing.allocator, std.testing.io, factory);
}

test "published mock HTTP backend runs raw transport contracts" {
    try http_conformance.runRawTransportContracts(
        std.testing.allocator,
        std.testing.io,
        http_conformance.mockBackendFactory(),
    );
}

test "published standard SDK crypto provider runs its contracts" {
    try crypto_conformance.runCryptoContracts(
        std.testing.allocator,
        std.testing.io,
        crypto_conformance.standardProviderFactory(),
    );
}

test "published request headers copy inputs and transfer explicit ownership" {
    var headers = core.http.RequestHeaders.init(std.testing.allocator);
    defer headers.deinit();
    var value = "owned".*;
    try headers.put("X-Example", &value);
    value[0] = 'X';
    try std.testing.expectEqualStrings("owned", headers.get("x-example").?);

    var copy = try headers.clone(std.testing.allocator);
    defer copy.deinit();
    var taken = headers.take("X-EXAMPLE").?;
    defer taken.deinit();
    try std.testing.expectEqual(@as(u32, 0), headers.count());
    try std.testing.expectEqualStrings("X-Example", taken.name);
    try std.testing.expectEqualStrings("owned", taken.value);
    try std.testing.expectEqualStrings("owned", copy.get("x-example").?);
}

const TraceExport = struct {
    resourceSpans: []const struct {
        scopeSpans: []const struct {
            scope: struct {
                name: []const u8,
                version: []const u8,
            },
            spans: []const struct {
                traceId: []const u8,
                spanId: []const u8,
                parentSpanId: []const u8,
                name: []const u8,
                kind: u8,
            },
        },
    },
};

test "published tracing propagates a child and explicitly exports owned OTLP data" {
    const parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    var transport = core.http.MockTransport.init(std.testing.allocator, 200, "response");
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
    var output: [64 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    var scratch: [64 * 1024]u8 = undefined;
    var exporter = core.tracing.OtlpJsonWriterExporter.init(&writer, &scratch);
    var provider = try core.tracing.ExportingTracerProvider.init(
        std.testing.allocator,
        std.testing.io,
        runtime.crypto,
        exporter.asExporter(),
        .{ .service_name = "immutable-consumer", .max_batch_size = 1 },
    );
    defer provider.deinit() catch unreachable;
    var pipeline = core.http.HttpPipeline.init(runtime, &.{});
    pipeline.setInstrumentation(.{
        .provider = provider.asProvider(),
        .scope_name = "current_runtime_consumer",
        .scope_version = "0.0.0",
        .namespace = "Microsoft.Storage",
    });
    {
        var request = core.http.Request.init(
            std.testing.allocator,
            .GET,
            "https://fixture.test/private-path?sig=not-exported",
        );
        defer request.deinit();
        try request.setHeader("TraceParent", parent);
        try request.setHeader("TraceState", "vendor=fixture");
        var response = try pipeline.send(&request);
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status_code);
        try std.testing.expectEqualStrings("response", response.body);
        try std.testing.expectEqualStrings(parent, request.getHeader("traceparent").?);
        try std.testing.expectEqualStrings("vendor=fixture", request.getHeader("tracestate").?);
    }

    const wire_parent = transport.last_headers.get("traceparent").?;
    try std.testing.expect(core.tracing.TraceContext.parseTraceparent(wire_parent) != null);
    try std.testing.expectEqualStrings(parent[3..35], wire_parent[3..35]);
    try std.testing.expect(!std.mem.eql(u8, parent[36..52], wire_parent[36..52]));
    try std.testing.expectEqualStrings("vendor=fixture", transport.last_headers.get("tracestate").?);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try provider.forceFlush(1000);
    try provider.shutdown(1000);

    const parsed = try std.json.parseFromSlice(
        TraceExport,
        std.testing.allocator,
        writer.buffered(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.resourceSpans.len);
    const scopes = parsed.value.resourceSpans[0].scopeSpans;
    try std.testing.expectEqual(@as(usize, 1), scopes.len);
    try std.testing.expectEqualStrings("current_runtime_consumer", scopes[0].scope.name);
    try std.testing.expectEqualStrings("0.0.0", scopes[0].scope.version);
    try std.testing.expectEqual(@as(usize, 1), scopes[0].spans.len);
    const span = scopes[0].spans[0];
    try std.testing.expectEqualStrings(wire_parent[3..35], span.traceId);
    try std.testing.expectEqualStrings(wire_parent[36..52], span.spanId);
    try std.testing.expectEqualStrings(parent[36..52], span.parentSpanId);
    try std.testing.expectEqualStrings("HTTP", span.name);
    try std.testing.expectEqual(@as(u8, 3), span.kind);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "private-path") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "not-exported") == null);
}
