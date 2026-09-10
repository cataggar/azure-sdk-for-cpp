const std = @import("std");
const tracing = @import("root.zig");

/// Writes one complete OTLP ExportTraceServiceRequest JSON object per line.
/// The caller owns the writer and scratch buffer and flushes/closes the writer.
/// This performs no network setup, environment discovery, or on-end export.
pub const OtlpJsonWriterExporter = struct {
    writer: *std.Io.Writer,
    scratch: []u8,
    exporter: tracing.SpanExporter = .{ .exportFn = exportBatch },

    pub fn init(writer: *std.Io.Writer, scratch: []u8) OtlpJsonWriterExporter {
        return .{ .writer = writer, .scratch = scratch };
    }

    pub fn asExporter(self: *OtlpJsonWriterExporter) *tracing.SpanExporter {
        return &self.exporter;
    }

    /// Output borrows scratch. Serialization completes before touching the sink.
    pub fn encode(batch: []const tracing.SpanData, scratch: []u8) ![]const u8 {
        for (batch) |span| {
            if (!span.context.isValid() or span.end_time_unix_nano < span.start_time_unix_nano)
                return error.InvalidSpanData;
            if (span.parent_span_id) |parent| {
                if (!(tracing.TraceContext{ .trace_id = span.context.trace_id, .span_id = parent }).isValid())
                    return error.InvalidSpanData;
            }
            if (span.context.trace_state) |state| {
                if (!tracing.TraceContext.validTracestate(state)) return error.InvalidSpanData;
            }
            if (!std.unicode.utf8ValidateSlice(span.name) or !std.unicode.utf8ValidateSlice(span.service_name) or
                !std.unicode.utf8ValidateSlice(span.scope_name) or !std.unicode.utf8ValidateSlice(span.scope_version))
                return error.InvalidSpanData;
            for (span.attributes) |attribute| {
                if (!std.unicode.utf8ValidateSlice(attribute.key)) return error.InvalidSpanData;
                switch (attribute.value) {
                    .string => |s| if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidSpanData,
                    .double => |d| if (!std.math.isFinite(d)) return error.InvalidSpanData,
                    else => {},
                }
            }
        }
        var writer: std.Io.Writer = .fixed(scratch);
        try std.json.Stringify.value(Payload{ .spans = batch }, .{}, &writer);
        return writer.buffered();
    }

    fn exportBatch(exporter: *tracing.SpanExporter, batch: []const tracing.SpanData, context: tracing.ExportContext) !void {
        const self: *OtlpJsonWriterExporter = @fieldParentPtr("exporter", exporter);
        const payload = try encode(batch, self.scratch);
        try context.check();
        try self.writer.writeAll(payload);
        try self.writer.writeByte('\n');
    }
};

const Payload = struct {
    spans: []const tracing.SpanData,

    pub fn jsonStringify(self: Payload, json: *std.json.Stringify) !void {
        try json.beginObject();
        try json.objectField("resourceSpans");
        try json.beginArray();
        for (self.spans) |*span| {
            try json.beginObject();
            try json.objectField("resource");
            try json.write(.{ .attributes = .{WireAttribute{ .attribute = .{
                .key = "service.name",
                .value = .{ .string = span.service_name },
            } }} });
            try json.objectField("scopeSpans");
            try json.beginArray();
            try json.beginObject();
            try json.objectField("scope");
            try json.write(.{ .name = span.scope_name, .version = span.scope_version });
            try json.objectField("spans");
            try json.beginArray();
            try writeSpan(json, span);
            try json.endArray();
            try json.endObject();
            try json.endArray();
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
};

const WireAttribute = struct {
    attribute: tracing.Attribute,

    pub fn jsonStringify(self: WireAttribute, json: *std.json.Stringify) !void {
        try json.beginObject();
        try json.objectField("key");
        try json.write(self.attribute.key);
        try json.objectField("value");
        try json.beginObject();
        switch (self.attribute.value) {
            .string => |s| {
                try json.objectField("stringValue");
                try json.write(s);
            },
            .int => |i| {
                try json.objectField("intValue");
                var buf: [21]u8 = undefined;
                try json.write(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
            },
            .boolean => |b| {
                try json.objectField("boolValue");
                try json.write(b);
            },
            .double => |d| {
                try json.objectField("doubleValue");
                try json.write(d);
            },
        }
        try json.endObject();
        try json.endObject();
    }
};

fn writeSpan(json: *std.json.Stringify, span: *const tracing.SpanData) !void {
    try json.beginObject();
    try json.objectField("traceId");
    try json.write(@as([]const u8, &span.context.trace_id));
    try json.objectField("spanId");
    try json.write(@as([]const u8, &span.context.span_id));
    if (span.parent_span_id) |*id| {
        try json.objectField("parentSpanId");
        try json.write(@as([]const u8, id));
    }
    if (span.context.trace_state) |state| {
        try json.objectField("traceState");
        try json.write(state);
    }
    try json.objectField("flags");
    try json.write(@as(u32, span.context.trace_flags & 1));
    try json.objectField("name");
    try json.write(span.name);
    try json.objectField("kind");
    try json.write(@as(u8, switch (span.kind) {
        .internal => 1,
        .server => 2,
        .client => 3,
        .producer => 4,
        .consumer => 5,
    }));
    var buf: [20]u8 = undefined;
    try json.objectField("startTimeUnixNano");
    try json.write(std.fmt.bufPrint(&buf, "{d}", .{span.start_time_unix_nano}) catch unreachable);
    try json.objectField("endTimeUnixNano");
    try json.write(std.fmt.bufPrint(&buf, "{d}", .{span.end_time_unix_nano}) catch unreachable);
    try json.objectField("attributes");
    try json.beginArray();
    for (span.attributes) |attribute| try json.write(WireAttribute{ .attribute = attribute });
    try json.endArray();
    try json.objectField("droppedAttributesCount");
    try json.write(span.dropped_attributes_count);
    try json.objectField("status");
    try json.write(.{ .code = @as(u8, switch (span.status) {
        .unset => 0,
        .ok => 1,
        .@"error" => 2,
    }) });
    try json.endObject();
}
