const std = @import("std");
const tracing = @import("root.zig");
const Request = @import("../http/transport.zig").Request;

/// A logical pipeline request, ending at buffered completion or open's headers.
pub const Scope = struct {
    request: *Request,
    span: ?*tracing.Span = null,
    provider: ?*tracing.TracerProvider = null,
    headers: ?HeaderGuard = null,
    previous_suppressed: bool = false,

    pub fn begin(request: *Request, options: ?tracing.InstrumentationOptions) Scope {
        var result: Scope = .{ .request = request };
        if (request.context.tracing_suppressed) return result;
        const config = options orelse return result;
        result.provider = config.provider;
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
            if (!headers.restore()) self.provider.?.recordPropagationError();
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

const Header = struct { key: []const u8, value: []const u8 };

/// Moves caller-owned entries aside, installs request-owned copies, then restores
/// the originals. No saved slice points at a stack traceparent buffer.
const HeaderGuard = struct {
    request: *Request,
    parent: ?Header,
    state: ?Header,
    previous_managed: bool,

    fn install(request: *Request, context: tracing.TraceContext) !HeaderGuard {
        try request.headers.ensureUnusedCapacity(2);
        var self: HeaderGuard = .{
            .request = request,
            .parent = take(request, "traceparent"),
            .state = take(request, "tracestate"),
            .previous_managed = request.tracing_headers_managed,
        };
        errdefer std.debug.assert(self.restore());
        const parent = context.formatTraceparent();
        try request.setHeader("traceparent", &parent);
        if (context.trace_state) |state| {
            if (tracing.TraceContext.validTracestate(state)) try request.setHeader("tracestate", state);
        }
        request.tracing_headers_managed = true;
        return self;
    }

    fn take(request: *Request, name: []const u8) ?Header {
        var it = request.headers.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                const removed = request.headers.fetchRemove(entry.key_ptr.*).?;
                return .{ .key = removed.key, .value = removed.value };
            }
        }
        return null;
    }

    fn free(request: *Request, header: ?Header) void {
        if (header) |h| {
            request.allocator.free(h.key);
            request.allocator.free(h.value);
        }
    }

    fn restore(self: *HeaderGuard) bool {
        free(self.request, take(self.request, "traceparent"));
        free(self.request, take(self.request, "tracestate"));
        self.request.tracing_headers_managed = self.previous_managed;
        // Downstream policies may have filled capacity after removing our headers.
        self.request.headers.ensureUnusedCapacity(2) catch {
            free(self.request, self.parent);
            free(self.request, self.state);
            self.parent = null;
            self.state = null;
            return false;
        };
        if (self.parent) |h| self.request.headers.putAssumeCapacity(h.key, h.value);
        if (self.state) |h| self.request.headers.putAssumeCapacity(h.key, h.value);
        self.parent = null;
        self.state = null;
        return true;
    }
};
