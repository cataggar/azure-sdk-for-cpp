# Opt-in HTTP tracing and explicit export

`core.tracing` provides an owned, bounded tracer provider and a pluggable span
exporter. The SDK does not select an endpoint, discover environment settings,
start background tasks, or send telemetry automatically. Unconfigured pipelines
do not create spans or modify trace headers.

## Configure a service client's existing pipeline

Given an existing `runtime: core.http.HttpRuntime`, caller-owned `policies`,
`allocator`, `io`, and a caller-owned `writer: *std.Io.Writer`:

```zig
var scratch: [64 * 1024]u8 = undefined;
var exporter = core.tracing.OtlpJsonWriterExporter.init(writer, &scratch);
var provider = try core.tracing.ExportingTracerProvider.init(
    allocator, io, runtime.crypto, exporter.asExporter(),
    .{ .service_name = "my-application", .max_batch_size = 1 },
);
defer provider.deinit() catch unreachable;

var pipeline = core.http.HttpPipeline.init(runtime, policies);
pipeline.setInstrumentation(.{
    .provider = provider.asProvider(),
    .scope_name = "azure_sdk_storage_blobs",
    .scope_version = "0.3.0",
    .namespace = "Microsoft.Storage",
});
// Pass this pipeline to the service's existing init(pipeline, options).
// Configure an auth policy separately for private service operations.
// After the service calls:
try provider.forceFlush(1000);
try provider.shutdown(1000);
```

`tracing/example.zig` contains an executable unit-tested, Core-only version using
the existing mock transport. The service example belongs to its service package;
Core does not depend on Storage Blobs.

The single canonical `HttpPipeline.init(runtime, policies)` is unchanged.
`setInstrumentation(null)` disables future operations on that pipeline value.
Configure before copying it into clients. Existing copies retain their options.
The pipeline owns no provider, policy, backend, or scope-string storage.

The concrete provider, exporter, writer, scratch buffer, crypto/I/O contexts,
and nonstatic scope strings must have stable addresses and outlive their uses.
End all operations before shutdown and free those objects only after clients
are no longer used. `shutdown` returns `ActiveSpans` if live spans remain, stops
accepting new spans, and can be retried after those spans end. `deinit` refuses
live spans; otherwise it frees retained storage **without** exporting or closing
the caller's writer. Shutdown and writer flush/close are explicit application
responsibilities.

## Parentage and propagation

Use existing `core.context.Context` on a request:

```zig
request.context = request.context.withTraceContext(parent);
```

Alternatively set `InstrumentationOptions.parent_context` for a client-wide
default parent. Precedence is request context, pipeline default, then valid
caller-supplied `traceparent`/`tracestate` headers. IDs are values; parent
tracestate is borrowed until span start and copied by the provider. A parent
span's `getContext()` view must not outlive that span unless copied.

The implementation uses W3C Trace Context Level 1: nonzero lowercase hex IDs,
version-00 exact length and specified higher-version handling, sampled-bit
propagation, and validated tracestate capped at 512 bytes/32 nonempty members.
Empty fields and empty/OWS list members are valid and ignored when counting
members; valid field ordering and whitespace are preserved. Malformed
parents become roots; invalid tracestate is dropped. Root sampling defaults to
enabled **only after** configuring instrumentation. Unsampled parents propagate
valid child IDs without queuing records.

Generated headers are request-owned, restored on completion, and are not
re-extracted as parents on retries or request reuse. Installation-allocation
failures leave the caller's original entries intact and increment the provider's
`propagation_errors` counter without replacing service results. Restoration
itself does not allocate: removing the installed entries frees the actual 0/1/2
slots needed by saved caller entries. If an original tracestate had invalid
contents, dispatch uses a valid empty tracestate field, discarding the invalid
contents while retaining its restoration slot. The exact original value,
including invalid or empty values, is restored afterward.

**Policy mutation contract:** policies may add, replace, and remove unrelated
headers and replace managed trace-header values. If they remove managed trace
entries or replace the header map, they must leave enough unused slots for all
saved caller entries (reserving two is sufficient). They must not consume those
restoration slots with unrelated additions. Keeping the managed entries is the
simple allocation-free option; suppress tracing before dispatch when propagation
is unwanted. Direct map mutation that destroys those slots is diagnosed as a
programming-contract violation, not a successful restore or discarded caller
context. Arbitrary removal plus saturation cannot preserve all unrelated
mutations and originals under permanent allocation failure in a single hash map;
supporting it would require a different header API/storage contract.

The shared transport strips managed trace headers
on cross-origin redirects; same-origin hops retain them. Uninstrumented,
caller-managed headers retain existing transport behavior.

## Span boundaries and safe attributes

Automatic instrumentation creates **one logical HTTP client span outside all
policies**, including retries. A legacy `TracingPolicy` in that chain is
suppressed to avoid double spans. Buffered requests finish at `send` return.
Streaming spans cover upload/open/response headers and finish at `open` return:
later response-body reading, draining, aborting, cancelling, and deinitializing
the operation are deliberately outside the span. No operation callbacks are
copied or replaced. Cancellation and timeouts retain the runtime's existing
cooperative/best-effort behavior, not guaranteed blocked-I/O interruption.

Built-in attributes are method, server hostname/port, configured namespace,
integer response status, and a safe symbolic error type. Span name is `HTTP`.
Success status is `unset`; HTTP 4xx/5xx and operation errors set `error`.
No paths, URL query/userinfo/fragment, resource names, body data, auth headers,
cookies, arbitrary request/response headers, or raw error messages are recorded.
Application-supplied attributes, resource `service.name`, scope metadata, and
vendor tracestate remain the application's responsibility.

## Bounded ownership and management

The provider preallocates a fixed span pool and scope cache under
`max_retained_bytes`. `max_spans` bounds active + queued + exporting records;
`max_queued_spans` bounds the completed queue. Each slot has a 4096-byte
owned-string arena and at most 32 typed attributes. Values support UTF-8 strings,
signed integers, booleans, and finite doubles. Limits can be lowered. Repeated
attribute replacement consumes arena space until that slot is reused. Excess
attributes/values are dropped, not unboundedly allocated or truncated.

`max_batch_size` is 1–64. Choose the writer scratch size for the batch's
worst-case escaped JSON size; insufficient scratch reports `WriteFailed`
without writing a partial JSON object to the sink. The output writer itself can
fail after partial output; treat that frame as failed. No automatic retry occurs.

Independent concurrent spans and provider methods are synchronized. Runtime
backend concurrency requirements still apply; the standard HTTP transport is
caller-serialized. A span handle is consumed by `end()` and must not be used
again. Completed records own all retained names/attributes/tracestate and can
outlive request and response buffers.

`end()` only enqueues. Applications call `drain(timeout_ms)` periodically;
`forceFlush(timeout_ms)` also invokes the exporter's optional flush callback.
Both process a snapshot of already-completed spans, not in-flight/new spans.
Queue/pool exhaustion drops telemetry rather than waiting for export.
Concurrent or reentrant management calls return `ExportInProgress`.
An export failure drops that batch, increments counters, and returns an error
to the management caller, never the service caller. `stats()` exposes starts,
ends, exports, dropped spans/attributes, export/propagation errors, active/queued
counts, and reserved pool/scope bytes. It does not emit logs or telemetry.

Management budgets are cooperative. Custom exporters must check `ExportContext`
and bound their own I/O; arbitrary synchronous code cannot be safely preempted.
The reference writer encodes complete genuine OTLP JSON requests using hex IDs,
integer enums, decimal-string 64-bit fields, and resource/scope/span envelopes.
It writes one request per line, not network traffic and not a full OTLP SDK.
It does not flush or close the supplied writer.

Custom `SpanExporter` implementations borrow batches only until the callback
returns. Do not retain slices without copying. For collector requests use a
separate uninstrumented pipeline, or explicitly set
`request.context.tracing_suppressed = true` on a shared one. This avoids exporter
request tracing without global or thread-local state. The SDK never exports from
`Span.end`, and snapshot draining never recursively drains newly-created spans.

## Compatibility and intentionally deferred work

Existing `TracerProvider`/`Tracer`/`Span` initializers remain valid. Optional
context/typed-attribute/start-options hooks extend them. Legacy custom tracers
without a context hook do not inject headers; string attributes continue to
work. `RecordingTracer` remains a borrowed-data, single-span test helper, not
the production provider.

Production OTLP networking/retry/TLS configuration, background batching,
per-attempt or public-service-method spans, body-complete streaming observation,
additional signals/events/links, and broader OpenTelemetry SDK conformance are
separate follow-ups. Applications can use the exporter interface without those
features.
