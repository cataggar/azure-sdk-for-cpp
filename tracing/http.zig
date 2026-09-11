const std = @import("std");
const tracing = @import("root.zig");
const Request = @import("../http/transport.zig").Request;

/// A logical pipeline request, ending at buffered completion or open's headers.
pub const Scope = struct {
    request: *Request,
    span: ?*tracing.Span = null,
    headers: ?HeaderGuard = null,
    previous_suppressed: bool = false,

    pub fn begin(request: *Request, options: ?tracing.InstrumentationOptions) Scope {
        var result: Scope = .{ .request = request };
        if (request.context.tracing_suppressed) return result;
        const config = options orelse return result;
        const parent = request.context.traceContext() orelse config.parent_context orelse
            tracing.TraceContext.extract(request.getHeader("traceparent"), request.getHeader("tracestate"));
        const tracer = config.provider.getTracer(config.scope_name, config.scope_version);
        const span = tracer.startSpanWithOptions("HTTP", .client, .{ .parent = parent }) catch return result;
        result.span = span;
        safeAttributes(span, request, config.namespace);
        if (span.getContext()) |context| {
            if (context.isValid()) {
                result.headers = HeaderGuard.install(request, context) catch blk: {
                    config.provider.recordPropagationError();
                    break :blk null;
                };
            }
        }
        result.previous_suppressed = request.context.tracing_suppressed;
        request.context.tracing_suppressed = true;
        return result;
    }

    pub fn recordResponse(self: *Scope, status: u16) void {
        if (self.span) |span| {
            span.setTypedAttribute("http.response.status_code", .{ .int = status }) catch {};
            if (status >= 400) {
                span.setStatus(.@"error");
                var code: [5]u8 = undefined;
                span.setAttribute("error.type", std.fmt.bufPrint(&code, "{d}", .{status}) catch unreachable) catch {};
            }
        }
    }

    pub fn recordError(self: *Scope, err: anyerror) void {
        if (self.span) |span| {
            span.setStatus(.@"error");
            span.setAttribute("error.type", @errorName(err)) catch {};
        }
    }

    pub fn end(self: *Scope) void {
        if (self.headers) |*headers| {
            headers.restore();
        }
        if (self.span) |span| {
            self.request.context.tracing_suppressed = self.previous_suppressed;
            span.end();
            self.span = null;
        }
    }
};

pub fn safeAttributes(span: *tracing.Span, request: *const Request, namespace: []const u8) void {
    span.setAttribute("http.request.method", @tagName(request.method)) catch {};
    if (namespace.len != 0) span.setAttribute("az.namespace", namespace) catch {};
    // Never retain raw URLs, paths, userinfo, query strings, or HTTP headers.
    const uri = std.Uri.parse(request.url) catch return;
    if (uri.host) |host| {
        span.setAttribute("server.address", switch (host) {
            .raw => |s| s,
            .percent_encoded => |s| s,
        }) catch {};
    }
    if (uri.port) |port| span.setTypedAttribute("server.port", .{ .int = port }) catch {};
}

/// Moves caller-owned entries aside, installs request-owned copies, then restores
/// them into dedicated storage, independently of all policy map mutations.
const HeaderGuard = struct {
    request: *Request,
    saved: @import("../http/request_headers.zig").RequestHeaders.TraceHeaders,
    previous_managed: bool,

    fn install(request: *Request, context: tracing.TraceContext) !HeaderGuard {
        var self: HeaderGuard = .{
            .request = request,
            .saved = request.headers.takeTraceHeaders(),
            .previous_managed = request.tracing_headers_managed,
        };
        errdefer self.restore();
        const parent = context.formatTraceparent();
        try request.setHeader("traceparent", &parent);
        const state = if (context.trace_state) |value|
            if (tracing.TraceContext.validTracestate(value)) value else null
        else
            null;
        if (state) |value| {
            try request.setHeader("tracestate", value);
        }
        request.tracing_headers_managed = true;
        return self;
    }

    fn restore(self: *HeaderGuard) void {
        self.request.headers.restoreTraceHeaders(&self.saved);
        self.request.tracing_headers_managed = self.previous_managed;
    }
};
