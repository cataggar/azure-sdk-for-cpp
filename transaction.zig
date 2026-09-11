//! Multipart Azure Tables transaction construction and response parsing.
//!
//! `$batch` is not present in the canonical Tables TypeSpec, so this module is
//! deliberately hand-written and kept outside the generated protocol package.

const std = @import("std");
const core = @import("azure_sdk_core");

var testing_crypto_provider = core.crypto.StdCryptoProvider.init(std.testing.io);

fn testingRuntime(http_transport: core.http.HttpTransport) core.http.HttpRuntime {
    return .init(http_transport, testing_crypto_provider.asProvider());
}
const entity = @import("entity.zig");
const entity_codec = @import("entity_codec.zig");
const errors = @import("errors.zig");
const options_mod = @import("options.zig");
const pipeline = @import("pipeline.zig");
const protocol_client = @import("protocol_client.zig");
const request = @import("request.zig");
const responses = @import("responses.zig");

pub const max_operations = 100;
pub const max_payload_size = 4 * 1024 * 1024;
const max_entity_size = 1024 * 1024;

pub const Action = enum {
    add,
    delete,
    update_merge,
    update_replace,
    upsert_merge,
    upsert_replace,
};

const Operation = struct {
    action: Action,
    partition_key: []u8,
    row_key: []u8,
    body: ?[]u8,
    if_match: ?[]u8,

    fn deinit(self: *Operation, allocator: std.mem.Allocator) void {
        allocator.free(self.partition_key);
        allocator.free(self.row_key);
        if (self.body) |body| allocator.free(body);
        if (self.if_match) |etag| allocator.free(etag);
        self.* = undefined;
    }
};

/// Allocator-owned transaction actions.
///
/// Entity values are serialized and copied when an action is appended. Caller
/// values therefore need not remain alive until submission.
pub const TransactionBuilder = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayList(Operation) = .empty,

    pub fn init(allocator: std.mem.Allocator) TransactionBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TransactionBuilder) void {
        for (self.operations.items) |*operation| operation.deinit(self.allocator);
        self.operations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const TransactionBuilder) usize {
        return self.operations.items.len;
    }

    pub fn add(self: *TransactionBuilder, comptime T: type, value: T) !void {
        return self.appendEntity(T, value, .add, null);
    }

    pub fn addDynamic(self: *TransactionBuilder, value: entity.DynamicEntity) !void {
        return self.appendDynamic(value, .add, null);
    }

    pub fn delete(
        self: *TransactionBuilder,
        partition_key: []const u8,
        row_key: []const u8,
        if_match: []const u8,
    ) !void {
        try request.validateEntityKey(partition_key);
        try request.validateEntityKey(row_key);
        try request.validateIfMatch(if_match);
        return self.appendOwned(.delete, partition_key, row_key, null, if_match);
    }

    pub fn updateMerge(
        self: *TransactionBuilder,
        comptime T: type,
        value: T,
        if_match: []const u8,
    ) !void {
        try request.validateIfMatch(if_match);
        return self.appendEntity(T, value, .update_merge, if_match);
    }

    pub fn updateMergeDynamic(
        self: *TransactionBuilder,
        value: entity.DynamicEntity,
        if_match: []const u8,
    ) !void {
        try request.validateIfMatch(if_match);
        return self.appendDynamic(value, .update_merge, if_match);
    }

    pub fn updateReplace(
        self: *TransactionBuilder,
        comptime T: type,
        value: T,
        if_match: []const u8,
    ) !void {
        try request.validateIfMatch(if_match);
        return self.appendEntity(T, value, .update_replace, if_match);
    }

    pub fn updateReplaceDynamic(
        self: *TransactionBuilder,
        value: entity.DynamicEntity,
        if_match: []const u8,
    ) !void {
        try request.validateIfMatch(if_match);
        return self.appendDynamic(value, .update_replace, if_match);
    }

    pub fn upsertMerge(self: *TransactionBuilder, comptime T: type, value: T) !void {
        return self.appendEntity(T, value, .upsert_merge, null);
    }

    pub fn upsertMergeDynamic(
        self: *TransactionBuilder,
        value: entity.DynamicEntity,
    ) !void {
        return self.appendDynamic(value, .upsert_merge, null);
    }

    pub fn upsertReplace(self: *TransactionBuilder, comptime T: type, value: T) !void {
        return self.appendEntity(T, value, .upsert_replace, null);
    }

    pub fn upsertReplaceDynamic(
        self: *TransactionBuilder,
        value: entity.DynamicEntity,
    ) !void {
        return self.appendDynamic(value, .upsert_replace, null);
    }

    fn appendEntity(
        self: *TransactionBuilder,
        comptime T: type,
        value: T,
        action: Action,
        if_match: ?[]const u8,
    ) !void {
        if (T == entity.DynamicEntity)
            @compileError("use the matching *Dynamic transaction method for DynamicEntity");
        const Codec = entity_codec.EntityCodec(T);
        const partition_key = @field(value, "partition_key");
        const row_key = @field(value, "row_key");
        try request.validateEntityKey(partition_key);
        try request.validateEntityKey(row_key);
        const body = try Codec.toJson(self.allocator, value);
        if (body.len == 0 or body.len > max_entity_size) {
            self.allocator.free(body);
            return error.EntityTooLarge;
        }
        return self.appendSerialized(action, partition_key, row_key, body, if_match);
    }

    fn appendDynamic(
        self: *TransactionBuilder,
        value: entity.DynamicEntity,
        action: Action,
        if_match: ?[]const u8,
    ) !void {
        try request.validateEntityKey(value.partition_key);
        try request.validateEntityKey(value.row_key);
        if (value.properties.count() > entity.max_custom_properties)
            return error.TooManyProperties;
        var iterator = value.properties.iterator();
        while (iterator.next()) |entry| try entity.validatePropertyName(entry.key_ptr.*);
        const body = try entity_codec.dynamicToJson(self.allocator, value);
        if (body.len == 0 or body.len > max_entity_size) {
            self.allocator.free(body);
            return error.EntityTooLarge;
        }
        return self.appendSerialized(
            action,
            value.partition_key,
            value.row_key,
            body,
            if_match,
        );
    }

    fn appendSerialized(
        self: *TransactionBuilder,
        action: Action,
        partition_key: []const u8,
        row_key: []const u8,
        owned_body: []u8,
        if_match: ?[]const u8,
    ) !void {
        errdefer self.allocator.free(owned_body);
        return self.appendOwned(action, partition_key, row_key, owned_body, if_match);
    }

    fn appendOwned(
        self: *TransactionBuilder,
        action: Action,
        partition_key: []const u8,
        row_key: []const u8,
        owned_body: ?[]u8,
        if_match: ?[]const u8,
    ) !void {
        if (self.operations.items.len >= max_operations)
            return error.TooManyTransactionOperations;
        const owned_partition = try self.allocator.dupe(u8, partition_key);
        errdefer self.allocator.free(owned_partition);
        const owned_row = try self.allocator.dupe(u8, row_key);
        errdefer self.allocator.free(owned_row);
        const owned_etag = if (if_match) |etag| try self.allocator.dupe(u8, etag) else null;
        errdefer if (owned_etag) |etag| self.allocator.free(etag);
        try self.operations.append(self.allocator, .{
            .action = action,
            .partition_key = owned_partition,
            .row_key = owned_row,
            .body = owned_body,
            .if_match = owned_etag,
        });
    }

    fn validate(self: *const TransactionBuilder) !void {
        if (self.operations.items.len == 0) return error.EmptyTransaction;
        if (self.operations.items.len > max_operations)
            return error.TooManyTransactionOperations;
        const partition_key = self.operations.items[0].partition_key;
        for (self.operations.items, 0..) |operation, index| {
            try request.validateEntityKey(operation.partition_key);
            try request.validateEntityKey(operation.row_key);
            if (!std.mem.eql(u8, operation.partition_key, partition_key))
                return error.TransactionPartitionMismatch;
            switch (operation.action) {
                .delete, .update_merge, .update_replace => {
                    const etag = operation.if_match orelse
                        return error.TransactionActionRequiresETag;
                    try request.validateIfMatch(etag);
                },
                .add, .upsert_merge, .upsert_replace => {
                    if (operation.if_match != null)
                        return error.TransactionActionForbidsETag;
                },
            }
            if (operation.body) |body| {
                if (body.len == 0 or body.len > max_entity_size)
                    return error.EntityTooLarge;
            } else if (operation.action != .delete) {
                return error.TransactionActionRequiresBody;
            }
            for (self.operations.items[0..index]) |previous| {
                if (std.mem.eql(u8, operation.partition_key, previous.partition_key) and
                    std.mem.eql(u8, operation.row_key, previous.row_key))
                {
                    return error.DuplicateTransactionEntity;
                }
            }
        }
    }
};

pub const Boundaries = options_mod.TransactionBoundaries;

pub const SerializedRequest = struct {
    body: []u8,
    content_type: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SerializedRequest) void {
        self.allocator.free(self.body);
        self.allocator.free(self.content_type);
        self.* = undefined;
    }
};

/// Renders a deterministic request when explicit boundaries are supplied.
pub fn serialize(
    builder: *const TransactionBuilder,
    allocator: std.mem.Allocator,
    table_name: []const u8,
    boundaries: Boundaries,
) !SerializedRequest {
    return serializeWithEndpoint(builder, allocator, table_name, null, boundaries);
}

/// Azure Tables accepts relative batch sub-request targets, but Azurite
/// requires fully qualified targets. Submission always supplies its validated
/// endpoint while the public serializer preserves relative deterministic wire
/// fixtures for callers.
fn serializeWithEndpoint(
    builder: *const TransactionBuilder,
    allocator: std.mem.Allocator,
    table_name: []const u8,
    endpoint: ?[]const u8,
    boundaries: Boundaries,
) !SerializedRequest {
    try builder.validate();
    try request.validateTableName(table_name);
    try validateBoundary(boundaries.batch);
    try validateBoundary(boundaries.changeset);
    if (std.mem.eql(u8, boundaries.batch, boundaries.changeset))
        return error.InvalidMultipartBoundary;
    for (builder.operations.items) |operation| {
        if (operation.body) |body| {
            try ensureNoBoundaryCollision(allocator, body, boundaries.batch);
            try ensureNoBoundaryCollision(allocator, body, boundaries.changeset);
        }
    }

    var count_buffer: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try render(builder, allocator, table_name, endpoint, boundaries, &counter.writer);
    const length = counter.fullCount();
    if (length > max_payload_size) return error.TransactionTooLarge;

    var output = try std.Io.Writer.Allocating.initCapacity(allocator, @intCast(length));
    errdefer output.deinit();
    render(builder, allocator, table_name, endpoint, boundaries, &output.writer) catch |err| {
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
    const body = try output.toOwnedSlice();
    errdefer allocator.free(body);
    if (body.len != length) return error.MultipartLengthMismatch;
    return .{
        .body = body,
        .content_type = try std.fmt.allocPrint(
            allocator,
            "multipart/mixed; boundary={s}",
            .{boundaries.batch},
        ),
        .allocator = allocator,
    };
}

fn render(
    builder: *const TransactionBuilder,
    allocator: std.mem.Allocator,
    table_name: []const u8,
    endpoint: ?[]const u8,
    boundaries: Boundaries,
    writer: anytype,
) !void {
    try writer.print(
        "--{s}\r\nContent-Type: multipart/mixed; boundary={s}\r\n\r\n",
        .{ boundaries.batch, boundaries.changeset },
    );
    for (builder.operations.items, 0..) |operation, index| {
        const relative_url = try operationUrl(allocator, table_name, operation);
        defer allocator.free(relative_url);
        const request_url = if (endpoint) |base|
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, relative_url })
        else
            relative_url;
        defer if (endpoint != null) allocator.free(request_url);
        try writer.print(
            "--{s}\r\n" ++
                "Content-Type: application/http\r\n" ++
                "Content-Transfer-Encoding: binary\r\n" ++
                "Content-ID: {d}\r\n\r\n" ++
                "{s} {s} HTTP/1.1\r\n" ++
                "Accept: application/json;odata=nometadata\r\n" ++
                "DataServiceVersion: 3.0;\r\n",
            .{
                boundaries.changeset,
                index + 1,
                method(operation.action),
                request_url,
            },
        );
        if (operation.body != null)
            try writer.writeAll("Content-Type: application/json\r\n");
        if (operation.action == .add)
            try writer.writeAll("Prefer: return-no-content\r\n");
        if (operation.if_match) |etag|
            try writer.print("If-Match: {s}\r\n", .{etag});
        try writer.writeAll("\r\n");
        if (operation.body) |body| try writer.writeAll(body);
        try writer.writeAll("\r\n");
    }
    try writer.print(
        "--{s}--\r\n--{s}--\r\n",
        .{ boundaries.changeset, boundaries.batch },
    );
}

fn operationUrl(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    operation: Operation,
) ![]u8 {
    if (operation.action == .add)
        return allocator.dupe(u8, table_name);
    const partition = try request.encodeODataStringLiteral(allocator, operation.partition_key);
    defer allocator.free(partition);
    const row = try request.encodeODataStringLiteral(allocator, operation.row_key);
    defer allocator.free(row);
    return std.fmt.allocPrint(
        allocator,
        "{s}(PartitionKey='{s}',RowKey='{s}')",
        .{ table_name, partition, row },
    );
}

fn method(action: Action) []const u8 {
    return switch (action) {
        .add => "POST",
        .delete => "DELETE",
        .update_merge, .upsert_merge => "PATCH",
        .update_replace, .upsert_replace => "PUT",
    };
}

fn validateBoundary(boundary: []const u8) !void {
    if (boundary.len == 0 or boundary.len > 70)
        return error.InvalidMultipartBoundary;
    for (boundary) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and
            byte != '.')
        {
            return error.InvalidMultipartBoundary;
        }
    }
}

fn ensureNoBoundaryCollision(
    allocator: std.mem.Allocator,
    body: []const u8,
    boundary: []const u8,
) !void {
    const marker = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(marker);
    const line_marker = try std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary});
    defer allocator.free(line_marker);
    if (std.mem.startsWith(u8, body, marker) or
        std.mem.indexOf(u8, body, line_marker) != null)
    {
        return error.MultipartBoundaryCollision;
    }
}

pub const OperationResult = struct {
    status: u16,
    etag: ?[]const u8 = null,
};

pub const TransactionResponse = struct {
    status: u16,
    operations: []OperationResult,
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TransactionResponse) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const TransactionResult = responses.TableResult(TransactionResponse);

pub fn submitResult(
    protocol: *protocol_client.ProtocolClient,
    allocator: std.mem.Allocator,
    table_name: []const u8,
    builder: *const TransactionBuilder,
    transaction_options: options_mod.TransactionOptions,
) !TransactionResult {
    try request.validateProtocolOptions(transaction_options.protocol);
    var batch_boundary: [38]u8 = undefined;
    var changeset_boundary: [42]u8 = undefined;
    const boundaries = transaction_options.boundaries orelse
        try randomBoundaries(
            protocol.pipeline.runtime.crypto,
            &batch_boundary,
            &changeset_boundary,
        );
    var serialized = try serializeWithEndpoint(
        builder,
        allocator,
        table_name,
        protocol.endpoint.base_url,
        boundaries,
    );
    defer serialized.deinit();

    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/$batch",
        .{protocol.endpoint.base_url},
    );
    defer allocator.free(url);
    var req = core.http.Request.init(allocator, .POST, url);
    defer req.deinit();
    req.redirect_policy = .not_allowed;
    req.body = serialized.body;
    try req.setHeader("Content-Type", serialized.content_type);
    try req.setHeader("Accept", "multipart/mixed");
    try req.setHeader("Accept-Charset", "UTF-8");
    try req.setHeader("DataServiceVersion", "3.0;");
    try req.setHeader("MaxDataServiceVersion", "3.0;NetFx");
    try req.setHeader("x-ms-version", protocol.api_version);
    if (transaction_options.protocol.client_request_id) |value|
        try req.setHeader("x-ms-client-request-id", value);

    var call = try pipeline.CallContext.initTransaction(
        allocator,
        protocol.pipeline,
        if (protocol.endpoint.has_query) protocol.endpoint.raw_query else null,
        protocol.endpoint_query_is_sas,
        transaction_options.protocol.operation_timeout_ms orelse
            protocol.default_operation_timeout_ms,
        transaction_options.protocol.timeout,
        transaction_options.protocol.policies,
        protocol.mutation_retry,
    );
    defer call.deinit();
    var response = try call.pipeline.send(&req);
    defer response.deinit();

    const content_type = response.getHeader("Content-Type");
    const request_id = response.getHeader("x-ms-request-id");
    if (!response.isSuccess()) {
        return .{ .failure = try errors.TableError.fromResponse(
            allocator,
            response.status_code,
            content_type,
            request_id,
            null,
            response.body,
        ) };
    }
    // A successful batch response must be 202 with a complete multipart
    // response. Any other 2xx or parse failure leaves the atomic outcome
    // indeterminate, so callers must not retry the transaction.
    if (response.status_code != 202) return error.TransactionOutcomeUnknown;
    return parseResponse(
        allocator,
        response.status_code,
        content_type orelse return error.TransactionOutcomeUnknown,
        request_id,
        response.body,
        builder.operations.items.len,
    ) catch return error.TransactionOutcomeUnknown;
}

fn randomBoundaries(
    crypto_provider: core.crypto.CryptoProvider,
    batch: *[38]u8,
    changeset: *[42]u8,
) !Boundaries {
    var bytes: [32]u8 = undefined;
    try crypto_provider.randomBytes(&bytes);
    const batch_slice = std.fmt.bufPrint(batch, "batch_{x}", .{bytes[0..16]}) catch unreachable;
    const changeset_slice = std.fmt.bufPrint(
        changeset,
        "changeset_{x}",
        .{bytes[16..32]},
    ) catch unreachable;
    return .{ .batch = batch_slice, .changeset = changeset_slice };
}

const BoundaryCryptoProvider = struct {
    random_calls: usize = 0,
    fail: bool = false,

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

    fn randomBytes(context: *anyopaque, out: []u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.random_calls += 1;
        if (self.fail) return error.ProviderFailure;
        for (out, 0..) |*byte, index| byte.* = @truncate(index);
    }

    fn md5(_: *anyopaque, _: []const u8, _: *core.crypto.Md5Digest) !void {
        return error.Unused;
    }

    fn sha256(_: *anyopaque, _: []const u8, _: *core.crypto.Sha256Digest) !void {
        return error.Unused;
    }

    fn hmacSha256(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: *core.crypto.HmacSha256Digest,
    ) !void {
        return error.Unused;
    }

    fn sha256Init(
        _: *anyopaque,
        _: std.mem.Allocator,
    ) !core.crypto.Sha256Operation {
        return error.Unused;
    }
};

test "generated multipart boundaries are valid and distinct" {
    var batch: [38]u8 = undefined;
    var changeset: [42]u8 = undefined;
    var provider = BoundaryCryptoProvider{};
    const boundaries = try randomBoundaries(
        provider.provider(),
        &batch,
        &changeset,
    );
    try std.testing.expectEqual(@as(usize, 1), provider.random_calls);
    try std.testing.expectEqual(@as(usize, 38), boundaries.batch.len);
    try std.testing.expectEqual(@as(usize, 42), boundaries.changeset.len);
    try std.testing.expect(!std.mem.eql(u8, boundaries.batch, boundaries.changeset));
    try validateBoundary(boundaries.batch);
    try validateBoundary(boundaries.changeset);
}

/// Parses a complete `202 Accepted` batch response. `submitResult` maps any
/// error from this parser to `TransactionOutcomeUnknown` because the atomic
/// outcome cannot then be determined safely.
pub fn parseResponse(
    allocator: std.mem.Allocator,
    status: u16,
    content_type: []const u8,
    request_id: ?[]const u8,
    body: []const u8,
    expected_operations: usize,
) !TransactionResult {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const batch_boundary = try parseBoundary(content_type);
    const outer_parts = try multipartParts(arena_allocator, body, batch_boundary);
    if (outer_parts.len != 1) return error.MalformedMultipart;
    const outer = try parseMessagePart(outer_parts[0]);
    const changeset_boundary = try parseBoundary(
        headerValue(outer.headers, "Content-Type") orelse
            return error.MalformedMultipart,
    );
    const inner_parts = try multipartParts(arena_allocator, outer.body, changeset_boundary);
    if (inner_parts.len == 0) return error.MalformedMultipart;

    const results = try arena_allocator.alloc(OperationResult, inner_parts.len);
    for (inner_parts, 0..) |bytes, index| {
        const mime = try parseMessagePart(bytes);
        const mime_type = headerValue(mime.headers, "Content-Type") orelse
            return error.MalformedMultipart;
        if (!mediaTypeIs(mime_type, "application/http")) return error.MalformedMultipart;
        const inner = try parseHttpResponse(mime.body);
        if (inner.status < 200 or inner.status >= 300) {
            const inner_content_type = headerValue(inner.headers, "Content-Type");
            const inner_request_id = headerValue(inner.headers, "x-ms-request-id") orelse
                request_id;
            var table_error = try errors.TableError.fromResponse(
                allocator,
                inner.status,
                inner_content_type,
                inner_request_id,
                null,
                inner.body,
            );
            errdefer table_error.deinit();
            table_error.operation_index = operationIndex(
                table_error.message,
                headerValue(inner.headers, "Content-ID") orelse
                    headerValue(mime.headers, "Content-ID"),
                index,
            );
            if (table_error.operation_index.? >= expected_operations)
                return error.MalformedTransactionOperationIndex;
            arena.deinit();
            allocator.destroy(arena);
            return .{ .failure = table_error };
        }
        results[index] = .{
            .status = inner.status,
            .etag = if (headerValue(inner.headers, "ETag")) |etag|
                try arena_allocator.dupe(u8, etag)
            else
                null,
        };
    }
    if (inner_parts.len != expected_operations)
        return error.TransactionResponseCountMismatch;
    return .{ .success = .{
        .status = status,
        .operations = results,
        .arena = arena,
        .allocator = allocator,
    } };
}

const MessagePart = struct {
    headers: []const u8,
    body: []const u8,
};

fn parseMessagePart(bytes: []const u8) !MessagePart {
    const separator = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse
        return error.MalformedMultipart;
    try validateHeaderBlock(bytes[0..separator]);
    return .{
        .headers = bytes[0..separator],
        .body = bytes[separator + 4 ..],
    };
}

const InnerResponse = struct {
    status: u16,
    headers: []const u8,
    body: []const u8,
};

fn parseHttpResponse(bytes: []const u8) !InnerResponse {
    const line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse
        return error.MalformedInnerResponse;
    const line = bytes[0..line_end];
    if (!std.mem.startsWith(u8, line, "HTTP/1.1 ") or line.len < 12)
        return error.MalformedInnerResponse;
    const code = std.fmt.parseInt(u16, line[9..12], 10) catch
        return error.MalformedInnerResponse;
    if (line.len > 12 and line[12] != ' ') return error.MalformedInnerResponse;
    const remainder = bytes[line_end + 2 ..];
    const separator = std.mem.indexOf(u8, remainder, "\r\n\r\n") orelse
        return error.MalformedInnerResponse;
    try validateHeaderBlock(remainder[0..separator]);
    return .{
        .status = code,
        .headers = remainder[0..separator],
        .body = remainder[separator + 4 ..],
    };
}

fn validateHeaderBlock(block: []const u8) !void {
    if (block.len == 0) return;
    var iterator = std.mem.splitSequence(u8, block, "\r\n");
    while (iterator.next()) |line| {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t')
            return error.MalformedMultipartHeaders;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return error.MalformedMultipartHeaders;
        if (colon == 0) return error.MalformedMultipartHeaders;
    }
}

fn headerValue(block: []const u8, name: []const u8) ?[]const u8 {
    var iterator = std.mem.splitSequence(u8, block, "\r\n");
    while (iterator.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name))
            continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn parseBoundary(content_type: []const u8) ![]const u8 {
    if (!mediaTypeIs(content_type, "multipart/mixed"))
        return error.MissingMultipartContentType;
    var parameters = std.mem.splitScalar(u8, content_type, ';');
    _ = parameters.next();
    while (parameters.next()) |parameter| {
        const equal = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        const name = std.mem.trim(u8, parameter[0..equal], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "boundary")) continue;
        var value = std.mem.trim(u8, parameter[equal + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
            value = value[1 .. value.len - 1];
        try validateBoundary(value);
        return value;
    }
    return error.MissingMultipartBoundary;
}

fn mediaTypeIs(value: []const u8, expected: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..end], " \t"), expected);
}

fn multipartParts(
    allocator: std.mem.Allocator,
    body: []const u8,
    boundary: []const u8,
) ![][]const u8 {
    const marker = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(marker);
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);

    var delimiter = findDelimiter(body, marker, 0) orelse
        return error.MalformedMultipart;
    while (true) {
        const after_marker = delimiter + marker.len;
        if (after_marker + 2 <= body.len and
            std.mem.eql(u8, body[after_marker .. after_marker + 2], "--"))
        {
            const tail = body[after_marker + 2 ..];
            if (tail.len != 0 and !std.mem.eql(u8, tail, "\r\n"))
                return error.MalformedMultipart;
            break;
        }
        if (after_marker + 2 > body.len or
            !std.mem.eql(u8, body[after_marker .. after_marker + 2], "\r\n"))
        {
            return error.MalformedMultipart;
        }
        const content_start = after_marker + 2;
        const next = findDelimiter(body, marker, content_start) orelse
            return error.MalformedMultipart;
        if (next < 2 or !std.mem.eql(u8, body[next - 2 .. next], "\r\n"))
            return error.MalformedMultipart;
        try parts.append(allocator, body[content_start .. next - 2]);
        delimiter = next;
    }
    return parts.toOwnedSlice(allocator);
}

fn findDelimiter(body: []const u8, marker: []const u8, start: usize) ?usize {
    var position = start;
    while (std.mem.indexOfPos(u8, body, position, marker)) |found| {
        const line_start = found == 0 or
            (found >= 2 and std.mem.eql(u8, body[found - 2 .. found], "\r\n"));
        const after = found + marker.len;
        const line_end = after + 2 <= body.len and
            (std.mem.eql(u8, body[after .. after + 2], "\r\n") or
                std.mem.eql(u8, body[after .. after + 2], "--"));
        if (line_start and line_end) return found;
        position = found + 1;
    }
    return null;
}

fn operationIndex(message: ?[]const u8, content_id: ?[]const u8, fallback: usize) usize {
    if (message) |text| {
        const colon = std.mem.indexOfScalar(u8, text, ':');
        if (colon) |position| {
            if (position > 0)
                if (std.fmt.parseInt(usize, text[0..position], 10)) |value|
                    return value
                else |_| {};
        }
    }
    if (content_id) |text| {
        const value = std.fmt.parseInt(usize, std.mem.trim(u8, text, " \t"), 10) catch
            return fallback;
        if (value > 0) return value - 1;
    }
    return fallback;
}

const TestEntity = struct {
    partition_key: []const u8,
    row_key: []const u8,
    value: []const u8,
};

test "all transaction actions have canonical golden wire shapes" {
    var builder = TransactionBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.add(TestEntity, .{ .partition_key = "p", .row_key = "add", .value = "a" });
    try builder.delete("p", "delete", "W/\"delete\"");
    try builder.updateMerge(TestEntity, .{ .partition_key = "p", .row_key = "merge", .value = "m" }, "*");
    try builder.updateReplace(TestEntity, .{ .partition_key = "p", .row_key = "replace", .value = "r" }, "W/\"replace\"");
    try builder.upsertMerge(TestEntity, .{ .partition_key = "p", .row_key = "upsert-m", .value = "um" });
    try builder.upsertReplace(TestEntity, .{ .partition_key = "p", .row_key = "upsert-r", .value = "ur" });

    var serialized = try serialize(
        &builder,
        std.testing.allocator,
        "People",
        .{ .batch = "batch_test", .changeset = "changeset_test" },
    );
    defer serialized.deinit();
    try std.testing.expectEqualStrings("multipart/mixed; boundary=batch_test", serialized.content_type);
    const expected =
        "--batch_test\r\nContent-Type: multipart/mixed; boundary=changeset_test\r\n\r\n" ++
        "--changeset_test\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 1\r\n\r\nPOST People HTTP/1.1\r\nAccept: application/json;odata=nometadata\r\nDataServiceVersion: 3.0;\r\nContent-Type: application/json\r\nPrefer: return-no-content\r\n\r\n{\"PartitionKey\":\"p\",\"RowKey\":\"add\",\"value\":\"a\"}\r\n" ++
        "--changeset_test\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 2\r\n\r\nDELETE People(PartitionKey='p',RowKey='delete') HTTP/1.1\r\nAccept: application/json;odata=nometadata\r\nDataServiceVersion: 3.0;\r\nIf-Match: W/\"delete\"\r\n\r\n\r\n" ++
        "--changeset_test\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 3\r\n\r\nPATCH People(PartitionKey='p',RowKey='merge') HTTP/1.1\r\nAccept: application/json;odata=nometadata\r\nDataServiceVersion: 3.0;\r\nContent-Type: application/json\r\nIf-Match: *\r\n\r\n{\"PartitionKey\":\"p\",\"RowKey\":\"merge\",\"value\":\"m\"}\r\n" ++
        "--changeset_test\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 4\r\n\r\nPUT People(PartitionKey='p',RowKey='replace') HTTP/1.1\r\nAccept: application/json;odata=nometadata\r\nDataServiceVersion: 3.0;\r\nContent-Type: application/json\r\nIf-Match: W/\"replace\"\r\n\r\n{\"PartitionKey\":\"p\",\"RowKey\":\"replace\",\"value\":\"r\"}\r\n" ++
        "--changeset_test\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 5\r\n\r\nPATCH People(PartitionKey='p',RowKey='upsert-m') HTTP/1.1\r\nAccept: application/json;odata=nometadata\r\nDataServiceVersion: 3.0;\r\nContent-Type: application/json\r\n\r\n{\"PartitionKey\":\"p\",\"RowKey\":\"upsert-m\",\"value\":\"um\"}\r\n" ++
        "--changeset_test\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 6\r\n\r\nPUT People(PartitionKey='p',RowKey='upsert-r') HTTP/1.1\r\nAccept: application/json;odata=nometadata\r\nDataServiceVersion: 3.0;\r\nContent-Type: application/json\r\n\r\n{\"PartitionKey\":\"p\",\"RowKey\":\"upsert-r\",\"value\":\"ur\"}\r\n" ++
        "--changeset_test--\r\n--batch_test--\r\n";
    try std.testing.expectEqualStrings(expected, serialized.body);
}

test "submitted transaction uses absolute sub-request targets" {
    var builder = TransactionBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.add(TestEntity, .{
        .partition_key = "p",
        .row_key = "r",
        .value = "value",
    });
    var serialized = try serializeWithEndpoint(
        &builder,
        std.testing.allocator,
        "People",
        "http://127.0.0.1:10002/devstoreaccount1",
        .{ .batch = "batch_test", .changeset = "changeset_test" },
    );
    defer serialized.deinit();
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            serialized.body,
            "POST http://127.0.0.1:10002/devstoreaccount1/People HTTP/1.1",
        ) != null,
    );
}

test "transaction URLs escape quotes and Unicode once" {
    var builder = TransactionBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.delete("O'Brien", "雪", "*");
    var serialized = try serialize(
        &builder,
        std.testing.allocator,
        "People",
        .{ .batch = "batch", .changeset = "changeset" },
    );
    defer serialized.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        serialized.body,
        "People(PartitionKey='O%27%27Brien',RowKey='%E9%9B%AA')",
    ) != null);
}

fn appendDynamicTestAction(
    builder: *TransactionBuilder,
    action: Action,
    row_key: []const u8,
) !void {
    var value = try entity.DynamicEntity.init(std.testing.allocator, "p", row_key);
    defer value.deinit();
    try value.put("Name", .{ .string = "before" });
    switch (action) {
        .add => try builder.addDynamic(value),
        .delete => unreachable,
        .update_merge => try builder.updateMergeDynamic(value, "*"),
        .update_replace => try builder.updateReplaceDynamic(value, "*"),
        .upsert_merge => try builder.upsertMergeDynamic(value),
        .upsert_replace => try builder.upsertReplaceDynamic(value),
    }
    try value.put("Name", .{ .string = "after" });
}

test "dynamic transaction variants serialize immediately" {
    var builder = TransactionBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try appendDynamicTestAction(&builder, .add, "add");
    try appendDynamicTestAction(&builder, .update_merge, "update-m");
    try appendDynamicTestAction(&builder, .update_replace, "update-r");
    try appendDynamicTestAction(&builder, .upsert_merge, "upsert-m");
    try appendDynamicTestAction(&builder, .upsert_replace, "upsert-r");
    var serialized = try serialize(
        &builder,
        std.testing.allocator,
        "People",
        .{ .batch = "batch", .changeset = "changeset" },
    );
    defer serialized.deinit();
    try std.testing.expect(std.mem.indexOf(u8, serialized.body, "\"Name\":\"after\"") == null);
    try std.testing.expect(std.mem.count(u8, serialized.body, "\"Name\":\"before\"") == 5);
}

test "transaction local validation rejects invalid groups" {
    var empty = TransactionBuilder.init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectError(error.EmptyTransaction, serialize(
        &empty,
        std.testing.allocator,
        "People",
        .{ .batch = "batch", .changeset = "changeset" },
    ));

    var partitions = TransactionBuilder.init(std.testing.allocator);
    defer partitions.deinit();
    try partitions.delete("a", "1", "*");
    try partitions.delete("b", "2", "*");
    try std.testing.expectError(error.TransactionPartitionMismatch, serialize(
        &partitions,
        std.testing.allocator,
        "People",
        .{ .batch = "batch", .changeset = "changeset" },
    ));

    var duplicate = TransactionBuilder.init(std.testing.allocator);
    defer duplicate.deinit();
    try duplicate.delete("a", "1", "*");
    try duplicate.updateMerge(TestEntity, .{ .partition_key = "a", .row_key = "1", .value = "x" }, "*");
    try std.testing.expectError(error.DuplicateTransactionEntity, serialize(
        &duplicate,
        std.testing.allocator,
        "People",
        .{ .batch = "batch", .changeset = "changeset" },
    ));

    try std.testing.expectError(error.InvalidEntityKey, duplicate.delete("bad/key", "2", "*"));
    try std.testing.expectError(error.InvalidIfMatch, duplicate.delete("a", "2", ""));
}

test "transaction count permits exactly one hundred actions" {
    var builder = TransactionBuilder.init(std.testing.allocator);
    defer builder.deinit();
    var row_buffer: [8]u8 = undefined;
    for (0..max_operations) |index| {
        const row = try std.fmt.bufPrint(&row_buffer, "r{d}", .{index});
        try builder.delete("p", row, "*");
    }
    try std.testing.expectEqual(max_operations, builder.count());
    try std.testing.expectError(
        error.TooManyTransactionOperations,
        builder.delete("p", "overflow", "*"),
    );
}

fn whitespaceObject(allocator: std.mem.Allocator, length: usize) ![]u8 {
    if (length < 2) return error.TestBodyTooSmall;
    const body = try allocator.alloc(u8, length);
    @memset(body, ' ');
    body[0] = '{';
    body[body.len - 1] = '}';
    return body;
}

test "complete MIME payload permits exactly four MiB and rejects one byte more" {
    const allocator = std.testing.allocator;
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    for (0..4) |index| {
        const body = try whitespaceObject(allocator, if (index < 3) max_entity_size else 2);
        var row_buffer: [8]u8 = undefined;
        const row = try std.fmt.bufPrint(&row_buffer, "r{d}", .{index});
        try builder.appendSerialized(.upsert_merge, "p", row, body, null);
    }
    const boundaries: Boundaries = .{ .batch = "batch", .changeset = "changeset" };
    var initial = try serialize(&builder, allocator, "People", boundaries);
    const missing = max_payload_size - initial.body.len;
    initial.deinit();

    allocator.free(builder.operations.items[3].body.?);
    builder.operations.items[3].body = try whitespaceObject(allocator, 2 + missing);
    var exact = try serialize(&builder, allocator, "People", boundaries);
    defer exact.deinit();
    try std.testing.expectEqual(@as(usize, max_payload_size), exact.body.len);

    const larger = try whitespaceObject(allocator, builder.operations.items[3].body.?.len + 1);
    allocator.free(builder.operations.items[3].body.?);
    builder.operations.items[3].body = larger;
    try std.testing.expectError(
        error.TransactionTooLarge,
        serialize(&builder, allocator, "People", boundaries),
    );
}

test "ETag action rules are revalidated before rendering" {
    const allocator = std.testing.allocator;
    var missing = TransactionBuilder.init(allocator);
    defer missing.deinit();
    try missing.delete("p", "r", "*");
    allocator.free(missing.operations.items[0].if_match.?);
    missing.operations.items[0].if_match = null;
    try std.testing.expectError(
        error.TransactionActionRequiresETag,
        serialize(
            &missing,
            allocator,
            "People",
            .{ .batch = "batch", .changeset = "changeset" },
        ),
    );

    var forbidden = TransactionBuilder.init(allocator);
    defer forbidden.deinit();
    try forbidden.add(TestEntity, .{ .partition_key = "p", .row_key = "r", .value = "v" });
    forbidden.operations.items[0].if_match = try allocator.dupe(u8, "*");
    try std.testing.expectError(
        error.TransactionActionForbidsETag,
        serialize(
            &forbidden,
            allocator,
            "People",
            .{ .batch = "batch", .changeset = "changeset" },
        ),
    );
}

test "nested transaction response preserves order and ETags" {
    const body =
        "--batchresponse\r\nContent-Type: multipart/mixed; boundary=changesetresponse\r\n\r\n" ++
        "--changesetresponse\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n\r\nHTTP/1.1 204 No Content\r\nContent-ID: 1\r\nETag: W/\"one\"\r\n\r\n\r\n" ++
        "--changesetresponse\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n\r\nHTTP/1.1 201 Created\r\nContent-ID: 2\r\nETag: W/\"two\"\r\n\r\n{}\r\n" ++
        "--changesetresponse--\r\n--batchresponse--\r\n";
    var result = try parseResponse(
        std.testing.allocator,
        202,
        "multipart/mixed; boundary=\"batchresponse\"",
        "outer-id",
        body,
        2,
    );
    defer result.deinit(std.testing.allocator);
    const response = &result.success;
    try std.testing.expectEqual(@as(u16, 204), response.operations[0].status);
    try std.testing.expectEqualStrings("W/\"one\"", response.operations[0].etag.?);
    try std.testing.expectEqual(@as(u16, 201), response.operations[1].status);
    try std.testing.expectEqualStrings("W/\"two\"", response.operations[1].etag.?);
}

test "inner transaction error exposes service error and zero-based index" {
    var result = try parseResponse(
        std.testing.allocator,
        202,
        "multipart/mixed; boundary=batchresponse",
        "outer-id",
        one_failure_body,
        6,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("InvalidInput", result.failure.code);
    try std.testing.expectEqual(@as(?usize, 3), result.failure.operation_index);
}

test "malformed multipart transaction responses are rejected" {
    try std.testing.expectError(
        error.MalformedMultipart,
        parseResponse(
            std.testing.allocator,
            202,
            "multipart/mixed; boundary=batch",
            null,
            "--batch\nContent-Type: multipart/mixed\n\n--batch--",
            1,
        ),
    );
    try std.testing.expectError(
        error.MissingMultipartBoundary,
        parseResponse(
            std.testing.allocator,
            202,
            "multipart/mixed",
            null,
            "",
            1,
        ),
    );
}

const one_success_body =
    "--batchresponse\r\nContent-Type: multipart/mixed; boundary=changesetresponse\r\n\r\n" ++
    "--changesetresponse\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n\r\n" ++
    "HTTP/1.1 204 No Content\r\nContent-ID: 1\r\nETag: W/\"one\"\r\n\r\n\r\n" ++
    "--changesetresponse--\r\n--batchresponse--\r\n";

const one_failure_body =
    "--batchresponse\r\nContent-Type: multipart/mixed; boundary=changesetresponse\r\n\r\n" ++
    "--changesetresponse\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n\r\nHTTP/1.1 400 Bad Request\r\nContent-ID: 4\r\nContent-Type: application/json\r\n\r\n" ++
    "{\"odata.error\":{\"code\":\"InvalidInput\",\"message\":{\"value\":\"3:bad action\"}}}\r\n" ++
    "--changesetresponse--\r\n--batchresponse--\r\n";

const transaction_response_headers = &[_]core.http.MockTransport.HeaderPair{
    .{ .name = "Content-Type", .value = "multipart/mixed; boundary=batchresponse" },
    .{ .name = "x-ms-request-id", .value = "outer-request" },
};

test "automatic transaction boundaries use the selected runtime provider" {
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 202, one_success_body);
    defer mock.deinit();
    mock.response_headers_list = transaction_response_headers;
    var crypto = BoundaryCryptoProvider{};
    const runtime = core.http.HttpRuntime.init(
        mock.asTransport(),
        crypto.provider(),
    );
    var client = try client_mod.TableClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" }, .table_name = "People" },
    );
    defer client.deinit();
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    try builder.delete("p", "r", "*");

    var result = try client.submitTransactionResult(allocator, &builder, .{
        .protocol = .{ .client_request_id = "automatic-boundary-test" },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), crypto.random_calls);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expect(std.mem.indexOf(
        u8,
        mock.last_body.?,
        "batch_000102030405060708090a0b0c0d0e0f",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        mock.last_body.?,
        "changeset_101112131415161718191a1b1c1d1e1f",
    ) != null);
}

test "boundary provider failure prevents send and explicit boundaries bypass it" {
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 202, one_success_body);
    defer mock.deinit();
    mock.response_headers_list = transaction_response_headers;
    var crypto = BoundaryCryptoProvider{ .fail = true };
    const runtime = core.http.HttpRuntime.init(
        mock.asTransport(),
        crypto.provider(),
    );
    var client = try client_mod.TableClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" }, .table_name = "People" },
    );
    defer client.deinit();
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    try builder.delete("p", "r", "*");

    try std.testing.expectError(
        error.ProviderFailure,
        client.submitTransactionResult(allocator, &builder, .{
            .protocol = .{ .client_request_id = "boundary-failure-test" },
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), crypto.random_calls);
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);

    var result = try client.submitTransactionResult(allocator, &builder, .{
        .protocol = .{ .client_request_id = "explicit-boundary-test" },
        .boundaries = .{ .batch = "batch", .changeset = "changeset" },
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), crypto.random_calls);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expect(std.mem.startsWith(
        u8,
        mock.last_body.?,
        "--batch\r\nContent-Type: multipart/mixed; boundary=changeset\r\n",
    ));
}

fn expectIndeterminateTransactionResponse(
    status: u16,
    headers: []const core.http.MockTransport.HeaderPair,
    body: []const u8,
    action_count: usize,
) !void {
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, status, body);
    defer mock.deinit();
    mock.response_headers_list = headers;
    var client = try client_mod.TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" }, .table_name = "People" },
    );
    defer client.deinit();
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    for (0..action_count) |index| {
        var row_buffer: [20]u8 = undefined;
        const row = try std.fmt.bufPrint(&row_buffer, "r{d}", .{index});
        try builder.delete("p", row, "*");
    }
    try std.testing.expectError(
        error.TransactionOutcomeUnknown,
        client.submitTransactionResult(allocator, &builder, .{
            .boundaries = .{ .batch = "batch", .changeset = "changeset" },
        }),
    );
}

test "transaction indeterminate post-202 responses are not retry-safe" {
    const no_headers = &[_]core.http.MockTransport.HeaderPair{};
    const wrong_content_type = &[_]core.http.MockTransport.HeaderPair{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    try expectIndeterminateTransactionResponse(
        204,
        transaction_response_headers,
        one_success_body,
        1,
    );
    try expectIndeterminateTransactionResponse(
        201,
        transaction_response_headers,
        one_success_body,
        1,
    );
    try expectIndeterminateTransactionResponse(202, no_headers, one_success_body, 1);
    try expectIndeterminateTransactionResponse(
        202,
        wrong_content_type,
        one_success_body,
        1,
    );
    try expectIndeterminateTransactionResponse(
        202,
        transaction_response_headers,
        one_success_body[0 .. one_success_body.len - 1],
        1,
    );
    try expectIndeterminateTransactionResponse(202, transaction_response_headers, "", 1);
    try expectIndeterminateTransactionResponse(202, transaction_response_headers, one_success_body, 2);
}

test "submitted transaction inner failure remains a precise indexed TableError" {
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 202, one_failure_body);
    defer mock.deinit();
    mock.response_headers_list = transaction_response_headers;
    var client = try client_mod.TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" }, .table_name = "People" },
    );
    defer client.deinit();
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    for (0..6) |index| {
        var row_buffer: [20]u8 = undefined;
        const row = try std.fmt.bufPrint(&row_buffer, "r{d}", .{index});
        try builder.delete("p", row, "*");
    }
    var result = try client.submitTransactionResult(allocator, &builder, .{
        .boundaries = .{ .batch = "batch", .changeset = "changeset" },
    });
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("InvalidInput", result.failure.code);
    try std.testing.expectEqual(@as(?usize, 3), result.failure.operation_index);
}

const TestCredential = struct {
    credential: core.credentials.TokenCredential,

    fn init() TestCredential {
        return .{ .credential = .{ .getTokenFn = &getToken } };
    }

    fn getToken(
        _: *core.credentials.TokenCredential,
        _: core.credentials.TokenRequestContext,
        _: core.context.Context,
        _: core.http.HttpRuntime,
    ) anyerror!core.credentials.AccessToken {
        return .{ .token = "transaction-token", .expires_on = std.math.maxInt(i64) };
    }
};

const TransactionAuthMode = enum {
    bearer,
    shared_key,
    sas,
};

fn expectTransactionRedirectRejected(
    status: u16,
    auth_mode: TransactionAuthMode,
) !void {
    const auth = @import("auth.zig");
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var transport = core.http.SequenceMockTransport.init(allocator, &.{
        .{
            .status = status,
            .body = "",
            .headers = &.{
                .{
                    .name = "Location",
                    .value = "https://account.table.core.windows.net/redirect-target",
                },
            },
        },
        .{
            .status = 202,
            .body = one_success_body,
            .headers = transaction_response_headers,
        },
    });
    var test_credential = TestCredential.init();
    var shared_credential = try auth.SharedKeyCredential.init(
        allocator,
        "account",
        "ZmFrZS1rZXk=",
    );
    defer shared_credential.deinit();
    var client = try client_mod.TableClient.init(allocator, testingRuntime(transport.asTransport()), .{
        .authentication = switch (auth_mode) {
            .bearer => .{ .token = .{
                .endpoint = "https://account.table.core.windows.net",
                .credential = &test_credential.credential,
            } },
            .shared_key => .{ .shared_key = .{
                .endpoint = "https://account.table.core.windows.net",
                .credential = &shared_credential,
            } },
            .sas => .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" },
        },
        .table_name = "People",
    });
    defer client.deinit();
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    try builder.delete("p", "r", "*");

    var result = try client.submitTransactionResult(allocator, &builder, .{
        .boundaries = .{ .batch = "b", .changeset = "c" },
    });
    defer result.deinit(allocator);
    switch (result) {
        .success => return error.ExpectedRedirectRejection,
        .failure => |failure| try std.testing.expectEqual(status, failure.status),
    }
    try std.testing.expectEqual(@as(usize, 1), transport.call_count);
    try std.testing.expectEqual(core.http.Method.POST, transport.captured_methods[0].?);
    try std.testing.expect(transport.captured_body_present[0]);
    try std.testing.expect(transport.capturedBody(0).len > 0);
    try std.testing.expect(!transport.captured_body_present[1]);
    try std.testing.expectEqual(@as(usize, 0), transport.capturedBody(1).len);
    switch (auth_mode) {
        .bearer, .shared_key => try std.testing.expect(
            transport.captured_authorization[0],
        ),
        .sas => {
            try std.testing.expect(!transport.captured_authorization[0]);
            try std.testing.expect(
                std.mem.indexOf(u8, transport.capturedUrl(0), "sig=SECRET") != null,
            );
        },
    }
    try std.testing.expect(!transport.captured_authorization[1]);
}

test "transaction 307 and 308 redirects are rejected without replay for every auth mode" {
    for ([_]u16{ 307, 308 }) |status| {
        inline for (std.meta.fields(TransactionAuthMode)) |field| {
            try expectTransactionRedirectRejected(
                status,
                @field(TransactionAuthMode, field.name),
            );
        }
    }
}

const PreTransportOncePolicy = struct {
    calls: usize = 0,
    policy: core.http.HttpPolicy = .{ .processFn = &process },

    fn process(
        policy: *core.http.HttpPolicy,
        req: *core.http.Request,
        next: []*core.http.HttpPolicy,
        runtime: core.http.HttpRuntime,
    ) anyerror!core.http.Response {
        const self: *PreTransportOncePolicy = @alignCast(@fieldParentPtr("policy", policy));
        self.calls += 1;
        if (self.calls == 1) return error.InjectedPreTransportFailure;
        if (next.len == 0) return runtime.transport.send(req);
        return next[0].process(req, next[1..], runtime);
    }
};

const AlwaysFailPreTransportPolicy = struct {
    calls: usize = 0,
    policy: core.http.HttpPolicy = .{ .processFn = &process },

    fn process(
        policy: *core.http.HttpPolicy,
        _: *core.http.Request,
        _: []*core.http.HttpPolicy,
        _: core.http.HttpRuntime,
    ) anyerror!core.http.Response {
        const self: *AlwaysFailPreTransportPolicy = @alignCast(
            @fieldParentPtr("policy", policy),
        );
        self.calls += 1;
        return error.InjectedPreTransportFailure;
    }
};

const FailingTransactionTransport = struct {
    calls: usize = 0,
    failure: anyerror = error.InjectedTransportFailure,

    const vtable: core.http.HttpTransport.VTable = .{ .send = &send };

    fn asTransport(self: *FailingTransactionTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(
        context: *anyopaque,
        _: *core.http.Request,
    ) anyerror!core.http.Response {
        const self: *FailingTransactionTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        return self.failure;
    }
};

test "transaction POST retries pretransport failure but not ambiguous transport failure" {
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    try builder.delete("p", "r", "*");

    var pretransport = PreTransportOncePolicy{};
    var mock = core.http.MockTransport.init(allocator, 202, one_success_body);
    defer mock.deinit();
    mock.response_headers_list = transaction_response_headers;
    var client = try client_mod.TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" },
            .table_name = "People",
            .options = .{ .retry = .{ .max_retries = 1, .initial_delay_ms = 0, .max_delay_ms = 0 } },
        },
    );
    defer client.deinit();
    var result = try client.submitTransactionResult(allocator, &builder, .{
        .protocol = .{ .policies = &.{&pretransport.policy} },
        .boundaries = .{ .batch = "batch", .changeset = "changeset" },
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), pretransport.calls);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqual(core.http.Method.POST, mock.last_method.?);
    try std.testing.expectEqual(false, mock.last_retryable.?);
    try std.testing.expect(mock.last_headers.get("Authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "sig=SECRET") != null);

    var failing = FailingTransactionTransport{};
    var failing_client = try client_mod.TableClient.init(
        allocator,
        testingRuntime(failing.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" },
            .table_name = "People",
            .options = .{ .retry = .{ .max_retries = 5, .initial_delay_ms = 0, .max_delay_ms = 0 } },
        },
    );
    defer failing_client.deinit();
    try std.testing.expectError(
        error.TransactionOutcomeUnknown,
        failing_client.submitTransactionResult(allocator, &builder, .{
            .boundaries = .{ .batch = "batch", .changeset = "changeset" },
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), failing.calls);

    var timed_out = FailingTransactionTransport{ .failure = error.OperationTimedOut };
    var timeout_client = try client_mod.TableClient.init(
        allocator,
        testingRuntime(timed_out.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" }, .table_name = "People" },
    );
    defer timeout_client.deinit();
    try std.testing.expectError(
        error.TransactionOutcomeUnknown,
        timeout_client.submitTransactionResult(allocator, &builder, .{
            .boundaries = .{ .batch = "batch", .changeset = "changeset" },
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), timed_out.calls);
}

test "transaction pretransport retries honor operation time budget" {
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var policy = AlwaysFailPreTransportPolicy{};
    var mock = core.http.MockTransport.init(allocator, 202, one_success_body);
    defer mock.deinit();
    mock.response_headers_list = transaction_response_headers;
    var client = try client_mod.TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" },
            .table_name = "People",
            .options = .{ .retry = .{ .max_retries = 5, .initial_delay_ms = 50, .max_delay_ms = 50 } },
        },
    );
    defer client.deinit();
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    try builder.delete("p", "r", "*");
    try std.testing.expectError(
        error.OperationTimedOut,
        client.submitTransactionResult(allocator, &builder, .{
            .protocol = .{
                .operation_timeout_ms = 1,
                .policies = &.{&policy.policy},
            },
            .boundaries = .{ .batch = "batch", .changeset = "changeset" },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "transaction submission uses bearer and SharedKey authentication" {
    const auth = @import("auth.zig");
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    try builder.delete("p", "r", "*");

    var bearer_mock = core.http.MockTransport.init(allocator, 202, one_success_body);
    defer bearer_mock.deinit();
    bearer_mock.response_headers_list = transaction_response_headers;
    var test_credential = TestCredential.init();
    var bearer = try client_mod.TableClient.init(
        allocator,
        testingRuntime(bearer_mock.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = &test_credential.credential } },
            .table_name = "People",
        },
    );
    defer bearer.deinit();
    var bearer_result = try bearer.submitTransactionResult(allocator, &builder, .{
        .boundaries = .{ .batch = "batch", .changeset = "changeset" },
    });
    defer bearer_result.deinit(allocator);
    try std.testing.expectEqualStrings(
        "Bearer transaction-token",
        bearer_mock.last_headers.get("Authorization").?,
    );

    var shared_mock = core.http.MockTransport.init(allocator, 202, one_success_body);
    defer shared_mock.deinit();
    shared_mock.response_headers_list = transaction_response_headers;
    var credential = try auth.SharedKeyCredential.init(
        allocator,
        "account",
        "ZmFrZS1rZXk=",
    );
    defer credential.deinit();
    var shared = try client_mod.TableClient.init(
        allocator,
        testingRuntime(shared_mock.asTransport()),
        .{
            .authentication = .{ .shared_key = .{ .endpoint = "https://account.table.core.windows.net", .credential = &credential } },
            .table_name = "People",
        },
    );
    defer shared.deinit();
    var shared_result = try shared.submitTransactionResult(allocator, &builder, .{
        .boundaries = .{ .batch = "batch", .changeset = "changeset" },
    });
    defer shared_result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(
        u8,
        shared_mock.last_headers.get("Authorization").?,
        "SharedKeyLite account:",
    ));
}

test "transaction validation occurs before transport" {
    const client_mod = @import("client.zig");
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 202, one_success_body);
    defer mock.deinit();
    var client = try client_mod.TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=SECRET&sp=a" }, .table_name = "People" },
    );
    defer client.deinit();
    var empty = TransactionBuilder.init(allocator);
    defer empty.deinit();
    try std.testing.expectError(
        error.EmptyTransaction,
        client.submitTransactionResult(allocator, &empty, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

fn testBuilderAllocationFailures(allocator: std.mem.Allocator) !void {
    var builder = TransactionBuilder.init(allocator);
    defer builder.deinit();
    try builder.add(TestEntity, .{ .partition_key = "p", .row_key = "r", .value = "value" });
    var dynamic = try entity.DynamicEntity.init(allocator, "p", "dynamic");
    defer dynamic.deinit();
    try dynamic.put("Name", .{ .string = "value" });
    try builder.updateMergeDynamic(dynamic, "*");
    var serialized = try serialize(
        &builder,
        allocator,
        "People",
        .{ .batch = "batch", .changeset = "changeset" },
    );
    serialized.deinit();
}

test "transaction builder allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testBuilderAllocationFailures,
        .{},
    );
}

fn testResponseAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try parseResponse(
        allocator,
        202,
        "multipart/mixed; boundary=batchresponse",
        "request-id",
        one_success_body,
        1,
    );
    result.deinit(allocator);
}

test "transaction response allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testResponseAllocationFailures,
        .{},
    );
}
