//! Tests for the generated Azure DevOps clients.
//!
//! Kept in a separate file so the emitter can overwrite every
//! `clients.zig` without losing test coverage. Wired into the
//! package's test step via `root.zig`.
//!
//! This file is **operator-owned**: `codegen/scripts/sync.sh` marks
//! it as operator-managed and never overwrites an existing copy.

const std = @import("std");
const core = @import("azure_sdk_core");
const root = @import("root.zig");

test "every API area is reachable from the package root" {
    try std.testing.expect(@hasDecl(root, "git"));
    try std.testing.expect(@hasDecl(root, "build"));
}

test "operation groups are reachable from an area root client" {
    try std.testing.expect(@hasDecl(root.git.GitClient, "repositories"));
    try std.testing.expect(@hasDecl(root.build.BuildClient, "builds"));
}

fn expectAreaPipelines(expected: core.http.HttpPipeline) !void {
    @setEvalBranchQuota(500_000);
    var roots: usize = 0;
    var descendants: usize = 0;
    inline for (comptime std.meta.declarations(root)) |area_decl| {
        const Area = @field(root, area_decl.name);
        inline for (comptime std.meta.declarations(Area)) |client_decl| {
            const Client = @field(Area, client_decl.name);
            if (@TypeOf(Client) == type and @typeInfo(Client) == .@"struct" and
                @hasDecl(Client, "InitOptions") and @hasDecl(Client, "init") and
                @hasField(Client, "pipeline"))
            {
                var client = Client.init(expected, .{ .endpoint = "https://devops.example" });
                try std.testing.expectEqualDeep(expected, client.pipeline);
                roots += 1;
                inline for (comptime std.meta.declarations(Client)) |decl| {
                    const accessor = @field(Client, decl.name);
                    const info = @typeInfo(@TypeOf(accessor));
                    if (info == .@"fn" and info.@"fn".params.len == 1 and
                        info.@"fn".params[0].type == *Client)
                    {
                        const Result = info.@"fn".return_type.?;
                        if (@typeInfo(Result) == .@"struct" and @hasField(Result, "pipeline")) {
                            const child = @call(.auto, accessor, .{&client});
                            try std.testing.expectEqualDeep(expected, child.pipeline);
                            try std.testing.expectEqualStrings(client.endpoint, child.endpoint);
                            try std.testing.expectEqualStrings(client.api_version, child.api_version);
                            descendants += 1;
                        }
                    }
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 44), roots);
    try std.testing.expectEqual(@as(usize, 371), descendants);
}

const TraceProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = exportBatch },
    traced: bool,
    calls: usize = 0,
    exported: usize = 0,
    wire_span_id: ?[16]u8 = null,

    fn asTransport(self: *@This()) core.http.HttpTransport {
        return .{ .context = self, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: *core.http.Request) !core.http.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        try std.testing.expectEqual(core.http.Method.DELETE, request.method);
        try std.testing.expectEqualStrings(
            "https://devops.example/org/project/_apis/git/repositories/repository?api-version=7.2-preview",
            request.url,
        );
        try std.testing.expectEqualStrings("azsdk-zig-azure_rest_devops/0.2.0", request.getHeader("User-Agent").?);
        try std.testing.expectEqual(self.traced, request.getHeader("traceparent") != null);
        if (self.traced) {
            const parent = core.tracing.TraceContext.parseTraceparent(request.getHeader("traceparent").?).?;
            self.wire_span_id = parent.span_id;
            try std.testing.expectEqualStrings("vendor=caller", request.getHeader("tracestate").?);
        } else {
            try std.testing.expect(request.getHeader("tracestate") == null);
        }
        return .{
            .status_code = 200,
            .headers = std.StringHashMap([]const u8).init(std.testing.allocator),
            .body = try std.testing.allocator.alloc(u8, 0),
            .allocator = std.testing.allocator,
        };
    }

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *@This() = @fieldParentPtr("exporter", exporter);
        for (batch) |span| {
            try std.testing.expectEqualStrings("caller.devops", span.scope_name);
            try std.testing.expectEqualStrings("caller-version", span.scope_version);
            try std.testing.expectEqualStrings("HTTP", span.name);
            try std.testing.expectEqual(core.tracing.SpanKind.client, span.kind);
            try std.testing.expectEqual(core.tracing.SpanStatus.unset, span.status);
            try std.testing.expectEqualStrings("b7ad6b7169203331", &span.parent_span_id.?);
            try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &span.context.trace_id);
            try std.testing.expectEqualStrings(&self.wire_span_id.?, &span.context.span_id);
            var namespace = false;
            var status = false;
            for (span.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.key, "az.namespace")) {
                    try std.testing.expectEqualStrings("Caller.Namespace", attribute.value.string);
                    namespace = true;
                }
                if (std.mem.eql(u8, attribute.key, "http.response.status_code")) {
                    try std.testing.expectEqual(@as(i64, 200), attribute.value.int);
                    status = true;
                }
            }
            try std.testing.expect(namespace and status);
            self.exported += 1;
        }
    }
};

test "all 44 area roots and 371 descendants retain caller tracing with real Git auto-spans" {
    const Mode = enum { default, enabled, disabled };
    for ([_]Mode{ .default, .enabled, .disabled }) |mode| {
        var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
        var probe: TraceProbe = .{ .traced = mode == .enabled };
        const runtime = core.http.HttpRuntime.init(probe.asTransport(), crypto.asProvider());
        var provider = try core.tracing.ExportingTracerProvider.init(
            std.testing.allocator,
            std.testing.io,
            runtime.crypto,
            &probe.exporter,
            .{},
        );
        defer provider.deinit() catch unreachable;
        var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_devops/0.2.0");
        var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
        var pipeline = core.http.HttpPipeline.init(runtime, &policies);
        try std.testing.expect(pipeline.instrumentation == null);
        var parent = core.tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
        parent.trace_state = "vendor=caller";
        if (mode != .default) pipeline.setInstrumentation(.{
            .provider = provider.asProvider(),
            .scope_name = "caller.devops",
            .scope_version = "caller-version",
            .namespace = "Caller.Namespace",
            .parent_context = parent,
        });
        if (mode == .disabled) pipeline.setInstrumentation(null);
        try expectAreaPipelines(pipeline);
        var client = root.git.GitClient.init(pipeline, .{ .endpoint = "https://devops.example" });
        pipeline.setInstrumentation(null);
        var repositories = client.repositories();
        try repositories.delete(std.testing.allocator, "org", "repository", "project");
        const expected: u64 = if (mode == .enabled) 1 else 0;
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(expected, provider.stats().started);
        try std.testing.expectEqual(expected, provider.stats().ended);
        try std.testing.expectEqual(@as(usize, 0), provider.stats().active_spans);
        try std.testing.expectEqual(@as(usize, 0), probe.exported);
        try std.testing.expect(!provider.closed);
        try provider.forceFlush(1000);
        try std.testing.expectEqual(@as(usize, @intCast(expected)), probe.exported);
        try provider.shutdown(1000);
    }
}
