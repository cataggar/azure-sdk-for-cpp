const std = @import("std");
const tracing = @import("root.zig");
const StdCryptoProvider = @import("../crypto.zig").StdCryptoProvider;
const Provider = tracing.ExportingTracerProvider;

const Sink = struct {
    exporter: tracing.SpanExporter = .{
        .exportFn = write,
        .shutdownFn = shutdown,
    },
    count: usize = 0,
    shutdowns: usize = 0,
    fail: bool = false,
    expected_name: ?[]const u8 = null,
    expected_string: ?[]const u8 = null,
    expected_scope: ?[]const u8 = null,
    add_span: ?*tracing.Tracer = null,
    reentrant_provider: ?*Provider = null,

    fn write(exporter: *tracing.SpanExporter, batch: []const tracing.SpanData, _: tracing.ExportContext) !void {
        const self: *Sink = @fieldParentPtr("exporter", exporter);
        if (self.fail) return error.TestExportFailure;
        for (batch) |data| {
            try std.testing.expect(data.context.isValid());
            try std.testing.expect(data.end_time_unix_nano >= data.start_time_unix_nano);
            if (self.expected_name) |name| try std.testing.expectEqualStrings(name, data.name);
            if (self.expected_scope) |name| try std.testing.expectEqualStrings(name, data.scope_name);
            if (self.expected_string) |s| {
                try std.testing.expectEqual(@as(usize, 1), data.attributes.len);
                try std.testing.expectEqualStrings(s, data.attributes[0].value.string);
            }
        }
        self.count += batch.len;
        if (self.reentrant_provider) |provider| {
            _ = provider.stats();
            try std.testing.expectError(error.ExportInProgress, provider.forceFlush(1000));
            try std.testing.expectError(error.ExportInProgress, provider.shutdown(1000));
        }
        if (self.add_span) |tracer| {
            self.add_span = null;
            (try tracer.startSpan("created during export", .internal)).end();
        }
    }

    fn shutdown(exporter: *tracing.SpanExporter, _: tracing.ExportContext) !void {
        const self: *Sink = @fieldParentPtr("exporter", exporter);
        self.shutdowns += 1;
    }
};

test "tracing provider owns names attributes and parent context with independent spans" {
    var crypto = StdCryptoProvider.init(std.testing.io);
    var sink: Sink = .{ .expected_name = "name", .expected_string = "value", .expected_scope = "test" };
    var provider = try Provider.init(std.testing.allocator, std.testing.io, crypto.asProvider(), &sink.exporter, .{});
    defer provider.deinit() catch unreachable;
    var scope_name = "test".*;
    const tracer = provider.asProvider().getTracer(&scope_name, "1.0");
    var name = "name".*;
    var value = "value".*;
    var state = "vendor=parent".*;
    var parent = tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
    parent.trace_state = &state;
    const one = try tracer.startSpanWithOptions(&name, .client, .{ .parent = parent });
    const two = try tracer.startSpan(&name, .client);
    try std.testing.expect(one != two);
    try std.testing.expectEqualStrings(&parent.trace_id, &one.getContext().?.trace_id);
    try std.testing.expect(!std.mem.eql(u8, &parent.span_id, &one.getContext().?.span_id));
    try one.setAttribute("key", &value);
    try two.setAttribute("key", &value);
    @memset(&name, 'x');
    @memset(&value, 'x');
    @memset(&state, 'x');
    @memset(&scope_name, 'x');
    try std.testing.expectEqualStrings("vendor=parent", one.getContext().?.trace_state.?);
    one.end();
    two.end();
    try std.testing.expectEqual(@as(usize, 0), sink.count);
    try provider.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try provider.shutdown(1000);
    try provider.shutdown(1000);
    try std.testing.expectEqual(@as(usize, 1), sink.shutdowns);
}

test "tracing provider bounds active spans queue bytes attributes and scope storage" {
    var crypto = StdCryptoProvider.init(std.testing.io);
    var sink: Sink = .{};
    try std.testing.expectError(error.InvalidTracingLimits, Provider.init(
        std.testing.allocator,
        std.testing.io,
        crypto.asProvider(),
        &sink.exporter,
        .{ .max_retained_bytes = 1 },
    ));
    var provider = try Provider.init(std.testing.allocator, std.testing.io, crypto.asProvider(), &sink.exporter, .{
        .max_spans = 2,
        .max_queued_spans = 1,
        .max_scopes = 1,
        .max_attributes = 1,
        .max_attribute_bytes = 8,
    });
    defer provider.deinit() catch unreachable;
    const tracer = provider.asProvider().getTracer("test", "");
    const one = try tracer.startSpan("one", .client);
    const two = try tracer.startSpan("two", .client);
    try std.testing.expectError(error.SpanLimitExceeded, tracer.startSpan("three", .client));
    try one.setTypedAttribute("status", .{ .int = 200 });
    try std.testing.expectError(error.SpanLimitExceeded, one.setAttribute("other", "x"));
    try std.testing.expectError(error.SpanLimitExceeded, two.setAttribute("key", "too many bytes"));
    _ = provider.asProvider().getTracer("second scope", "");
    one.end();
    two.end();
    const stats = provider.stats();
    try std.testing.expectEqual(@as(u64, 3), stats.dropped_spans);
    try std.testing.expectEqual(@as(u64, 2), stats.dropped_attributes);
    try std.testing.expectEqual(@as(usize, 1), stats.queued_spans);
    try std.testing.expect(stats.retained_bytes <= provider.options.max_retained_bytes);
    try provider.shutdown(1000);
}

test "tracing provider shutdown live handles errors timeout and snapshot flush" {
    var crypto = StdCryptoProvider.init(std.testing.io);
    var sink: Sink = .{};
    var provider = try Provider.init(std.testing.allocator, std.testing.io, crypto.asProvider(), &sink.exporter, .{});
    defer provider.deinit() catch unreachable;
    const tracer = provider.asProvider().getTracer("test", "");
    (try tracer.startSpan("one", .client)).end();
    try std.testing.expectError(error.ExportTimedOut, provider.forceFlush(0));
    try std.testing.expectEqual(@as(usize, 1), provider.stats().queued_spans);
    sink.add_span = tracer;
    sink.reentrant_provider = &provider;
    try provider.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(@as(usize, 1), provider.stats().queued_spans);
    sink.fail = true;
    try std.testing.expectError(error.TestExportFailure, provider.forceFlush(1000));
    try std.testing.expectEqual(@as(usize, 0), provider.stats().queued_spans);
    try std.testing.expect(provider.stats().export_errors >= 2);
    const active = try tracer.startSpan("active", .client);
    try std.testing.expectError(error.ActiveSpans, provider.shutdown(1000));
    try std.testing.expectError(error.ActiveSpans, provider.deinit());
    try std.testing.expectError(error.ProviderShutdown, tracer.startSpan("closed", .client));
    active.end();
    sink.fail = false;
    try provider.shutdown(1000);
    try std.testing.expectError(error.ProviderShutdown, provider.forceFlush(1000));
}

test "tracing provider unsampled parent propagates without recording" {
    var crypto = StdCryptoProvider.init(std.testing.io);
    var sink: Sink = .{};
    var provider = try Provider.init(std.testing.allocator, std.testing.io, crypto.asProvider(), &sink.exporter, .{});
    defer provider.deinit() catch unreachable;
    const parent = tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00").?;
    const span = try provider.asProvider().getTracer("test", "").startSpanWithOptions("op", .client, .{ .parent = parent });
    try std.testing.expect(span.getContext().?.isValid());
    try std.testing.expectEqual(@as(u8, 0), span.getContext().?.trace_flags);
    span.end();
    try provider.shutdown(1000);
    try std.testing.expectEqual(@as(usize, 0), sink.count);
}

test "tracing provider initialization allocation failure cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var crypto = StdCryptoProvider.init(std.testing.io);
    var sink: Sink = .{};
    var provider = try Provider.init(allocator, std.testing.io, crypto.asProvider(), &sink.exporter, .{});
    defer provider.deinit() catch unreachable;
    const span = try provider.asProvider().getTracer("test", "").startSpan("op", .client);
    try span.setTypedAttribute("ok", .{ .boolean = true });
    span.end();
    try provider.shutdown(1000);
}

test "tracing provider concurrent independent spans" {
    var crypto = StdCryptoProvider.init(std.testing.io);
    var sink: Sink = .{};
    var provider = try Provider.init(std.testing.allocator, std.testing.io, crypto.asProvider(), &sink.exporter, .{});
    defer provider.deinit() catch unreachable;
    const tracer = provider.asProvider().getTracer("threads", "");
    const Worker = struct {
        fn run(t: *tracing.Tracer) void {
            for (0..20) |i| {
                const span = t.startSpan("parallel", .client) catch unreachable;
                span.setTypedAttribute("index", .{ .int = @intCast(i) }) catch unreachable;
                span.end();
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{tracer});
            started += 1;
        }
    }
    try provider.shutdown(1000);
    try std.testing.expectEqual(@as(usize, 80), sink.count);
    try std.testing.expectEqual(@as(u64, 0), provider.stats().dropped_spans);
}

test "tracing OTLP JSON golden typed values timestamps enums and bounded writer" {
    const context = tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
    const data: tracing.SpanData = .{
        .context = context,
        .parent_span_id = "1234567890abcdef".*,
        .name = "HTTP",
        .kind = .client,
        .status = .@"error",
        .start_time_unix_nano = 123,
        .end_time_unix_nano = 456,
        .scope_name = "azure_sdk_test",
        .scope_version = "1.0",
        .service_name = "app",
        .attributes = &.{
            .{ .key = "status", .value = .{ .int = 500 } },
            .{ .key = "flag", .value = .{ .boolean = true } },
            .{ .key = "text", .value = .{ .string = "a\"b" } },
        },
    };
    var scratch: [4096]u8 = undefined;
    const actual = try tracing.OtlpJsonWriterExporter.encode(&.{data}, &scratch);
    try std.testing.expectEqualStrings(
        "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"app\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"azure_sdk_test\",\"version\":\"1.0\"},\"spans\":[{\"traceId\":\"0af7651916cd43dd8448eb211c80319c\",\"spanId\":\"b7ad6b7169203331\",\"parentSpanId\":\"1234567890abcdef\",\"flags\":1,\"name\":\"HTTP\",\"kind\":3,\"startTimeUnixNano\":\"123\",\"endTimeUnixNano\":\"456\",\"attributes\":[{\"key\":\"status\",\"value\":{\"intValue\":\"500\"}},{\"key\":\"flag\",\"value\":{\"boolValue\":true}},{\"key\":\"text\",\"value\":{\"stringValue\":\"a\\\"b\"}}],\"droppedAttributesCount\":0,\"status\":{\"code\":2}}]}]}]}",
        actual,
    );
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    var tiny: [10]u8 = undefined;
    var exporter = tracing.OtlpJsonWriterExporter.init(&writer, &tiny);
    try std.testing.expectError(error.WriteFailed, exporter.asExporter().exportBatch(&.{data}, .init(std.testing.io, 1000)));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    exporter.scratch = &scratch;
    try exporter.asExporter().exportBatch(&.{data}, .init(std.testing.io, 1000));
    try std.testing.expectEqual(@as(u8, '\n'), writer.buffered()[writer.buffered().len - 1]);
    var invalid = data;
    invalid.context.span_id = @splat('0');
    try std.testing.expectError(error.InvalidSpanData, tracing.OtlpJsonWriterExporter.encode(&.{invalid}, &scratch));
}

test "tracing provider duration uses monotonic clock despite wall clock rollback" {
    const Clock = struct {
        calls: usize = 0,
        fn now(context: *anyopaque) Provider.Clock.Sample {
            const self: *@This() = @ptrCast(@alignCast(context));
            defer self.calls += 1;
            return if (self.calls == 0)
                .{ .unix_ns = 1000, .monotonic_ns = 100 }
            else
                .{ .unix_ns = 1, .monotonic_ns = 150 };
        }
    };
    const TimedSink = struct {
        fn write(_: *tracing.SpanExporter, batch: []const tracing.SpanData, _: tracing.ExportContext) !void {
            try std.testing.expectEqual(@as(u64, 1000), batch[0].start_time_unix_nano);
            try std.testing.expectEqual(@as(u64, 1050), batch[0].end_time_unix_nano);
        }
    };
    var crypto = StdCryptoProvider.init(std.testing.io);
    var clock: Clock = .{};
    var exporter: tracing.SpanExporter = .{ .exportFn = TimedSink.write };
    var provider = try Provider.init(std.testing.allocator, std.testing.io, crypto.asProvider(), &exporter, .{
        .clock = .{ .context = &clock, .nowFn = Clock.now },
    });
    defer provider.deinit() catch unreachable;
    const span = try provider.asProvider().getTracer("clock", "").startSpan("op", .client);
    span.end();
    try provider.shutdown(1000);
}
