# Azure Tables REST for Zig

`azure_rest_data_tables` is the generated Azure Tables protocol package for
the stable **2019-02-02** TypeSpec contract. It is entirely
generator-owned; update the fixture or emitter and regenerate instead of
editing package files by hand.

## Protocol surface

The package exposes `TablesClient`, `Table`, and `Service`, covering all
14 canonical operations, JSON and XML wire models, enum values, response
headers, exact alternate statuses, and continuation headers. It preserves
the TypeSpec's OData entity records and literal-query routes.

The source contract is
[`specification/cosmos-db/data-plane/Tables/tspconfig.yaml`](https://github.com/Azure/azure-rest-api-specs/tree/0744f52a86919d243ba2225e55bdb9c87bf521a5/specification/cosmos-db/data-plane/Tables).
The directory is historical; this package has no Cosmos-specific runtime
behavior. The selected TypeSpec has no `$batch` operation.

## Core 0.4 and optional tracing

Package **0.2.0** pins the published **Core 0.4.0** release by commit and hash.
Constructors copy the caller's complete `core.http.HttpPipeline`, including
optional instrumentation, into both `table()` and `service()` clients. No
provider option is added to generated constructors and tracing remains off by
default. Configure the caller's pipeline before constructing clients:

```zig
var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_data_tables/0.2.0");
var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
var pipeline = core.http.HttpPipeline.init(runtime, &policies);
pipeline.setInstrumentation(.{
    .provider = provider.asProvider(),
    .scope_name = "azure_rest_data_tables",
    .scope_version = "0.2.0",
    .namespace = "Microsoft.Storage",
});
var client = TablesClient.init(pipeline, .{ .endpoint = endpoint });
```

`provider` is a caller-owned `core.tracing.ExportingTracerProvider` (or another
provider implementation). The provider, exporter, runtime backends, policy
storage, scope strings and optional parent tracestate must outlive every client
copy and active operation. Clients preserve all caller scope/version/namespace
and parent values; they never synthesize them or configure tracing on the runtime.
They do not flush or shut down the provider. Export and shut down explicitly
after operations complete. Use `pipeline.setInstrumentation(null)` before
construction to disable instrumentation; later pipeline changes do not mutate
existing value copies.

Core automatically traces logical pipeline requests. Streaming spans end when
response headers arrive, not at body completion. Generated per-call context
expansion remains deferred to **#465**. Generated clients do not synthesize
user-agent policies; the versioned policy above is also caller-configured.

## Build and regeneration

```bash
zig build test --summary all
```

The manifest pins `azure_sdk_core` by immutable release commit and Zig
package hash. The `.azure-sdk-generator` provenance file records the
generator revision and reproducible generation command.
