# azure_sdk_testing

Testing helpers for Azure SDK packages, including full-contract recording and
playback HTTP transports.

- Source: repository root on the `sdk/testing` package branch
- Release branch: `sdk/testing`
- Version: `0.3.0`
- Internal dependency: `azure_sdk_core` 0.4.0 at
  `be32073994f37422f2f6b5e9255d208b1284de85`

Transport descriptors are copied by value while their contexts are borrowed.
Keep playback/recording transport values, wrapped transport contexts, crypto
provider contexts, and any open operations alive for the full lifetime stated
by their API documentation. Playback is caller-serialized. Recording attempt
reservation/finalization and every recorder-owned allocation/free are
internally synchronized, so the allocator supplied to `RecordingTransport`
need not itself support concurrent calls. Callers must still synchronize
borrowed `getExchanges` slices, policy contexts, and `toJson` lifecycle access.

Construct a runtime with independently selected dependencies:

```zig
const runtime = testing.initHttpRuntime(
    playback.asTransport(),
    crypto_provider,
);
```

Playback validates method, exact URL, body presence/content, and every
recorded request header. Additional live request headers are allowed so
volatile telemetry can be omitted from recordings. Response header order and
duplicates are preserved.

This compatibility release adopts Core's owned `RequestHeaders`. Request
snapshots still allocate independent header name/value copies, including
`traceparent` and `tracestate`, and remain valid after the original request is
mutated or destroyed. Response and capture-map ownership has not changed.
Testing supplies transports, not a service HTTP client: it adds no
instrumentation options or automatic spans. Configure tracing on the caller's
Core pipeline; the caller owns the provider and its flush/shutdown lifecycle.
Recording captures the propagated headers at dispatch and preserves its
existing volatile-header redaction behavior.

`RecordingTransport.toJson` emits version 3 recordings. Version 3 records a
stable outcome stage and error category for transport/send, open, response-body,
and finish failures; playback reproduces the failure at that stage without
persisting backend-specific error identities. Version 2 successful-response
recordings remain readable. The stable cancellation category replays as
Core's terminal `OperationCancelled` error so retry policy behavior does not
diverge. URL and header metadata stays readable as JSON strings when it is
valid UTF-8; arbitrary byte sequences such as HTTP obs-text are represented
losslessly with the same explicit base64 encoding object and remain
exact-match data. Accepted request and response bodies are
represented losslessly as base64 with an explicit encoding field. Every
non-empty body is rejected by default and requires an explicit caller
body-policy decision. Approved textual and binary bodies, including NUL and
non-UTF-8 data, then round-trip exactly through `parseJson`. Parsed recordings
can be passed directly to playback:

```zig
var parsed = try testing.parseJson(allocator, json);
defer parsed.deinit();
var playback = testing.PlaybackTransport.init(allocator, parsed.asSlice());
```

Each exchange represents one raw HTTP transport invocation, not a logical
pipeline transaction. Redirect and retry responses are recorded and replayed
in the order observed. Buffered responses are recorded when the inner
transport returns them. Streaming responses are recorded when the operation
finishes, is aborted, or is cancelled, including only response body bytes
observed before that terminal event. A body failure retains its partial bytes
and replays the error after those bytes; a finish failure replays only from
`finish`.

Request metadata and an ordered slot are allocated before dispatch. Each
attempt finalizes its own ticket, so overlapping operations remain in dispatch
order even when they complete out of order. Active unresolved slots make
`isComplete` false and `toJson` returns `IncompleteRecording`. Bookkeeping
allocation failure after dispatch or deinitializing an open operation without
a terminal event additionally poisons the recorder and rejects subsequent
dispatch rather than silently emitting a divergent sequence.

A redirect allocation failure still consumed a real transport attempt. A
later caller retry therefore requires the next recorded attempt, just as live
recording would. A terminal retryable result must include every raw attempt
produced by the selected retry configuration.

Recording JSON replaces recognized authorization, token, secret, key, cookie,
and SAS-bearing header values with `REDACTED`. Credential URL headers such as
`x-ms-copy-source`, `x-ms-rename-source`, and
`x-ms-file-rename-source` are fully redacted; recognized credential-specific
query parameters in request URLs and location-style headers are value-redacted.
Established vendor signing fields such as `X-Amz-Signature`,
`X-Amz-Credential`, `X-Amz-Security-Token`, and `X-Goog-Signature` receive the
same treatment, including nested and multiply encoded URLs.
Each redacted header carries a structured `redacted` flag, so playback
wildcards only values that recording explicitly classified as credentials.
Sanitized request URLs and location-style headers additionally carry an
internal structured redaction template. Playback never infers wildcard
positions from the literal text `REDACTED`, so caller data containing that
text remains exact even beside a generated credential wildcard. Older version
3 files without templates and version 2 files are matched conservatively as
exact URL text.
Those structured redactions match a caller-supplied live credential, while
nonsensitive query fields such as App Configuration's `key` filter and all
other nonsensitive URL components, headers, and bodies remain exact-match
requirements.

`Location`, `Content-Location`, `Operation-Location`, and
`Azure-AsyncOperation` retain their origin/path and nonsensitive query fields;
only recognized credential query values are replaced. This keeps redirect and
LRO URLs replayable. Malformed or unsafe non-fragment location values are
fully redacted.
Credential source URL headers such as `x-ms-copy-source` remain fully redacted.
URL sanitization parses the URI reference from its start, percent-decodes path
and query components through a bounded recursive decoder, and recursively
sanitizes URI-valued parameters. Safe nested URIs retain the caller's original
encoding exactly. When nested credentials require redaction, the nested URI is
re-encoded with its host/path/nonsensitive fields preserved and exact while
only credential fields are redacted; outer percent-encoding depth is retained,
so paths such as `/a%252Fb` and `/a%2Fb` cannot collapse into one match.
Credential-bearing paths are rejected.
Safe fragments are preserved in recorded URL headers; Core strips them when
constructing the redirected HTTP request. Recognized sensitive Location
fragments are stripped
while preserving the replayable pre-fragment target; malformed location
fragments fail closed. Relative redirects such as
`/callback?return=https://...` remain replayable when their decoded values are
safe. Safe network-path references such as `//example.test/final` and pathless
absolute references such as `https://example.test?mode=one` are preserved;
userinfo and credential-bearing authorities are rejected. Decode depth and
size are bounded, and malformed or over-depth encodings fail closed.

Header names are checked case-insensitively. The default preserves only a
known-safe standard/Azure header allowlist, after inspecting every value for
signed URLs, JWTs, connection strings, and other recognized credentials.
Unknown application and metadata headers are redacted. Credential-shaped names,
including metadata suffixes such as `password`, `pwd`, `private-key`, and
`connection-string`, are also redacted. Applications can add redactions or
explicitly preserve a known-safe false positive with an exchange-aware header
policy:

Volatile request headers—including request/correlation IDs, `date`,
`x-ms-date`, `traceparent`, and `tracestate`—are structurally redacted by
default so freshly generated Core pipeline values wildcard during playback.
Returning `preserve` from the header policy makes a selected value exact.

```zig
fn headerPolicy(
    context: ?*anyopaque,
    header: testing.HeaderSafetyContext,
) testing.HeaderPolicyDecision {
    _ = context;
    if (isApplicationCredential(header.name)) return .redact;
    if (isKnownSafeMetadataLabel(header.name)) return .preserve;
    return .inspect;
}
```

`preserve` bypasses a conservative built-in classification and therefore
asserts that the persisted value is not a credential. Policy contexts are
borrowed through `toJson`.

Credential-bearing JSON fields are detected structurally and
case-insensitively, including nested list-keys results, connection strings,
API keys, tokens, passwords, SAS URIs, and common Azure key fields. Form,
connection-string, multipart field names, XML elements/attributes, and common
private-key envelopes receive conservative checks. String scalars are scanned
recursively for signed URLs/SAS parameters, connection strings, private-key
containers, and JWT-shaped identity tokens. Key Vault secret, certificate, and
JWK rules apply only to parsed trusted Azure vault hosts and matching resource
paths; Kusto rules likewise use trusted service host suffixes. ARM
list/regenerate credential schemas—including Batch, AI Search, Event Grid,
Cognitive Services, Cosmos DB, and Container Registry—apply only to the
explicit public, US Government, China, and German management hosts. Storage
User Delegation Key XML is recognized only on trusted sovereign Blob service
hosts and the matching action. Managed HSM host rules include every supported
sovereign suffix, including `managedhsm.microsoftazure.de`. Endpoint path
segments and query names/values are canonicalized with the same bounded
recursive decoder before schema classification; malformed or over-depth
endpoint encodings fail closed. Endpoint hosts are parsed canonically,
percent-decoded, and normalized by removing a terminal DNS root dot; malformed
and userinfo-bearing authorities fail closed. Arbitrary URL text cannot
activate these schema rules, so App Configuration key/value documents and
paths containing words such as `vault/secrets` remain recordable and exact.

The default body contract is deny-by-default: every non-empty body is rejected
with `BodyPolicyRequired` unless `bodyPolicyFn` classifies that exact exchange.
Before default rejection, the recorder still detects known plaintext and
structured credentials and returns `SensitiveBodyRequiresSanitization`.
Returning `inspect` explicitly opts a recognized textual content type into
built-in structural checks. A declared JSON content type must parse
successfully. Only untyped UTF-8 text,
`text/*`, JSON, XML, form URL encoding, JavaScript/ECMAScript, and GraphQL are
recognized as textual; PDF, CBOR, PKCS7, protobuf, arbitrary vendor/container
types, Unicode BOMs, NUL-bearing data, UTF-16/32 charsets, non-identity content
encodings, and non-UTF-8 bodies are opaque. Returning `allow_opaque` is the
explicit trust boundary for a caller-verified opaque body:

```zig
fn bodyPolicy(
    context: ?*anyopaque,
    body: testing.BodySafetyContext,
) testing.BodyPolicyDecision {
    _ = context;
    if (isKnownSafeAppConfigurationExchange(body)) return .inspect;
    if (isKnownSafeBinaryEndpoint(body.url)) return .allow_opaque;
    return .reject_sensitive;
}

var recording = testing.RecordingTransport.initWithOptions(
    allocator,
    transport,
    .{
        .bodyPolicyFn = &bodyPolicy,
        .headerPolicyFn = &headerPolicy,
    },
);
```

`inspect` does not sanitize or rewrite bodies; it persists only bodies that pass
the built-in checks, and playback continues to match request bodies exactly.
`reject_sensitive` rejects application-specific schemas. Private-key markers
and detectable plaintext credentials cannot be bypassed by `allow_opaque`;
callers that approve otherwise opaque encodings take responsibility for their
decoded contents. Multipart bodies are also scanned before opaque allowance,
including form-data names, embedded HTTP authorization headers, signed URLs,
JWTs, and parseable structured part payloads. Declared multipart boundaries are
parsed from `Content-Type` and recognized only as exact MIME delimiter lines;
legal preambles, epilogues, and nested multipart parts are inspected, while
invalid close suffixes, missing closes, and malformed multipart structures fail
closed. Mixed structured content in preambles or epilogues that cannot be
classified in full also fails closed. Folded MIME/application-HTTP headers are
unsupported and fail closed before disposition fields or embedded
authorization can be hidden across continuation lines. XML-looking bodies
must be consumed as one well-formed document; mismatched tags, malformed
prefixes, extra roots, and trailing mixed structures are rejected. Policy
contexts are borrowed through `toJson`.

Playback consumes one exchange for each raw transport invocation, including
recorded failures. Buffered attempts advance after either a recorded transport
error is returned or response allocation succeeds. Streaming attempts advance
after either a recorded open error is returned or operation allocation
succeeds. Body and finish outcomes then replay from the operation. Outer
pipeline redirect allocation, retry, backoff, and cancellation behavior does
not roll back an already completed raw attempt. If a cooperative upload reader
cancels exactly after producing the prefix recorded for a cancelled open
attempt, playback validates and consumes that attempt before returning
`OperationCancelled`; preflight cancellation and cancellation against a
non-cancelled recording leave the attempt unconsumed.

Run its independent tests from this directory:

```bash
zig build test --summary all
```

The test target runs both Core raw-transport and pipeline conformance contracts,
plus Core allocation-failure fixtures.
