//! Strict Storage Table connection-string parsing.
const std = @import("std");
const core = @import("azure_sdk_core");
const auth = @import("auth.zig");
const request = @import("request.zig");

pub const development_account_name = "devstoreaccount1";
pub const development_account_key =
    "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";

fn wipeAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
    const volatile_bytes: []volatile u8 = bytes;
    @memset(volatile_bytes, 0);
    allocator.free(bytes);
}

pub const Parsed = struct {
    allocator: std.mem.Allocator,
    endpoint: []u8,
    account_name: []u8,
    account_key: ?[]u8 = null,
    sas: ?[]u8 = null,

    pub fn deinit(self: *Parsed) void {
        wipeAndFree(self.allocator, self.endpoint);
        self.allocator.free(self.account_name);
        if (self.account_key) |value| wipeAndFree(self.allocator, value);
        if (self.sas) |value| wipeAndFree(self.allocator, value);
        self.* = undefined;
    }

    pub fn format(_: Parsed, writer: anytype) !void {
        try writer.writeAll("TablesConnectionString(***)");
    }
};

/// Parses account-key and SAS connection strings before any client or pipeline
/// allocation. Unknown keys, duplicates, mixed credentials, and ambiguous
/// endpoint forms are rejected.
pub fn parse(allocator: std.mem.Allocator, value: []const u8) !Parsed {
    var end = value.len;
    while (end > 0 and value[end - 1] == ';') : (end -= 1) {}
    const trimmed = value[0..end];
    if (trimmed.len == 0) return error.InvalidConnectionString;

    var account_name: ?[]const u8 = null;
    var account_key: ?[]const u8 = null;
    var sas: ?[]const u8 = null;
    var protocol: ?[]const u8 = null;
    var suffix: ?[]const u8 = null;
    var table_endpoint: ?[]const u8 = null;
    var development_storage = false;
    var blob_endpoint_seen = false;
    var queue_endpoint_seen = false;
    var file_endpoint_seen = false;
    var entries = std.mem.splitScalar(u8, trimmed, ';');
    while (entries.next()) |entry| {
        if (entry.len == 0) return error.InvalidConnectionString;
        const equal = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidConnectionString;
        const key = std.mem.trim(u8, entry[0..equal], " \t");
        const field_value = std.mem.trim(u8, entry[equal + 1 ..], " \t");
        if (key.len == 0 or field_value.len == 0) return error.InvalidConnectionString;
        if (std.ascii.eqlIgnoreCase(key, "AccountName")) {
            if (account_name != null) return error.DuplicateConnectionStringKey;
            account_name = field_value;
        } else if (std.ascii.eqlIgnoreCase(key, "AccountKey")) {
            if (account_key != null) return error.DuplicateConnectionStringKey;
            account_key = field_value;
        } else if (std.ascii.eqlIgnoreCase(key, "SharedAccessSignature")) {
            if (sas != null) return error.DuplicateConnectionStringKey;
            sas = field_value;
        } else if (std.ascii.eqlIgnoreCase(key, "DefaultEndpointsProtocol")) {
            if (protocol != null) return error.DuplicateConnectionStringKey;
            protocol = field_value;
        } else if (std.ascii.eqlIgnoreCase(key, "EndpointSuffix")) {
            if (suffix != null) return error.DuplicateConnectionStringKey;
            suffix = field_value;
        } else if (std.ascii.eqlIgnoreCase(key, "TableEndpoint")) {
            if (table_endpoint != null) return error.DuplicateConnectionStringKey;
            table_endpoint = field_value;
        } else if (std.ascii.eqlIgnoreCase(key, "BlobEndpoint")) {
            if (blob_endpoint_seen) return error.DuplicateConnectionStringKey;
            blob_endpoint_seen = true;
        } else if (std.ascii.eqlIgnoreCase(key, "QueueEndpoint")) {
            if (queue_endpoint_seen) return error.DuplicateConnectionStringKey;
            queue_endpoint_seen = true;
        } else if (std.ascii.eqlIgnoreCase(key, "FileEndpoint")) {
            if (file_endpoint_seen) return error.DuplicateConnectionStringKey;
            file_endpoint_seen = true;
        } else if (std.ascii.eqlIgnoreCase(key, "UseDevelopmentStorage")) {
            if (development_storage) return error.DuplicateConnectionStringKey;
            if (!std.ascii.eqlIgnoreCase(field_value, "true")) return error.InvalidConnectionString;
            development_storage = true;
        } else return error.UnknownConnectionStringKey;
    }
    if (development_storage) {
        if (account_name != null or account_key != null or sas != null or protocol != null or
            suffix != null or table_endpoint != null or blob_endpoint_seen or
            queue_endpoint_seen or file_endpoint_seen)
        {
            return error.InvalidConnectionString;
        }
        return development(allocator);
    }
    if ((account_key == null and sas == null) or
        (account_key != null and sas != null))
        return error.InvalidConnectionString;
    if (account_key != null and account_name == null)
        return error.InvalidConnectionString;
    if (account_name) |name| try auth.validateAccountName(name);
    if (account_key) |key| {
        const decoded = core.base64.decode(allocator, key) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidAccountKey,
        };
        defer wipeAndFree(allocator, decoded);
        if (decoded.len == 0) return error.InvalidAccountKey;
    }
    if (table_endpoint != null and suffix != null)
        return error.AmbiguousConnectionStringEndpoint;
    if (protocol) |scheme| {
        if (!std.ascii.eqlIgnoreCase(scheme, "https") and !std.ascii.eqlIgnoreCase(scheme, "http"))
            return error.InvalidEndpointScheme;
    }

    const endpoint = if (table_endpoint) |explicit|
        try allocator.dupe(u8, explicit)
    else blk: {
        const name = account_name orelse return error.InvalidConnectionString;
        const scheme = protocol orelse "https";
        const endpoint_suffix = suffix orelse "core.windows.net";
        if (std.mem.indexOfAny(u8, endpoint_suffix, "/?#@") != null) return error.InvalidEndpoint;
        break :blk try std.fmt.allocPrint(
            allocator,
            "{s}://{s}.table.{s}",
            .{ scheme, name, endpoint_suffix },
        );
    };
    errdefer allocator.free(endpoint);
    if (std.mem.indexOfScalar(u8, endpoint, '?') != null)
        return error.InvalidConnectionString;
    if (sas) |token| {
        const raw = if (token[0] == '?') token[1..] else token;
        if (raw.len == 0) return error.InvalidConnectionString;
        const complete = try std.fmt.allocPrint(allocator, "{s}?{s}", .{ endpoint, raw });
        errdefer allocator.free(complete);
        const owned_account_name = try allocator.dupe(u8, account_name orelse "");
        errdefer allocator.free(owned_account_name);
        const owned_sas = try allocator.dupe(u8, raw);
        allocator.free(endpoint);
        return .{
            .allocator = allocator,
            .endpoint = complete,
            .account_name = owned_account_name,
            .sas = owned_sas,
        };
    }
    const owned_account_name = try allocator.dupe(u8, account_name.?);
    errdefer allocator.free(owned_account_name);
    const owned_key = try allocator.dupe(u8, account_key.?);
    return .{
        .allocator = allocator,
        .endpoint = endpoint,
        .account_name = owned_account_name,
        .account_key = owned_key,
    };
}

fn development(allocator: std.mem.Allocator) !Parsed {
    const endpoint = try allocator.dupe(u8, "http://127.0.0.1:10002/devstoreaccount1");
    errdefer allocator.free(endpoint);
    const account_name = try allocator.dupe(u8, development_account_name);
    errdefer allocator.free(account_name);
    const account_key = try allocator.dupe(u8, development_account_key);
    return .{
        .allocator = allocator,
        .endpoint = endpoint,
        .account_name = account_name,
        .account_key = account_key,
    };
}

const TestCryptoProvider = struct {
    inner: core.crypto.CryptoProvider,
    hmac_calls: usize = 0,

    const vtable: core.crypto.CryptoProvider.VTable = .{
        .random_bytes = &randomBytes,
        .md5 = &md5,
        .sha256 = &sha256,
        .hmac_sha256 = &hmacSha256,
        .sha256_init = &sha256Init,
    };

    fn provider(self: *@This()) core.crypto.CryptoProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    fn randomBytes(_: *anyopaque, _: []u8) !void {
        return error.Unused;
    }

    fn md5(_: *anyopaque, _: []const u8, _: *core.crypto.Md5Digest) !void {
        return error.Unused;
    }

    fn sha256(_: *anyopaque, _: []const u8, _: *core.crypto.Sha256Digest) !void {
        return error.Unused;
    }

    fn hmacSha256(
        context: *anyopaque,
        key: []const u8,
        message: []const u8,
        out: *core.crypto.HmacSha256Digest,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.hmac_calls += 1;
        out.* = try self.inner.hmacSha256(key, message);
    }

    fn sha256Init(
        _: *anyopaque,
        _: std.mem.Allocator,
    ) !core.crypto.Sha256Operation {
        return error.Unused;
    }
};

test "parse documented Storage and Azurite connection strings" {
    const allocator = std.testing.allocator;
    var azure = try parse(allocator, "DefaultEndpointsProtocol=https;AccountName=account;AccountKey=YQ==;EndpointSuffix=core.windows.net");
    defer azure.deinit();
    try std.testing.expectEqualStrings("https://account.table.core.windows.net", azure.endpoint);
    var custom = try parse(allocator, "AccountName=account;SharedAccessSignature=sv=1%2F2&sig=a+b%3D;TableEndpoint=https://tables.example.test/root");
    defer custom.deinit();
    try std.testing.expectEqualStrings("https://tables.example.test/root?sv=1%2F2&sig=a+b%3D", custom.endpoint);
    var azurite = try parse(allocator, "UseDevelopmentStorage=true");
    defer azurite.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:10002/devstoreaccount1", azurite.endpoint);
    try std.testing.expectEqualStrings(development_account_key, azurite.account_key.?);
    var azurite_trailing = try parse(allocator, "UseDevelopmentStorage=true;;");
    defer azurite_trailing.deinit();
    try std.testing.expectEqualStrings(azurite.endpoint, azurite_trailing.endpoint);

    var full_azurite = try parse(
        allocator,
        "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=" ++
            development_account_key ++
            ";BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;" ++
            "QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;" ++
            "TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;",
    );
    defer full_azurite.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:10002/devstoreaccount1", full_azurite.endpoint);
}

test "documented Azurite account key signs the SharedKeyLite vector" {
    const allocator = std.testing.allocator;
    var provider = core.crypto.StdCryptoProvider.init(std.testing.io);
    const key = try core.base64.decode(allocator, development_account_key);
    defer wipeAndFree(allocator, key);
    const signature = try core.base64.hmacSha256Base64(
        allocator,
        provider.asProvider(),
        key,
        "Thu, 23 Apr 2020 09:43:37 GMT\n/devstoreaccount1/?comp=properties",
    );
    defer wipeAndFree(allocator, signature);
    try std.testing.expectEqualStrings(
        "DKy2WIvWLvpXbgT2cc0NqjkcHYoV3AdwfcMHgV8UYd8=",
        signature,
    );

    var selected = TestCryptoProvider{ .inner = provider.asProvider() };
    const selected_signature = try core.base64.hmacSha256Base64(
        allocator,
        selected.provider(),
        key,
        "Thu, 23 Apr 2020 09:43:37 GMT\n/devstoreaccount1/?comp=properties",
    );
    defer wipeAndFree(allocator, selected_signature);
    try std.testing.expectEqualStrings(signature, selected_signature);
    try std.testing.expectEqual(@as(usize, 1), selected.hmac_calls);
}

test "connection strings support explicit endpoints and harmless trailing semicolons" {
    const allocator = std.testing.allocator;
    var explicit_sas = try parse(
        allocator,
        "TableEndpoint=https://tables.example.test/root;SharedAccessSignature=sv=1%2F2&sig=a+b%3D;;",
    );
    defer explicit_sas.deinit();
    try std.testing.expectEqualStrings(
        "https://tables.example.test/root?sv=1%2F2&sig=a+b%3D",
        explicit_sas.endpoint,
    );
    try std.testing.expectEqualStrings("", explicit_sas.account_name);

    var explicit_wins = try parse(
        allocator,
        "AccountName=account;AccountKey=YQ==;DefaultEndpointsProtocol=http;TableEndpoint=https://tables.example.test",
    );
    defer explicit_wins.deinit();
    try std.testing.expectEqualStrings("https://tables.example.test", explicit_wins.endpoint);

    try std.testing.expectError(error.InvalidAccountKey, parse(allocator, "AccountName=account;AccountKey=not base64!"));
    try std.testing.expectError(error.DuplicateConnectionStringKey, parse(allocator, "AccountName=account;AccountName=other;AccountKey=YQ=="));
    try std.testing.expectError(error.UnknownConnectionStringKey, parse(allocator, "AccountName=account;AccountKey=YQ==;OtherEndpoint=x"));
    try std.testing.expectError(error.DuplicateConnectionStringKey, parse(allocator, "AccountName=account;AccountKey=YQ==;BlobEndpoint=x;BlobEndpoint=y"));
    try std.testing.expectError(error.InvalidConnectionString, parse(allocator, "AccountName=account;;AccountKey=YQ=="));
    try std.testing.expectError(error.InvalidEndpointScheme, parse(allocator, "AccountName=account;AccountKey=YQ==;DefaultEndpointsProtocol=ftp;TableEndpoint=https://x"));
    try std.testing.expectError(error.AmbiguousConnectionStringEndpoint, parse(allocator, "AccountName=account;AccountKey=YQ==;TableEndpoint=https://x;EndpointSuffix=example.test"));
}

fn testDevelopmentAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try development(allocator);
    parsed.deinit();
}

test "development connection string allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testDevelopmentAllocationFailures,
        .{},
    );
}
