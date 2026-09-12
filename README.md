# azure_sdk_core

Core HTTP, authentication, error, paging, long-running-operation, URL, crypto,
and utility infrastructure for the Azure SDK for Zig.

The canonical package/module name is `azure_sdk_core`, released from
`sdk/core`. Identity remains part of this package. The current release line is
`0.4.0`, adding opt-in tracing, owned request headers, and expanded real-backend
conformance to the explicit provider/streaming runtime introduced in `0.3.0`.

## Core surface

| API | Purpose |
| --- | --- |
| `http.StdHttpTransport` | Streaming HTTP via `std.http.Client` with gzip, deflate, and zstd response decoding |
| `http.MockTransport` | Canned buffered and streaming responses for tests |
| `http.SequenceMockTransport` | Ordered responses for retry tests |
| `http.HttpRuntime` | Selected HTTP transport and SDK crypto provider |
| `http.HttpPipeline` | Policies followed by one runtime |
| `http.RequestHeaders` | Owned case-insensitive request headers with allocation-free trace restoration |
| `http.TelemetryPolicy` | Adds `User-Agent` |
| `http.LoggingPolicy` | Logs requests through `std.log` |
| `http.RetryPolicy` | Bounded exponential backoff, jitter, and `Retry-After` |
| `http.BearerTokenAuthPolicy` | Bearer authentication with token caching |
| `http.RequestIdPolicy` | Adds an `x-ms-client-request-id` UUID |
| `crypto.CryptoProvider` | Pluggable random, MD5, SHA-256, and HMAC-SHA256 operations |
| `crypto.StdCryptoProvider` | Pure-Zig provider backed by `std.Io` and `std.crypto` |
| `credentials.CachedTokenCredential` | In-memory token cache with expiry |
| `base64` | Provider-backed HMAC-SHA256, SHA-256, and integrity-only MD5 helpers |
| `url` | URL parsing and RFC 3986 percent encoding |
| `errors` | Azure error-envelope parsing |
| `lro` | Long-running-operation polling |
| `pager` | Generic `PipelinePager` |
| `tracing` | Opt-in bounded spans and explicit OTLP JSON output |
| `perf` | Wall-clock and allocation benchmark harness |

`HttpTransport.open` and `HttpPipeline.open` return a heap-backed,
single-owner `HttpOperation`. Consume its reader and call `finish` to drain for
connection reuse, or `abort`/`cancel` to close early. Always call `deinit`;
it aborts an active operation. Streaming request preparation runs once and
does not replay a consumed reader.

HTTP construction has one explicit dependency path:

```zig
var transport = core.http.StdHttpTransport.init(allocator, io);
defer transport.deinit();
var crypto = core.crypto.StdCryptoProvider.init(io);
const runtime = core.http.HttpRuntime.init(
    transport.asTransport(),
    crypto.asProvider(),
);
var pipeline = core.http.HttpPipeline.init(runtime, policies);
```

Transport and crypto descriptors, and therefore `HttpRuntime`, copy by value
while borrowing their backend contexts. Keep `transport` and `crypto` alive
for every pipeline, credential call, client, and open operation that uses
them. `StdHttpTransport` remains caller-serialized. Custom crypto provider
contexts must be concurrent-safe or caller-serialized. Incremental SHA-256
operations own stable allocator-backed state and must be deinitialized once.

`Request.headers` is now an owned `http.RequestHeaders`, not a raw
`std.StringHashMap`. Existing `Request.setHeader` / `getHeader` calls are
unchanged. Direct map mutation and typed map pointers require the
[request-header migration](http/request_headers.md). Response-header APIs are
unchanged. This is a public source-compatibility change in `0.4.0`: migrate raw
request-header access and keep transitive Core dependency pins coherent when
upgrading consumers.

## Adapter conformance

Core exports two test-only build modules in addition to the production
`azure_sdk_core` module:

- `azure_sdk_core_http_conformance`
- `azure_sdk_core_crypto_conformance`

Optional adapter packages import these modules from their pinned Core
dependency and invoke the public factory-based runners. They are deliberately
not imported by `root.zig`, and Core has no dependency on optional HTTP or
crypto adapters.

```zig
const core_dep = b.dependency("azure_sdk_core", .{
    .target = target,
    .optimize = optimize,
});
const http_contracts = core_dep.module("azure_sdk_core_http_conformance");
const crypto_contracts = core_dep.module("azure_sdk_core_crypto_conformance");
```

HTTP factories publish explicit capabilities for streaming, response-header
ordering, framing validation, response limits, cancellation grade,
decompression ownership, lifecycle observation, and bounded-memory
logical-large uploads/downloads. Crypto factories publish incremental-allocation and
concurrency guarantees. A skipped capability is not evidence of runtime
support.

Core runs the raw transport suite against `StdHttpTransport` and
`MockTransport`, retains the fake redirect/retry/allocation contracts, and runs
actual standard-backend attempt and allocation-failure contracts. The crypto
suite uses `StdCryptoProvider`. The standard transport remains
caller-serialized; the standard SDK crypto provider supports concurrent
hash/HMAC calls. CI also archives exactly the manifest `.paths`,
fetches that archive into a separate consumer package, and resolves all three
modules through `b.dependency`; omitted package files therefore fail the
package test.

### HTTP factory integration

Existing runner signatures, the three `CancellationGrade` tags, and required
factory/instance fields are unchanged. New fields default to unsupported/null.
Adapters opt in only when their fixture implements the associated contract:

- **`scripted_attempts`**: honor `BackendOptions.responses`, serving successive
  responses at the same endpoint, and implement `BackendInstance.attemptFn`.
  Each observation includes the method/path request line, body prefix and
  length, credential headers, and `X-Conformance-Policy`. Record requests at
  the peer, not just descriptor invocations: invisible backend retries must
  fail the contract. `finish` must stop an unused scripted endpoint without
  waiting for a request. An exhausted script must respond deterministically
  (Core's server returns 418), not leave an extra attempt blocked.
- The actual-backend suite asserts no raw retry, exactly one configured retry,
  the retry ceiling, `retryable=false`, one-shot suppression, exact rewind
  counts/errors, and policy invocation counts outside/inside the retry policy.
  It also checks forbidden redirects, one-shot redirects, and rejection of
  plaintext redirect targets before a destination request.
- **`https_redirects`**, together with `scripted_attempts`: provide distinct,
  trusted **HTTPS** endpoints. This additionally enables successful same-origin
  and cross-origin redirects, credential stripping/preservation, fragment
  removal, cross-origin Host replacement, 303 body/method rewriting, and
  rewind-failure cleanup. Core's
  standard fixture is HTTP loopback and does **not** claim this capability.
  Existing fake positive redirect tests remain separate evidence. No test
  weakens Core's HTTPS redirect requirement or substitutes for TLS trust tests.
- **`bounded_memory_logical_large_upload` /
  `bounded_memory_logical_large_download`**: honor `fixture_allocator` for
  peer/harness allocations, while every backend/context/operation allocation
  uses the allocator supplied to `createFn`. Each transfer gets a fixed
  **2 MiB cumulative allocation budget**, independent of the generated
  **32 MiB + 257-byte** body. Uploads cover known-length and chunked framing,
  retaining a 4096-byte prefix and a seed-zero `std.hash.Wyhash` of the entire
  received body in `Observation.body_hash`. Downloads honor
  `Response.generated_body`, validate every byte and exact length, and exercise
  full consumption, partial-read `finish` drainage, and early abort with both
  framings. The buffered-response limit must not truncate streaming reads.
- The wide-upload framing case advertises **4 GiB + 65537 bytes** but sends
  only 65537 bytes, expecting `RequestBodyTooShort` and an unchanged wire
  `Content-Length`. This is a width/framing test, **not a multi-GiB transfer**.
  `finish` currently drains to EOF; these tests do not claim an independent
  drain-byte ceiling or interruption of a blocked drain.
- **`allocation_failure_cleanup`**: implement `allocationFixtureFn` and invoke
  `runBackendAllocationFailureContracts(allocator, io, factory)`. It exhaustively
  fails allocations in buffered, finish, abort, redirect, and retry scenarios.
  `runBackendAllocationScenario` is a reusable implementation for that hook;
  adapters must additionally account for native handles/pools and normalize
  allocator-caused wrapper errors to `OutOfMemory`. The runner owns each
  failing allocator and rejects OOM results without an induced failure;
  `WriteFailed` is normalized only after an induced allocation failure.
  The peer uses the separate
  fixture allocator, never the failing allocator on a second thread. Without
  HTTPS fixtures, the redirect scenario proves rejection-path cleanup only.
  The original zero-argument `runAllocationFailureContracts()` still tests
  **fakes only**.
- **`assertQuiescentFn`** optionally verifies adapter-native resources after
  operation teardown, including failed allocation paths. The standard factory
  checks one remaining transport reference, no leased connections, and no
  idle connections for the server's `Connection: close` responses. Lifecycle
  counters, when advertised, must distinguish exactly one finish/abort/cancel
  and one deinit; deinitializing an active operation aborts it once. These
  counters also check intermediate retry/redirect cleanup. Counters belong to
  the transport context that dispatched the operations, even when the peer
  URL changes; peer request counts belong to each endpoint. These close-only
  fixtures do not certify keep-alive pool reuse.

### Stronger interruption evidence

`Capabilities.interruption` has independent `token` and `deadline` phase sets:
`connect`, `upload_read`, `upload_write`, `response_headers`, `response_body`,
and `finish_drain`. Blocking caller-reader interruption is deliberately
separate from interrupting an upload socket write.
Populate them with `InterruptionPhases.initMany(...)` (or `insert`) only when
the adapter implements `interruptionFixtureFn`. `runRawTransportContracts`
invokes `runInterruptionContracts` automatically; either runner rejects a
claimed phase without its integration hook.

The adapter-local fixture must synchronize entry into a genuinely blocked
phase, then signal the token or expire a deadline, measure completion within
1000 ms of that trigger, and return `InterruptionEvidence`. It must use a
bounded watchdog and join/clean up even on failure. Evidence must report the
original `OperationCancelled` or `OperationTimedOut` outcome, a started
transport, exactly one cleanup, zero live operations, and zero leased
connections. Preflight cancellation, a late success, or cleanup after manually
unblocking the phase is not proof of interruption.

Standard Core still advertises only `cooperative_upload`; its stronger phase
sets are empty. WASI gains no cancellation/runtime claim. Adapter/TLS trust
fixtures, HTTPX and native SymCrypt composition, service-client provider
selection, and the final supported-target/release matrix remain separate
integration work.

The WASI HTTP implementation separates target-neutral request adaptation from
the `wasi:http@0.2.6` host externs. Native tests use an injectable fake host for
the target-neutral seam. `zig build wasi-check` only proves that the
`wasm32-wasi` guest code builds; it does **not** claim a runtime WASI engine,
network, TLS, or trust-provider test.

## Identity

Identity remains part of `azure_sdk_core` and is available through
`core.identity`.

| Credential | Authentication source |
| --- | --- |
| `ClientSecretCredential` | OAuth 2.0 client credentials |
| `EnvironmentCredential` | `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and `AZURE_CLIENT_SECRET` |
| `ManagedIdentityCredential` | Azure Instance Metadata Service |
| `AzureCliCredential` | `az account get-access-token` |
| `WorkloadIdentityCredential` | Kubernetes OIDC federation |
| `ChainedTokenCredential` | First successful credential |
| `DefaultAzureCredential` | A chain selected by `AZURE_TOKEN_CREDENTIALS` |

### `AZURE_TOKEN_CREDENTIALS`

`DefaultAzureCredential` builds its chain from `AZURE_TOKEN_CREDENTIALS`.

| Value | Chain |
| --- | --- |
| unset | `EnvironmentCredential`, `WorkloadIdentityCredential`, `AzureCliCredential`, `AzureDeveloperCliCredential` |
| `prod` | `EnvironmentCredential`, `WorkloadIdentityCredential`, `ManagedIdentityCredential` |
| `dev` | `AzureCliCredential`, `AzureDeveloperCliCredential` |
| a credential name | just that credential |

Values are matched ignoring ASCII case and surrounding whitespace; any other
value fails with `error.UnknownTokenCredentialSelection`. A selected credential
whose configuration is absent is left out of the chain, and a selection that
leaves the chain empty fails with `error.NoCredentialConfigured`.

`ManagedIdentityCredential` probes the Instance Metadata Service at
`169.254.169.254`, which is unroutable outside Azure and stalls every token
request until the connection times out. It is therefore never in the default
chain. Set `AZURE_TOKEN_CREDENTIALS=prod` on deployed services, or name the
credential directly, to use it.

## Benchmarking

`core.perf` measures a closure against the monotonic clock and counts the
allocations it makes.

```zig
fn encodeOnce() !void { ... }

const result = core.perf.benchmark(io, "encode", 10_000, encodeOnce);
core.perf.printResult(result);
```

`benchmark` needs a `std.Io` because it reads `std.Io.Timestamp.now(io, .awake)`,
the monotonic clock that keeps running while a task sleeps. Pass the same `Io`
the code under test uses; `std.testing.io` works in tests.

To attribute allocations, run through `benchmarkAllocating`, which wraps the
allocator you hand it and reports `allocationsPerOp` and `bytesPerOp` alongside
`avgNs`:

```zig
fn encodeWith(allocator: std.mem.Allocator) !void { ... }

const result = core.perf.benchmarkAllocating(io, "encode", 10_000, gpa, encodeWith);
```

`CountingAllocator` is also usable on its own to assert an operation stays
allocation-free. It counts only events that obtain new memory: a failed
allocation, an in-place `resize`, and a `remap` that succeeds without moving
are all excluded, so the count reflects real allocation churn rather than
allocator bookkeeping.

`avgNs` and `opsPerSecond` are reciprocals — both derive from the summed
per-iteration laps. `total_ns` is wall-clock for the whole run and also
includes the harness's own timer reads, so it is always larger. Each lap costs
two clock reads, which puts a floor of roughly one clock read on `min_ns`;
give each iteration enough work to dominate it.

## Related packages

- [AMQP](https://github.com/cataggar/azure-sdk-for-zig/tree/sdk/amqp)
- [Event Hubs](https://github.com/cataggar/azure-sdk-for-zig/tree/sdk/eventhubs)
- [Service Bus](https://github.com/cataggar/azure-sdk-for-zig/tree/sdk/servicebus)
- [Testing](https://github.com/cataggar/azure-sdk-for-zig/tree/sdk/testing)

`tracing` and `perf` are namespaces of this package, not separate packages.

## Development

```bash
zig build test --summary all
zig build package-consumer-check --summary all
zig build wasi-check --summary all
```

The package depends on `serde`. See the
[package model](https://github.com/cataggar/azure-sdk-for-zig/blob/main/doc/package-branch-model.md).
