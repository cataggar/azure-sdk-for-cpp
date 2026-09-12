const std = @import("std");
const core = @import("azure_sdk_core");

// ─────────────────────── ShareServiceClient ──────────────────

pub const ShareServiceClientOptions = struct {
    api_version: []const u8 = "2024-11-04",
};

/// Account-scoped Azure Files client.
///
/// The endpoint, option strings, pipeline policy storage, and the backend
/// contexts borrowed by `pipeline.runtime`, and any instrumentation provider
/// and configuration strings must outlive this client and its descendants.
pub const ShareServiceClient = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,

    pub fn init(
        pipeline: core.http.HttpPipeline,
        endpoint: []const u8,
        options: ShareServiceClientOptions,
    ) ShareServiceClient {
        return .{
            .endpoint = endpoint,
            .api_version = options.api_version,
            .pipeline = pipeline,
        };
    }

    pub fn getShareClient(self: *const ShareServiceClient, share_name: []const u8) ShareClient {
        return .{
            .endpoint = self.endpoint,
            .share_name = share_name,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
        };
    }
};

// ─────────────────────────── ShareClient ──────────────────────

pub const ShareClientOptions = struct {
    api_version: []const u8 = "2024-11-04",
};

/// Share-scoped Azure Files client.
///
/// The endpoint, share name, option strings, pipeline policy storage, and the
/// backend contexts borrowed by `pipeline.runtime`, and any instrumentation
/// provider/configuration strings must outlive this client and its descendants.
pub const ShareClient = struct {
    endpoint: []const u8,
    share_name: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,

    pub fn init(
        pipeline: core.http.HttpPipeline,
        endpoint: []const u8,
        share_name: []const u8,
        options: ShareClientOptions,
    ) ShareClient {
        return .{
            .endpoint = endpoint,
            .share_name = share_name,
            .api_version = options.api_version,
            .pipeline = pipeline,
        };
    }

    /// PUT /share?restype=share
    pub fn create(self: *ShareClient, allocator: std.mem.Allocator) !void {
        var r = try self.createResult(allocator);
        try r.unwrap(error.CreateShareFailed);
    }

    /// Same as `create` but returns `Result(void)`.
    pub fn createResult(self: *ShareClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}?restype=share",
            .{ self.endpoint, self.share_name },
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

    /// DELETE /share?restype=share
    pub fn deleteShare(self: *ShareClient, allocator: std.mem.Allocator) !void {
        var r = try self.deleteShareResult(allocator);
        try r.unwrap(error.DeleteShareFailed);
    }

    /// Same as `deleteShare` but returns `Result(void)`.
    pub fn deleteShareResult(self: *ShareClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}?restype=share",
            .{ self.endpoint, self.share_name },
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

    pub fn getDirectoryClient(self: *const ShareClient, directory_name: []const u8) ShareDirectoryClient {
        return .{
            .endpoint = self.endpoint,
            .share_name = self.share_name,
            .directory_name = directory_name,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
        };
    }
};

// ────────────────────── ShareDirectoryClient ──────────────────

pub const ShareDirectoryClientOptions = struct {
    api_version: []const u8 = "2024-11-04",
};

/// Directory-scoped Azure Files client.
///
/// The endpoint, names, option strings, pipeline policy storage, and the
/// backend contexts borrowed by `pipeline.runtime`, and any instrumentation
/// provider/configuration strings must outlive this client and its descendants.
pub const ShareDirectoryClient = struct {
    endpoint: []const u8,
    share_name: []const u8,
    directory_name: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,

    pub fn init(
        pipeline: core.http.HttpPipeline,
        endpoint: []const u8,
        share_name: []const u8,
        directory_name: []const u8,
        options: ShareDirectoryClientOptions,
    ) ShareDirectoryClient {
        return .{
            .endpoint = endpoint,
            .share_name = share_name,
            .directory_name = directory_name,
            .api_version = options.api_version,
            .pipeline = pipeline,
        };
    }

    /// PUT /share/directory?restype=directory
    pub fn create(self: *ShareDirectoryClient, allocator: std.mem.Allocator) !void {
        var r = try self.createResult(allocator);
        try r.unwrap(error.CreateDirectoryFailed);
    }

    /// Same as `create` but returns `Result(void)`.
    pub fn createResult(self: *ShareDirectoryClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}?restype=directory",
            .{ self.endpoint, self.share_name, self.directory_name },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .PUT, url);
        defer req.deinit();
        try req.setHeader("x-ms-type", "directory");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// DELETE /share/directory?restype=directory
    pub fn deleteDirectory(self: *ShareDirectoryClient, allocator: std.mem.Allocator) !void {
        var r = try self.deleteDirectoryResult(allocator);
        try r.unwrap(error.DeleteDirectoryFailed);
    }

    /// Same as `deleteDirectory` but returns `Result(void)`.
    pub fn deleteDirectoryResult(self: *ShareDirectoryClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}?restype=directory",
            .{ self.endpoint, self.share_name, self.directory_name },
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

    pub fn getFileClient(self: *const ShareDirectoryClient, file_name: []const u8) ShareFileClient {
        return .{
            .endpoint = self.endpoint,
            .share_name = self.share_name,
            .directory_name = self.directory_name,
            .file_name = file_name,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
        };
    }
};

// ──────────────────────── ShareFileClient ─────────────────────

pub const ShareFileClientOptions = struct {
    api_version: []const u8 = "2024-11-04",
};

/// File-scoped Azure Files client.
///
/// The endpoint, names, option strings, pipeline policy storage, and the
/// transport/crypto contexts borrowed by `pipeline.runtime`, and any
/// instrumentation provider/configuration strings must outlive this client.
pub const ShareFileClient = struct {
    endpoint: []const u8,
    share_name: []const u8,
    directory_name: []const u8,
    file_name: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,

    pub fn init(
        pipeline: core.http.HttpPipeline,
        endpoint: []const u8,
        share_name: []const u8,
        directory_name: []const u8,
        file_name: []const u8,
        options: ShareFileClientOptions,
    ) ShareFileClient {
        return .{
            .endpoint = endpoint,
            .share_name = share_name,
            .directory_name = directory_name,
            .file_name = file_name,
            .api_version = options.api_version,
            .pipeline = pipeline,
        };
    }

    /// PUT /share/dir/file (create with x-ms-type: file and x-ms-content-length)
    pub fn create(self: *ShareFileClient, allocator: std.mem.Allocator, content_length: u64) !void {
        var r = try self.createResult(allocator, content_length);
        try r.unwrap(error.CreateFileFailed);
    }

    /// Same as `create` but returns `Result(void)`.
    pub fn createResult(self: *ShareFileClient, allocator: std.mem.Allocator, content_length: u64) !core.errors.Result(void) {
        const url = try self.buildFileUrl(allocator);
        defer allocator.free(url);

        const len_str = try std.fmt.allocPrint(allocator, "{d}", .{content_length});
        defer allocator.free(len_str);

        var req = core.http.Request.init(allocator, .PUT, url);
        defer req.deinit();
        try req.setHeader("x-ms-type", "file");
        try req.setHeader("x-ms-content-length", len_str);

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// PUT /share/dir/file?comp=range
    pub fn upload(self: *ShareFileClient, allocator: std.mem.Allocator, data: []const u8) !void {
        var r = try self.uploadResult(allocator, data);
        try r.unwrap(error.UploadFailed);
    }

    /// Same as `upload` but returns `Result(void)`.
    pub fn uploadResult(self: *ShareFileClient, allocator: std.mem.Allocator, data: []const u8) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}/{s}?comp=range",
            .{ self.endpoint, self.share_name, self.directory_name, self.file_name },
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .PUT, url);
        defer req.deinit();
        try req.setHeader("x-ms-write", "update");
        try req.setHeader("x-ms-type", "file");
        req.body = data;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// GET /share/dir/file
    pub fn download(self: *ShareFileClient, allocator: std.mem.Allocator) ![]const u8 {
        var r = try self.downloadResult(allocator);
        return r.unwrap(error.DownloadFailed);
    }

    /// Same as `download` but returns `Result([]const u8)`.
    pub fn downloadResult(self: *ShareFileClient, allocator: std.mem.Allocator) !core.errors.Result([]const u8) {
        const url = try self.buildFileUrl(allocator);
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

    /// DELETE /share/dir/file
    pub fn deleteFile(self: *ShareFileClient, allocator: std.mem.Allocator) !void {
        var r = try self.deleteFileResult(allocator);
        try r.unwrap(error.DeleteFileFailed);
    }

    /// Same as `deleteFile` but returns `Result(void)`.
    pub fn deleteFileResult(self: *ShareFileClient, allocator: std.mem.Allocator) !core.errors.Result(void) {
        const url = try self.buildFileUrl(allocator);
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

    fn buildFileUrl(self: *ShareFileClient, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}/{s}",
            .{ self.endpoint, self.share_name, self.directory_name, self.file_name },
        );
    }
};

// ─────────────────────────── Tests ────────────────────────────

test "ShareFileClient create and download" {
    const allocator = std.testing.allocator;
    var mock_create = core.http.MockTransport.init(allocator, 201, "");
    defer mock_create.deinit();

    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(
        mock_create.asTransport(),
        crypto.asProvider(),
    );
    const pipeline = core.http.HttpPipeline.init(runtime, &.{});
    var service = ShareServiceClient.init(
        pipeline,
        "https://myaccount.file.core.windows.net",
        .{},
    );
    var share = service.getShareClient("myshare");

    try share.create(allocator);
    try std.testing.expect(std.mem.find(u8, mock_create.last_url.?, "myshare?restype=share") != null);

    // Create directory and file
    var dir = share.getDirectoryClient("mydir");
    try dir.create(allocator);

    var file = dir.getFileClient("readme.txt");
    mock_create.response_status = 200;
    mock_create.response_body = "file content here";

    const content = try file.download(allocator);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("file content here", content);
}

test "constructors and derived clients preserve the selected runtime providers" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "");
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
    const pipeline = core.http.HttpPipeline.init(runtime, &.{});

    var service = ShareServiceClient.init(pipeline, "https://example.file.core.windows.net", .{});
    var share = service.getShareClient("share");
    var directory = share.getDirectoryClient("directory");
    const file = directory.getFileClient("file");

    inline for (.{ service.pipeline, share.pipeline, directory.pipeline, file.pipeline }) |client_pipeline| {
        try std.testing.expectEqual(runtime.transport.context, client_pipeline.runtime.transport.context);
        try std.testing.expectEqual(runtime.transport.vtable, client_pipeline.runtime.transport.vtable);
        try std.testing.expectEqual(runtime.crypto.context, client_pipeline.runtime.crypto.context);
        try std.testing.expectEqual(runtime.crypto.vtable, client_pipeline.runtime.crypto.vtable);
    }

    const direct_share = ShareClient.init(pipeline, service.endpoint, "share", .{});
    const direct_directory = ShareDirectoryClient.init(
        pipeline,
        service.endpoint,
        "share",
        "directory",
        .{},
    );
    const direct_file = ShareFileClient.init(
        pipeline,
        service.endpoint,
        "share",
        "directory",
        "file",
        .{},
    );
    inline for (.{ direct_share.pipeline, direct_directory.pipeline, direct_file.pipeline }) |client_pipeline| {
        try std.testing.expectEqual(runtime.transport.context, client_pipeline.runtime.transport.context);
        try std.testing.expectEqual(runtime.crypto.context, client_pipeline.runtime.crypto.context);
    }
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

test "caller tracing is inherited by every Shares constructor and descendant, or stays disabled" {
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
        var service = ShareServiceClient.init(pipeline, "https://account.file.core.windows.net", .{});
        var share = service.getShareClient("share");
        var directory = share.getDirectoryClient("directory");
        var file = directory.getFileClient("file");
        var direct_share = ShareClient.init(pipeline, service.endpoint, "share", .{});
        var direct_directory = ShareDirectoryClient.init(pipeline, service.endpoint, "share", "directory", .{});
        var direct_file = ShareFileClient.init(pipeline, service.endpoint, "share", "directory", "file", .{});
        pipeline.setInstrumentation(null);
        service.pipeline.setInstrumentation(null);

        try share.create(allocator);
        try probe.capture(&transport, enabled);
        share.pipeline.setInstrumentation(null);
        try directory.create(allocator);
        try probe.capture(&transport, enabled);
        directory.pipeline.setInstrumentation(null);
        try file.create(allocator, 13);
        try probe.capture(&transport, enabled);
        try direct_share.deleteShare(allocator);
        try probe.capture(&transport, enabled);
        try direct_directory.deleteDirectory(allocator);
        try probe.capture(&transport, enabled);
        const content = try direct_file.download(allocator);
        defer allocator.free(content);
        try std.testing.expectEqualStrings("file contents", content);
        try probe.capture(&transport, enabled);

        const expected: usize = if (enabled) 6 else 0;
        try std.testing.expectEqual(@as(usize, 6), transport.call_count);
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
