const std = @import("std");
const Headers = @import("request_headers.zig").RequestHeaders;
const allocator = std.testing.allocator;

test "RequestHeaders owns case-insensitive values and exposes read-only iteration" {
    var headers = Headers.init(allocator);
    defer headers.deinit();
    var name = "X-Name".*;
    var value = "value".*;
    try headers.put(&name, &value);
    try headers.put("TraceParent", "parent");
    try headers.put("TraceState", "");
    @memset(&name, 'x');
    @memset(&value, 'x');
    try std.testing.expectEqualStrings("value", headers.get("x-name").?);
    try headers.put("X-NAME", headers.get("X-Name").?);
    try headers.put("TRACEPARENT", "replaced");
    try std.testing.expectEqual(@as(usize, 3), headers.count());
    var iterator = headers.iterator();
    var count: usize = 0;
    while (iterator.next()) |entry| {
        comptime std.debug.assert(@typeInfo(@TypeOf(entry.value_ptr)).pointer.is_const);
        try std.testing.expectEqualStrings(headers.get(entry.key_ptr.*).?, entry.value_ptr.*);
        count += 1;
    }
    try std.testing.expectEqual(headers.count(), count);
    try std.testing.expect(headers.remove("tRaCePaReNt"));
    try std.testing.expect(!headers.remove("traceparent"));
    try std.testing.expect(headers.remove("x-name"));
    try std.testing.expectEqualStrings("", headers.get("tracestate").?);
}

test "RequestHeaders take clone and clear preserve ownership" {
    var headers = Headers.init(allocator);
    defer headers.deinit();
    try headers.put("X-Test", "ordinary");
    try headers.put("traceparent", "parent");
    try headers.put("tracestate", "state");
    var cloned = try headers.clone(allocator);
    defer cloned.deinit();
    var taken = headers.take("X-Test").?;
    defer taken.deinit();
    headers.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), headers.count());
    try std.testing.expectEqualStrings("ordinary", taken.value);
    try std.testing.expectEqualStrings("ordinary", cloned.get("x-test").?);
    try std.testing.expectEqualStrings("parent", cloned.get("TRACEPARENT").?);
    try std.testing.expectEqualStrings("state", cloned.get("TRACESTATE").?);
    cloned.clearAndFree();
    try std.testing.expectEqual(@as(usize, 0), cloned.unusedCapacity());
    try cloned.put("X-Reused", "yes");
    try std.testing.expectEqualStrings("yes", cloned.get("x-reused").?);
}

test "RequestHeaders restores trace ownership into a full replacement using another allocator" {
    var original = std.testing.FailingAllocator.init(allocator, .{});
    var replacement = std.testing.FailingAllocator.init(allocator, .{});
    {
        var headers = Headers.init(original.allocator());
        defer headers.deinit();
        try headers.put("TraceParent", "original parent");
        try headers.put("TraceState", "original state");
        var saved = headers.takeTraceHeaders();
        defer saved.deinit();
        try headers.put("traceparent", "generated");
        headers.deinit();
        headers = Headers.init(replacement.allocator());
        try headers.ensureUnusedCapacity(8);
        var added: usize = 0;
        while (headers.unusedCapacity() > 0) {
            var key: [32]u8 = undefined;
            try headers.put(try std.fmt.bufPrint(&key, "x-header-{d}", .{added}), "retained");
            added += 1;
        }
        try headers.put("TRACEPARENT", "policy parent");
        try headers.put("TRACESTATE", "policy state");
        original.fail_index = original.alloc_index;
        replacement.fail_index = replacement.alloc_index;
        headers.restoreTraceHeaders(&saved);
        try std.testing.expect(!original.has_induced_failure);
        try std.testing.expect(!replacement.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), headers.unusedCapacity());
        try std.testing.expectEqual(added + 2, headers.count());
        try std.testing.expectEqualStrings("original parent", headers.get("traceparent").?);
        try std.testing.expectEqualStrings("original state", headers.get("tracestate").?);
        replacement.fail_index = std.math.maxInt(usize);
        try headers.put("traceparent", "replacement allocation");
        try std.testing.expectEqualStrings("replacement allocation", headers.get("traceparent").?);
    }
    try std.testing.expectEqual(original.allocated_bytes, original.freed_bytes);
    try std.testing.expectEqual(replacement.allocated_bytes, replacement.freed_bytes);
}

test "RequestHeaders updates and clones are transactional on allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, allocationFailures, .{});
}

fn allocationFailures(alloc: std.mem.Allocator) !void {
    var headers = Headers.init(alloc);
    defer headers.deinit();
    try headers.put("X-Test", "old");
    headers.put("x-test", "new") catch |err| {
        try std.testing.expectEqualStrings("old", headers.get("x-test").?);
        return err;
    };
    try headers.put("traceparent", "parent");
    headers.put("TRACEPARENT", "replacement") catch |err| {
        try std.testing.expectEqualStrings("parent", headers.get("traceparent").?);
        return err;
    };
    try headers.put("tracestate", "");
    var cloned = try headers.clone(alloc);
    defer cloned.deinit();
    try std.testing.expectEqual(headers.count(), cloned.count());
    var saved = headers.takeTraceHeaders();
    defer headers.restoreTraceHeaders(&saved);
    try headers.put("traceparent", "temporary");
    try headers.put("tracestate", "temporary");
}

test "RequestHeaders validates HTTP syntax before changing owned entries" {
    var headers = Headers.init(allocator);
    defer headers.deinit();
    try headers.put("x-test", "original");
    try std.testing.expectError(error.InvalidHttpHeaderName, headers.put("", "bad"));
    try std.testing.expectError(error.InvalidHttpHeaderName, headers.put("bad name", "bad"));
    try std.testing.expectError(error.InvalidHttpHeaderValue, headers.put("x-test", "bad\r\nvalue"));
    try std.testing.expectEqualStrings("original", headers.get("x-test").?);
    try std.testing.expectEqual(@as(usize, 1), headers.count());
}
