const std = @import("std");
const core = @import("azure_sdk_core");
const http_conformance = @import("azure_sdk_core_http_conformance");
const crypto_conformance = @import("azure_sdk_core_crypto_conformance");

test "current immutable Core composes the canonical runtime and pipeline" {
    try std.testing.expectEqualStrings("0.3.0", core.version);
    var transport = core.http.MockTransport.init(std.testing.allocator, 200, "runtime");
    defer transport.deinit();
    var provider = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), provider.asProvider());
    var pipeline = core.http.HttpPipeline.init(runtime, &.{});
    try std.testing.expectEqual(runtime.transport.context, pipeline.runtime.transport.context);
    try std.testing.expectEqual(runtime.crypto.context, pipeline.runtime.crypto.context);

    var request = core.http.Request.init(std.testing.allocator, .GET, "https://example.test/");
    defer request.deinit();
    var response = try pipeline.send(&request);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqualStrings("runtime", response.body);
}

test "published standard HTTP backend runs raw and pipeline contracts" {
    const factory = http_conformance.standardBackendFactory();
    try http_conformance.runRawTransportContracts(std.testing.allocator, std.testing.io, factory);
    try http_conformance.runPipelineContracts(std.testing.allocator, std.testing.io, factory);
}

test "published mock HTTP backend runs raw transport contracts" {
    try http_conformance.runRawTransportContracts(
        std.testing.allocator,
        std.testing.io,
        http_conformance.mockBackendFactory(),
    );
}

test "published standard SDK crypto provider runs its contracts" {
    try crypto_conformance.runCryptoContracts(
        std.testing.allocator,
        std.testing.io,
        crypto_conformance.standardProviderFactory(),
    );
}
