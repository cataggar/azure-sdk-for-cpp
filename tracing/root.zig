///! OpenTelemetry-compatible distributed tracing for Azure SDK.
///!
///! Provides pluggable `TracerProvider` / `Tracer` / `Span` interfaces
///! following the fn-pointer pattern used throughout the SDK. A
///! Pipelines are uninstrumented by default. Opt in with InstrumentationOptions.
///! ExportingTracerProvider owns bounded span storage and exports only during
///! explicit drain/forceFlush/shutdown. See tracing/README.md for lifetimes.
const std = @import("std");

pub const TraceContext = @import("trace_context.zig").TraceContext;
pub const AttributeValue = @import("exporter.zig").AttributeValue;
pub const Attribute = @import("exporter.zig").Attribute;
pub const SpanData = @import("exporter.zig").SpanData;
pub const ExportContext = @import("exporter.zig").ExportContext;
pub const SpanExporter = @import("exporter.zig").SpanExporter;
pub const ExportingTracerProvider = @import("provider.zig").ExportingTracerProvider;
pub const OtlpJsonWriterExporter = @import("otlp_json.zig").OtlpJsonWriterExporter;

pub const StartOptions = struct {
    /// IDs are copied; tracestate is borrowed until startSpanWithOptions returns.
    parent: ?TraceContext = null,
};

/// Copied into a pipeline. Provider and nonstatic strings must outlive its copies.
pub const InstrumentationOptions = struct {
    provider: *TracerProvider,
    scope_name: []const u8,
    scope_version: []const u8 = "",
    namespace: []const u8 = "",
    /// Default parent for requests without an explicit context. Tracestate is borrowed.
    parent_context: ?TraceContext = null,
};

// ─────────────────── Enums ───────────────────────

pub const SpanKind = enum {
    client,
    server,
    producer,
    consumer,
    internal,
};

pub const SpanStatus = enum {
    unset,
    ok,
    @"error",
};

// ─────────────────── Span Interface ──────────────

/// A unit of work in a trace.
pub const Span = struct {
    setAttributeFn: *const fn (self: *Span, key: []const u8, value: []const u8) anyerror!void,
    setStatusFn: *const fn (self: *Span, status: SpanStatus) void,
    endFn: *const fn (self: *Span) void,
    setTypedAttributeFn: ?*const fn (self: *Span, key: []const u8, value: AttributeValue) anyerror!void = null,
    getContextFn: ?*const fn (self: *Span) ?TraceContext = null,

    pub fn setTypedAttribute(self: *Span, key: []const u8, value: AttributeValue) !void {
        if (self.setTypedAttributeFn) |f| return f(self, key, value);
        if (value == .string) return self.setAttribute(key, value.string);
        return error.UnsupportedAttributeType;
    }

    /// Returned tracestate is borrowed until end; copy it to retain it longer.
    pub fn getContext(self: *Span) ?TraceContext {
        return if (self.getContextFn) |f| f(self) else null;
    }

    pub fn setAttribute(self: *Span, key: []const u8, value: []const u8) !void {
        return self.setAttributeFn(self, key, value);
    }

    pub fn setStatus(self: *Span, status: SpanStatus) void {
        self.setStatusFn(self, status);
    }

    pub fn end(self: *Span) void {
        self.endFn(self);
    }
};

/// A tracer that creates spans for a specific service.
pub const Tracer = struct {
    startSpanFn: *const fn (self: *Tracer, name: []const u8, kind: SpanKind) anyerror!*Span,
    startSpanWithOptionsFn: ?*const fn (self: *Tracer, name: []const u8, kind: SpanKind, options: StartOptions) anyerror!*Span = null,

    pub fn startSpanWithOptions(self: *Tracer, name: []const u8, kind: SpanKind, options: StartOptions) !*Span {
        if (self.startSpanWithOptionsFn) |f| return f(self, name, kind, options);
        return self.startSpan(name, kind);
    }

    pub fn startSpan(self: *Tracer, name: []const u8, kind: SpanKind) !*Span {
        return self.startSpanFn(self, name, kind);
    }
};

/// Factory for creating service-specific tracers.
pub const TracerProvider = struct {
    getTracerFn: *const fn (self: *TracerProvider, name: []const u8, version: []const u8) *Tracer,
    recordPropagationErrorFn: ?*const fn (self: *TracerProvider) void = null,

    pub fn recordPropagationError(self: *TracerProvider) void {
        if (self.recordPropagationErrorFn) |f| f(self);
    }

    pub fn getTracer(self: *TracerProvider, name: []const u8, version: []const u8) *Tracer {
        return self.getTracerFn(self, name, version);
    }
};

// ─────────────── Noop Implementation ─────────────

/// Zero-cost tracer provider for when tracing is disabled (default).
pub const NoopTracerProvider = struct {
    tracer: NoopTracer = NoopTracer.init(),
    provider: TracerProvider,

    pub fn init() NoopTracerProvider {
        return .{
            .provider = .{ .getTracerFn = &getTracerImpl },
        };
    }

    pub fn asProvider(self: *NoopTracerProvider) *TracerProvider {
        return &self.provider;
    }

    fn getTracerImpl(p: *TracerProvider, name: []const u8, version: []const u8) *Tracer {
        _ = name;
        _ = version;
        const self: *NoopTracerProvider = @alignCast(@fieldParentPtr("provider", p));
        return &self.tracer.tracer;
    }
};

pub const NoopTracer = struct {
    span: NoopSpan = NoopSpan.init(),
    tracer: Tracer,

    pub fn init() NoopTracer {
        return .{
            .tracer = .{ .startSpanFn = &startSpanImpl },
        };
    }

    fn startSpanImpl(t: *Tracer, name: []const u8, kind: SpanKind) !*Span {
        _ = name;
        _ = kind;
        const self: *NoopTracer = @alignCast(@fieldParentPtr("tracer", t));
        return &self.span.span;
    }
};

pub const NoopSpan = struct {
    span: Span,

    pub fn init() NoopSpan {
        return .{
            .span = .{
                .setAttributeFn = &setAttributeImpl,
                .setStatusFn = &setStatusImpl,
                .endFn = &endImpl,
            },
        };
    }

    fn setAttributeImpl(s: *Span, key: []const u8, value: []const u8) !void {
        _ = s;
        _ = key;
        _ = value;
    }

    fn setStatusImpl(s: *Span, status: SpanStatus) void {
        _ = s;
        _ = status;
    }

    fn endImpl(s: *Span) void {
        _ = s;
    }
};

// ─────────────── Recording Implementation ────────

/// A borrowed-data test helper, not an exporter or concurrent span store.
pub const RecordingSpan = struct {
    name: []const u8,
    kind: SpanKind,
    status: SpanStatus = .unset,
    attributes: std.StringHashMap([]const u8),
    ended: bool = false,
    span: Span,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, kind: SpanKind) RecordingSpan {
        return .{
            .name = name,
            .kind = kind,
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .span = .{
                .setAttributeFn = &setAttributeImpl,
                .setStatusFn = &setStatusImpl,
                .endFn = &endImpl,
            },
        };
    }

    pub fn asSpan(self: *RecordingSpan) *Span {
        return &self.span;
    }

    pub fn deinit(self: *RecordingSpan) void {
        self.attributes.deinit();
    }

    fn setAttributeImpl(s: *Span, key: []const u8, value: []const u8) !void {
        const self: *RecordingSpan = @alignCast(@fieldParentPtr("span", s));
        try self.attributes.put(key, value);
    }

    fn setStatusImpl(s: *Span, status: SpanStatus) void {
        const self: *RecordingSpan = @alignCast(@fieldParentPtr("span", s));
        self.status = status;
    }

    fn endImpl(s: *Span) void {
        const self: *RecordingSpan = @alignCast(@fieldParentPtr("span", s));
        self.ended = true;
    }
};

/// A tracer that creates RecordingSpans — useful for tests.
pub const RecordingTracer = struct {
    allocator: std.mem.Allocator,
    last_span: ?RecordingSpan = null,
    tracer: Tracer,

    pub fn init(allocator: std.mem.Allocator) RecordingTracer {
        return .{
            .allocator = allocator,
            .tracer = .{ .startSpanFn = &startSpanImpl },
        };
    }

    pub fn asTracer(self: *RecordingTracer) *Tracer {
        return &self.tracer;
    }

    pub fn deinit(self: *RecordingTracer) void {
        if (self.last_span) |*s| s.deinit();
    }

    fn startSpanImpl(t: *Tracer, name: []const u8, kind: SpanKind) !*Span {
        const self: *RecordingTracer = @alignCast(@fieldParentPtr("tracer", t));
        if (self.last_span) |*s| s.deinit();
        self.last_span = RecordingSpan.init(self.allocator, name, kind);
        return &self.last_span.?.span;
    }
};

// ─────────────────────── Tests ───────────────────────

test "NoopTracerProvider creates noop spans" {
    var provider = NoopTracerProvider.init();
    const tracer = provider.asProvider().getTracer("test", "0.1.0");
    const span = try tracer.startSpan("op", .client);
    try span.setAttribute("key", "val");
    span.setStatus(.ok);
    span.end();
}

test "RecordingSpan captures attributes and status" {
    const allocator = std.testing.allocator;
    var span = RecordingSpan.init(allocator, "HTTP GET", .client);
    defer span.deinit();
    try span.asSpan().setAttribute("http.method", "GET");
    span.asSpan().setStatus(.ok);
    span.asSpan().end();
    try std.testing.expectEqualStrings("GET", span.attributes.get("http.method").?);
    try std.testing.expectEqual(SpanStatus.ok, span.status);
    try std.testing.expect(span.ended);
}

test "RecordingTracer creates recording spans" {
    const allocator = std.testing.allocator;
    var tracer = RecordingTracer.init(allocator);
    defer tracer.deinit();
    const span = try tracer.asTracer().startSpan("test.op", .internal);
    try span.setAttribute("az.namespace", "KeyVault");
    span.setStatus(.ok);
    span.end();
    try std.testing.expectEqualStrings("test.op", tracer.last_span.?.name);
    try std.testing.expectEqual(SpanKind.internal, tracer.last_span.?.kind);
    try std.testing.expect(tracer.last_span.?.ended);
}

test "TraceContext formatTraceparent" {
    var ctx = TraceContext{};
    @memcpy(&ctx.trace_id, "0af7651916cd43dd8448eb211c80319c");
    @memcpy(&ctx.span_id, "b7ad6b7169203331");
    ctx.trace_flags = 0x01;
    const tp = ctx.formatTraceparent();
    try std.testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", &tp);
}

test "TraceContext parseTraceparent" {
    const ctx = TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
    try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &ctx.trace_id);
    try std.testing.expectEqualStrings("b7ad6b7169203331", &ctx.span_id);
    try std.testing.expectEqual(@as(u8, 0x01), ctx.trace_flags);
}

test "TraceContext parseTraceparent invalid" {
    try std.testing.expect(TraceContext.parseTraceparent("invalid") == null);
    try std.testing.expect(TraceContext.parseTraceparent("") == null);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("example.zig");
}
