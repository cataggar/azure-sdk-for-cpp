# azure_sdk_data_tables

Hand-written, idiomatic Zig conveniences for **Azure Storage Tables**.

Release branch: `sdk/data_tables`. Package version: `0.3.0`.
Version 0.3.0 introduces the breaking single-initializer API described below.
The `TableClient`, `TableServiceClient`, and `TableEntity` exports remain while the parity roadmap in
[tracker #148](https://github.com/cataggar/azure-sdk-for-zig/issues/148) is
implemented.

## Package boundary and protocol provenance

Two independently released packages form the planned Tables stack:

| Package | Branch | Owns |
|---|---|---|
| `azure_rest_data_tables` | `rest/data_tables` | Generated HTTP clients, wire models, operation options, exact request/response serialization, status codes, headers, and regeneration metadata |
| `azure_sdk_data_tables` | `sdk/data_tables` | Authentication, stable pipelines, typed and dynamic entities, paging, transactions, SAS, connection strings, structured errors, and convenience APIs |

The generated package must come from
`Azure/azure-rest-api-specs/specification/cosmos-db/data-plane/Tables/tspconfig.yaml`.
The directory name is historical: this is the shared Azure Tables wire
contract. **Cosmos DB Table API runtime support is excluded.** Cosmos endpoint
audiences, request transforms, compatibility policies, and emulator behavior
belong in a separate Cosmos SDK.

The contract was checked on 2026-07-27 at upstream `main` commit
`0744f52a86919d243ba2225e55bdb9c87bf521a5`. `Data.Tables.Versions` contains
only `2019-02-02`. Generation must nevertheless re-read
`Data.Tables.Versions`, choose the newest stable member, and record an
immutable upstream commit every time it is regenerated. A generic Storage
`x-ms-version` is not a substitute for a Tables contract version.

The SDK pins generated package commit
`799b35f81a0478045ec8faca7eb0e1b41c5fafe0` and Zig package hash
`azure_rest_data_tables-0.1.0-CqXnR-ZzAQD4MTM5hBpINSq2sdV70SMD2lKjSN1-9loh`,
and Core commit `bc77bcacbb64af935ca53d60bf8a351c9592bc41` with hash
`azure_sdk_core-0.3.0-eFY0Ev0-CACjsFaYPL6jS7CpeVNvsqYqTrXRfgQKiRFV`.
It re-exports the REST package public root as `protocol`. The REST provenance
records upstream spec commit `0744f52a86919d243ba2225e55bdb9c87bf521a5`,
generator commit `c83a1cbef5f728d7530fdec4a724cc453233cfa4`, and stable
API version `2019-02-02`.

`ProtocolClient` is the shared validated bridge to generated calls. It
normalizes endpoint paths while preserving SAS query bytes, maps metadata,
request ID, server timeout, client timeout, and per-call policy options, and
adapts generated values with allocator-owned raw response headers. Generated
models remain the only wire models.

### Release-time TypeSpec and regeneration checks

Run these immediately before releasing either package:

```bash
./scripts/verify-typespec-version.sh
./scripts/verify-rest-regeneration.sh <pinned-codegen-worktree> <rest/data_tables-worktree>
```

The first command requires the upstream `main` ref to equal the immutable
source commit above, extracts all stable `Data.Tables.Versions` entries from
`main.tsp`, verifies `2019-02-02` is the only one, and rejects a newly modeled
`$batch`. If it reports a changed source, update the fixture and generator,
regenerate `rest/data_tables`, update provenance and the SDK's immutable REST
commit/hash together, then repeat the checks. The second command regenerates
with generator commit `c83a1cbef5f728d7530fdec4a724cc453233cfa4` and performs
an exact diff against `rest/data_tables`; it removes only its generated output
under the supplied codegen worktree. It never selects a generic Storage API
version.

## Canonical construction

Both clients have one constructor, `init(allocator, runtime, init_options)`.
`TableClient.InitOptions` contains `authentication`, `table_name`, and optional
`options` (the existing retry, telemetry, request-ID, timeout, and policy settings).
`TableServiceClient.InitOptions` has the same fields except `table_name`.
The shared `ClientAuthentication` tagged union selects exactly one input:

| Tag | Input | Ownership |
|---|---|---|
| `.token` | `.{ .endpoint = endpoint, .credential = token_credential }` | Credential borrowed |
| `.shared_key` | `.{ .endpoint = endpoint, .credential = shared_key }` | Credential borrowed |
| `.sas_url` | Complete signed URL | URL copied; no credential created |
| `.connection_string` | Storage or Azurite connection string | Parsed strings released after copying; account-key credential owned by client |

```zig
var service = try tables.TableServiceClient.init(allocator, runtime, .{
    .authentication = .{ .token = .{
        .endpoint = endpoint,
        .credential = credential.asCredential(),
    } },
    .options = .{ .retry = .{ .max_retries = 2 } },
});
defer service.deinit();

var table = try tables.TableClient.init(allocator, runtime, .{
    .authentication = .{ .connection_string = connection_string },
    .table_name = table_name,
});
defer table.deinit();
```

Input strings are borrowed only for initialization; clients copy their endpoint,
table name, and applicable option strings. Runtime descriptors are copied while
their backend contexts remain borrowed. Explicit credentials and policy objects
must outlive owning clients and their derived clients. Do not deinitialize or copy
an owning client twice. Formatting `ClientAuthentication` redacts its contents.

## Microsoft Entra authentication

Create owning token-authenticated clients with
`TableServiceClient.init` or `TableClient.init` with `.authentication.token`. Both copy
their endpoint, API version, telemetry application ID, default client request
ID, and policy pointer list. Every constructor takes a canonical
`core.http.HttpRuntime`; its transport and crypto descriptors are copied by
value while their backend contexts remain borrowed. The credential, runtime
contexts, and policy objects must outlive the client and all in-flight calls.
The bearer policy requests
`https://storage.azure.com/.default`. Token-authenticated constructors require
HTTPS, including for custom and private endpoint hosts. HTTP is available only
to explicit local-emulator Shared Key and SAS authentication.

`TableServiceClient.getTableClient` creates a table client that owns its table
name and protocol configuration while borrowing the service client's stable
pipeline state. Deinitialize every derived client before its service client.
Derived clients share the parent's bearer-token cache and transport.

## Shared Key, SAS, and connection strings

`SharedKeyCredential.init` validates and decodes an account key, and
`.authentication.shared_key` uses the Table-only `SharedKeyLite` canonical form. The
signer runs after retry, so it applies a current `x-ms-date`, API version, and
signature to every attempt. Shared Key, connection-string, account SAS, and
table SAS signing all use the crypto provider selected by the client's
`HttpRuntime`; provider failures are returned without a standard-provider
fallback. Use `.authentication.sas_url` only with a complete signed
URL; its query bytes are retained verbatim and the pipeline has no
`Authorization` policy. Client formatting omits all query strings.

`.authentication.connection_string` accepts account-key and SAS strings with
`DefaultEndpointsProtocol`, `EndpointSuffix`, or `TableEndpoint`, plus
`UseDevelopmentStorage=true` for Azurite. It rejects duplicate, unknown, and
ambiguous fields before creating a pipeline. Token authentication is always
HTTPS; cleartext Shared Key/SAS endpoints are limited to local emulators.

`sas.AccountSignatureValues` generates Table-only account SAS values, and
`sas.TableSignatureValues` generates table service SAS values including stored
identifier and inclusive partition/row bounds. Its `accessPolicy` is a tagged
union: `.adHoc` requires permissions and expiry, while `.stored` accepts only
the identifier, so inline access fields cannot accidentally accompany a stored
policy. A partition bound may stand alone; a row bound requires its matching
partition. Permissions, services, and resource types are emitted in Azure's
required order; invalid time, permission, identifier, IP, and key-range
combinations fail before signing. SAS times use UTC whole-second precision and
the canonical Tables version `2019-02-02`.
`getAccountSasUrl` and `getTableSasUrl` are available only on Shared Key
clients. Their caller-owned URL results are secrets; SAS value/query formatting
is redacted. A full generated table URL can be passed directly to
`TableClient.init` using `.authentication.sas_url`. It recognizes table scope from one unambiguous,
decoded `tn` parameter and retains the complete encoded query bytes verbatim;
account SAS URLs never infer scope from their path.

Client options configure retry count/delays, telemetry application ID, a
default client request ID, a default operation timeout, API version, and
caller policies. Per-operation request IDs and operation timeouts override
client defaults. The stable policy order is request ID, telemetry, retry,
bearer authentication, client policies, then per-operation policies. Thus
authentication and caller policies run on every retry.

Initialized clients may be moved because policy objects and their type-erased
pointers live in allocator-owned stable storage. Calls that share a pipeline
must nevertheless be serialized: the bearer-token cache and standard HTTP
transport are mutable and not thread-safe. Crypto provider contexts must be
concurrent-safe or caller-serialized. Callers may provide external
synchronization when sharing a client or using multiple derived clients.

The canonical TypeSpec does not model `$batch`; the generated provenance and
operation inventory test prove that gap. `transaction.zig` therefore owns the
isolated hand-written multipart implementation; regeneration must never move
it into or overwrite the generated REST package.

## Examples

Compile all examples without credentials or network access:

```bash
zig build examples
```

| Example | Covers | Runtime configuration |
|---|---|---|
| `authentication.zig` | Entra bearer, Shared Key, SAS URL, connection string, and Azurite constructors | It sends no request; set only the environment variables for the constructor to exercise. `AZURE_DATA_TABLES_AZURITE=1` selects `UseDevelopmentStorage=true`. |
| `entities.zig` | Typed add/get, `DynamicEntity`, `EntityPager`, and conditional ETag update | `AZURE_DATA_TABLES_CONNECTION_STRING`, `AZURE_DATA_TABLES_TABLE`; use a disposable table. |
| `administration.zig` | Stored access policies, service-property read/update shape, and geo statistics | `AZURE_DATA_TABLES_CONNECTION_STRING`, `AZURE_DATA_TABLES_TABLE`; account-wide writes additionally require `AZURE_DATA_TABLES_ALLOW_SERVICE_PROPERTIES_WRITE=1`. Set `AZURE_DATA_TABLES_SECONDARY_CONNECTION_STRING` to actually call `getStatistics`; otherwise statistics are intentionally skipped. |
| `transactions.zig` | Hand-written same-partition `$batch` transaction | Same connection string/table variables; the sample inserts two rows. |

Examples deliberately use environment variables and never embed an account
name, account key, bearer token, or complete SAS query. Treat a connection
string and any URL returned by SAS generation as a secret; do not print or
record them.

`getStatistics` requires a conventional `{account}-secondary.table...`
read-access endpoint. For a standard Azure account, set
`AZURE_DATA_TABLES_SECONDARY_CONNECTION_STRING` to an independent string with
the same account credentials (or a secondary-valid SAS) and explicit
`TableEndpoint=https://{account}-secondary.table.core.windows.net`; omit
`EndpointSuffix` when supplying that explicit endpoint. For a custom Azure
Storage suffix or path, set `TableEndpoint` to that account's actual
conventional `-secondary` Table endpoint; do not derive it by replacing
unrelated host/path text. Azurite has no geo-replication secondary, so leave
the variable unset and the example will not call statistics.

## Integration and live tests

`zig build azurite-test` is opt-in and returns a clean Zig test skip unless
`AZURE_DATA_TABLES_AZURITE_TESTS=1`. A configured run requires a unique
alphanumeric `AZURE_DATA_TABLES_AZURITE_TEST_RUN_ID`; it defaults to
`UseDevelopmentStorage=true`, or accepts
`AZURE_DATA_TABLES_AZURITE_CONNECTION_STRING`. It creates one test table,
cleans it up, and covers lifecycle, typed CRUD, dynamic entities, entity
query paging, conditional ETag rejection, and `$batch`. No default test makes
a network request. The Linux CI job runs this test against the immutable
Azurite `3.35.0` image manifest
`sha256:dae2a5f96553962901304b94e72ef87e299d0825e4b679673bcc527a25076fe4`,
waits for its Table endpoint, and stops its exact background process ID.

`zig build live-test` is destructive and returns a clean skip unless
`AZURE_DATA_TABLES_LIVE_TESTS=1`. A configured Azure Storage run requires:

- `AZURE_DATA_TABLES_ENDPOINT` — HTTPS primary Table endpoint, without a
  trailing slash;
- `AZURE_DATA_TABLES_SECONDARY_ENDPOINT` — HTTPS read-access secondary Table
  endpoint for `getStatistics`, without a trailing slash;
- `AZURE_DATA_TABLES_LIVE_TEST_RUN_ID` — unique alphanumeric suffix;
- `AZURE_TOKEN` — short-lived Entra token for
  `https://storage.azure.com/.default`;
- `AZURE_DATA_TABLES_ACCOUNT_NAME` and `AZURE_DATA_TABLES_SHARED_KEY` —
  Shared Key credentials.

The live flow checks Entra list paging, Shared Key operations, generated
account SAS access, table ACL set/get, service properties, and statistics on
the secondary endpoint. It creates and deletes only the run-specific table.
It does not change account-wide service properties, and it uses no recording
or playback; this prevents account names, keys, bearer tokens, and complete
SAS queries from being committed.

## Entity CRUD

`TableClient.addEntity` accepts either a comptime-validated caller struct or a
`DynamicEntity`; `getEntityAs(T, ...)` decodes either form. The matching
`*Result` methods retain structured service failures, while simple methods map
them to operation errors. `EntityResponse(T)` owns its decoded value, ETag,
OData metadata, selected and raw headers in an arena; call `deinit`.

`DeleteEntityOptions.if_match` defaults to `"*"` and accepts an ETag for a
conditional delete through `deleteEntityWithOptions`. The original
`getEntity(allocator, pk, rk)`, `createEntity`, and
`deleteEntity(allocator, pk, rk)` raw-response calls retain exact source
compatibility; explicit `getEntityRaw` and `deleteEntityRaw` aliases are also
available.

`UpdateMode` is a closed `merge`/`replace` enum shared by `updateEntity` and
`upsertEntity` (and their result-preserving variants). Merge uses the generated
PATCH operation and preserves omitted properties; replace uses generated PUT
and removes them. Updates default to wildcard `If-Match` and accept an explicit
ETag, while upserts omit `If-Match` so a missing entity is created. Mutation
responses own the returned ETag, status, selected headers, and raw headers.
Explicit-ETag updates retry only failures before transport entry; a transport
failure after entry is `error.MutationOutcomeUnknown`. Their pre-transport
retries use the configured retry limit and exponential jittered backoff while
checking the effective operation deadline before every attempt and delay.
Wildcard updates and upserts use normal retries because repeating the same
payload is safe, but an exhausted transport failure is still classified as
outcome-unknown.

## Entity group transactions

`TransactionBuilder` owns copied keys, ETags, and entity JSON. Typed `add`,
`updateMerge`, `updateReplace`, `upsertMerge`, and `upsertReplace` methods
serialize immediately; matching `*Dynamic` methods accept `DynamicEntity`.
`delete` accepts keys and a required `If-Match` value. Submission validates a
nonempty group of at most 100 unique targets in one partition and enforces the
4 MiB complete MIME payload limit before transport. Automatic multipart
boundaries use `HttpRuntime.crypto`; a provider error is returned before
transport dispatch. Explicit `TransactionOptions.boundaries` remain available
for deterministic fixtures and bypass provider randomness.

`TableClient.submitTransactionResult` returns ordered inner status/ETag
results or a `TableError` whose `operation_index` is zero-based. Batch POSTs
retry only failures known to occur before transport entry. After dispatch, a
transport failure, any successful outer status other than `202 Accepted`, or a
missing, truncated, malformed, or wrong-count `202` multipart response returns
`error.TransactionOutcomeUnknown`. Do not retry in that case: the atomic
transaction may already have committed. A fully parsed inner HTTP failure still
returns its precise indexed `TableError`; pretransport validation failures
remain deterministic local errors.

## Checked feature-parity contract

`[x]` means the Go capability has been reviewed and assigned a Zig API owner;
it does **not** claim that a later roadmap phase is already implemented.

### Construction, authentication, and pipeline

| Checked | Go `sdk/data/aztables` capability | Planned Zig API |
|---|---|---|
| [x] | `NewServiceClient` / `NewClient` | `TableServiceClient.init` / `TableClient.init` with `.authentication.token` |
| [x] | `NewServiceClientWithSharedKey` / `NewClientWithSharedKey` | `.authentication.shared_key`; Tables-specific `SharedKeyCredential` and SharedKeyLite policy |
| [x] | `NewSharedKeyCredential`, account-name access, and key rotation | `auth.SharedKeyCredential.init`, `accountName`, and `updateKey` |
| [x] | `NewServiceClientWithNoCredential` / `NewClientWithNoCredential` | `.authentication.sas_url` |
| [x] | `NewServiceClientFromConnectionString` | `.authentication.connection_string` in either client's `init` |
| [x] | Service client `NewClient` | `TableServiceClient.getTableClient` |
| [x] | Core client options, retry, telemetry, request IDs, cloud token auth | `options`, `pipeline`, and `auth`; Storage bearer scope is `https://storage.azure.com/.default` |
| [x] | Storage and Azurite connection strings | `connection_string` |

### Tables, entities, administration, and transactions

| Checked | Go capability | Planned Zig API |
|---|---|---|
| [x] | Service `CreateTable` | `TableServiceClient.createTable` / `createTableResult` |
| [x] | Table client `CreateTable` convenience | `TableClient.createTable` / `createTableResult` |
| [x] | Service `DeleteTable` | `TableServiceClient.deleteTable` / `deleteTableResult` |
| [x] | Table client `Delete` convenience | `TableClient.deleteTable` / `deleteTableResult` |
| [x] | `NewListTablesPager` with filter, select, top, format, and continuation | `TableServiceClient.listTables` returning `TablePager` |
| [x] | `AddEntity` | generic `TableClient.addEntity` / `addEntityResult` |
| [x] | `GetEntity` | generic `TableClient.getEntityAs` / `getEntityResult`; raw-compatible `getEntity` |
| [x] | `DeleteEntity` with `IfMatch` | `TableClient.deleteEntityWithOptions` / `deleteEntityResult`; raw-compatible `deleteEntity` |
| [x] | `UpdateEntity` merge and replace with ETags | `TableClient.updateEntity` / `updateEntityResult` plus `UpdateMode` |
| [x] | `UpsertEntity` merge and replace | `TableClient.upsertEntity` / `upsertEntityResult` |
| [x] | `NewListEntitiesPager` with filter, select, top, format, and two continuation keys | generic `TableClient.queryEntities` returning `EntityPager(T)` |
| [x] | `GetAccessPolicy` / `SetAccessPolicy` | `TableClient.getAccessPolicy` / `setAccessPolicy` and result variants |
| [x] | `SubmitTransaction` and all six action kinds | `TransactionBuilder` and `TableClient.submitTransactionResult` |
| [x] | `GetProperties` / `SetProperties` | `TableServiceClient.getProperties` / `setProperties` (or explicit `*ServiceProperties` spellings) and result variants |
| [x] | `GetStatistics` | `TableServiceClient.getStatistics` / `getStatisticsResult` |

### SAS and model families

| Checked | Go capability or model family | Planned Zig API |
|---|---|---|
| [x] | `GetAccountSASURL`, account permissions, resource types | `sas.AccountSignatureValues`, `AccountPermissions`, `AccountResourceTypes` |
| [x] | `GetTableSASURL`, table permissions and key ranges | `sas.TableSignatureValues`, `TablePermissions` |
| [x] | SAS protocol, IP range, query parsing/encoding, time formatting | `sas.Protocol`, `IPRange`, and `QueryParameters` |
| [x] | `Entity`, `EDMEntity`, binary, DateTime, GUID, and Int64 | typed `EntityCodec(T)`, `DynamicEntity`, `EdmValue`, and `edm` wrappers |
| [x] | metadata format and operation option structs | `options` operation-specific types and `MetadataFormat` |
| [x] | operation response structs, ETags, raw entity/table values | generic types in `responses` with status, ETag, selected headers, and owned decoded values |
| [x] | CORS, logging, metrics, retention, table properties | `service_models` |
| [x] | signed identifiers and access policies | `service_models.SignedIdentifier` / `AccessPolicy` |
| [x] | geo-replication status and last-sync time | `service_models.GeoReplication` |
| [x] | `TableErrorCode` and HTTP response errors | `errors.TableError`, known code constants, and unknown-code preservation |
| [x] | paged table/entity responses | `TablePager`, `EntityPager(T)`, `ListTablesPage`, and `EntityPage(T)` |
| [x] | transactional action and per-operation responses | `TransactionBuilder`, action types, and indexed transaction results |

Typed Zig entities add compile-time schema checking while `DynamicEntity`
retains the runtime-schema escape hatch. `$batch` is absent from the canonical
TypeSpec, so transactions remain hand-written unless upstream adds it.

### Entity codecs

`EntityCodec(T)` validates entity shapes when it is instantiated. `T` needs
string `partition_key` and `row_key` fields; an optional `timestamp` is the
service `Timestamp`. Supported property types are `bool`, `i32`, `f64`,
strings, optionals, and the `EdmBinary`, `EdmDateTime`, `EdmGuid`, and
`EdmInt64` wrappers. Declare `pub const table = .{ .rename = .{ ... } };` to
rename application properties on the wire. `Codec.toJson` returns an
allocator-owned byte slice; values returned by `Codec.deserialize` own decoded
strings and binary data and must be released with `Codec.deinit`.

For runtime schemas, `DynamicEntity.init` and `put` copy keys and values.
Release it with `DynamicEntity.deinit`; use `dynamicToJson` and
`dynamicFromJson` for its OData JSON representation. `Timestamp` is retained
when decoding service responses but omitted by both typed and dynamic
serialization because the service owns that field. The original
string-only `TableEntity` remains available as a compatibility export and
continues to borrow its keys and values.

## Migrating constructors from 0.2.0

Replace the removed `initWithToken`, `initWithSharedKey`, `initWithSasUrl`, and
`initFromConnectionString` methods with `init(allocator, runtime, init_options)`.
Move endpoint and credential into the matching `authentication` tag, put the
table name in `table_name`, and place existing client settings in `options`.
No compatibility constructor wrappers remain. Use
`TableServiceClient.getTableClient` instead of the removed internal-facing
`TableClient.initBorrowed` to obtain a client borrowing its parent's state.

## Migrating from the prototype

The 0.1.0 compatibility exports remain: `TableClient`,
`TableServiceClient`, `TableEntity`, and the raw `getEntity`, `createEntity`,
and `deleteEntity` calls keep their signatures. New code should select an
explicit `ClientAuthentication` input for the canonical `init` rather than assembling an unauthenticated
prototype client. Replace `TableEntity` with a comptime-checked struct and
`addEntity`/`getEntityAs(T, ...)` when the schema is known. For runtime
schemas, use owning `DynamicEntity`. Replace manual continuation handling with
`queryEntities(T, allocator, options)` and release its pager; replace raw
conditional requests with `updateEntity(..., .{ .if_match = etag })`.

## Public API conventions

- Public types and generic type families use `PascalCase`; functions, methods,
  and fields use `lowerCamelCase`. Operation settings end in `Options`.
- Clients expose one `init` with an explicit `ClientAuthentication` tagged input.
  Invalid credential combinations must not be representable.
- Each network operation has a simple `operation` method and an
  `operationResult` variant. Zig error unions report local failures such as
  allocation, validation, transport, or decoding. The result variant preserves
  Azure HTTP failures as a typed branch containing status, service code,
  message, request ID, and selected headers. The simple method maps that branch
  to its documented service error.
- Any public operation that allocates accepts an allocator. An allocating
  response owns one arena and has one `deinit`; all decoded strings and binary
  values belong to it and remain valid until `deinit`.
- An owning client holds heap-allocated `PipelineState` at a stable address and
  releases it in `deinit`. A client created by
  `TableServiceClient.getTableClient` borrows that state and must not outlive
  the service client. Moving either client value does not move policy objects.
- Pager state owns a resettable arena. Page values remain valid until the next
  successful page request or pager `deinit`. Continuation inputs are copied
  when needed and never borrowed from a released page.
- Caller entity values passed for serialization are borrowed only for the
  duration of the call. `DynamicEntity` owns copied keys and values and has
  `deinit`.
- The compatibility `TableEntity` is the exception retained from `0.1.0`: its
  map bookkeeping is owned, but partition key, row key, property keys, and
  property values are borrowed. Call `deinit` to release the map.

## Table lifecycle

`TableServiceClient.createTable` and `deleteTable` operate on a supplied
validated name; `TableClient` provides the same methods for its bound name.
Their `*Result` variants retain non-2xx service failures as `TableError`.
`listTables` returns a `TablePager`; configure `$filter`, `$select`, `$top`,
metadata format, and an initial continuation through `ListTablesOptions`.
Each page exposes the generated table wire response plus status and raw
headers. Page values are borrowed from the pager until its next successful
request or `deinit`. A pager owns an immutable protocol configuration copy,
but borrows the service client's heap-stable pipeline state; deinitialize it
before its parent service client. `ListTablesOptions` strings and policy
pointer-list storage are copied at pager creation, but the policy objects
themselves are borrowed and must remain stable and outlive the pager.

The pipeline policy order is request ID, telemetry, retry, then authentication.
Putting authentication after retry ensures date-sensitive SharedKeyLite
requests are signed on every attempt.

## Service administration

`TableServiceClient.setServiceProperties` and `getServiceProperties` use the
generated XML operations. `ServiceProperties`, `Logging`, `Metrics`,
`RetentionPolicy`, and `CorsRule` are generated-wire aliases; validation
rejects invalid retention periods, analytics versions, CORS limits, and
unsupported methods before transport. Use their `*Result` variants to retain
HTTP status, raw headers, request IDs, and structured `TableError` values.

`getStatistics` is available only for conventional
`{account}-secondary.table...` geo-replication endpoints. It returns generated
`ServiceStatistics` / `GeoReplication` values; its open
`GeoReplicationStatus` preserves future service status strings. Last-sync
timestamps use RFC 7231 HTTP-date syntax and may be empty while replication is
bootstrapping or unavailable; parse them with `LastSyncTime.parse`. All three
allocating responses own an arena and must be released with `deinit`.

## Module ownership

| Module | Responsibility |
|---|---|
| `root.zig` | Public exports, compatibility aliases, and compile coverage |
| `client.zig`, `service_client.zig` | Table- and account-scoped clients |
| `client_configuration.zig` | Internal authentication normalization and construction-time ownership |
| `pipeline.zig`, `auth.zig`, `request.zig` | Stable policy state, authentication, and shared request plumbing |
| `connection_string.zig`, `sas.zig` | Connection strings and SAS |
| `entity.zig`, `entity_codec.zig`, `edm.zig` | Entity models, typed codec, and EDM values |
| `options.zig`, `responses.zig`, `errors.zig` | Operation contracts and structured results |
| `pager.zig`, `transaction.zig` | Continuation paging and multipart transactions |
| `service_models.zig` | ACL, metrics, logging, CORS, and geo-replication |

## Development

```bash
git ls-files -z -- '*.zig' 'build.zig.zon' | xargs -0 zig fmt --check
zig build test --summary all
zig build examples
zig build azurite-test
zig build live-test
```

The package manifest pins immutable Core, REST, and serde commits/hashes.
`package-ci.yml` runs formatting, package tests, examples, and the cleanly
skipping live-test step on Linux, macOS, and Windows; its Linux Azurite job
runs configured lifecycle/CRUD/query-paging/ETag/batch coverage. Validate
`rest/data_tables` independently with `zig build test --summary all` before
creating the normal immutable package-branch release tag after both package
PRs are merged.

## Errors and results

`*Result` APIs return `TableResult(T)`: local failures remain Zig errors while
HTTP failures retain a `TableError` with status, service code, message, request
ID, and optional batch operation index. Call `deinit` on a result that is not
consumed by a simple-method adapter. `TableError` formatting redacts
Authorization values and complete URL query strings, including SAS.
