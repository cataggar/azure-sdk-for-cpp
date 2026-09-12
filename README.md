# Azure DevOps REST for Zig

`azure_rest_devops` is the generated Azure DevOps protocol package for
the **7.2** REST contract. It is entirely generator-owned; update the
TypeSpec source or emitter and regenerate instead of editing package
files by hand.

## Protocol surface

Azure DevOps publishes its REST API as 44 independent areas that share
a host family, an auth scheme and a release cadence, so they ship here
as one package with a Zig namespace per area rather than 44 packages.
Each area exposes a root client (`root.git.GitClient`) whose accessor
methods reach the area's operation groups
(`git_client.repositories()`), matching the shape Azure DevOps uses in
its REST documentation.

`api-version` is client state pinned to the area's 7.2 contract, and
each area's root client carries the default endpoint for its own host
(`dev.azure.com`, `vssps.dev.azure.com`, `pkgs.dev.azure.com`, …),
overridable through `InitOptions` for Azure DevOps Server.

The source contract is the `typespec` branch of
[`cataggar/vsts-rest-api-specs`](https://github.com/cataggar/vsts-rest-api-specs/tree/typespec/typespec),
which converts Microsoft's published Swagger 2.0 definitions to
TypeSpec. The `.azure-sdk-generator` provenance file records the
generator revision, the spec revision and the reproducible generation
command.

## Core 0.4 and optional tracing

Package **0.2.0** pins published **Core 0.4.0** by immutable commit and hash.
All 44 area roots and their 371 operation groups copy the caller's complete
pipeline. Configure it once before constructing any area client:

```zig
var telemetry = core.http.TelemetryPolicy.init("azsdk-zig-azure_rest_devops/0.2.0");
var policies = [_]*core.http.HttpPolicy{telemetry.asPolicy()};
var pipeline = core.http.HttpPipeline.init(runtime, &policies);
pipeline.setInstrumentation(.{
    .provider = provider.asProvider(),
    .scope_name = "azure_rest_devops",
    .scope_version = "0.2.0",
    .namespace = "Azure.DevOps",
});
var git_client = root.git.GitClient.init(pipeline, .{});
```

The example's `provider` is caller-owned, for example a
`core.tracing.ExportingTracerProvider`. Scope/version/namespace and default
parent context are caller choices, preserved without an area-specific override.
Generated constructors do not grow provider options, synthesize user agents, or
configure tracing on `HttpRuntime`. The versioned telemetry policy above is
also caller-configured.

Tracing is off by default; `pipeline.setInstrumentation(null)` disables it for
future copies. Existing clients retain their copied configuration. Provider,
exporter, runtime backends, policy storage, scope strings and optional parent
tracestate must outlive all clients and operations. Clients never flush or shut
down providers: the caller explicitly exports and shuts down after use.
Streaming spans end at response headers, not body completion. Generated
per-call context expansion is deferred to **#465**, not added to every operation.

## Build and regeneration

```bash
zig build test --summary all
```

The manifest pins `azure_sdk_core` by immutable release commit and Zig
package hash.

## API areas

- `account` — 2 clients, 1 operations
- `advanced_security` — 18 clients, 28 operations
- `approvals_and_checks` — 5 clients, 15 operations
- `artifacts` — 9 clients, 37 operations
- `artifacts_package_types` — 7 clients, 74 operations
- `audit` — 5 clients, 9 operations
- `build` — 29 clients, 89 operations
- `core` — 6 clients, 19 operations
- `dashboard` — 4 clients, 16 operations
- `delegated_auth` — 2 clients, 2 operations
- `distributed_task` — 22 clients, 62 operations
- `environments` — 7 clients, 17 operations
- `extension_management` — 2 clients, 5 operations
- `favorite` — 2 clients, 4 operations
- `git` — 38 clients, 108 operations
- `graph` — 13 clients, 29 operations
- `hooks` — 6 clients, 22 operations
- `ims` — 2 clients, 1 operations
- `member_entitlement_management` — 7 clients, 21 operations
- `notification` — 7 clients, 17 operations
- `operations` — 2 clients, 1 operations
- `permissions_report` — 3 clients, 4 operations
- `pipelines` — 6 clients, 10 operations
- `policy` — 5 clients, 12 operations
- `processadmin` — 3 clients, 4 operations
- `processes` — 14 clients, 56 operations
- `profile` — 2 clients, 1 operations
- `release` — 9 clients, 31 operations
- `resource_usage` — 3 clients, 2 operations
- `search` — 7 clients, 6 operations
- `security` — 5 clients, 9 operations
- `security_roles` — 3 clients, 6 operations
- `service_endpoint` — 5 clients, 12 operations
- `status` — 2 clients, 1 operations
- `symbol` — 6 clients, 13 operations
- `test` — 12 clients, 36 operations
- `test_plan` — 14 clients, 42 operations
- `test_results` — 42 clients, 84 operations
- `tfvc` — 6 clients, 15 operations
- `token_admin` — 4 clients, 3 operations
- `tokens` — 2 clients, 4 operations
- `wiki` — 7 clients, 15 operations
- `wit` — 33 clients, 84 operations
- `work` — 27 clients, 59 operations
