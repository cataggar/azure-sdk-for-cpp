# azure_sdk_keyvault

One independently versioned Key Vault package with four namespaces:

| Namespace | Clients |
| --- | --- |
| [`secrets`](secrets/README.md) | `SecretClient` |
| [`keys`](keys/README.md) | `KeyClient`, `CryptographyClient` |
| [`certificates`](certificates/README.md) | `CertificateClient` |
| [`administration`](administration/README.md) | `BackupClient`, `SettingsClient` |

- Source: `sdk/keyvault`
- Release branch: `sdk/keyvault`
- Current version: `0.3.0`
- Dependencies: `azure_sdk_core` `0.4.0` and `serde`

All clients require an explicit `core.http.HttpRuntime`, so applications select
the HTTP transport and SDK crypto provider independently:

```zig
const core = @import("azure_sdk_core");
const keyvault = @import("azure_sdk_keyvault");

var transport = core.http.StdHttpTransport.init(allocator, io);
defer transport.deinit();
var crypto = core.crypto.StdCryptoProvider.init(io);
const runtime = core.http.HttpRuntime.init(
    transport.asTransport(),
    crypto.asProvider(),
);

var client = try keyvault.secrets.SecretClient.init(
    allocator,
    "https://my-vault.vault.azure.net",
    credential,
    runtime,
    .{},
);
defer client.deinit();
```

Runtime descriptors are copied by value while their transport and crypto
contexts are borrowed. Credentials and policy contexts are borrowed too. They
must outlive every client, derived cryptography client, pager, and in-flight
operation that uses them. Keep a parent `KeyClient` alive until clients
returned by `getCryptographyClient` and all of its pagers are deinitialized.
Core's bearer-token cache is mutable and unsynchronized, so callers must
serialize every operation sharing a client's pipeline state, including pager
operations and calls through derived cryptography clients, even when the
selected transport and crypto backends are independently synchronized. The
package installs no fallback crypto provider.

## Opt-in tracing

All six client option types accept the full
`?core.tracing.InstrumentationOptions`, defaulting to `null`:
`SecretClientOptions`, `CertificateClientOptions`, `KeyClientOptions`,
`CryptographyClientOptions`, `BackupClientOptions` and `SettingsClientOptions`.
No new constructor or runtime is required:

```zig
var client = try keyvault.secrets.SecretClient.init(
    allocator,
    "https://my-vault.vault.azure.net",
    credential,
    runtime,
    .{ .instrumentation = .{
        .provider = provider.asProvider(),
        .scope_name = "azure_sdk_keyvault",
        .scope_version = "0.3.0",
        .namespace = "Microsoft.KeyVault",
        .parent_context = parent, // Optional core.tracing.TraceContext.
    } },
);
defer client.deinit();
```

The example scope is not a default. Explicit scope/version/namespace/default
parent values are preserved; `options.scope` remains the separate OAuth token
scope. With `instrumentation = null`, no automatic spans or trace headers are
added. Constructors configure the shared state before it can be copied into
pagers or borrowed by `KeyClient.getCryptographyClient`. Derived cryptography
clients inherit the parent's configuration and do not acquire ownership.
The low-level `PipelineState.create` signature remains unchanged and creates
an uninstrumented state; `setInstrumentation` configures it before sharing.

Providers and exporters/sinks stay application-owned and address-stable.
Keep them, their backing resources, nonstatic scope/version/namespace strings
and default-parent tracestate alive until every client, borrowed descendant,
pager and operation has finished. Deinitialize derived clients/pagers before
their owning client. Clients never drain, flush, shut down or deinitialize
providers. For Core's
[`ExportingTracerProvider`](https://github.com/cataggar/azure-sdk-for-zig/blob/azure_sdk_core/v0.4.0/tracing/README.md),
the application explicitly calls bounded `drain(timeout_ms)`,
`forceFlush(timeout_ms)` and `shutdown(timeout_ms)` as appropriate; there is no
hidden worker or network exporter. Core streaming spans end at response headers,
not after body consumption; SDK result parsing is outside the HTTP span.
Per-call context parameters remain deferred to
[#465](https://github.com/cataggar/azure-sdk-for-zig/issues/465).

## Operation behavior

Authenticated pagers accept continuation URLs only when they are absolute
HTTPS URLs on the original vault's effective host and port. Cross-origin,
userinfo-bearing, fragmented, malformed, and non-HTTPS continuations fail
before the URL can be retained for another authenticated request.

`keys.CryptographyClient` performs Key Vault service-side cryptography: its
`sign` operation sends a caller-provided digest as a REST payload. It does not
hash that payload locally and is separate from both SDK runtime cryptography
and the transport's TLS implementation.

The handwritten Secrets namespace is separate from the generated
[`azure_rest_keyvault_secrets`](https://github.com/cataggar/azure-sdk-for-zig/tree/main/rest/keyvault_secrets)
protocol package.

## Development

```bash
zig build test --summary all
```
