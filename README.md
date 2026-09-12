# azure_sdk_attestation

Azure Attestation client exposing `AttestationClient`.

Release branch: `sdk/attestation`. The package depends on
`azure_sdk_core` and `serde`. Version `0.3.0` adds opt-in tracing with Core `0.4.0`.

Construct clients with Core's canonical HTTP runtime:

```zig
var transport = core.http.StdHttpTransport.init(allocator, io);
defer transport.deinit();
var crypto = core.crypto.StdCryptoProvider.init(io);
const runtime = core.http.HttpRuntime.init(
    transport.asTransport(),
    crypto.asProvider(),
);
var client = try attestation.AttestationClient.init(
    allocator,
    endpoint,
    credential,
    .{ .runtime = runtime },
);
defer client.deinit();
```

The client copies the runtime, transport, and crypto descriptors by value.
Their backend contexts and the credential are borrowed and must outlive the
client and every operation on it. Transport and crypto providers remain
independently selectable. Attestation request IDs use `runtime.crypto`;
provider failures propagate without falling back to `std.crypto` or sending a
request.

Core is pinned to commit
`be32073994f37422f2f6b5e9255d208b1284de85` with package hash
`azure_sdk_core-0.4.0-eFY0EufqCgD3plkaubfUTeY5Jvr__1k0noWHdQjBVAdX`.

## Opt-in tracing

Use the existing options to configure both attestation operations:

```zig
var client = try attestation.AttestationClient.init(
    allocator,
    endpoint,
    credential,
    .{
        .runtime = runtime,
        .instrumentation = .{
            .provider = provider.asProvider(),
            .scope_name = "azure_sdk_attestation",
            .scope_version = "0.3.0",
            .namespace = "Microsoft.Attestation",
            .parent_context = parent, // Optional core.tracing.TraceContext.
        },
    },
);
defer client.deinit();
```

`instrumentation` defaults to `null`, with no automatic spans or trace headers.
It accepts the full `core.tracing.InstrumentationOptions`; the example scope
is not imposed on callers. Scope, version, namespace and default parent are
preserved and are unrelated to the OAuth credential scope.

The provider and exporter/sink are application-owned and must stay at stable
addresses, with their resources alive, until all clients and operations finish.
Nonstatic scope/version/namespace strings and parent tracestate are borrowed
for that lifetime too. Clients never drain, flush, shut down or deinitialize
providers. The application explicitly calls Core
[`ExportingTracerProvider`](https://github.com/cataggar/azure-sdk-for-zig/blob/azure_sdk_core/v0.4.0/tracing/README.md)
`drain(timeout_ms)`, `forceFlush(timeout_ms)` and `shutdown(timeout_ms)` as
appropriate; there is no hidden worker or network exporter. Automatic HTTP
spans end at response headers, not after streaming body consumption or result
parsing. Per-call context parameters remain deferred to
[#465](https://github.com/cataggar/azure-sdk-for-zig/issues/465).

## Development

```bash
zig build
zig build test --summary all
```
