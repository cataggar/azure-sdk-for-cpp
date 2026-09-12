# azure_sdk_storage_files_datalake

Azure Data Lake Storage clients:

- `DataLakeFileSystemClient`
- `DataLakeFileClient`

Release branch: `sdk/storage_files_datalake`. The package depends on
`azure_sdk_core` 0.4.0 at `be32073994f37422f2f6b5e9255d208b1284de85`.
Package version 0.3.0 adopts that Core source/type boundary.

## Construction and lifetime

Clients take one caller-assembled `core.http.HttpPipeline`. This keeps HTTP and
SDK crypto backend selection independent and lets callers install the
authentication or signing policies appropriate for their credential:

```zig
var transport = core.http.StdHttpTransport.init(allocator, io);
defer transport.deinit();
var crypto_provider = core.crypto.StdCryptoProvider.init(io);

const runtime = core.http.HttpRuntime.init(
    transport.asTransport(),
    crypto_provider.asProvider(),
);
var pipeline = core.http.HttpPipeline.init(runtime, &.{});
// Optional: tracing_provider is a caller-owned *core.tracing.TracerProvider.
pipeline.setInstrumentation(.{
    .provider = tracing_provider,
    .scope_name = "azure_sdk_storage_files_datalake",
    .scope_version = "0.3.0",
    .namespace = "Microsoft.Storage",
});
var filesystem = datalake.DataLakeFileSystemClient.init(pipeline, .{
    .endpoint = "https://account.dfs.core.windows.net",
    .filesystem_name = "example",
});
var file = filesystem.getFileClient("path/to/file");
```

The pipeline and runtime descriptors are copied by value. Transport and crypto
backend contexts and pipeline policy objects are borrowed; they must outlive
all clients and in-flight operations that use them. Derived file clients retain
the same transport and crypto provider selections and the complete optional
instrumentation configuration.

Tracing is disabled by default and configured on `HttpPipeline`, not
`HttpRuntime`. Filesystem and derived file clients preserve explicit scope
name/version, namespace, and default `parent_context`; later changes to an
ancestor's pipeline do not alter existing child copies. The provider and
borrowed configuration strings must outlive those copies. No client
constructor option, hidden flush, or hidden shutdown is added: the caller
owns provider lifecycle management. Per-call parent options remain deferred
to #465. Core streaming spans end at response headers; these file operations
currently use buffered sends.

```bash
zig build
zig build test --summary all
```
