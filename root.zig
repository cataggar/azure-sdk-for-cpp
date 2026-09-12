//! Data Lake clients borrow their pipeline dependencies.
//!
//! `HttpPipeline`, `HttpRuntime`, and transport/crypto descriptors are copied
//! by value. Their policy objects and backend contexts remain borrowed and
//! must outlive every client and in-flight operation derived from them.
//! Optional pipeline instrumentation and its borrowed provider/configuration
//! are preserved in every derived file client.

const std = @import("std");
const core = @import("azure_sdk_core");

// ──────────────── DataLakeFileSystemClient ────────────────────

pub const DataLakeFileSystemClientOptions = struct {
    endpoint: []const u8,
    filesystem_name: []const u8,
    api_version: []const u8 = "2024-11-04",
};

pub const DataLakeFileSystemClient = struct {
    endpoint: []const u8,
    filesystem_name: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,

    /// Creates a filesystem client from the caller-owned canonical pipeline.
    ///
    /// The pipeline is copied by value. Its policies and the transport and
    /// crypto provider contexts in its runtime are borrowed for this client's
    /// lifetime and for the lifetime of every open operation. Optional tracing
    /// provider/configuration strings are borrowed for those same lifetimes.
    pub fn init(
        pipeline: core.http.HttpPipeline,
        options: DataLakeFileSystemClientOptions,
    ) DataLakeFileSystemClient {
        return .{
            .endpoint = options.endpoint,
            .filesystem_name = options.filesystem_name,
            .api_version = options.api_version,
            .pipeline = pipeline,
        };
    }

    /// PUT /filesystem?resource=filesystem
    pub fn create(self: *DataLakeFileSystemClient, allocator: std.mem.Allocator) !void {
        var r = try self.createResult(allocator);
        try r.unwrap(error.CreateFileSystemFailed);
    }

    /// Same as `create` but returns `Result(void)`.
    pub fn createResult(self: *DataLakeFileSystemClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}?resource=filesystem",
            .{ self.endpoint, self.filesystem_name },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .PUT, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// DELETE /filesystem?resource=filesystem
    pub fn deleteFileSystem(self: *DataLakeFileSystemClient, allocator: std.mem.Allocator) !void {
        var r = try self.deleteFileSystemResult(allocator);
        try r.unwrap(error.DeleteFileSystemFailed);
    }

    /// Same as `deleteFileSystem` but returns `Result(void)`.
    pub fn deleteFileSystemResult(self: *DataLakeFileSystemClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}?resource=filesystem",
            .{ self.endpoint, self.filesystem_name },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// Derives a file client while preserving the complete pipeline, including
    /// HTTP/crypto selections and optional caller-owned instrumentation.
    pub fn getFileClient(self: *DataLakeFileSystemClient, file_path: []const u8) DataLakeFileClient {
        return .{
            .endpoint = self.endpoint,
            .filesystem_name = self.filesystem_name,
            .file_path = file_path,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
        };
    }
};

// ──────────────────── DataLakeFileClient ──────────────────────

pub const DataLakeFileClient = struct {
    endpoint: []const u8,
    filesystem_name: []const u8,
    file_path: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,

    /// PUT /filesystem/path?resource=file
    pub fn create(self: *DataLakeFileClient, allocator: std.mem.Allocator) !void {
        var r = try self.createResult(allocator);
        try r.unwrap(error.CreateFileFailed);
    }

    /// Same as `create` but returns `Result(void)`.
    pub fn createResult(self: *DataLakeFileClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}?resource=file",
            .{ self.endpoint, self.filesystem_name, self.file_path },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .PUT, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// PATCH /filesystem/path?action=append&position={pos}
    pub fn append(self: *DataLakeFileClient, allocator: std.mem.Allocator, data: []const u8, position: u64) !void {
        var r = try self.appendResult(allocator, data, position);
        try r.unwrap(error.AppendFailed);
    }

    /// Same as `append` but returns `Result(void)`.
    pub fn appendResult(self: *DataLakeFileClient, allocator: std.mem.Allocator, data: []const u8, position: u64) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}?action=append&position={d}",
            .{ self.endpoint, self.filesystem_name, self.file_path, position },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/octet-stream");
        req.body = data;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// PATCH /filesystem/path?action=flush&position={pos}
    pub fn flush(self: *DataLakeFileClient, allocator: std.mem.Allocator, position: u64) !void {
        var r = try self.flushResult(allocator, position);
        try r.unwrap(error.FlushFailed);
    }

    /// Same as `flush` but returns `Result(void)`.
    pub fn flushResult(self: *DataLakeFileClient, allocator: std.mem.Allocator, position: u64) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}?action=flush&position={d}",
            .{ self.endpoint, self.filesystem_name, self.file_path, position },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .PATCH, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// GET /filesystem/path
    pub fn read(self: *DataLakeFileClient, allocator: std.mem.Allocator) ![]const u8 {
        var r = try self.readResult(allocator);
        return r.unwrap(error.ReadFailed);
    }

    /// Same as `read` but returns `Result([]const u8)`.
    pub fn readResult(self: *DataLakeFileClient, allocator: std.mem.Allocator) !core.errors.Result([]const u8) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}",
            .{ self.endpoint, self.filesystem_name, self.file_path },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .GET, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try allocator.dupe(u8, resp.body) };
    }

    /// DELETE /filesystem/path
    pub fn deleteFile(self: *DataLakeFileClient, allocator: std.mem.Allocator) !void {
        var r = try self.deleteFileResult(allocator);
        try r.unwrap(error.DeleteFileFailed);
    }

    /// Same as `deleteFile` but returns `Result(void)`.
    pub fn deleteFileResult(self: *DataLakeFileClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}",
            .{ self.endpoint, self.filesystem_name, self.file_path },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }
};

// ─────────────────────────── Tests ────────────────────────────

test "DataLakeFileClient create append flush and read" {
    const allocator = std.testing.allocator;
    var crypto_provider = core.crypto.StdCryptoProvider.init(std.testing.io);

    var mock_create = core.http.MockTransport.init(allocator, 201, "");
    defer mock_create.deinit();
    const create_runtime = core.http.HttpRuntime.init(
        mock_create.asTransport(),
        crypto_provider.asProvider(),
    );
    const create_pipeline = core.http.HttpPipeline.init(create_runtime, &.{});

    var fs_client = DataLakeFileSystemClient.init(
        create_pipeline,
        .{
            .endpoint = "https://myaccount.dfs.core.windows.net",
            .filesystem_name = "myfilesystem",
        },
    );

    try fs_client.create(allocator);
    try std.testing.expect(std.mem.find(u8, mock_create.last_url.?, "myfilesystem?resource=filesystem") != null);

    var file = fs_client.getFileClient("data/myfile.csv");

    // Create file
    var mock_file = core.http.MockTransport.init(allocator, 201, "");
    defer mock_file.deinit();
    file.pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(mock_file.asTransport(), crypto_provider.asProvider()),
        &.{},
    );
    try file.create(allocator);
    try std.testing.expect(std.mem.find(u8, mock_file.last_url.?, "data/myfile.csv?resource=file") != null);

    // Append data
    var mock_append = core.http.MockTransport.init(allocator, 202, "");
    defer mock_append.deinit();
    file.pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(mock_append.asTransport(), crypto_provider.asProvider()),
        &.{},
    );
    try file.append(allocator, "col1,col2\na,b\n", 0);
    try std.testing.expect(std.mem.find(u8, mock_append.last_url.?, "action=append&position=0") != null);

    // Read
    var mock_read = core.http.MockTransport.init(allocator, 200, "col1,col2\na,b\n");
    defer mock_read.deinit();
    file.pipeline = core.http.HttpPipeline.init(
        core.http.HttpRuntime.init(mock_read.asTransport(), crypto_provider.asProvider()),
        &.{},
    );

    const content = try file.read(allocator);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("col1,col2\na,b\n", content);
}

test "derived file client preserves runtime providers" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "");
    defer transport.deinit();
    var crypto_provider = core.crypto.StdCryptoProvider.init(std.testing.io);

    const runtime = core.http.HttpRuntime.init(
        transport.asTransport(),
        crypto_provider.asProvider(),
    );
    const pipeline = core.http.HttpPipeline.init(runtime, &.{});
    var filesystem = DataLakeFileSystemClient.init(pipeline, .{
        .endpoint = "https://myaccount.dfs.core.windows.net",
        .filesystem_name = "myfilesystem",
    });
    const file = filesystem.getFileClient("data/myfile.csv");

    try std.testing.expectEqual(
        pipeline.runtime.transport.context,
        file.pipeline.runtime.transport.context,
    );
    try std.testing.expectEqual(
        pipeline.runtime.transport.vtable,
        file.pipeline.runtime.transport.vtable,
    );
    try std.testing.expectEqual(
        pipeline.runtime.crypto.context,
        file.pipeline.runtime.crypto.context,
    );
    try std.testing.expectEqual(
        pipeline.runtime.crypto.vtable,
        file.pipeline.runtime.crypto.vtable,
    );
}

const TracingProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = &exportBatch },
    span_ids: [8][16]u8 = undefined,
    dispatched: usize = 0,
    exported: usize = 0,

    fn capture(self: *TracingProbe, transport: *core.http.MockTransport, enabled: bool) !void {
        const traceparent = transport.last_headers.get("traceparent");
        const tracestate = transport.last_headers.get("tracestate");
        if (enabled) {
            const context = core.tracing.TraceContext.parseTraceparent(traceparent orelse return error.MissingTraceparent) orelse
                return error.InvalidTraceparent;
            try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &context.trace_id);
            try std.testing.expectEqualStrings("vendor=value", tracestate orelse "");
            try std.testing.expect(!std.mem.eql(u8, "b7ad6b7169203331", &context.span_id));
            for (self.span_ids[0..self.dispatched]) |previous|
                try std.testing.expect(!std.mem.eql(u8, &previous, &context.span_id));
            self.span_ids[self.dispatched] = context.span_id;
        } else {
            try std.testing.expect(traceparent == null and tracestate == null);
        }
        self.dispatched += 1;
    }

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *TracingProbe = @fieldParentPtr("exporter", exporter);
        for (batch) |span| {
            try std.testing.expect(self.exported < self.dispatched);
            try std.testing.expectEqualStrings("caller.scope", span.scope_name);
            try std.testing.expectEqualStrings("caller-version", span.scope_version);
            try std.testing.expectEqual(core.tracing.SpanKind.client, span.kind);
            try std.testing.expectEqualStrings("b7ad6b7169203331", &span.parent_span_id.?);
            try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &span.context.trace_id);
            try std.testing.expectEqualStrings("vendor=value", span.context.trace_state orelse "");
            try std.testing.expectEqualStrings(&self.span_ids[self.exported], &span.context.span_id);
            var namespace_seen = false;
            for (span.attributes) |attribute| {
                if (!std.mem.eql(u8, "az.namespace", attribute.key)) continue;
                try std.testing.expect(attribute.value == .string);
                try std.testing.expectEqualStrings("Caller.Namespace", attribute.value.string);
                namespace_seen = true;
            }
            try std.testing.expect(namespace_seen);
            self.exported += 1;
        }
    }
};

test "caller tracing follows Data Lake filesystem and derived file operations, or stays disabled" {
    for ([_]bool{ true, false }) |enabled| {
        const allocator = std.testing.allocator;
        var transport = core.http.MockTransport.init(allocator, 200, "file contents");
        defer transport.deinit();
        var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
        const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
        var probe = TracingProbe{};
        var provider = try core.tracing.ExportingTracerProvider.init(
            allocator,
            std.testing.io,
            runtime.crypto,
            &probe.exporter,
            .{},
        );
        defer provider.deinit() catch unreachable;
        var pipeline = core.http.HttpPipeline.init(runtime, &.{});
        var parent = core.tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
        parent.trace_state = "vendor=value";
        if (enabled) pipeline.setInstrumentation(.{
            .provider = provider.asProvider(),
            .scope_name = "caller.scope",
            .scope_version = "caller-version",
            .namespace = "Caller.Namespace",
            .parent_context = parent,
        });
        var filesystem = DataLakeFileSystemClient.init(pipeline, .{
            .endpoint = "https://account.dfs.core.windows.net",
            .filesystem_name = "filesystem",
        });
        var file = filesystem.getFileClient("directory/file");
        pipeline.setInstrumentation(null);

        try filesystem.create(allocator);
        try probe.capture(&transport, enabled);
        filesystem.pipeline.setInstrumentation(null);
        try file.create(allocator);
        try probe.capture(&transport, enabled);
        try file.append(allocator, "data", 0);
        try probe.capture(&transport, enabled);
        try file.flush(allocator, 4);
        try probe.capture(&transport, enabled);
        const content = try file.read(allocator);
        defer allocator.free(content);
        try std.testing.expectEqualStrings("file contents", content);
        try probe.capture(&transport, enabled);

        const expected: usize = if (enabled) 5 else 0;
        try std.testing.expectEqual(@as(usize, 5), transport.call_count);
        try std.testing.expectEqual(@as(usize, 0), probe.exported);
        try std.testing.expectEqual(expected, provider.stats().queued_spans);
        try std.testing.expectEqual(@as(usize, 0), provider.stats().active_spans);
        try std.testing.expect(!provider.closed);
        try provider.forceFlush(1000);
        try std.testing.expectEqual(expected, probe.exported);
        try std.testing.expectEqual(@as(u64, expected), provider.stats().started);
        try std.testing.expectEqual(@as(u64, expected), provider.stats().ended);
        try provider.shutdown(1000);
    }
}
