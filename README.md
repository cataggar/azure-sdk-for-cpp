# azure_sdk_storage_files_shares

Azure Files clients:

- `ShareServiceClient`
- `ShareClient`
- `ShareDirectoryClient`
- `ShareFileClient`

Release branch: `sdk/storage_files_shares`. The package depends on
`azure_sdk_core` 0.4.0 at `be32073994f37422f2f6b5e9255d208b1284de85`.
Version 0.3.0 adopts that Core source/type boundary.

Construct a Core `HttpRuntime` with independently selected HTTP transport and
crypto providers, place it in an `HttpPipeline`, and pass that pipeline to a
client constructor:

```zig
var transport = core.http.StdHttpTransport.init(allocator, io);
defer transport.deinit();
var crypto = core.crypto.StdCryptoProvider.init(io);
const runtime = core.http.HttpRuntime.init(
    transport.asTransport(),
    crypto.asProvider(),
);
var pipeline = core.http.HttpPipeline.init(runtime, &.{});
// Optional: tracing_provider is a caller-owned *core.tracing.TracerProvider.
pipeline.setInstrumentation(.{
    .provider = tracing_provider,
    .scope_name = "azure_sdk_storage_files_shares",
    .scope_version = "0.3.0",
    .namespace = "Microsoft.Storage",
});

var service = ShareServiceClient.init(
    pipeline,
    "https://myaccount.file.core.windows.net",
    .{},
);
var share = service.getShareClient("myshare");
var directory = share.getDirectoryClient("documents");
var file = directory.getFileClient("readme.txt");
```

Clients and pipelines copy the runtime descriptors by value but borrow the
transport and crypto provider contexts. Those contexts, the pipeline policy
storage, and all endpoint/name/option strings must outlive the clients and any
operations using them. Backend thread-safety and caller-serialization
requirements continue to apply.

The legacy credential-plus-transport `ShareClient.init` signature is removed.
Service, share, directory, and file clients each have one pipeline-based
constructor; derived clients preserve the complete runtime, including its
crypto provider and the complete optional instrumentation configuration.

Tracing is disabled by default. Configure it on the supplied pipeline, not
`HttpRuntime`; no additional client constructor option is needed. Explicit
scope name/version, namespace, and default `parent_context` are preserved
through service, share, directory, and file clients. Existing client copies
are unaffected by later reconfiguration of the original pipeline. The tracing
provider and borrowed configuration strings must outlive every copy.
Flush/shutdown remain explicit caller responsibilities; clients never manage
the provider lifecycle. Per-call parent options remain deferred to #465.
Core streaming spans, when used, end at response headers rather than at body
completion; the operations exposed here currently use buffered sends.

```bash
zig build test --summary all
```
