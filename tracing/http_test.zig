const std = @import("std");
const http = @import("../http.zig");
const tracing = @import("root.zig");
const crypto_mod = @import("../crypto.zig");
const Provider = tracing.ExportingTracerProvider;
const allocator = std.testing.allocator;

const Probe = struct {
    exporter: tracing.SpanExporter = .{ .exportFn = exportBatch },
    count: usize = 0,
    ids: [16][16]u8 = undefined,
    parents: [16]?[16]u8 = undefined,
    statuses: [16]tracing.SpanStatus = undefined,
    response_codes: [16]?i64 = @splat(null),
    error_types: usize = 0,
    collector_pipeline: ?*http.HttpPipeline = null,
    fail: bool = false,

    fn exportBatch(exporter: *tracing.SpanExporter, batch: []const tracing.SpanData, _: tracing.ExportContext) !void {
        const self: *Probe = @fieldParentPtr("exporter", exporter);
        if (self.fail) return error.TestExportFailure;
        for (batch) |data| {
            try std.testing.expectEqualStrings("azure_sdk_storage_blobs", data.scope_name);
            self.ids[self.count] = data.context.span_id;
            self.parents[self.count] = data.parent_span_id;
            self.statuses[self.count] = data.status;
            for (data.attributes) |attribute| {
                try std.testing.expect(!std.mem.eql(u8, attribute.key, "url.full"));
                try std.testing.expect(!std.mem.eql(u8, attribute.key, "Authorization"));
                if (attribute.value == .string)
                    try std.testing.expect(std.mem.indexOf(u8, attribute.value.string, "secret") == null);
                if (std.mem.eql(u8, attribute.key, "http.response.status_code"))
                    self.response_codes[self.count] = attribute.value.int;
                if (std.mem.eql(u8, attribute.key, "error.type")) self.error_types += 1;
            }
            self.count += 1;
        }
        if (self.collector_pipeline) |pipeline| {
            var request = http.Request.init(allocator, .POST, "https://collector.test/v1/traces");
            defer request.deinit();
            request.context.tracing_suppressed = true;
            var response = try pipeline.send(&request);
            defer response.deinit();
            try std.testing.expect(request.getHeader("traceparent") == null);
        }
    }
};

fn pipelineFor(runtime: http.HttpRuntime, provider: *Provider, policies: []*http.HttpPolicy) http.HttpPipeline {
    var pipeline = http.HttpPipeline.init(runtime, policies);
    pipeline.setInstrumentation(.{
        .provider = provider.asProvider(),
        .scope_name = "azure_sdk_storage_blobs",
        .scope_version = "0.3.0",
        .namespace = "Microsoft.Storage",
    });
    return pipeline;
}

const Capture = struct {
    inner: http.HttpTransport,
    count: usize = 0,
    parents: [16]?[55]u8 = @splat(null),
    states: [16]bool = @splat(false),
    const vtable: http.HttpTransport.VTable = .{ .send = send, .open = open };

    fn asTransport(self: *Capture) http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn record(self: *Capture, request: *http.Request) !void {
        if (request.getHeader("traceparent")) |parent| {
            try std.testing.expectEqual(@as(usize, 55), parent.len);
            self.parents[self.count] = parent[0..55].*;
        }
        self.states[self.count] = request.getHeader("tracestate") != null;
        self.count += 1;
    }

    fn send(context: *anyopaque, request: *http.Request) !http.Response {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.record(request);
        return self.inner.vtable.send(self.inner.context, request);
    }

    fn open(context: *anyopaque, request: *http.Request, options: http.OpenOptions) !*http.HttpOperation {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.record(request);
        return self.inner.vtable.open.?(self.inner.context, request, options);
    }
};

test "tracing pipeline automatic copied configuration parent wire IDs redaction and request reuse" {
    var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
    var mock = http.MockTransport.init(allocator, 200, "secret response");
    defer mock.deinit();
    var capture: Capture = .{ .inner = mock.asTransport() };
    const runtime = http.HttpRuntime.init(capture.asTransport(), crypto.asProvider());
    var probe: Probe = .{};
    var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
    defer provider.deinit() catch unreachable;
    var pipeline = pipelineFor(runtime, &provider, &.{});
    var copied = pipeline;
    {
        const url = try allocator.dupe(u8, "https://user:secret@account.test/container/secret?sig=secret#secret");
        defer allocator.free(url);
        var request = http.Request.init(allocator, .GET, url);
        defer request.deinit();
        const parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
        try request.setHeader("Traceparent", parent);
        try request.setHeader("Tracestate", "vendor=value");
        try request.setHeader("Authorization", "Bearer secret");
        request.body = "secret body";
        var response = try copied.send(&request);
        response.deinit();
        try std.testing.expectEqualStrings(parent, request.getHeader("traceparent").?);
        try std.testing.expectEqualStrings("vendor=value", request.getHeader("tracestate").?);
        try std.testing.expect(!request.tracing_headers_managed);
        var second = try pipeline.send(&request);
        second.deinit();
        try std.testing.expect(capture.parents[0] != null and capture.parents[1] != null);
        try std.testing.expect(!std.mem.eql(u8, &capture.parents[0].?, &capture.parents[1].?));
    }
    // The request, response, URL and their header storage are already gone.
    try provider.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    for (0..2) |i| {
        try std.testing.expectEqualStrings(capture.parents[i].?[36..52], &probe.ids[i]);
        try std.testing.expectEqualStrings("b7ad6b7169203331", &probe.parents[i].?);
        try std.testing.expectEqual(@as(?i64, 200), probe.response_codes[i]);
        try std.testing.expectEqual(tracing.SpanStatus.unset, probe.statuses[i]);
    }
    try provider.shutdown(1000);
}

test "tracing pipeline one logical retry span and no legacy policy duplication" {
    var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
    var sequence = http.SequenceMockTransport.init(allocator, &.{
        .{ .status = 500, .body = "first" }, .{ .status = 200, .body = "last" },
    });
    var capture: Capture = .{ .inner = sequence.asTransport() };
    const runtime = http.HttpRuntime.init(capture.asTransport(), crypto.asProvider());
    var probe: Probe = .{};
    var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
    defer provider.deinit() catch unreachable;
    var legacy = tracing.RecordingTracer.init(allocator);
    defer legacy.deinit();
    var tracing_policy = http.TracingPolicy.init(legacy.asTracer(), "Storage");
    var retry = http.RetryPolicy.init();
    retry.initial_delay_ms = 0;
    retry.max_retries = 1;
    var policies = [_]*http.HttpPolicy{ retry.asPolicy(), tracing_policy.asPolicy() };
    var pipeline = pipelineFor(runtime, &provider, &policies);
    var request = http.Request.init(allocator, .GET, "https://example.test");
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 2), sequence.call_count);
    try std.testing.expectEqualStrings(&capture.parents[0].?, &capture.parents[1].?);
    try std.testing.expect(legacy.last_span == null);
    try provider.shutdown(1000);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(@as(?i64, 200), probe.response_codes[0]);
}

test "tracing pipeline managed headers stay same-origin but stop at cross-origin redirects" {
    for ([_]bool{ false, true }) |streaming| {
        var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
        var sequence = http.SequenceMockTransport.init(allocator, &.{
            .{ .status = 302, .body = "", .headers = &.{.{ .name = "Location", .value = "/next" }} },
            .{ .status = 302, .body = "", .headers = &.{.{ .name = "Location", .value = "https://other.test/final" }} },
            .{ .status = 200, .body = "done" },
        });
        var capture: Capture = .{ .inner = sequence.asTransport() };
        const runtime = http.HttpRuntime.init(capture.asTransport(), crypto.asProvider());
        var probe: Probe = .{};
        var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
        defer provider.deinit() catch unreachable;
        var pipeline = pipelineFor(runtime, &provider, &.{});
        var request = http.Request.init(allocator, .GET, "https://origin.test/start");
        defer request.deinit();
        var parent = tracing.TraceContext.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01").?;
        parent.trace_state = "vendor=value";
        request.context = request.context.withTraceContext(parent);
        if (streaming) {
            const operation = try pipeline.open(&request, .{});
            defer operation.deinit();
            try operation.finish();
        } else {
            var response = try pipeline.send(&request);
            defer response.deinit();
        }
        try std.testing.expectEqual(@as(usize, 3), capture.count);
        try std.testing.expect(capture.parents[0] != null and capture.parents[1] != null);
        try std.testing.expectEqualStrings(&capture.parents[0].?, &capture.parents[1].?);
        try std.testing.expect(capture.states[0] and capture.states[1]);
        try std.testing.expect(capture.parents[2] == null and !capture.states[2]);
        try std.testing.expect(request.getHeader("traceparent") == null);
        try provider.shutdown(1000);
        try std.testing.expectEqual(@as(usize, 1), probe.count);
    }
}

test "tracing pipeline open ends at headers without owning response operation callbacks" {
    var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
    var mock = http.MockTransport.init(allocator, 200, "secret response body");
    defer mock.deinit();
    const runtime = http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
    var probe: Probe = .{};
    var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
    defer provider.deinit() catch unreachable;
    var pipeline = pipelineFor(runtime, &provider, &.{});
    var request = http.Request.init(allocator, .GET, "https://example.test/secret");
    defer request.deinit();
    const operation = try pipeline.open(&request, .{});
    defer operation.deinit();
    try std.testing.expectEqual(@as(usize, 0), provider.stats().active_spans);
    try std.testing.expectEqual(@as(usize, 1), provider.stats().queued_spans);
    try std.testing.expectEqual(http.OperationState.active, operation.state);
    try provider.forceFlush(1000);
    operation.cancel();
    try std.testing.expectEqual(@as(usize, 1), mock.stream_cancel_count);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(tracing.SpanStatus.unset, probe.statuses[0]);
    try std.testing.expectEqual(@as(usize, 0), provider.stats().queued_spans);
    var token = http.CancellationToken{};
    token.cancel();
    try std.testing.expectError(error.OperationCancelled, pipeline.open(&request, .{ .cancellation = &token }));
    try std.testing.expectEqual(@as(u64, 1), provider.stats().started);
    try provider.shutdown(1000);
}

test "tracing pipeline header allocation failures roll back without failing service operation" {
    for ([_][]const u8{ "vendor=value", "", "invalid=has=equals" }) |original_state| {
        for (0..8) |offset| {
            var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
            var mock = http.MockTransport.init(allocator, 200, "");
            defer mock.deinit();
            const runtime = http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
            var probe: Probe = .{};
            var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
            defer provider.deinit() catch unreachable;
            var pipeline = pipelineFor(runtime, &provider, &.{});
            var failing = std.testing.FailingAllocator.init(allocator, .{});
            var request = http.Request.init(failing.allocator(), .GET, "https://example.test");
            defer request.deinit();
            const original = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
            try request.setHeader("traceparent", original);
            try request.setHeader("tracestate", original_state);
            failing.fail_index = failing.alloc_index + offset;
            var response = try pipeline.send(&request);
            defer response.deinit();
            try std.testing.expectEqual(@as(u16, 200), response.status_code);
            try std.testing.expectEqualStrings(original, request.getHeader("traceparent").?);
            try std.testing.expectEqualStrings(original_state, request.getHeader("tracestate").?);
            if (failing.has_induced_failure)
                try std.testing.expect(provider.stats().propagation_errors > 0);
            try provider.shutdown(1000);
        }
    }
}

test "tracing restoration at the map load limit never allocates or loses saved caller headers" {
    const original_parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const Case = struct { parent: bool, state: ?[]const u8, wire_state: ?[]const u8 };
    const cases = [_]Case{
        .{ .parent = false, .state = null, .wire_state = null },
        .{ .parent = true, .state = null, .wire_state = null },
        .{ .parent = false, .state = "vendor=value", .wire_state = "" },
        .{ .parent = true, .state = "vendor=value", .wire_state = "vendor=value" },
        .{ .parent = true, .state = "invalid=has=equals", .wire_state = "" },
        .{ .parent = true, .state = "", .wire_state = "" },
        .{ .parent = true, .state = " \t", .wire_state = " \t" },
        .{ .parent = true, .state = "vendor=value,", .wire_state = "vendor=value," },
        .{ .parent = true, .state = "vendor=value, ,other=value", .wire_state = "vendor=value, ,other=value" },
        .{ .parent = true, .state = ", , ", .wire_state = ", , " },
    };
    const Mutation = enum { unrelated, replace_managed, remove_with_room };
    const Policy = struct {
        failing: *std.testing.FailingAllocator,
        mutation: Mutation,
        saved_count: u32,
        additions: usize = 0,
        return_count: u32 = 0,
        installed_count: u32 = 0,
        blocked_at: usize = 0,
        return_error: bool = false,
        policy: http.HttpPolicy = .{ .processFn = process },

        fn remove(request: *http.Request, key: []const u8) void {
            if (request.headers.fetchRemove(key)) |removed| {
                request.allocator.free(removed.key);
                request.allocator.free(removed.value);
            }
        }

        fn process(policy: *http.HttpPolicy, request: *http.Request, _: []*http.HttpPolicy, runtime: http.HttpRuntime) !http.Response {
            const self: *@This() = @fieldParentPtr("policy", policy);
            try request.setHeader("x-change", "after");
            remove(request, "x-remove");
            switch (self.mutation) {
                .unrelated => {},
                .replace_managed => {
                    try request.setHeader("traceparent", "00-1234567890abcdef1234567890abcdef-1234567890abcdef-01");
                    if (request.getHeader("tracestate") != null)
                        try request.setHeader("tracestate", "policy=value");
                },
                .remove_with_room => {
                    remove(request, "traceparent");
                    remove(request, "tracestate");
                },
            }
            const reserve = if (self.mutation == .remove_with_room) self.saved_count else 0;
            while (request.headers.unmanaged.available > reserve) {
                var name: [32]u8 = undefined;
                try request.setHeader(std.fmt.bufPrint(&name, "x-added-{d}", .{self.additions}) catch unreachable, "retained");
                self.additions += 1;
            }
            self.return_count = request.headers.count();
            self.installed_count = @as(u32, @intFromBool(request.getHeader("traceparent") != null)) +
                @intFromBool(request.getHeader("tracestate") != null);
            self.blocked_at = self.failing.alloc_index;
            self.failing.fail_index = self.blocked_at;
            if (self.return_error) return error.TestPolicyFailure;
            return runtime.transport.send(request);
        }
    };
    for (cases) |case| {
        inline for (.{ Mutation.unrelated, Mutation.replace_managed, Mutation.remove_with_room }) |mutation| {
            var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
            var mock = http.MockTransport.init(allocator, 200, "");
            defer mock.deinit();
            const runtime = http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
            var probe: Probe = .{};
            var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
            defer provider.deinit() catch unreachable;
            var failing = std.testing.FailingAllocator.init(allocator, .{});
            var request = http.Request.init(failing.allocator(), .GET, "https://example.test");
            defer request.deinit();
            if (case.parent) try request.setHeader("TraceParent", original_parent);
            if (case.state) |state| try request.setHeader("TraceState", state);
            try request.setHeader("x-change", "before");
            try request.setHeader("x-remove", "remove me");
            var policy: Policy = .{
                .failing = &failing,
                .mutation = mutation,
                .saved_count = @as(u32, @intFromBool(case.parent)) + @intFromBool(case.state != null),
            };
            var policies = [_]*http.HttpPolicy{&policy.policy};
            var pipeline = pipelineFor(runtime, &provider, &policies);
            // Reuse the same request, including a service/policy error return.
            for (0..2) |call| {
                failing.fail_index = std.math.maxInt(usize);
                policy.return_error = call == 1;
                if (policy.return_error) {
                    try std.testing.expectError(error.TestPolicyFailure, pipeline.send(&request));
                } else {
                    var response = try pipeline.send(&request);
                    defer response.deinit();
                    try std.testing.expectEqual(@as(u16, 200), response.status_code);
                    if (mutation == .unrelated) {
                        if (case.wire_state) |state|
                            try std.testing.expectEqualStrings(state, mock.last_headers.get("tracestate").?)
                        else
                            try std.testing.expect(mock.last_headers.get("tracestate") == null);
                    }
                }
                try std.testing.expect(!failing.has_induced_failure);
                try std.testing.expectEqual(policy.blocked_at, failing.alloc_index);
                try std.testing.expectEqual(policy.return_count - policy.installed_count + policy.saved_count, request.headers.count());
                if (case.parent)
                    try std.testing.expectEqualStrings(original_parent, request.getHeader("traceparent").?)
                else
                    try std.testing.expect(request.getHeader("traceparent") == null);
                if (case.state) |state|
                    try std.testing.expectEqualStrings(state, request.getHeader("tracestate").?)
                else
                    try std.testing.expect(request.getHeader("tracestate") == null);
                try std.testing.expectEqualStrings("after", request.getHeader("x-change").?);
                try std.testing.expect(request.getHeader("x-remove") == null);
                for (0..policy.additions) |i| {
                    var name: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&name, "x-added-{d}", .{i}) catch unreachable;
                    try std.testing.expectEqualStrings("retained", request.getHeader(key).?);
                }
            }
            try std.testing.expectEqual(@as(u64, 0), provider.stats().propagation_errors);
            try provider.shutdown(1000);
            try std.testing.expectEqual(@as(usize, 2), probe.count);
            if (case.parent) {
                for (probe.parents[0..2]) |parent|
                    try std.testing.expectEqualStrings("b7ad6b7169203331", &parent.?);
            }
        }
    }
}

test "tracing pipeline disabled is inert and explicit suppression prevents exporter recursion" {
    var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
    var mock = http.MockTransport.init(allocator, 200, "");
    defer mock.deinit();
    const runtime = http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
    var probe: Probe = .{};
    var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
    defer provider.deinit() catch unreachable;
    var pipeline = http.HttpPipeline.init(runtime, &.{});
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var request = http.Request.init(failing.allocator(), .GET, "https://example.test");
    defer request.deinit();
    var response = try pipeline.send(&request);
    response.deinit();
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try std.testing.expectEqual(@as(u64, 0), provider.stats().started);
    pipeline = pipelineFor(runtime, &provider, &.{});
    var normal = http.Request.init(allocator, .GET, "https://example.test");
    defer normal.deinit();
    var traced = try pipeline.send(&normal);
    traced.deinit();
    probe.collector_pipeline = &pipeline;
    try provider.forceFlush(1000);
    try std.testing.expectEqual(@as(u64, 1), provider.stats().started);
    try std.testing.expectEqual(@as(usize, 0), provider.stats().queued_spans);
    try std.testing.expectEqual(@as(usize, 3), mock.call_count);
    probe.collector_pipeline = null;
    try provider.shutdown(1000);
}

test "tracing pipeline preserves transport timeout and crypto failures" {
    const Failure = struct {
        fn send(_: *anyopaque, _: *http.Request) !http.Response {
            return error.TestTransportFailure;
        }
        fn random(_: *anyopaque, _: []u8) !void {
            return error.TestRandomFailure;
        }
        fn open(_: *anyopaque, _: *http.Request, _: http.OpenOptions) !*http.HttpOperation {
            return error.OperationCancelled;
        }
    };
    var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
    var mock = http.MockTransport.init(allocator, 200, "");
    defer mock.deinit();
    var probe: Probe = .{};
    var runtime = http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
    var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
    defer provider.deinit() catch unreachable;
    var pipeline = pipelineFor(runtime, &provider, &.{});
    const failure_vtable: http.HttpTransport.VTable = .{ .send = Failure.send, .open = Failure.open };
    pipeline.runtime.transport.vtable = &failure_vtable;
    var request = http.Request.init(allocator, .GET, "https://example.test");
    defer request.deinit();
    try std.testing.expectError(error.TestTransportFailure, pipeline.send(&request));
    try std.testing.expect(request.transport_started);
    try std.testing.expectError(error.OperationCancelled, pipeline.open(&request, .{}));
    try std.testing.expect(request.transport_started);
    var retry = http.RetryPolicy.init();
    var policies = [_]*http.HttpPolicy{retry.asPolicy()};
    pipeline.policies = &policies;
    request.operation_timeout_ms = 0;
    try std.testing.expectError(error.OperationTimedOut, pipeline.send(&request));
    try std.testing.expect(!request.transport_started);
    try provider.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 3), probe.error_types);
    try std.testing.expectEqual(@as(usize, 0), provider.stats().active_spans);
    try provider.shutdown(1000);

    var crypto_vtable = runtime.crypto.vtable.*;
    crypto_vtable.random_bytes = Failure.random;
    runtime.crypto.vtable = &crypto_vtable;
    var failed_provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{});
    defer failed_provider.deinit() catch unreachable;
    pipeline = pipelineFor(runtime, &failed_provider, &.{});
    var response = try pipeline.send(&request);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqual(@as(u64, 1), failed_provider.stats().dropped_spans);
    try failed_provider.shutdown(1000);
}

test "tracing pipeline attribute and export failures do not change service outcomes" {
    var crypto = crypto_mod.StdCryptoProvider.init(std.testing.io);
    var mock = http.MockTransport.init(allocator, 503, "");
    defer mock.deinit();
    const runtime = http.HttpRuntime.init(mock.asTransport(), crypto.asProvider());
    var probe: Probe = .{ .fail = true };
    var provider = try Provider.init(allocator, std.testing.io, runtime.crypto, &probe.exporter, .{ .max_attributes = 0 });
    defer provider.deinit() catch unreachable;
    var pipeline = pipelineFor(runtime, &provider, &.{});
    var request = http.Request.init(allocator, .GET, "https://example.test");
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 503), response.status_code);
    try std.testing.expect(provider.stats().dropped_attributes >= 3);
    try std.testing.expectEqual(@as(u64, 0), provider.stats().export_errors);
    try std.testing.expectError(error.TestExportFailure, provider.forceFlush(1000));
    try std.testing.expectEqual(@as(u64, 1), provider.stats().export_errors);
    try std.testing.expectEqual(@as(u64, 1), provider.stats().dropped_spans);
    probe.fail = false;
    try provider.shutdown(1000);
}
