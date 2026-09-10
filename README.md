# azure_sdk_data_cosmos

Azure Cosmos DB clients:

- `CosmosClient`
- `DatabaseClient`
- `ContainerClient`

Release branch: `sdk/data_cosmos`. The package depends on
`azure_sdk_core` and `serde`. Version `0.2.0` uses Core's canonical
`HttpRuntime`.

Construct `CosmosClient` with an allocator, borrowed token credential, and
`core.http.HttpRuntime`, then call `deinit`. Database and container clients
borrow the parent client's heap-stable pipeline state and must not outlive it.
The runtime's transport and crypto backend contexts are also borrowed.
Authenticated endpoints must use HTTPS.

## Driver boundary decision (#145)

**Decision (2026-09-10): keep the current package and private helpers; do not
extract a driver or introduce another module boundary now.** This completes the
bounded evaluation requested by
[#145](https://github.com/cataggar/azure-sdk-for-zig/issues/145), not an
implementation of Rust-driver feature parity.

The evaluated baseline is `azure_sdk_data_cosmos/v0.2.0`, commit
`6060b28e83ecebed55de26a4e3bd7b223d2a7c15` on `sdk/data_cosmos`.
The canonical runtime, provider selection and conservative create replay
handling were already shipped in
[#439](https://github.com/cataggar/azure-sdk-for-zig/pull/439); they are not new
requirements blocked on the remaining repository-wide runtime migration.

### Evidence from read, create and query

The document API is already schema-agnostic. `CosmosItem.body` is supplied by
the caller, `readItem` returns allocated raw bytes, and `QueryResult.documents`
contains allocated raw document slices. Typed parsing concerns resource
metadata and query envelopes, not application document schemas.

| Path | Existing ownership and protocol boundary | Evaluation evidence |
| --- | --- | --- |
| `createItemResult` | Borrows the supplied body for the synchronous call, forwards the partition-key header, and uses `sendNonIdempotent`. The caller retains the body. | The create test checks a single POST and exact partition-key bytes. The dispatched-failure test exercises database, container and item creates: one transport call each, each returning `CosmosCreateOutcomeUnknown`. |
| `readItemResult` | Uses the existing Core pipeline and duplicates the raw response body before destroying the response. The caller frees the returned bytes with its allocator. | The read test checks one GET, exact partition-key bytes and byte-for-byte preservation of whitespace, escaped text, a nested array and numeric representations after response cleanup. |
| `queryItemsResult` | Makes one buffered request, extracts document slices and owns the returned continuation token. The caller uses `QueryResult.deinit`. | The query tests check exact document bytes, one request, existing query headers, and opaque header-token precedence over the body token without decoding or an automatic next-page request. |

The existing Core `HttpRuntime`/`MockTransport` seam already tests these paths
without live credentials or a typed document model. `PipelineState` centralizes
the heap-stable authentication/policy state, `sendNonIdempotent` centralizes
create replay classification, and `replaceContinuationToken` centralizes
allocate-before-replace ownership. Existing provider-spy, retry-date,
redirect and failing-allocator tests exercise these helpers without extracting
a package. These tests do not establish live-service conformance or a
performance result.

The evaluated tests pass with Zig 0.16.0 on native aarch64 Linux: 23/23 in
Debug and 23/23 in ReleaseSafe, using `zig build test --summary all` and
`zig build test -Doptimize=ReleaseSafe --summary all`.

### Alternatives considered

- **No new split — selected.** Keep request/response cleanup next to the
  public operation and reuse the current Core transport and private helpers.
  The three paths have different result ownership but no duplicated
  transport, token cache or routing implementation to extract.
- **Private protocol/state modules — deferred.** Moving the already
  centralized helpers changes file organization, not their ownership or
  testability. A generic raw-operation adapter would mostly wrap Core's
  existing request/response contract while introducing operation flags and
  another lifetime boundary. This evaluation found no concrete benefit that
  requires either change. Small common-header duplication alone does not
  justify a driver abstraction. No speculative prototype or performance
  comparison is claimed.
- **Separately versioned driver — not justified.** No second consumer or
  independent release requirement was demonstrated. The additional public
  contract, Core type/pin coordination and two-package release process have
  no demonstrated payoff. Rust's cross-language reuse motivation does not
  establish that need for this pure-Zig package.

This decision changes no constructor, method, public field, dependency,
provider lifetime, request policy or runtime code. There is no new package,
manifest path, exported driver type or release-version bump.

### Limits and reconsideration gates

`queryItems` currently returns one page; it does not accept a continuation
token or provide automatic paging. `parseQueryResult` uses a simple envelope
scanner: it expects `"Documents":[`, stops at the first closing bracket and
does not track JSON string quoting. Nested arrays, alternate envelope
whitespace and delimiters inside strings need a separately scoped parser
correctness change. They are not promises established by the raw-document
tests or problems solved merely by moving files.

There is no account topology/partition-range cache or automatic session-token
management in this package. Binary encoding, advanced routing, an in-memory
emulator, broader fault injection and new streaming APIs remain independent
feature decisions. No Cosmos service guarantee, new response-size cap or
Rust retry rule is introduced.

Reconsider a **private** seam when a concrete feature duplicates protocol/state
logic, needs independently testable effects not expressible through the
existing runtime, or demonstrates a response-ownership simplification. Require
unchanged public behavior, exact opaque data, no extra full-body copy, unchanged
create replay/request counts and allocation-failure coverage. Reconsider a
**separate package** only with a named consumer or demonstrated independent
release need, a stable ownership/provider contract and explicit maintainer
approval. No live Azure operation is needed to retain the current decision.

## Development

```bash
zig build test --summary all
```
