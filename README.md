# azure_sdk_messaging_common

Shared messaging types used by Event Hubs and Service Bus.

## Connection strings

`ConnectionStringProperties.parse` accepts the two shapes the portal and the
other Azure SDKs produce: an embedded `SharedAccessKeyName`/`SharedAccessKey`
pair, or a pre-formed `SharedAccessSignature`. Keys are matched
case-insensitively and a value may contain `=`, as base64 keys and SAS tokens
do. A string with neither a key nor a signature is rejected at parse time
rather than failing later as an opaque broker 401.

`UseDevelopmentEmulator=true` sets `emulator`, which switches `scheme()` from
`amqps` to `amqp` and makes `useTls()` false. The emulator is only addressable
as `sb://host` or `sb://host:port`, and any other endpoint is rejected.

Every slice borrows from the connection string, which must outlive the result.

## Shared Access Signatures

`sas.sign` produces the token format the brokers accept:

```text
SharedAccessSignature sr={encoded resource}&sig={encoded HMAC}&se={expiry}&skn={key name}
```

The string-to-sign is `encoded_resource + "\n" + expiry`. HMAC-SHA256 uses the
exact UTF-8 bytes of `SharedAccessKey`; the value is not Base64-decoded. Raw
and Base64-encoded temporary MAC material is wiped on every success and failure
path. Signing uses an explicit `azure_sdk_core.crypto.CryptoProvider`; there is
no fallback to the standard provider. Encoding follows Go's
`url.QueryEscape`: everything outside `A-Za-z0-9-_.~` is escaped and a space
becomes `+`. The resource is lowercased after encoding, so its escapes read
`%3a`/`%2f`; the signature is not lowercased, so its escapes read `%2B`/`%3D`.
That asymmetry is deliberate and is pinned by a reference vector cross-checked
against the Go and Rust SDKs.

`SasCredential` implements `azure_sdk_core`'s `TokenCredential`, so downstream
clients only ever see a credential. It either signs a fresh token per request
from a shared key, defaulting to one hour of validity, or hands back a
pre-formed signature and reports that signature's own `se` expiry. A pre-formed
signature cannot be re-signed, so `isRefreshable` is false and a request made
after it expires fails with `error.SignatureExpired` instead of handing back a
token the broker will reject.

A shared-key credential signs with the provider in the `HttpRuntime` supplied
to each `TokenCredential.getToken` call, so provider selection follows the
client runtime and no provider is retained by the credential. A pre-formed
token remains independent of the runtime provider.

The `azure_sdk_core` dependency is pinned to the
`azure_sdk_core/v0.4.0` release commit
`be32073994f37422f2f6b5e9255d208b1284de85` and package hash.

This is a Core source/type compatibility release. Messaging Common provides
SAS and connection-string helpers, not an HTTP service client, and therefore
does not add instrumentation options, automatic HTTP spans, or propagation.
Tracing belongs to the calling client/pipeline; its provider and
flush/shutdown lifecycle remain caller-owned. `HttpRuntime` continues to select
only HTTP transport and SDK crypto, not tracing.

Use `sas.audienceFor` to build the `amqps://{namespace}/{entity}` resource. An
entity-scoped token authorizes every partition and consumer group beneath it,
so one token covers all of a client's links.

The CBS token type constants are `cbs_token_type_sas`
(`servicebus.windows.net:sastoken`) and `cbs_token_type_jwt` (`jwt`).

Release branch: `sdk/messaging_common`. The package depends on
`azure_sdk_core`; the current package version is `0.4.0`.

## Development

```bash
zig build test --summary all
```
