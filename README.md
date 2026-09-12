# keyvault-secrets

Generated Azure SDK client for Zig.

This package is produced by `codegen` from the TypeSpec
specification in [`Azure/azure-rest-api-specs`](https://github.com/Azure/azure-rest-api-specs).
Do not edit generated package files by hand — they will be
overwritten on the next regeneration.

## Core 0.4 and optional tracing

Package **0.3.0** pins the published **Core 0.4.0** release by commit and hash.
`KeyVaultClient.init` copies the caller's complete HTTP pipeline:

```zig
var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_keyvault_secrets/0.3.0");
var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
var pipeline = core.http.HttpPipeline.init(runtime, &policies);
pipeline.setInstrumentation(.{
    .provider = provider.asProvider(),
    .scope_name = "azure_rest_keyvault_secrets",
    .scope_version = "0.3.0",
    .namespace = "Microsoft.KeyVault",
});
var client = KeyVaultClient.init(pipeline, .{ .endpoint = endpoint });
```

The caller owns `provider`, for example a
`core.tracing.ExportingTracerProvider`, and its exporter. Constructor signatures
do not change: scope/version/namespace, default parent context and policies are
preserved, never overwritten with package defaults. Tracing is not configured
on `HttpRuntime`. Generated clients do not synthesize a user agent; the versioned
telemetry policy above is also caller-configured.

Tracing is off by default; configure before construction or call
`pipeline.setInstrumentation(null)` to disable future copies. Existing clients
retain their copied configuration. Provider/exporter, runtime backends, policy
storage, scope strings and optional parent tracestate must outlive all clients
and operations. Clients never flush or shut down providers: export and shut down
explicitly after use. Core's automatic HTTP spans exclude secret paths and
values; streaming spans end at response headers, not body completion. Generated
per-call context expansion remains deferred to **#465**.

Validate with `zig build test --summary all`.

## Clients
- `KeyVaultClient`
