const std = @import("std");
const tracing = @import("root.zig");

pub const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    boolean: bool,
    double: f64,
};

pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,
};

/// Immutable export view. All slices live until the export callback returns.
pub const SpanData = struct {
    context: tracing.TraceContext,
    parent_span_id: ?[16]u8,
    name: []const u8,
    kind: tracing.SpanKind,
    status: tracing.SpanStatus = .unset,
    start_time_unix_nano: u64,
    end_time_unix_nano: u64 = 0,
    attributes: []const Attribute = &.{},
    dropped_attributes_count: u32 = 0,
    scope_name: []const u8,
    scope_version: []const u8,
    service_name: []const u8,
};

/// Cooperative budget. Custom callbacks must check it and bound their own I/O.
pub const ExportContext = struct {
    io: std.Io,
    deadline_ns: i128,

    pub fn init(io: std.Io, timeout_ms: u64) ExportContext {
        return .{
            .io = io,
            .deadline_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds() + @as(i128, timeout_ms) * std.time.ns_per_ms,
        };
    }

    pub fn check(self: ExportContext) !void {
        if (std.Io.Timestamp.now(self.io, .awake).toNanoseconds() >= self.deadline_ns)
            return error.ExportTimedOut;
    }
};

/// Borrowed, address-stable exporter. Callbacks are serialized by the provider.
/// Never retain batch slices; use an uninstrumented pipeline or request-context
/// suppression for any network requests. No callback runs from Span.end.
pub const SpanExporter = struct {
    exportFn: *const fn (*SpanExporter, []const SpanData, ExportContext) anyerror!void,
    forceFlushFn: ?*const fn (*SpanExporter, ExportContext) anyerror!void = null,
    shutdownFn: ?*const fn (*SpanExporter, ExportContext) anyerror!void = null,

    pub fn exportBatch(self: *SpanExporter, batch: []const SpanData, context: ExportContext) !void {
        try context.check();
        try self.exportFn(self, batch, context);
        try context.check();
    }

    pub fn forceFlush(self: *SpanExporter, context: ExportContext) !void {
        try context.check();
        if (self.forceFlushFn) |f| try f(self, context);
        try context.check();
    }

    pub fn shutdown(self: *SpanExporter, context: ExportContext) !void {
        if (self.shutdownFn) |f| try f(self, context);
        try context.check();
    }
};
