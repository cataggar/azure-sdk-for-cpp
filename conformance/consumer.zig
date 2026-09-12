const core = @import("azure_sdk_core");
const std = @import("std");
const http_conformance = @import("azure_sdk_core_http_conformance");
const crypto_conformance = @import("azure_sdk_core_crypto_conformance");

comptime {
    _ = core.http.HttpTransport;
    _ = core.http.RequestHeaders;
    _ = http_conformance.BackendFactory;
    _ = http_conformance.runRawTransportContracts;
    _ = http_conformance.runPipelineContracts;
    _ = http_conformance.runAllocationFailureContracts;
    _ = http_conformance.runBackendAllocationFailureContracts;
    _ = http_conformance.runBackendAllocationScenario;
    _ = http_conformance.InterruptionCapabilities;
    _ = http_conformance.runInterruptionContracts;
    _ = crypto_conformance.ProviderFactory;
    _ = crypto_conformance.runCryptoContracts;
    _ = crypto_conformance.runProviderBoundaryContracts;
}

export fn azureSdkCoreConformanceConsumerCheck() void {
    var storage: [2048]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var headers = core.http.RequestHeaders.init(allocator.allocator());
    defer headers.deinit();
    headers.put("X-Consumer", "owned") catch return;
    headers.put("traceparent", "caller") catch return;
    var saved = headers.takeTraceHeaders();
    headers.clearRetainingCapacity();
    headers.restoreTraceHeaders(&saved);
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        std.mem.doNotOptimizeAway(entry.key_ptr.*);
        std.mem.doNotOptimizeAway(entry.value_ptr.*);
    }
}
