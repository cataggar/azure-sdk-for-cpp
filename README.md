# azure_sdk_data_appconfiguration

Azure App Configuration client exposing `ConfigurationClient`.

Release branch: `sdk/data_appconfiguration`. The package depends on
`azure_sdk_core` and `serde`. Version 0.3.0 adopts Core 0.4.0 at
`be32073994f37422f2f6b5e9255d208b1284de85`.

`ConfigurationClient` copies a caller-built `core.http.HttpPipeline`. The
endpoint and API version, the pipeline policy pointers, and the runtime
transport and crypto-provider contexts are borrowed. They must outlive the
client, every pager derived from it, and all operations. The package does not
install a transport or standard crypto fallback.

```zig
var transport = core.http.StdHttpTransport.init(allocator, io);
defer transport.deinit();
var crypto_provider = core.crypto.StdCryptoProvider.init(io);
const runtime = core.http.HttpRuntime.init(
    transport.asTransport(),
    crypto_provider.asProvider(),
);
var auth_policy = core.http.BearerTokenAuthPolicy.init(
    allocator,
    credential,
    app_configuration.auth_scopes,
);
defer auth_policy.deinit();
var policies = [_]*core.http.HttpPolicy{auth_policy.asPolicy()};
var pipeline = core.http.HttpPipeline.init(runtime, &policies);
// Optional: tracing_provider is a caller-owned *core.tracing.TracerProvider.
pipeline.setInstrumentation(.{
    .provider = tracing_provider,
    .scope_name = "azure_sdk_data_appconfiguration",
    .scope_version = "0.3.0",
    .namespace = "Microsoft.AppConfiguration",
});
var client = app_configuration.ConfigurationClient.init(endpoint, pipeline, .{});
```

Tracing is disabled by default. The client and its pagers copy the complete
pipeline, including explicit scope name/version, namespace, and default
`parent_context`; they do not replace those values with package defaults.
Existing pagers retain their configuration if the client or original pipeline
is subsequently changed. The provider and borrowed configuration strings must
outlive the client, pagers, and operations. Tracing does not belong in
`HttpRuntime`, and no new constructor option or implicit provider
flush/shutdown is added. The caller manages that lifecycle. Per-call parent
options remain deferred to #465. Core streaming spans end at response headers;
this package's setting and paging operations use buffered sends.

## Development

```bash
zig build test --summary all
```
