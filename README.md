# arm-avs

Generated Azure SDK client for Zig.

This package is produced by `codegen` from the TypeSpec
specification in [`Azure/azure-rest-api-specs`](https://github.com/Azure/azure-rest-api-specs).
Do not edit generated package files by hand — they will be
overwritten on the next regeneration.

## Core 0.4 and optional tracing

Package **0.3.0** pins the published **Core 0.4.0** release by commit and hash.
`AVSClient` and all 24 subgroups copy the caller's complete HTTP pipeline:

```zig
var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_arm_avs/0.3.0");
var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
var pipeline = core.http.HttpPipeline.init(runtime, &policies);
pipeline.setInstrumentation(.{
    .provider = provider.asProvider(),
    .scope_name = "azure_rest_arm_avs",
    .scope_version = "0.3.0",
    .namespace = "Microsoft.AVS",
});
var client = AVSClient.init(pipeline, .{ .subscription_id = subscription_id });
```

The caller owns `provider` (for example, a
`core.tracing.ExportingTracerProvider`) and its exporter. Constructors preserve
caller scope/version/namespace, parent context and policies without adding a
provider parameter or configuring tracing on `HttpRuntime`. User-agent policies
are also caller-configured; the example uses this package's version.

Tracing is off by default. Configure before construction, or use
`pipeline.setInstrumentation(null)` to disable future copies. Existing clients
retain their copied configuration. Provider/exporter, runtime backends, policy
storage, scope strings and optional parent tracestate must outlive all client
copies and operations. Clients do not flush or shut down providers; the caller
explicitly exports and shuts down after use. Streaming spans end at response
headers, not body completion. Generated per-call context expansion remains
deferred to **#465**.

Validate with `zig build test examples --summary all`.

## Clients
- `AVSClient`
- `Operations`
- `Addons`
- `Authorizations`
- `CloudLinks`
- `Clusters`
- `Datastores`
- `GlobalReachConnections`
- `HcxEnterpriseSites`
- `Hosts`
- `IscsiPaths`
- `Licenses`
- `Locations`
- `Maintenances`
- `PlacementPolicies`
- `PrivateClouds`
- `ProvisionedNetworks`
- `PureStoragePolicies`
- `ScriptCmdlets`
- `ScriptExecutions`
- `ScriptPackages`
- `ServiceComponents`
- `Skus`
- `VirtualMachines`
- `WorkloadNetworks`
