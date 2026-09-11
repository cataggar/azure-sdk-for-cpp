//! Target-neutral request adaptation for WASI-style HTTP hosts.
//!
//! The canonical-ABI extern implementation lives in `wasi_http.zig`. Keeping
//! URL/header adaptation here permits native tests to inject a fake host
//! without claiming runtime coverage for a WASI engine.

const std = @import("std");
const transport = @import("transport.zig");

pub const Scheme = enum {
    http,
    https,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HostRequest = struct {
    method: transport.Method,
    scheme: Scheme,
    authority: []const u8,
    path_with_query: []const u8,
    headers: *const transport.RequestHeaders,
};

pub const HostResponse = struct {
    status_code: u16,
    headers: []const Header = &.{},
    /// Allocated by the host with the allocator passed to `send`.
    body: []u8,
};

/// Build an `HttpTransport` around a host value exposing:
///
/// `send(allocator, HostRequest) !HostResponse`.
pub fn HttpTransportAdapter(comptime Host: type) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,

        const Self = @This();
        const vtable: transport.HttpTransport.VTable = .{ .send = &sendImpl };

        pub fn init(allocator: std.mem.Allocator, host: Host) Self {
            return .{ .allocator = allocator, .host = host };
        }

        pub fn asTransport(self: *Self) transport.HttpTransport {
            return .{ .context = self, .vtable = &vtable };
        }

        fn sendImpl(
            context: *anyopaque,
            request: *transport.Request,
        ) !transport.Response {
            const self: *Self = @ptrCast(@alignCast(context));
            if (request.body != null) return error.RequestBodyUnsupported;

            const uri = std.Uri.parse(request.url) catch return error.InvalidUrl;
            const scheme: Scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
                .http
            else if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
                .https
            else
                return error.InvalidUrl;
            if (uri.host == null or uri.user != null or uri.password != null)
                return error.InvalidUrl;

            const authority = try std.fmt.allocPrint(self.allocator, "{f}", .{
                std.Uri.fmt(&uri, .{ .authority = true, .port = true }),
            });
            defer self.allocator.free(authority);
            const path_with_query = try std.fmt.allocPrint(self.allocator, "{f}", .{
                std.Uri.fmt(&uri, .{
                    .path = true,
                    .query = true,
                    .fragment = false,
                }),
            });
            defer self.allocator.free(path_with_query);

            const host_response = try self.host.send(self.allocator, .{
                .method = request.method,
                .scheme = scheme,
                .authority = authority,
                .path_with_query = path_with_query,
                .headers = &request.headers,
            });
            errdefer self.allocator.free(host_response.body);

            var headers = std.StringHashMap([]const u8).init(self.allocator);
            errdefer deinitHeaders(self.allocator, &headers);
            var ordered = transport.ResponseHeaders.init(self.allocator);
            errdefer ordered.deinit();
            for (host_response.headers) |header| {
                try ordered.append(header.name, header.value);
                const name = try self.allocator.dupe(u8, header.name);
                errdefer self.allocator.free(name);
                const value = try self.allocator.dupe(u8, header.value);
                errdefer self.allocator.free(value);
                const entry = try headers.getOrPut(name);
                if (entry.found_existing) {
                    self.allocator.free(name);
                    self.allocator.free(entry.value_ptr.*);
                } else {
                    entry.key_ptr.* = name;
                }
                entry.value_ptr.* = value;
            }

            return .{
                .status_code = host_response.status_code,
                .headers = headers,
                .body = host_response.body,
                .allocator = self.allocator,
                .response_headers = ordered,
            };
        }
    };
}

fn deinitHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

const RecordingHost = struct {
    calls: usize = 0,
    method: ?transport.Method = null,
    scheme: ?Scheme = null,
    authority: [256]u8 = undefined,
    authority_len: usize = 0,
    path: [512]u8 = undefined,
    path_len: usize = 0,
    saw_host: bool = false,
    trace_headers_seen: usize = 0,

    fn authorityValue(self: *const RecordingHost) []const u8 {
        return self.authority[0..self.authority_len];
    }

    fn pathValue(self: *const RecordingHost) []const u8 {
        return self.path[0..self.path_len];
    }

    fn send(
        self: *RecordingHost,
        allocator: std.mem.Allocator,
        request: HostRequest,
    ) !HostResponse {
        self.calls += 1;
        self.method = request.method;
        self.scheme = request.scheme;
        if (request.authority.len > self.authority.len or
            request.path_with_query.len > self.path.len)
        {
            return error.FakeHostCaptureTooLong;
        }
        @memcpy(self.authority[0..request.authority.len], request.authority);
        self.authority_len = request.authority.len;
        @memcpy(self.path[0..request.path_with_query.len], request.path_with_query);
        self.path_len = request.path_with_query.len;
        var headers = request.headers.iterator();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.key_ptr.*, "host")) {
                self.saw_host = true;
            }
            if (std.ascii.eqlIgnoreCase(header.key_ptr.*, "traceparent") or
                std.ascii.eqlIgnoreCase(header.key_ptr.*, "tracestate"))
            {
                if (!std.mem.eql(u8, request.headers.get(header.key_ptr.*).?, header.value_ptr.*))
                    return error.FakeHostHeaderMismatch;
                self.trace_headers_seen += 1;
            }
        }
        return .{
            .status_code = 202,
            .headers = &.{
                .{ .name = "X-Test", .value = "first" },
                .{ .name = "x-test", .value = "second" },
            },
            .body = try allocator.dupe(u8, "fake-host"),
        };
    }
};

test "native fake host exercises target-neutral WASI adaptation" {
    var fake = RecordingHost{};
    var adapter = HttpTransportAdapter(*RecordingHost).init(
        std.testing.allocator,
        &fake,
    );
    var request = transport.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com:8443/path?query=yes",
    );
    defer request.deinit();
    try request.setHeader("Host", "ignored.example");
    try request.setHeader("TraceParent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    try request.setHeader("TraceState", "");
    var response = try adapter.asTransport().send(&request);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(transport.Method.GET, fake.method.?);
    try std.testing.expectEqual(Scheme.https, fake.scheme.?);
    try std.testing.expectEqualStrings("example.com:8443", fake.authorityValue());
    try std.testing.expectEqualStrings("/path?query=yes", fake.pathValue());
    try std.testing.expect(fake.saw_host);
    try std.testing.expectEqual(@as(usize, 2), fake.trace_headers_seen);
    try std.testing.expectEqualStrings("fake-host", response.body);
    const values = try response.getHeaderValues(std.testing.allocator, "x-test");
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("first", values[0]);
    try std.testing.expectEqualStrings("second", values[1]);

    var body_request = transport.Request.init(
        std.testing.allocator,
        .POST,
        "https://example.com/",
    );
    defer body_request.deinit();
    body_request.body = "unsupported";
    try std.testing.expectError(
        error.RequestBodyUnsupported,
        adapter.asTransport().send(&body_request),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "WASI adapter constructs a root path before a root query" {
    var fake = RecordingHost{};
    var adapter = HttpTransportAdapter(*RecordingHost).init(
        std.testing.allocator,
        &fake,
    );
    var request = transport.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com?api-version=1",
    );
    defer request.deinit();
    var response = try adapter.asTransport().send(&request);
    defer response.deinit();
    try std.testing.expectEqualStrings("example.com", fake.authorityValue());
    try std.testing.expectEqualStrings("/?api-version=1", fake.pathValue());
}

test "WASI adapter preserves an explicit authority port" {
    var fake = RecordingHost{};
    var adapter = HttpTransportAdapter(*RecordingHost).init(
        std.testing.allocator,
        &fake,
    );
    var request = transport.Request.init(
        std.testing.allocator,
        .GET,
        "http://example.com:8080/path",
    );
    defer request.deinit();
    var response = try adapter.asTransport().send(&request);
    defer response.deinit();
    try std.testing.expectEqual(Scheme.http, fake.scheme.?);
    try std.testing.expectEqualStrings("example.com:8080", fake.authorityValue());
    try std.testing.expectEqualStrings("/path", fake.pathValue());
}

test "WASI adapter omits URI fragments from the host request" {
    var fake = RecordingHost{};
    var adapter = HttpTransportAdapter(*RecordingHost).init(
        std.testing.allocator,
        &fake,
    );
    var request = transport.Request.init(
        std.testing.allocator,
        .GET,
        "https://example.com/path?query=yes#client-only",
    );
    defer request.deinit();
    var response = try adapter.asTransport().send(&request);
    defer response.deinit();
    try std.testing.expectEqualStrings("/path?query=yes", fake.pathValue());
}

test "WASI adapter rejects URI userinfo" {
    var fake = RecordingHost{};
    var adapter = HttpTransportAdapter(*RecordingHost).init(
        std.testing.allocator,
        &fake,
    );
    var request = transport.Request.init(
        std.testing.allocator,
        .GET,
        "https://username@example.com/path",
    );
    defer request.deinit();
    try std.testing.expectError(
        error.InvalidUrl,
        adapter.asTransport().send(&request),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}
