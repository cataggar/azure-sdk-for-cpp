const std = @import("std");
const CaseInsensitiveMap = @import("../case_insensitive_map.zig").CaseInsensitiveMap;

/// Owned, case-insensitive request headers. Mutate through these methods, not
/// raw hash-map entries. Trace headers have two independent owned slots so
/// restoring their ownership never depends on ordinary-header table capacity.
pub const RequestHeaders = struct {
    allocator: std.mem.Allocator,
    ordinary: Map,
    trace: TraceHeaders = .{},

    const Map = CaseInsensitiveMap([]const u8);

    /// A move-only owned entry returned by take(). Its originating allocator
    /// must outlive the entry, even if it is moved to a different collection.
    pub const OwnedHeader = struct {
        name: []const u8,
        value: []const u8,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !OwnedHeader {
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, value);
            return .{ .name = owned_name, .value = owned_value, .allocator = allocator };
        }

        pub fn deinit(self: *OwnedHeader) void {
            self.allocator.free(self.name);
            self.allocator.free(self.value);
            self.* = undefined;
        }
    };

    /// Move-only trace-header ownership, detached independently of the normal
    /// table. Consume with restoreTraceHeaders(), or explicitly deinit().
    pub const TraceHeaders = struct {
        parent: ?OwnedHeader = null,
        state: ?OwnedHeader = null,

        pub fn deinit(self: *TraceHeaders) void {
            if (self.parent) |*header| header.deinit();
            if (self.state) |*header| header.deinit();
            self.* = .{};
        }
    };

    /// Read-only borrowed views; iteration is invalidated by any mutation.
    pub const Entry = struct {
        key_ptr: *const []const u8,
        value_ptr: *const []const u8,
    };

    pub const Iterator = struct {
        ordinary: Map.Iterator,
        trace: *const TraceHeaders,
        next_trace: u2 = 0,

        pub fn next(self: *Iterator) ?Entry {
            if (self.ordinary.next()) |entry| {
                return .{ .key_ptr = entry.key_ptr, .value_ptr = entry.value_ptr };
            }
            if (self.next_trace == 0) {
                self.next_trace = 1;
                if (self.trace.parent) |*header|
                    return .{ .key_ptr = &header.name, .value_ptr = &header.value };
            }
            if (self.next_trace == 1) {
                self.next_trace = 2;
                if (self.trace.state) |*header|
                    return .{ .key_ptr = &header.name, .value_ptr = &header.value };
            }
            return null;
        }
    };

    pub fn init(allocator: std.mem.Allocator) RequestHeaders {
        return .{ .allocator = allocator, .ordinary = Map.initContext(allocator, .{}) };
    }

    /// Copies both strings. Replacing a header is transactional, retains the
    /// first spelling of its name, and frees its previous owned storage.
    pub fn put(self: *RequestHeaders, name: []const u8, value: []const u8) !void {
        try validate(name, value);
        if (traceIndex(name)) |index| {
            const slot = self.traceSlot(index);
            if (slot.*) |*header| {
                if (header.allocator.ptr == self.allocator.ptr and
                    header.allocator.vtable == self.allocator.vtable)
                {
                    const owned_value = try self.allocator.dupe(u8, value);
                    header.allocator.free(header.value);
                    header.value = owned_value;
                    return;
                }
            }
            const spelling = if (slot.*) |header| header.name else name;
            const replacement = try OwnedHeader.init(self.allocator, spelling, value);
            if (slot.*) |*header| header.deinit();
            slot.* = replacement;
            return;
        }
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        if (self.ordinary.getPtr(name)) |existing| {
            self.allocator.free(existing.*);
            existing.* = owned_value;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.ordinary.put(owned_name, owned_value);
    }

    pub fn get(self: *const RequestHeaders, name: []const u8) ?[]const u8 {
        if (traceIndex(name)) |index| {
            const header = (if (index == 0) self.trace.parent else self.trace.state) orelse return null;
            return header.value;
        }
        return self.ordinary.get(name);
    }

    pub fn contains(self: *const RequestHeaders, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// Removes and transfers ownership. Use remove() to remove and free instead.
    pub fn take(self: *RequestHeaders, name: []const u8) ?OwnedHeader {
        if (traceIndex(name)) |index| {
            const slot = self.traceSlot(index);
            const result = slot.*;
            slot.* = null;
            return result;
        }
        const removed = self.ordinary.fetchRemove(name) orelse return null;
        return .{ .name = removed.key, .value = removed.value, .allocator = self.allocator };
    }

    /// Case-insensitive, allocation-free removal including storage cleanup.
    pub fn remove(self: *RequestHeaders, name: []const u8) bool {
        var header = self.take(name) orelse return false;
        header.deinit();
        return true;
    }

    pub fn count(self: *const RequestHeaders) usize {
        return @as(usize, self.ordinary.count()) + @intFromBool(self.trace.parent != null) +
            @intFromBool(self.trace.state != null);
    }

    pub fn iterator(self: *const RequestHeaders) Iterator {
        return .{ .ordinary = self.ordinary.iterator(), .trace = &self.trace };
    }

    /// Reserves capacity for this many additional ordinary headers. Trace
    /// headers never use that capacity. Strings are still copied by put().
    pub fn ensureUnusedCapacity(self: *RequestHeaders, additional: usize) !void {
        const size = std.math.cast(Map.Size, additional) orelse return error.OutOfMemory;
        try self.ordinary.ensureUnusedCapacity(size);
    }

    /// Available ordinary-header table slots; independent of the two trace slots.
    pub fn unusedCapacity(self: *const RequestHeaders) usize {
        return self.ordinary.unmanaged.available;
    }

    pub fn clearRetainingCapacity(self: *RequestHeaders) void {
        var entries = self.ordinary.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.ordinary.clearRetainingCapacity();
        self.trace.deinit();
    }

    pub fn clearAndFree(self: *RequestHeaders) void {
        self.clearRetainingCapacity();
        self.ordinary.deinit();
        self.ordinary = Map.initContext(self.allocator, .{});
    }

    pub fn clone(self: *const RequestHeaders, allocator: std.mem.Allocator) !RequestHeaders {
        var result = RequestHeaders.init(allocator);
        errdefer result.deinit();
        var entries = self.iterator();
        while (entries.next()) |entry| try result.put(entry.key_ptr.*, entry.value_ptr.*);
        return result;
    }

    pub fn deinit(self: *RequestHeaders) void {
        self.clearAndFree();
    }

    pub fn takeTraceHeaders(self: *RequestHeaders) TraceHeaders {
        const result = self.trace;
        self.trace = .{};
        return result;
    }

    /// Consumes saved ownership with no allocation or map reservation. This
    /// works after removal, clearing, table growth or replacement of the entire
    /// collection, even by one using a different allocator.
    pub fn restoreTraceHeaders(self: *RequestHeaders, saved: *TraceHeaders) void {
        self.trace.deinit();
        self.trace = saved.*;
        saved.* = .{};
    }

    fn traceSlot(self: *RequestHeaders, index: u1) *?OwnedHeader {
        return if (index == 0) &self.trace.parent else &self.trace.state;
    }
};

fn traceIndex(name: []const u8) ?u1 {
    if (std.ascii.eqlIgnoreCase(name, "traceparent")) return 0;
    if (std.ascii.eqlIgnoreCase(name, "tracestate")) return 1;
    return null;
}

fn validate(name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidHttpHeaderName;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and !switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        }) return error.InvalidHttpHeaderName;
    }
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidHttpHeaderValue;
    }
}

test {
    _ = @import("request_headers_test.zig");
}
