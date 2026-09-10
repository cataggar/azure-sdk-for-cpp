const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status_code: u16 = 200,
    reason: []const u8 = "OK",
    headers: []const Header = &.{},
    body: []const u8 = "",
    chunked: bool = false,
    advertised_content_length: ?usize = null,
    omit_body: bool = false,
    generated_body: ?GeneratedBody = null,
};

pub const GeneratedBody = struct {
    byte: u8,
    length: usize,
    chunk_size: usize = 4093,
};

pub const CapturedRequest = struct {
    request_line: []u8,
    header_lines: std.ArrayList([]u8),
    body_prefix: [4096]u8,
    body_prefix_len: usize,
    body_length: usize,
    body_hash: u64,

    pub fn headerValue(self: *const CapturedRequest, name: []const u8) ?[]const u8 {
        for (self.header_lines.items) |line| {
            const header = ScriptedHttpServer.splitHeader(line) orelse continue;
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }
};

const StopInterleaveHooks = struct {
    stream_active: *std.Io.Event,
    stop_locked: *std.Io.Event,
    release_stop: *std.Io.Event,
    cleanup_entered: *std.Io.Event,
};

/// A loopback HTTP/1.1 server for deterministic transport tests. By default it
/// serves one request; a nonempty responses script runs until stopAndJoin.
///
/// Request bodies are counted while only a bounded prefix is retained, so
/// conformance tests can exercise logical-large streams without allocating
/// storage proportional to the upload.
pub const ScriptedHttpServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    listener: std.Io.net.Server,
    response: Response,
    thread: ?std.Thread = null,
    joined: bool = false,
    stopping: bool = false,
    mutex: std.Io.Mutex = .init,
    active_stream: ?std.Io.net.Stream = null,
    done: std.Io.Event = .unset,
    stop_interleave: ?StopInterleaveHooks = null,
    allow_peer_failure: bool = false,
    failure: ?anyerror = null,
    request_line: []u8 = &.{},
    header_lines: std.ArrayList([]u8) = .empty,
    body_prefix: [4096]u8 = undefined,
    body_prefix_len: usize = 0,
    body_length: usize = 0,
    body_hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),
    /// Nonempty scripts serve successive connections until stopAndJoin.
    /// Exhausted scripts return 418 rather than hanging an unexpected retry.
    responses: []const Response = &.{},
    requests: std.ArrayList(CapturedRequest) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        response: Response,
    ) !ScriptedHttpServer {
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{
            .allocator = allocator,
            .io = io,
            .listener = try address.listen(io, .{ .reuse_address = true }),
            .response = response,
        };
    }

    pub fn start(self: *ScriptedHttpServer) !void {
        if (self.thread != null) return error.ServerAlreadyStarted;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn allocUrl(
        self: *const ScriptedHttpServer,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "http://127.0.0.1:{d}{s}",
            .{ self.listener.socket.address.getPort(), path },
        );
    }

    pub fn join(self: *ScriptedHttpServer) !void {
        if (!self.joined) {
            self.waitForDone() catch |err| switch (err) {
                error.Timeout, error.Canceled => {
                    self.requestStop();
                    try self.waitForDone();
                    self.joinThread();
                    return error.ServerJoinTimedOut;
                },
            };
            self.joinThread();
        }
        if (self.failure) |failure| {
            if (!self.allow_peer_failure) return failure;
        }
    }

    pub fn deinit(self: *ScriptedHttpServer) void {
        self.stopAndJoin() catch @panic("scripted HTTP server failed to stop");
        self.listener.deinit(self.io);
        if (self.request_line.len > 0) self.allocator.free(self.request_line);
        for (self.header_lines.items) |line| self.allocator.free(line);
        self.header_lines.deinit(self.allocator);
        for (self.requests.items) |*request| {
            self.allocator.free(request.request_line);
            for (request.header_lines.items) |line| self.allocator.free(line);
            request.header_lines.deinit(self.allocator);
        }
        self.requests.deinit(self.allocator);
    }

    pub fn stopAndJoin(self: *ScriptedHttpServer) !void {
        if (self.joined or self.thread == null) return;
        self.requestStop();
        try self.waitForDone();
        self.joinThread();
    }

    fn waitForDone(self: *ScriptedHttpServer) !void {
        return self.done.waitTimeout(
            self.io,
            .{
                .duration = .{
                    .raw = .fromSeconds(2),
                    .clock = .awake,
                },
            },
        );
    }

    fn joinThread(self: *ScriptedHttpServer) void {
        if (self.joined) return;
        if (self.thread) |thread| thread.join();
        self.joined = true;
    }

    fn requestStop(self: *ScriptedHttpServer) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        if (self.active_stream) |stream| {
            if (self.stop_interleave) |hooks| {
                hooks.stop_locked.set(self.io);
                hooks.release_stop.waitUncancelable(self.io);
            }
            // Keep the native handle protected until shutdown completes.
            // Stream cleanup takes the same mutex before clearing and closing.
            stream.shutdown(self.io, .both) catch {};
            self.mutex.unlock(self.io);
            return;
        }
        self.mutex.unlock(self.io);

        // The listener remains open until after the server thread joins.
        // Once `stopping` is set, serve cannot publish a newly accepted stream.
        const wake_stream = self.listener.socket.address.connect(
            self.io,
            .{ .mode = .stream },
        ) catch return;
        wake_stream.close(self.io);
    }

    fn isStopping(self: *ScriptedHttpServer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stopping;
    }

    pub fn body(self: *const ScriptedHttpServer) []const u8 {
        return self.body_prefix[0..self.body_prefix_len];
    }

    pub fn headerCount(self: *const ScriptedHttpServer, name: []const u8) usize {
        var count: usize = 0;
        for (self.header_lines.items) |line| {
            const header = splitHeader(line) orelse continue;
            if (std.ascii.eqlIgnoreCase(header.name, name)) count += 1;
        }
        return count;
    }

    pub fn headerValue(
        self: *const ScriptedHttpServer,
        name: []const u8,
    ) ?[]const u8 {
        for (self.header_lines.items) |line| {
            const header = splitHeader(line) orelse continue;
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }

    fn splitHeader(line: []const u8) ?Header {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        return .{
            .name = line[0..colon],
            .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
        };
    }

    fn run(self: *ScriptedHttpServer) void {
        defer self.done.set(self.io);
        while (!self.isStopping()) {
            if (self.responses.len > 0) {
                self.response = if (self.requests.items.len < self.responses.len)
                    self.responses[self.requests.items.len]
                else
                    .{ .status_code = 418, .reason = "Unexpected attempt" };
            }
            self.serve() catch |err| {
                if (!self.isStopping()) self.failure = err;
                return;
            };
            if (self.responses.len == 0 or self.isStopping()) return;
        }
    }

    fn serve(self: *ScriptedHttpServer) !void {
        const stream = self.listener.accept(self.io) catch |err| {
            if (self.isStopping()) return;
            return err;
        };
        self.mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            stream.close(self.io);
            return;
        }
        self.active_stream = stream;
        self.mutex.unlock(self.io);
        if (self.stop_interleave) |hooks| hooks.stream_active.set(self.io);
        defer {
            if (self.stop_interleave) |hooks| hooks.cleanup_entered.set(self.io);
            self.mutex.lockUncancelable(self.io);
            self.active_stream = null;
            self.mutex.unlock(self.io);
            stream.close(self.io);
        }

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, self.io, &read_buffer);
        var write_buffer: [16 * 1024]u8 = undefined;
        var writer = std.Io.net.Stream.Writer.init(stream, self.io, &write_buffer);

        const first = (reader.interface.takeDelimiter('\n') catch
            return error.ServerHeaderReadFailed) orelse
            return error.ServerHeaderReadFailed;
        const first_line = std.mem.trimEnd(u8, first, "\r");
        self.request_line = try self.allocator.dupe(u8, first_line);

        var content_length: ?usize = null;
        var chunked = false;
        while (true) {
            const raw_line = (reader.interface.takeDelimiter('\n') catch
                return error.ServerHeaderReadFailed) orelse
                return error.ServerHeaderReadFailed;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) break;
            const owned_line = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(owned_line);
            try self.header_lines.append(self.allocator, owned_line);
            const header = splitHeader(line) orelse continue;
            if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
                content_length = try std.fmt.parseInt(usize, header.value, 10);
            } else if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) {
                chunked = std.ascii.eqlIgnoreCase(header.value, "chunked");
            }
        }

        if (chunked) {
            try self.readChunkedBody(&reader.interface);
        } else if (content_length) |length| {
            try self.readBody(&reader.interface, length);
        }

        if (self.responses.len > 0) {
            try self.requests.append(self.allocator, .{
                .request_line = self.request_line,
                .header_lines = self.header_lines,
                .body_prefix = self.body_prefix,
                .body_prefix_len = self.body_prefix_len,
                .body_length = self.body_length,
                .body_hash = self.body_hasher.final(),
            });
            self.request_line = &.{};
            self.header_lines = .empty;
            self.body_prefix_len = 0;
            self.body_length = 0;
            self.body_hasher = std.hash.Wyhash.init(0);
        }

        try writer.interface.print(
            "HTTP/1.1 {d} {s}\r\n",
            .{ self.response.status_code, self.response.reason },
        );
        for (self.response.headers) |header| {
            try writer.interface.print(
                "{s}: {s}\r\n",
                .{ header.name, header.value },
            );
        }
        if (self.response.chunked) {
            try writer.interface.writeAll(
                "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
            );
            if (!self.response.omit_body and self.response.generated_body != null) {
                try writeGenerated(&writer.interface, self.response.generated_body.?, true);
            } else if (!self.response.omit_body and self.response.body.len > 0) {
                const midpoint = (self.response.body.len + 1) / 2;
                try writer.interface.print("{x}\r\n", .{midpoint});
                try writer.interface.writeAll(self.response.body[0..midpoint]);
                if (midpoint < self.response.body.len) {
                    try writer.interface.print(
                        "\r\n{x}\r\n",
                        .{self.response.body.len - midpoint},
                    );
                    try writer.interface.writeAll(self.response.body[midpoint..]);
                }
                try writer.interface.writeAll("\r\n");
            }
            try writer.interface.writeAll("0\r\n\r\n");
        } else {
            const content_length_value = self.response.advertised_content_length orelse
                if (self.response.generated_body) |generated| generated.length else self.response.body.len;
            try writer.interface.print(
                "Content-Length: {d}\r\nConnection: close\r\n\r\n",
                .{content_length_value},
            );
            if (!self.response.omit_body) {
                if (self.response.generated_body) |generated| {
                    try writeGenerated(&writer.interface, generated, false);
                } else {
                    try writer.interface.writeAll(self.response.body);
                }
            }
        }
        try writer.interface.flush();
    }

    fn writeGenerated(writer: *std.Io.Writer, generated: GeneratedBody, chunked: bool) !void {
        if (generated.chunk_size == 0) return error.InvalidGeneratedChunkSize;
        var buffer: [16 * 1024]u8 = undefined;
        @memset(&buffer, generated.byte);
        var remaining = generated.length;
        while (remaining > 0) {
            const count = @min(remaining, buffer.len, generated.chunk_size);
            if (chunked) try writer.print("{x}\r\n", .{count});
            try writer.writeAll(buffer[0..count]);
            if (chunked) try writer.writeAll("\r\n");
            remaining -= count;
        }
    }

    fn readChunkedBody(
        self: *ScriptedHttpServer,
        reader: *std.Io.Reader,
    ) !void {
        while (true) {
            const raw_size = (reader.takeDelimiter('\n') catch
                return error.ServerChunkHeaderReadFailed) orelse
                return error.ServerChunkHeaderReadFailed;
            const size_text = std.mem.trim(u8, raw_size, "\r \t");
            const semicolon = std.mem.indexOfScalar(u8, size_text, ';') orelse
                size_text.len;
            const size = try std.fmt.parseInt(usize, size_text[0..semicolon], 16);
            if (size == 0) {
                while (true) {
                    const trailer = (reader.takeDelimiter('\n') catch
                        return error.ServerChunkTrailerReadFailed) orelse
                        return error.ServerChunkTrailerReadFailed;
                    if (std.mem.trimEnd(u8, trailer, "\r").len == 0) break;
                }
                return;
            }
            try self.readBody(reader, size);
            var crlf: [2]u8 = undefined;
            reader.readSliceAll(&crlf) catch
                return error.ServerChunkTerminatorReadFailed;
            if (!std.mem.eql(u8, &crlf, "\r\n")) return error.InvalidChunkTerminator;
        }
    }

    fn readBody(
        self: *ScriptedHttpServer,
        reader: *std.Io.Reader,
        length: usize,
    ) !void {
        var remaining = length;
        var buffer: [16 * 1024]u8 = undefined;
        while (remaining > 0) {
            const amount = @min(remaining, buffer.len);
            reader.readSliceAll(buffer[0..amount]) catch
                return error.ServerBodyReadFailed;
            const prefix_remaining = self.body_prefix.len - self.body_prefix_len;
            const copy_len = @min(prefix_remaining, amount);
            if (copy_len > 0) {
                @memcpy(
                    self.body_prefix[self.body_prefix_len..][0..copy_len],
                    buffer[0..copy_len],
                );
                self.body_prefix_len += copy_len;
            }
            self.body_length += amount;
            self.body_hasher.update(buffer[0..amount]);
            remaining -= amount;
        }
    }
};

fn elapsedNanoseconds(io: std.Io, start: std.Io.Timestamp) i128 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds() -
        start.toNanoseconds();
}

test "scripted server teardown completes without a client" {
    const io = std.testing.io;
    var server = try ScriptedHttpServer.init(
        std.testing.allocator,
        io,
        .{},
    );
    try server.start();
    const start = std.Io.Timestamp.now(io, .awake);
    server.deinit();
    try std.testing.expect(
        elapsedNanoseconds(io, start) < 5 * std.time.ns_per_s,
    );
}

test "scripted server teardown interrupts a stalled request body" {
    const io = std.testing.io;
    var server = try ScriptedHttpServer.init(
        std.testing.allocator,
        io,
        .{},
    );
    try server.start();

    const stream = try server.listener.socket.address.connect(
        io,
        .{ .mode = .stream },
    );
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &write_buffer);
    try writer.interface.writeAll(
        "POST /stalled HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Length: 1024\r\n\r\n" ++
            "x",
    );
    try writer.interface.flush();

    const start = std.Io.Timestamp.now(io, .awake);
    server.deinit();
    try std.testing.expect(
        elapsedNanoseconds(io, start) < 5 * std.time.ns_per_s,
    );
}

test "requestStop protects stream handle through concurrent cleanup" {
    const Stopper = struct {
        fn run(server: *ScriptedHttpServer) void {
            server.requestStop();
        }
    };

    const io = std.testing.io;
    var stream_active: std.Io.Event = .unset;
    var stop_locked: std.Io.Event = .unset;
    var release_stop: std.Io.Event = .unset;
    var cleanup_entered: std.Io.Event = .unset;
    var server = try ScriptedHttpServer.init(
        std.testing.allocator,
        io,
        .{},
    );
    var server_deinitialized = false;
    defer if (!server_deinitialized) server.deinit();
    server.stop_interleave = .{
        .stream_active = &stream_active,
        .stop_locked = &stop_locked,
        .release_stop = &release_stop,
        .cleanup_entered = &cleanup_entered,
    };
    try server.start();

    const client = try server.listener.socket.address.connect(
        io,
        .{ .mode = .stream },
    );
    var client_closed = false;
    defer if (!client_closed) client.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(client, io, &write_buffer);
    try writer.interface.writeAll(
        "POST /interleave HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Length: 1024\r\n\r\n" ++
            "x",
    );
    try writer.interface.flush();
    stream_active.waitUncancelable(io);

    server.mutex.lockUncancelable(io);
    const protected_handle = server.active_stream.?.socket.handle;
    server.mutex.unlock(io);

    const stopper = try std.Thread.spawn(.{}, Stopper.run, .{&server});
    var stopper_joined = false;
    defer if (!stopper_joined) {
        release_stop.set(io);
        stopper.join();
    };
    stop_locked.waitUncancelable(io);
    client.close(io);
    client_closed = true;
    cleanup_entered.waitUncancelable(io);

    // If cleanup could close between the stop snapshot and shutdown, the OS
    // could immediately reuse that descriptor for one of these connections.
    var churn_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var churn_listener = try churn_address.listen(io, .{ .reuse_address = true });
    defer churn_listener.deinit(io);
    for (0..32) |_| {
        const churn_client = try churn_listener.socket.address.connect(
            io,
            .{ .mode = .stream },
        );
        const churn_server = try churn_listener.accept(io);
        try std.testing.expect(churn_client.socket.handle != protected_handle);
        try std.testing.expect(churn_server.socket.handle != protected_handle);
        churn_client.close(io);
        churn_server.close(io);
    }

    release_stop.set(io);
    stopper.join();
    stopper_joined = true;
    try server.join();
    server.deinit();
    server_deinitialized = true;
}
