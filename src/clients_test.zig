const std = @import("std");
const core = @import("azure_sdk_core");
const serde = @import("serde");
const clients = @import("clients.zig");
const models = @import("models.zig");

test "all 29 stable operations are directly accessible" {
    try expectPublicMethods(clients.ContainerRegistryClient, &.{
        "containerRegistry",
        "containerRegistryBlob",
        "authentication",
    });
    try expectPublicMethods(clients.ContainerRegistry, &.{
        "checkDockerV2Support",
        "getManifest",
        "createManifest",
        "deleteManifest",
        "getRepositories",
        "getProperties",
        "deleteRepository",
        "updateProperties",
        "getTags",
        "getTagProperties",
        "updateTagAttributes",
        "deleteTag",
        "getManifests",
        "getManifestProperties",
        "updateManifestProperties",
    });
    try expectPublicMethods(clients.ContainerRegistryBlob, &.{
        "getBlob",
        "checkBlobExists",
        "deleteBlob",
        "mountBlob",
        "getUploadStatus",
        "uploadChunk",
        "completeUpload",
        "cancelUpload",
        "startUpload",
        "getChunk",
        "checkChunkExists",
    });
    try expectPublicMethods(clients.Authentication, &.{
        "exchangeAadAccessTokenForAcrRefreshToken",
        "exchangeAcrRefreshTokenForAcrAccessToken",
        "getAcrAccessTokenFromLogin",
    });
}

fn expectPublicMethods(comptime Client: type, comptime methods: []const []const u8) !void {
    inline for (methods) |method| {
        try std.testing.expect(@hasDecl(Client, method));
    }
}

const Mock = struct {
    allocator: std.mem.Allocator,
    mode: enum { blob, redirect, multipart, cancel },
    calls: usize = 0,
    expected_trace: ?bool = null,
    wire_span_id: ?[16]u8 = null,

    fn init(allocator: std.mem.Allocator, mode: @FieldType(@This(), "mode")) @This() {
        return .{ .allocator = allocator, .mode = mode };
    }

    fn asTransport(self: *@This()) core.http.HttpTransport {
        return .{
            .context = self,
            .vtable = &.{ .send = send },
        };
    }

    fn send(context: *anyopaque, request: *core.http.Request) !core.http.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.expected_trace) |traced| {
            try std.testing.expectEqualStrings("azsdk-zig-azure_rest_container_registry/0.3.0", request.getHeader("User-Agent").?);
            try std.testing.expectEqual(traced, request.getHeader("traceparent") != null);
            if (traced) {
                const parent = core.tracing.TraceContext.parseTraceparent(request.getHeader("traceparent").?).?;
                self.wire_span_id = parent.span_id;
                try std.testing.expectEqualStrings("vendor=caller", request.getHeader("tracestate").?);
            } else {
                try std.testing.expect(request.getHeader("tracestate") == null);
            }
        }
        const headers = std.StringHashMap([]const u8).init(self.allocator);
        var response_headers = core.http.ResponseHeaders.init(self.allocator);
        const status: u16, const body: []u8 = switch (self.mode) {
            .blob => .{
                200,
                try self.blobResponse(request, &response_headers),
            },
            .redirect => .{
                307,
                try self.redirectResponse(request, &response_headers),
            },
            .multipart => .{
                200,
                try self.multipartResponse(request),
            },
            .cancel => .{
                204,
                try self.cancelResponse(request),
            },
        };
        return .{
            .status_code = status,
            .headers = headers,
            .body = body,
            .allocator = self.allocator,
            .response_headers = response_headers,
        };
    }

    fn blobResponse(
        self: *@This(),
        request: *core.http.Request,
        response_headers: *core.http.ResponseHeaders,
    ) ![]u8 {
        try std.testing.expectEqualStrings(
            "application/octet-stream",
            request.getHeader("Accept").?,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, request.url, "/v2/team/app/blobs/sha256%3Aabc") != null,
        );
        try response_headers.append("Content-Length", "4");
        try response_headers.append("Docker-Content-Digest", "sha256:abc");
        return self.allocator.dupe(u8, "blob");
    }

    fn redirectResponse(
        self: *@This(),
        request: *core.http.Request,
        response_headers: *core.http.ResponseHeaders,
    ) ![]u8 {
        try std.testing.expectEqual(
            core.http.RedirectPolicy.not_allowed,
            request.redirect_policy,
        );
        try response_headers.append("Location", "https://storage.example/blob");
        return self.allocator.alloc(u8, 0);
    }

    fn multipartResponse(self: *@This(), request: *core.http.Request) ![]u8 {
        try std.testing.expect(std.mem.startsWith(
            u8,
            request.getHeader("Content-Type").?,
            "multipart/form-data; boundary=",
        ));
        try std.testing.expect(
            std.mem.indexOf(u8, request.body.?, "name=\"grantType\"") != null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, request.body.?, "access_token") != null,
        );
        return self.allocator.dupe(u8, "{\"refresh_token\":\"token\"}");
    }

    fn cancelResponse(self: *@This(), request: *core.http.Request) ![]u8 {
        try std.testing.expectEqual(core.http.Method.DELETE, request.method);
        try std.testing.expect(request.body == null);
        try std.testing.expect(request.getHeader("Content-Length") == null);
        try std.testing.expect(request.getHeader("Transfer-Encoding") == null);
        return self.allocator.alloc(u8, 0);
    }
};

test "generated ACR raw, multipart, statuses, and validated continuations" {
    const allocator = std.testing.allocator;
    var empty = [_]*core.http.HttpPolicy{};
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);

    var blob_mock = Mock.init(allocator, .blob);
    const blob_runtime = core.http.HttpRuntime.init(
        blob_mock.asTransport(),
        crypto.asProvider(),
    );
    const blob_pipeline = core.http.HttpPipeline.init(blob_runtime, &empty);
    var root = clients.ContainerRegistryClient.init(
        blob_pipeline,
        .{ .endpoint = "https://registry.example" },
    );
    var blob_client = root.containerRegistryBlob();
    const blob_result = try blob_client.getBlob(allocator, "team/app", "sha256:abc");
    switch (blob_result) {
        .status_200 => |result| {
            defer allocator.free(result.body);
            defer allocator.free(result.headers.docker_content_digest);
            try std.testing.expectEqualStrings("blob", result.body);
        },
        else => return error.UnexpectedStatus,
    }

    try std.testing.expectError(
        error.UnexpectedHost,
        blob_client.getUploadStatus(
            allocator,
            "https://evil.example/v2/team/app/blobs/uploads/id",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), blob_mock.calls);

    var redirect_mock = Mock.init(allocator, .redirect);
    const redirect_runtime = core.http.HttpRuntime.init(
        redirect_mock.asTransport(),
        crypto.asProvider(),
    );
    const redirect_pipeline = core.http.HttpPipeline.init(redirect_runtime, &empty);
    root = clients.ContainerRegistryClient.init(
        redirect_pipeline,
        .{ .endpoint = "https://registry.example" },
    );
    blob_client = root.containerRegistryBlob();
    const redirected_blob = try blob_client.getBlob(
        allocator,
        "team/app",
        "sha256:abc",
    );
    switch (redirected_blob) {
        .status_307 => |result| {
            defer allocator.free(result.headers.location);
            try std.testing.expectEqualStrings(
                "https://storage.example/blob",
                result.headers.location,
            );
        },
        else => return error.UnexpectedStatus,
    }
    const redirected_exists = try blob_client.checkBlobExists(
        allocator,
        "team/app",
        "sha256:abc",
    );
    switch (redirected_exists) {
        .status_307 => |result| {
            defer allocator.free(result.headers.location);
            try std.testing.expectEqualStrings(
                "https://storage.example/blob",
                result.headers.location,
            );
        },
        else => return error.UnexpectedStatus,
    }
    try std.testing.expectEqual(@as(usize, 2), redirect_mock.calls);

    var multipart_mock = Mock.init(allocator, .multipart);
    const multipart_runtime = core.http.HttpRuntime.init(
        multipart_mock.asTransport(),
        crypto.asProvider(),
    );
    const multipart_pipeline = core.http.HttpPipeline.init(multipart_runtime, &empty);
    root = clients.ContainerRegistryClient.init(
        multipart_pipeline,
        .{ .endpoint = "https://registry.example" },
    );
    var auth = root.authentication();
    const token = try auth.exchangeAadAccessTokenForAcrRefreshToken(
        allocator,
        .{
            .grant_type = .access_token,
            .service = "registry.example",
            .access_token = "aad-token",
        },
    );
    defer allocator.free(token.refresh_token.?);
    try std.testing.expectEqualStrings("token", token.refresh_token.?);

    var cancel_mock = Mock.init(allocator, .cancel);
    const cancel_runtime = core.http.HttpRuntime.init(
        cancel_mock.asTransport(),
        crypto.asProvider(),
    );
    const cancel_pipeline = core.http.HttpPipeline.init(cancel_runtime, &empty);
    root = clients.ContainerRegistryClient.init(
        cancel_pipeline,
        .{ .endpoint = "https://registry.example" },
    );
    blob_client = root.containerRegistryBlob();
    try blob_client.cancelUpload(allocator, "/v2/team/app/blobs/uploads/id");
}

test "generated ACR open records round trip arbitrary JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try serde.json.fromSlice(
        models.Annotations,
        allocator,
        "{\"org.opencontainers.image.created\":\"2026-01-01T00:00:00Z\",\"count\":3,\"nested\":{\"ok\":true}}",
    );
    try std.testing.expectEqualStrings("2026-01-01T00:00:00Z", value.created.?);
    try std.testing.expect(value.additional_properties.get("count").? == .integer);
    try std.testing.expect(value.additional_properties.get("nested").? == .object);
    const encoded = try serde.json.toSlice(allocator, value);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"count\":3") != null);
}

const SpanProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = exportBatch },
    transport: *Mock,
    count: usize = 0,

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *@This() = @fieldParentPtr("exporter", exporter);
        for (batch) |span| {
            try std.testing.expectEqualStrings("caller.acr", span.scope_name);
            try std.testing.expectEqualStrings("caller-version", span.scope_version);
            try std.testing.expectEqualStrings("HTTP", span.name);
            try std.testing.expectEqual(core.tracing.SpanKind.client, span.kind);
            try std.testing.expectEqual(core.tracing.SpanStatus.unset, span.status);
            try std.testing.expectEqualStrings("b7ad6b7169203331", &span.parent_span_id.?);
            try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &span.context.trace_id);
            try std.testing.expectEqualStrings(&self.transport.wire_span_id.?, &span.context.span_id);
            var namespace = false;
            var status = false;
            for (span.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.key, "az.namespace")) {
                    try std.testing.expectEqualStrings("Caller.Namespace", attribute.value.string);
                    namespace = true;
                }
                if (std.mem.eql(u8, attribute.key, "http.response.status_code")) {
                    try std.testing.expectEqual(@as(i64, 204), attribute.value.int);
                    status = true;
                }
            }
            try std.testing.expect(namespace and status);
            self.count += 1;
        }
    }
};

test "ACR descendants preserve optional caller instrumentation and automatically trace real operations" {
    const Mode = enum { default, enabled, disabled };
    for ([_]Mode{ .default, .enabled, .disabled }) |mode| {
        var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
        var mock = Mock.init(std.testing.allocator, .cancel);
        mock.expected_trace = mode == .enabled;
        const runtime = core.http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
        var probe: SpanProbe = .{ .transport = &mock };
        var provider = try core.tracing.ExportingTracerProvider.init(
            std.testing.allocator,
            std.testing.io,
            runtime.crypto,
            &probe.exporter,
            .{},
        );
        defer provider.deinit() catch unreachable;
        var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_container_registry/0.3.0");
        var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
        var pipeline = core.http.HttpPipeline.init(runtime, &policies);
        try std.testing.expect(pipeline.instrumentation == null);
        var parent = core.tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
        parent.trace_state = "vendor=caller";
        if (mode != .default) pipeline.setInstrumentation(.{
            .provider = provider.asProvider(),
            .scope_name = "caller.acr",
            .scope_version = "caller-version",
            .namespace = "Caller.Namespace",
            .parent_context = parent,
        });
        if (mode == .disabled) pipeline.setInstrumentation(null);
        var client = clients.ContainerRegistryClient.init(pipeline, .{ .endpoint = "https://registry.example" });
        for ([_]core.http.HttpPipeline{
            client.pipeline,
            client.containerRegistry().pipeline,
            client.containerRegistryBlob().pipeline,
            client.authentication().pipeline,
        }) |copied| try std.testing.expectEqualDeep(pipeline, copied);
        pipeline.setInstrumentation(null);
        var blob = client.containerRegistryBlob();
        try blob.cancelUpload(std.testing.allocator, "/v2/team/app/blobs/uploads/id");
        const expected: u64 = if (mode == .enabled) 1 else 0;
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try std.testing.expectEqual(expected, provider.stats().started);
        try std.testing.expectEqual(expected, provider.stats().ended);
        try std.testing.expectEqual(@as(usize, 0), provider.stats().active_spans);
        try std.testing.expectEqual(@as(usize, 0), probe.count);
        try std.testing.expect(!provider.closed);
        try provider.forceFlush(1000);
        try std.testing.expectEqual(@as(usize, @intCast(expected)), probe.count);
        try provider.shutdown(1000);
    }
}
