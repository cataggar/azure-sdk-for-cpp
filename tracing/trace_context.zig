const std = @import("std");

/// W3C Trace Context Level 1. IDs are values; tracestate is a borrowed view.
pub const TraceContext = struct {
    trace_id: [32]u8 = @splat('0'),
    span_id: [16]u8 = @splat('0'),
    trace_flags: u8 = 0,
    trace_state: ?[]const u8 = null,

    pub fn isValid(self: TraceContext) bool {
        return validId(&self.trace_id) and validId(&self.span_id);
    }

    pub fn formatTraceparent(self: TraceContext) [55]u8 {
        var buf: [55]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "00-{s}-{s}-{s}", .{
            self.trace_id, self.span_id, std.fmt.bytesToHex([_]u8{self.trace_flags & 1}, .lower),
        }) catch unreachable;
        return buf;
    }

    pub fn parseTraceparent(header: []const u8) ?TraceContext {
        if (header.len < 55 or !hex(header[0..2]) or
            std.mem.eql(u8, header[0..2], "ff") or header[2] != '-' or
            header[35] != '-' or header[52] != '-' or !hex(header[53..55])) return null;
        if (std.mem.eql(u8, header[0..2], "00")) {
            if (header.len != 55) return null;
        } else if (header.len > 55 and header[55] != '-') return null;
        if (!validId(header[3..35]) or !validId(header[36..52])) return null;
        return .{
            .trace_id = header[3..35].*,
            .span_id = header[36..52].*,
            .trace_flags = (std.fmt.parseUnsigned(u8, header[53..55], 16) catch return null) & 1,
        };
    }

    /// Invalid tracestate is dropped independently of an otherwise valid parent.
    pub fn extract(parent: ?[]const u8, state: ?[]const u8) ?TraceContext {
        var result = parseTraceparent(parent orelse return null) orelse return null;
        if (state) |s| {
            if (validTracestate(s)) result.trace_state = s;
        }
        return result;
    }

    /// Conservative 512-byte/32-nonempty-member limit; rejects duplicate keys.
    /// Empty/OWS members are ignored, including an entirely empty field.
    pub fn validTracestate(state: []const u8) bool {
        if (state.len > 512) return false;
        var keys: [32][]const u8 = undefined;
        var count: usize = 0;
        var members = std.mem.splitScalar(u8, state, ',');
        while (members.next()) |raw| {
            const member = std.mem.trim(u8, raw, " \t");
            if (member.len == 0) continue;
            if (count == keys.len) return false;
            const equal = std.mem.indexOfScalar(u8, member, '=') orelse return false;
            const key = member[0..equal];
            const value = member[equal + 1 ..];
            if (!validKey(key) or value.len == 0 or value.len > 256) return false;
            for (value) |c| {
                if (c < 0x20 or c > 0x7e or c == ',' or c == '=') return false;
            }
            for (keys[0..count]) |existing| {
                if (std.mem.eql(u8, key, existing)) return false;
            }
            keys[count] = key;
            count += 1;
        }
        return true;
    }
};

fn hex(value: []const u8) bool {
    for (value) |c| {
        if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn validId(value: []const u8) bool {
    if (!hex(value)) return false;
    for (value) |c| if (c != '0') return true;
    return false;
}

fn keyTail(value: []const u8) bool {
    for (value) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and
            c != '_' and c != '-' and c != '*' and c != '/') return false;
    }
    return true;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 256) return false;
    if (std.mem.indexOfScalar(u8, key, '@')) |at| {
        const tenant = key[0..at];
        const system = key[at + 1 ..];
        return tenant.len > 0 and tenant.len <= 241 and system.len > 0 and system.len <= 14 and
            (std.ascii.isLower(tenant[0]) or std.ascii.isDigit(tenant[0])) and
            std.ascii.isLower(system[0]) and keyTail(tenant) and keyTail(system);
    }
    return std.ascii.isLower(key[0]) and keyTail(key);
}

test "W3C strict IDs versions and tracestate" {
    const good = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    try std.testing.expect(TraceContext.parseTraceparent(good) != null);
    inline for (.{
        "00-00000000000000000000000000000000-b7ad6b7169203331-01",
        "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01",
        "00-0Af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        "00-gaf7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        good ++ "-extra",
        "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        "01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01extra",
    }) |bad| try std.testing.expect(TraceContext.parseTraceparent(bad) == null);
    try std.testing.expect(TraceContext.parseTraceparent("01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-03-extra") != null);
    try std.testing.expect(TraceContext.validTracestate("vendor=abc, 1tenant@system=value"));
    inline for (.{ "a=1,a=2", "A=1", "a=", "a=x=y", "a=x\n", "@x=y", "a@=x" }) |bad|
        try std.testing.expect(!TraceContext.validTracestate(bad));
    inline for (.{ "", " ", "\t", " , \t, ", "a=x,", ",a=x", "a=x, ,other=value" }) |valid| {
        try std.testing.expect(TraceContext.validTracestate(valid));
        try std.testing.expectEqualStrings(valid, TraceContext.extract(good, valid).?.trace_state.?);
    }
    try std.testing.expect(TraceContext.extract(good, "bad").?.trace_state == null);
    try std.testing.expect(TraceContext.extract(null, "a=x") == null);
    const too_long = "a=" ++ "x" ** 511;
    try std.testing.expect(!TraceContext.validTracestate(too_long));
    try std.testing.expect(!TraceContext.validTracestate("a=" ++ "x" ** 257));
    var members: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&members);
    for (0..33) |i| try writer.print("{s}k{d}=x", .{ if (i == 0) "" else ",", i });
    try std.testing.expect(!TraceContext.validTracestate(writer.buffered()));
}

test "W3C empty tracestate members do not consume member limits" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (0..32) |i| try writer.print(" ,k{d}=v,", .{i});
    try writer.writeAll(" \t,");
    try std.testing.expect(TraceContext.validTracestate(writer.buffered()));
    try writer.writeAll("overflow=v");
    try std.testing.expect(!TraceContext.validTracestate(writer.buffered()));
    try std.testing.expect(!TraceContext.validTracestate("a=x, ,a=y"));
    try std.testing.expect(!TraceContext.validTracestate("a=x,\r"));
    try std.testing.expect(!TraceContext.validTracestate(" " ** 513));
}
