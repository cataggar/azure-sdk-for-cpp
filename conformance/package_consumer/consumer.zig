const std = @import("std");
const core = @import("azure_sdk_core");
const http = @import("azure_sdk_core_http_conformance");
const crypto = @import("azure_sdk_core_crypto_conformance");

test "manifest-filtered package exports usable conformance modules" {
    try http.runRawTransportContracts(
        std.testing.allocator,
        std.testing.io,
        http.mockBackendFactory(),
    );
    try http.runPipelineContracts(
        std.testing.allocator,
        std.testing.io,
        http.standardBackendFactory(),
    );
    try http.runBackendAllocationFailureContracts(
        std.testing.allocator,
        std.testing.io,
        http.standardBackendFactory(),
    );
    try crypto.runCryptoContracts(
        std.testing.allocator,
        std.testing.io,
        crypto.standardProviderFactory(),
    );
    try std.testing.expectEqualStrings("0.4.0", core.version);
}

test "manifest-filtered package exports owned request headers with infallible trace restoration" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var request = core.http.Request.init(failing.allocator(), .GET, "https://example.test");
    defer request.deinit();
    try request.setHeader("TraceParent", "caller");
    try request.setHeader("TraceState", "");
    var saved = request.headers.takeTraceHeaders();
    defer saved.deinit();
    request.headers.clearAndFree();
    try request.headers.ensureUnusedCapacity(8);
    var added: usize = 0;
    while (request.headers.unusedCapacity() > 0) {
        var key: [32]u8 = undefined;
        try request.setHeader(try std.fmt.bufPrint(&key, "x-header-{d}", .{added}), "retained");
        added += 1;
    }
    failing.fail_index = failing.alloc_index;
    request.headers.restoreTraceHeaders(&saved);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), request.headers.unusedCapacity());
    try std.testing.expectEqualStrings("caller", request.getHeader("traceparent").?);
    try std.testing.expectEqualStrings("", request.getHeader("tracestate").?);
    var copied = try request.headers.clone(std.testing.allocator);
    defer copied.deinit();
    try std.testing.expectEqual(added + 2, copied.count());
    try std.testing.expect(copied.remove("TRACEPARENT"));
    var iterator = copied.iterator();
    var seen: usize = 0;
    while (iterator.next()) |entry| {
        try std.testing.expectEqualStrings(copied.get(entry.key_ptr.*).?, entry.value_ptr.*);
        seen += 1;
    }
    try std.testing.expectEqual(copied.count(), seen);
}
