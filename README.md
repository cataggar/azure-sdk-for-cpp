# Azure Container Registry REST for Zig

`azure_rest_container_registry` is the generated protocol package for
Azure Container Registry data-plane API version **2021-07-01**.
It is produced from the checked-in TypeSpec code model and is entirely
generator-owned. Do not edit this package by hand; change the emitter or
fixture and regenerate it instead.

## Protocol surface

The generated clients expose all 29 stable operations through:

- `ContainerRegistryClient`
- `ContainerRegistry`
- `ContainerRegistryBlob`
- `Authentication`

This layer preserves raw protocol request/response types and status
unions. It does not add challenge authentication, safe continuation
validation, digest verification, transfer replay, or domain ownership
helpers. Use `azure_sdk_container_registry` for those behaviors.

The generated `init` constructor accepts the caller's
`core.http.HttpPipeline`. Construct that pipeline from a
`core.http.HttpRuntime` and the policy chain required by the application.
The runtime descriptors and their backend contexts are borrowed and must
outlive every generated client and active operation.
Generated result fields follow their declared allocator ownership; free
or deinitialize every owned body/header/model value shown by the type.

## Core 0.4 and optional tracing

Package **0.3.0** adopts the published **Core 0.4.0** release. Configure optional
instrumentation on the caller's pipeline before constructing a client:

```zig
var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_container_registry/0.3.0");
var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
var pipeline = core.http.HttpPipeline.init(runtime, &policies);
pipeline.setInstrumentation(.{
    .provider = provider.asProvider(),
    .scope_name = "azure_rest_container_registry",
    .scope_version = "0.3.0",
    .namespace = "Microsoft.ContainerRegistry",
});
var client = ContainerRegistryClient.init(pipeline, .{ .endpoint = endpoint });
```

`provider` is a caller-owned tracing provider, such as
`core.tracing.ExportingTracerProvider`. Every generated subgroup copies the
complete pipeline: caller scope/version/namespace, default parent context, and
policies are preserved, never overwritten with package defaults. Constructors
do not add provider parameters or configure tracing on `HttpRuntime`.

Tracing is disabled by default. `pipeline.setInstrumentation(null)` disables it
for future copies; changing the original pipeline does not reconfigure existing
clients. Provider/exporter, runtime backends, policy storage, scope strings and
optional parent tracestate must outlive every copy and operation. Clients never
flush or shut down providers; the application exports and shuts down explicitly.
Streaming spans end at response headers, not body completion. Generated per-call
context expansion remains deferred to **#465**. User-agent policies remain
caller-configured, as in the versioned example above.

## Media types

The REST package transports caller-provided media types. The hand-written
package has first-class upload support for OCI image manifests and Docker
schema-2 manifests and accepts OCI image/index, Docker schema-2
manifest/list/config, ORAS artifact manifest, and wildcard manifest
responses.

## Build and regeneration

```bash
zig build test --summary all
gh workflow run generated-package-pr.yml \
  -f target_branch=rest/container_registry \
  -f generator_commit=<main-commit>
```

The package manifest pins `azure_sdk_core` by immutable commit and Zig
package hash. See the
[package branch model](https://github.com/cataggar/azure-sdk-for-zig/blob/main/doc/package-branch-model.md)
and
[Container Registry release staging](https://github.com/cataggar/azure-sdk-for-zig/blob/main/eng/container_registry_release/README.md).
