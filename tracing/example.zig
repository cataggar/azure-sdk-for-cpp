const std = @import("std");
const http = @import("../http.zig");
const tracing = @import("root.zig");
const crypto = @import("../crypto.zig");

/// A Core-only composition example; service packages pass the same configured
/// pipeline to their existing client constructor instead of calling send here.
pub fn writeExample(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer) !void {
    var mock = http.MockTransport.init(allocator, 200, "fixture response");
    defer mock.deinit();
    var crypto_provider = crypto.StdCryptoProvider.init(io);
    const runtime = http.HttpRuntime.init(mock.asTransport(), crypto_provider.asProvider());
    var scratch: [64 * 1024]u8 = undefined;
    var exporter = tracing.OtlpJsonWriterExporter.init(writer, &scratch);
    var provider = try tracing.ExportingTracerProvider.init(
        allocator,
        io,
        runtime.crypto,
        exporter.asExporter(),
        .{ .service_name = "my-application", .max_batch_size = 1 },
    );
    defer provider.deinit() catch unreachable;
    var pipeline = http.HttpPipeline.init(runtime, &.{});
    pipeline.setInstrumentation(.{
        .provider = provider.asProvider(),
        .scope_name = "azure_sdk_example",
        .scope_version = "0.3.0",
        .namespace = "Microsoft.Storage",
    });
    {
        var request = http.Request.init(allocator, .GET, "https://fixture.test/container?sig=not-exported");
        defer request.deinit();
        var response = try pipeline.send(&request);
        defer response.deinit();
    }
    try provider.forceFlush(1000);
    try provider.shutdown(1000);
}

test "tracing composition example exports after the request is destroyed" {
    var output: [64 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try writeExample(std.testing.allocator, std.testing.io, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"resourceSpans\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"scope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "not-exported") == null);
}
