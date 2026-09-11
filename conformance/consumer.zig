const core = @import("azure_sdk_core");
const http_conformance = @import("azure_sdk_core_http_conformance");
const crypto_conformance = @import("azure_sdk_core_crypto_conformance");

comptime {
    _ = core.http.HttpTransport;
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

export fn azureSdkCoreConformanceConsumerCheck() void {}
