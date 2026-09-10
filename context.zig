/// Carries cancellation signals and trace context across API boundaries.
///
/// Deadline-based cancellation is left to callers who have access to
/// `std.Io`; this type provides a lightweight, IO-independent
/// cancellation token that can be threaded through the SDK.
pub const Context = struct {
    cancelled: bool = false,
    trace_id: ?[32]u8 = null,
    span_id: ?[16]u8 = null,
    trace_flags: u8 = 0,
    /// Borrowed until the operation starts; the concrete tracer copies it.
    trace_state: ?[]const u8 = null,
    /// Use for exporter requests on a shared instrumented pipeline.
    tracing_suppressed: bool = false,

    pub const none = Context{};

    pub fn cancel(self: *Context) void {
        self.cancelled = true;
    }

    pub fn isCancelled(self: Context) bool {
        return self.cancelled;
    }

    /// Create a child context inheriting trace context.
    pub fn withTrace(self: Context, trace_id: [32]u8, span_id: [16]u8) Context {
        var result = self;
        result.trace_id = trace_id;
        result.span_id = span_id;
        return result;
    }

    pub fn withTraceContext(self: Context, trace: @import("tracing/trace_context.zig").TraceContext) Context {
        var result = self.withTrace(trace.trace_id, trace.span_id);
        result.trace_flags = trace.trace_flags;
        result.trace_state = trace.trace_state;
        return result;
    }

    pub fn traceContext(self: Context) ?@import("tracing/trace_context.zig").TraceContext {
        return .{
            .trace_id = self.trace_id orelse return null,
            .span_id = self.span_id orelse return null,
            .trace_flags = self.trace_flags,
            .trace_state = self.trace_state,
        };
    }
};

const std = @import("std");

test "context none is never cancelled" {
    try std.testing.expect(!Context.none.isCancelled());
}

test "context cancel" {
    var ctx = Context{};
    try std.testing.expect(!ctx.isCancelled());
    ctx.cancel();
    try std.testing.expect(ctx.isCancelled());
}
