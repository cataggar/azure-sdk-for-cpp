const core = @import("azure_sdk_core");
const std = @import("std");

comptime {
    _ = core.http.wasi.WasiHttpTransport;
}

export fn azureSdkCoreWasiBuildCheck() void {
    var storage: [2048]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var request = core.http.Request.init(allocator.allocator(), .GET, "https://example.test");
    defer request.deinit();
    request.setHeader("X-Consumer", "owned") catch return;
    request.setHeader("traceparent", "caller") catch return;
    var saved = request.headers.takeTraceHeaders();
    request.headers.clearRetainingCapacity();
    request.headers.restoreTraceHeaders(&saved);
    std.mem.doNotOptimizeAway(request.getHeader("traceparent"));
}
