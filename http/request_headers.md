# Owned request headers: API and migration

`core.http.Request.headers` is `core.http.RequestHeaders`, an owned,
case-insensitive collection. It is no longer a `std.StringHashMap([]const u8)`.
This change makes tracing restoration independent of hash-table capacity and
allows policies to remove or replace managed entries, grow the ordinary table,
clear it, or replace the entire collection without losing caller context or
changing a service result during restoration.

## Common operations

```zig
try request.setHeader("Content-Type", "application/json"); // unchanged
const content_type = request.getHeader("content-type");    // unchanged
_ = request.removeHeader("CONTENT-TYPE");                 // removes and frees

try request.headers.put("X-Example", value);              // copies both strings
_ = request.headers.remove("x-example");                  // removes and frees
request.headers.clearRetainingCapacity();                 // frees every entry
request.headers.clearAndFree();                           // also frees the table
```

`put` validates HTTP header-name/value syntax. Replacement is transactional:
failure preserves the old entry. The first spelling of a case-insensitive name
is retained. Duplicate names are replaced, not added; this matches the existing
`Request.setHeader` behavior. `get` and `contains` are case-insensitive, and
`count()` includes ordinary and trace headers.

## Migration from raw map access

| Before | After |
| --- | --- |
| `Request.setHeader/getHeader` | Unchanged |
| `headers.get/count/iterator` reads | Same method names; iterator pointers are read-only |
| `headers.put(owned_key, owned_value)` transferring allocated strings | `headers.put(key, value)` copies; caller retains responsibility for any input allocations |
| `headers.remove(key)` plus manual frees | `headers.remove(key)` owns cleanup; do not free removed storage again |
| `headers.fetchRemove(key)` followed by manual frees | `headers.remove(key)` |
| `fetchRemove` when ownership must be retained | `var entry = headers.take(key).?; defer entry.deinit();` |
| `getPtr/getEntry/getOrPut/fetchPut`, mutable iterator entries, `putAssumeCapacity` | `put` for mutation, `get` for borrowed reads, `take` for ownership transfer |
| `headers.unmanaged.available` | `headers.unusedCapacity()` for ordinary-header table capacity |
| A request-header `*const std.StringHashMap([]const u8)` parameter | `*const core.http.RequestHeaders` |
| Raw map `.deinit()` after manually freeing each entry | `headers.deinit()` alone |

`OwnedHeader` returned by `take` has `name` and `value` views and a `deinit`
method. It owns both allocations, including their originating allocator.
Collections, taken entries, and detached trace snapshots are move-only owners:
do not copy them and then destroy both copies. To duplicate a collection, use
`try headers.clone(destination_allocator)`, which copies all entries.

Iteration includes **all** headers, including the two trace names:

```zig
var iterator = request.headers.iterator();
while (iterator.next()) |entry| {
    const name = entry.key_ptr.*;
    const value = entry.value_ptr.*;
    // Borrowed read-only strings: serialize or copy; do not modify/free them.
}
```

Any mutation invalidates iterators. Header value views live until their entry
is replaced/removed or the collection is cleared/deinitialized. The collection's
backing fields are implementation details, not a raw mutable map API.

`Response.headers`, `HttpOperation.headers`, `ResponseHeaders`, and mock
transport capture maps have **not** changed. The target-neutral WASI
`HostRequest.headers` view now points to `RequestHeaders`; its read-only
iteration pattern is unchanged.

## Tracing ownership and allocation pressure

Ordinary entries reuse Core's `CaseInsensitiveMap`. `traceparent` and
`tracestate` live in two separate, fixed owned-entry slots; their values remain
allocator-owned strings, not borrowed stack buffers. Empty slots allocate
nothing, and merely constructing a request enables no tracing.

At instrumentation entry, `takeTraceHeaders()` moves the caller's two entries
into a bounded `TraceHeaders` snapshot. Policies operate on normal generated
entries. On return, `restoreTraceHeaders(&snapshot)` frees only the current
trace entries and moves the saved originals back into the two dedicated slots.
It consumes the snapshot and never allocates, reserves map slots, drops saved
headers, or panics on map saturation. Unrelated policy mutations remain intact.
Invalid incoming tracestate is omitted during dispatch, then restored exactly
to the caller; valid empty/OWS state follows the W3C propagation rules.

Removal of managed entries, replacement of their values, and normal table
growth/clearing are supported without retaining spare capacity. Collection
replacement is also supported:

```zig
request.headers.deinit();
request.headers = core.http.RequestHeaders.init(other_allocator);
try request.headers.put("X-New", "value");
```

The old allocator must remain alive while a detached snapshot still owns its
entries. Restored entries retain their originating allocator even when restored
into a collection using another allocator; later replacement/removal/deinit
frees each allocation through its correct owner. This does not change the
lifetimes of request URLs, bodies, pipeline/provider contexts, or response
operations.

`ensureUnusedCapacity(n)` reserves slots for additional **ordinary** headers;
`unusedCapacity()` reports that table's currently available slots. Neither
controls the two trace slots or performs string allocation in advance. Tracing
restoration works even when ordinary unused capacity is zero and every further
allocation fails.
