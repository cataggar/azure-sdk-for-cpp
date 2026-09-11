const std = @import("std");
const core = @import("azure_sdk_core");

var testing_crypto_provider = core.crypto.StdCryptoProvider.init(std.testing.io);

fn testingRuntime(http_transport: core.http.HttpTransport) core.http.HttpRuntime {
    return .init(http_transport, testing_crypto_provider.asProvider());
}
const auth = @import("auth.zig");
const Configuration = @import("client_configuration.zig").Configuration;
const entity = @import("entity.zig");
const entity_codec = @import("entity_codec.zig");
const options = @import("options.zig");
const pager = @import("pager.zig");
const pipeline = @import("pipeline.zig");
const protocol_client = @import("protocol_client.zig");
const request = @import("request.zig");
const sas_types = @import("sas.zig");
const responses = @import("responses.zig");
const service_models = @import("service_models.zig");
const transaction = @import("transaction.zig");

/// Client for Azure Table Storage REST operations.
///
/// A directly initialized client owns stable pipeline state. A client returned
/// by `TableServiceClient.getTableClient` borrows that state and must be
/// deinitialized before its parent. Explicit credentials, caller policies,
/// and runtime backend contexts are borrowed and must outlive the client and
/// in-flight calls. Connection-string credentials are owned. Calls sharing
/// pipeline state must be serialized because the token cache and standard
/// transport are mutable.
pub const TableClient = struct {
    allocator: std.mem.Allocator,
    protocol: protocol_client.ProtocolClient,
    table_name: []u8,
    pipeline_state: *pipeline.PipelineState,
    owns_pipeline_state: bool,
    owned_credential: ?*auth.SharedKeyCredential = null,

    pub const Options = options.TableClientOptions;
    pub const InitOptions = options.TableClientInitOptions;

    pub fn init(
        allocator: std.mem.Allocator,
        runtime: core.http.HttpRuntime,
        init_options: InitOptions,
    ) !TableClient {
        try request.validateTableName(init_options.table_name);
        var configuration = try Configuration.init(allocator, init_options.authentication);
        defer configuration.deinit();
        const state = try configuration.createPipeline(runtime, init_options.options);
        errdefer state.deinit();
        const sas_endpoint = if (state.usesSas())
            try serviceEndpointFromSasUrl(allocator, configuration.endpoint, init_options.table_name)
        else
            null;
        defer if (sas_endpoint) |endpoint| allocator.free(endpoint);
        var protocol = try protocol_client.ProtocolClient.init(
            allocator,
            sas_endpoint orelse configuration.endpoint,
            state.pipeline,
            .{
                .api_version = init_options.options.api_version,
                .endpoint_query_is_sas = state.usesSas(),
                .mutation_retry = state.retryOptions(),
                .default_operation_timeout_ms = state.operationTimeoutMs(),
            },
        );
        errdefer protocol.deinit();
        const table_name = try allocator.dupe(u8, init_options.table_name);
        const owned_credential = configuration.owned_credential;
        configuration.owned_credential = null;
        return .{
            .allocator = allocator,
            .protocol = protocol,
            .table_name = table_name,
            .pipeline_state = state,
            .owns_pipeline_state = true,
            .owned_credential = owned_credential,
        };
    }

    pub fn deinit(self: *TableClient) void {
        self.protocol.deinit();
        self.allocator.free(self.table_name);
        if (self.owns_pipeline_state) self.pipeline_state.deinit();
        if (self.owned_credential) |credential| {
            credential.deinit();
            self.allocator.destroy(credential);
        }
        self.* = undefined;
    }

    /// Formats a query-redacted endpoint so SAS signatures never enter logs.
    pub fn format(self: TableClient, writer: anytype) !void {
        try writer.print("TableClient({s})", .{self.protocol.endpoint.base_url});
    }

    /// Generates a full table SAS URL. This is available only on a Shared Key
    /// client; the returned URL is secret and must be released by the caller.
    pub fn getTableSasUrl(
        self: *TableClient,
        allocator: std.mem.Allocator,
        signature_values: sas_types.TableSignatureValues,
    ) ![]u8 {
        const credential = self.pipeline_state.sharedKeyCredential() orelse
            return error.SasRequiresSharedKeyCredential;
        var values = signature_values;
        if (values.tableName.len == 0) {
            values.tableName = self.table_name;
        } else if (!std.ascii.eqlIgnoreCase(values.tableName, self.table_name)) {
            return error.SasTableNameMismatch;
        }
        var parameters = try values.sign(
            allocator,
            credential,
            self.pipeline_state.pipeline.runtime.crypto,
        );
        defer parameters.deinit();
        const table_url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ self.protocol.endpoint.base_url, self.table_name },
        );
        defer allocator.free(table_url);
        return parameters.appendToUrl(allocator, table_url);
    }

    pub fn createTableResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        create_options: options.CreateTableOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.CreateTableResponse)) {
        return self.protocol.createTable(allocator, self.table_name, create_options);
    }

    pub fn createTable(
        self: *TableClient,
        allocator: std.mem.Allocator,
        create_options: options.CreateTableOptions,
    ) !responses.SdkResponse(protocol_client.CreateTableResponse) {
        return responses.unwrapCreateTable(
            responses.SdkResponse(protocol_client.CreateTableResponse),
            try self.createTableResult(allocator, create_options),
        );
    }

    pub fn deleteTableResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        delete_options: options.DeleteTableOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.DeleteTableResponse)) {
        return self.protocol.deleteTable(allocator, self.table_name, delete_options);
    }

    pub fn deleteTable(
        self: *TableClient,
        allocator: std.mem.Allocator,
        delete_options: options.DeleteTableOptions,
    ) !responses.SdkResponse(protocol_client.DeleteTableResponse) {
        return responses.unwrapDeleteTable(
            responses.SdkResponse(protocol_client.DeleteTableResponse),
            try self.deleteTableResult(allocator, delete_options),
        );
    }

    /// Starts a typed or dynamic entity query. The returned pager owns copies
    /// of request options and table protocol configuration; its pages remain
    /// valid only until its next successful call or deinitialization.
    pub fn queryEntities(
        self: *TableClient,
        comptime T: type,
        allocator: std.mem.Allocator,
        query_options: options.QueryEntitiesOptions,
    ) !pager.EntityPager(T) {
        return pager.EntityPager(T).init(
            allocator,
            &self.protocol,
            self.table_name,
            query_options,
        );
    }

    /// Adds a typed or dynamic entity and returns the service echo.
    pub fn addEntity(
        self: *TableClient,
        allocator: std.mem.Allocator,
        value: anytype,
        add_options: options.AddEntityOptions,
    ) !responses.EntityResponse(@TypeOf(value)) {
        const result = try self.addEntityResult(allocator, value, add_options);
        return switch (result) {
            .success => |response| response,
            .failure => |table_error| {
                var owned_error = table_error;
                owned_error.deinit();
                return error.AddEntityFailed;
            },
        };
    }

    /// Result-preserving add operation. HTTP failures are values; malformed
    /// success payloads, transport failures, and allocation failures are Zig
    /// errors.
    pub fn addEntityResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        value: anytype,
        add_options: options.AddEntityOptions,
    ) !responses.TableResult(responses.EntityResponse(@TypeOf(value))) {
        const T = @TypeOf(value);
        try validateEntityValue(T, value);
        const json = if (T == entity.DynamicEntity)
            try entity_codec.dynamicToJson(allocator, value)
        else
            try entity_codec.EntityCodec(T).toJson(allocator, value);
        defer allocator.free(json);
        if (json.len > 1024 * 1024) return error.EntityTooLarge;

        const protocol_result = try self.protocol.insertEntityResult(
            allocator,
            self.table_name,
            json,
            add_options,
        );
        return switch (protocol_result) {
            .failure => |table_error| .{ .failure = table_error },
            .success => |raw_value| blk: {
                var raw = raw_value;
                errdefer raw.deinit();
                break :blk .{ .success = try adaptEntityResponse(T, &raw) };
            },
        };
    }

    /// Retrieves and decodes one typed or dynamic entity.
    pub fn getEntityAs(
        self: *TableClient,
        comptime T: type,
        allocator: std.mem.Allocator,
        partition_key: []const u8,
        row_key: []const u8,
        get_options: options.GetEntityOptions,
    ) !responses.EntityResponse(T) {
        const result = try self.getEntityResult(T, allocator, partition_key, row_key, get_options);
        return switch (result) {
            .success => |response| response,
            .failure => |table_error| {
                var owned_error = table_error;
                owned_error.deinit();
                return error.GetEntityFailed;
            },
        };
    }

    pub fn getEntityResult(
        self: *TableClient,
        comptime T: type,
        allocator: std.mem.Allocator,
        partition_key: []const u8,
        row_key: []const u8,
        get_options: options.GetEntityOptions,
    ) !responses.TableResult(responses.EntityResponse(T)) {
        if (T != entity.DynamicEntity) _ = entity_codec.EntityCodec(T);
        const protocol_result = try self.protocol.queryEntityResult(
            allocator,
            self.table_name,
            partition_key,
            row_key,
            get_options,
        );
        return switch (protocol_result) {
            .failure => |table_error| .{ .failure = table_error },
            .success => |raw_value| blk: {
                var raw = raw_value;
                errdefer raw.deinit();
                break :blk .{ .success = try adaptEntityResponse(T, &raw) };
            },
        };
    }

    /// Deletes an entity unconditionally (`if_match = "*"`) or conditionally
    /// with a service ETag.
    pub fn deleteEntityWithOptions(
        self: *TableClient,
        allocator: std.mem.Allocator,
        partition_key: []const u8,
        row_key: []const u8,
        delete_options: options.DeleteEntityOptions,
    ) !responses.DeleteEntityResponse {
        const result = try self.deleteEntityResult(allocator, partition_key, row_key, delete_options);
        return switch (result) {
            .success => |response| response,
            .failure => |table_error| {
                var owned_error = table_error;
                owned_error.deinit();
                return error.DeleteEntityFailed;
            },
        };
    }

    pub fn deleteEntityResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        partition_key: []const u8,
        row_key: []const u8,
        delete_options: options.DeleteEntityOptions,
    ) !responses.TableResult(responses.DeleteEntityResponse) {
        const protocol_result = try self.protocol.deleteEntityResult(
            allocator,
            self.table_name,
            partition_key,
            row_key,
            delete_options,
        );
        return switch (protocol_result) {
            .failure => |table_error| .{ .failure = table_error },
            .success => |raw_value| blk: {
                var raw = raw_value;
                const etag_headers = entityHeaders(&raw.headers);
                break :blk .{ .success = .{
                    .status = raw.status,
                    .headers = etag_headers,
                    .raw_headers = raw.headers,
                    .arena = raw.arena,
                    .allocator = raw.allocator,
                } };
            },
        };
    }

    /// Updates an existing typed or dynamic entity. Merge preserves omitted
    /// properties; replace removes them.
    pub fn updateEntity(
        self: *TableClient,
        allocator: std.mem.Allocator,
        value: anytype,
        update_options: options.UpdateEntityOptions,
    ) !responses.MutationEntityResponse {
        const result = try self.updateEntityResult(allocator, value, update_options);
        return switch (result) {
            .success => |response| response,
            .failure => |table_error| {
                var owned_error = table_error;
                owned_error.deinit();
                return error.UpdateEntityFailed;
            },
        };
    }

    pub fn updateEntityResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        value: anytype,
        update_options: options.UpdateEntityOptions,
    ) !responses.TableResult(responses.MutationEntityResponse) {
        try request.validateIfMatch(update_options.if_match);
        return self.mutateEntityResult(
            allocator,
            value,
            update_options.mode,
            update_options.if_match,
            update_options.protocol,
        );
    }

    /// Inserts a missing entity or updates an existing one using the selected
    /// merge/replace semantics.
    pub fn upsertEntity(
        self: *TableClient,
        allocator: std.mem.Allocator,
        value: anytype,
        upsert_options: options.UpsertEntityOptions,
    ) !responses.MutationEntityResponse {
        const result = try self.upsertEntityResult(allocator, value, upsert_options);
        return switch (result) {
            .success => |response| response,
            .failure => |table_error| {
                var owned_error = table_error;
                owned_error.deinit();
                return error.UpsertEntityFailed;
            },
        };
    }

    pub fn upsertEntityResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        value: anytype,
        upsert_options: options.UpsertEntityOptions,
    ) !responses.TableResult(responses.MutationEntityResponse) {
        return self.mutateEntityResult(
            allocator,
            value,
            upsert_options.mode,
            null,
            upsert_options.protocol,
        );
    }

    /// Atomically submits the builder's ordered actions.
    pub fn submitTransaction(
        self: *TableClient,
        allocator: std.mem.Allocator,
        builder: *const transaction.TransactionBuilder,
        transaction_options: options.TransactionOptions,
    ) !transaction.TransactionResponse {
        const result = try self.submitTransactionResult(
            allocator,
            builder,
            transaction_options,
        );
        return switch (result) {
            .success => |response| response,
            .failure => |table_error| {
                var owned_error = table_error;
                owned_error.deinit();
                return error.SubmitTransactionFailed;
            },
        };
    }

    /// Preserves outer and indexed inner Tables service failures.
    pub fn submitTransactionResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        builder: *const transaction.TransactionBuilder,
        transaction_options: options.TransactionOptions,
    ) !transaction.TransactionResult {
        return transaction.submitResult(
            &self.protocol,
            allocator,
            self.table_name,
            builder,
            transaction_options,
        );
    }

    fn mutateEntityResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        value: anytype,
        mode: options.UpdateMode,
        if_match: ?[]const u8,
        protocol_options: options.ProtocolOptions,
    ) !responses.TableResult(responses.MutationEntityResponse) {
        const T = @TypeOf(value);
        try validateEntityValue(T, value);
        const json = if (T == entity.DynamicEntity)
            try entity_codec.dynamicToJson(allocator, value)
        else
            try entity_codec.EntityCodec(T).toJson(allocator, value);
        defer allocator.free(json);
        if (json.len > 1024 * 1024) return error.EntityTooLarge;

        const partition_key = @field(value, "partition_key");
        const row_key = @field(value, "row_key");
        const protocol_result = try self.protocol.mutateEntityResult(
            allocator,
            self.table_name,
            partition_key,
            row_key,
            json,
            mode,
            if_match,
            protocol_options,
        );
        return switch (protocol_result) {
            .failure => |table_error| .{ .failure = table_error },
            .success => |raw_value| blk: {
                var raw = raw_value;
                errdefer raw.deinit();
                const etag = raw.headers.getFirst("ETag") orelse
                    return error.MissingResponseHeader;
                break :blk .{ .success = .{
                    .etag = etag,
                    .status = raw.status,
                    .headers = entityHeaders(&raw.headers),
                    .raw_headers = raw.headers,
                    .arena = raw.arena,
                    .allocator = raw.allocator,
                } };
            },
        };
    }

    pub fn getAccessPolicyResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        get_options: options.GetAccessPolicyOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.GetAccessPolicyResponse)) {
        return self.protocol.getAccessPolicy(allocator, self.table_name, get_options);
    }

    pub fn getAccessPolicy(
        self: *TableClient,
        allocator: std.mem.Allocator,
        get_options: options.GetAccessPolicyOptions,
    ) !responses.SdkResponse(protocol_client.GetAccessPolicyResponse) {
        return responses.unwrapGetAccessPolicy(
            responses.SdkResponse(protocol_client.GetAccessPolicyResponse),
            try self.getAccessPolicyResult(allocator, get_options),
        );
    }

    pub fn setAccessPolicyResult(
        self: *TableClient,
        allocator: std.mem.Allocator,
        identifiers: []const service_models.SignedIdentifier,
        set_options: options.SetAccessPolicyOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.SetAccessPolicyResponse)) {
        return self.protocol.setAccessPolicy(
            allocator,
            self.table_name,
            identifiers,
            set_options,
        );
    }

    pub fn setAccessPolicy(
        self: *TableClient,
        allocator: std.mem.Allocator,
        identifiers: []const service_models.SignedIdentifier,
        set_options: options.SetAccessPolicyOptions,
    ) !responses.SdkResponse(protocol_client.SetAccessPolicyResponse) {
        return responses.unwrapSetAccessPolicy(
            responses.SdkResponse(protocol_client.SetAccessPolicyResponse),
            try self.setAccessPolicyResult(allocator, identifiers, set_options),
        );
    }

    /// Compatibility escape hatch for the original raw GET operation.
    pub fn getEntityRaw(
        self: *TableClient,
        allocator: std.mem.Allocator,
        partition_key: []const u8,
        row_key: []const u8,
    ) !core.http.Response {
        const url = try request.buildEntityUrl(
            allocator,
            self.protocol.endpoint.base_url,
            self.table_name,
            partition_key,
            row_key,
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json;odata=nometadata");
        try req.setHeader("x-ms-version", self.protocol.api_version);
        return self.protocol.send(&req, .{});
    }

    /// Original 0.1.0 raw-response GET retained with its exact signature.
    pub fn getEntity(
        self: *TableClient,
        allocator: std.mem.Allocator,
        partition_key: []const u8,
        row_key: []const u8,
    ) !core.http.Response {
        return self.getEntityRaw(allocator, partition_key, row_key);
    }

    /// POST `{endpoint}/{tableName}` with JSON entity body.
    pub fn createEntity(
        self: *TableClient,
        allocator: std.mem.Allocator,
        table_entity: entity.TableEntity,
    ) !core.http.Response {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{
                self.protocol.endpoint.base_url,
                self.table_name,
            },
        );
        defer allocator.free(url);

        var body_buf: std.Io.Writer.Allocating = .init(allocator);
        defer body_buf.deinit();
        const writer = &body_buf.writer;
        try writer.writeAll("{\"PartitionKey\":\"");
        try request.writeJsonEscaped(writer, table_entity.partition_key);
        try writer.writeAll("\",\"RowKey\":\"");
        try request.writeJsonEscaped(writer, table_entity.row_key);
        try writer.writeByte('"');
        var it = table_entity.properties.iterator();
        while (it.next()) |entry| {
            try writer.writeAll(",\"");
            try request.writeJsonEscaped(writer, entry.key_ptr.*);
            try writer.writeAll("\":\"");
            try request.writeJsonEscaped(writer, entry.value_ptr.*);
            try writer.writeByte('"');
        }
        try writer.writeAll("}");

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json;odata=nometadata");
        try req.setHeader("x-ms-version", self.protocol.api_version);
        req.body = body_buf.written();
        return self.protocol.send(&req, .{});
    }

    /// Compatibility escape hatch for the original raw DELETE operation.
    pub fn deleteEntityRaw(
        self: *TableClient,
        allocator: std.mem.Allocator,
        partition_key: []const u8,
        row_key: []const u8,
    ) !core.http.Response {
        const url = try request.buildEntityUrl(
            allocator,
            self.protocol.endpoint.base_url,
            self.table_name,
            partition_key,
            row_key,
        );
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();
        try req.setHeader("If-Match", "*");
        try req.setHeader("x-ms-version", self.protocol.api_version);
        return self.protocol.send(&req, .{});
    }

    /// Original 0.1.0 unconditional raw-response DELETE retained with its
    /// exact signature.
    pub fn deleteEntity(
        self: *TableClient,
        allocator: std.mem.Allocator,
        partition_key: []const u8,
        row_key: []const u8,
    ) !core.http.Response {
        return self.deleteEntityRaw(allocator, partition_key, row_key);
    }
};

/// No-credential table clients accept both an account SAS URL and the full
/// table SAS URL returned by `getTableSasUrl`.
fn serviceEndpointFromSasUrl(
    allocator: std.mem.Allocator,
    complete_sas_url: []const u8,
    table_name: []const u8,
) ![]u8 {
    var normalized = try request.NormalizedEndpoint.init(allocator, complete_sas_url);
    defer normalized.deinit();
    const signed_table_name = try tableNameFromSasQuery(allocator, normalized.raw_query);
    defer if (signed_table_name) |value| allocator.free(value);

    var base = normalized.base_url;
    if (signed_table_name) |value| {
        if (!std.ascii.eqlIgnoreCase(value, table_name))
            return error.SasTableNameMismatch;
        const slash = std.mem.lastIndexOfScalar(u8, normalized.base_url, '/') orelse
            return error.InvalidTableSasUrl;
        if (!std.ascii.eqlIgnoreCase(normalized.base_url[slash + 1 ..], table_name))
            return error.InvalidTableSasUrl;
        base = normalized.base_url[0..slash];
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}?{s}",
        .{ base, normalized.raw_query },
    );
}

fn tableNameFromSasQuery(
    allocator: std.mem.Allocator,
    raw_query: []const u8,
) !?[]u8 {
    var result: ?[]u8 = null;
    errdefer if (result) |value| allocator.free(value);
    var parameters = std.mem.splitScalar(u8, raw_query, '&');
    while (parameters.next()) |parameter| {
        const equal = std.mem.indexOfScalar(u8, parameter, '=') orelse parameter.len;
        if (!try queryComponentEqlIgnoreCase(parameter[0..equal], "tn")) continue;
        if (result != null) return error.DuplicateSasTableName;
        const raw_value = if (equal < parameter.len) parameter[equal + 1 ..] else "";
        const value = try decodeQueryComponent(allocator, raw_value);
        errdefer allocator.free(value);
        request.validateTableName(value) catch return error.InvalidSasTableName;
        result = value;
    }
    return result;
}

fn queryComponentEqlIgnoreCase(raw: []const u8, expected: []const u8) !bool {
    var raw_index: usize = 0;
    var expected_index: usize = 0;
    while (raw_index < raw.len) : (expected_index += 1) {
        const byte = try decodeQueryByte(raw, &raw_index);
        if (expected_index >= expected.len or
            std.ascii.toLower(byte) != std.ascii.toLower(expected[expected_index]))
        {
            return false;
        }
    }
    return expected_index == expected.len;
}

fn decodeQueryComponent(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(allocator);
    var index: usize = 0;
    while (index < raw.len)
        try decoded.append(allocator, try decodeQueryByte(raw, &index));
    return decoded.toOwnedSlice(allocator);
}

fn decodeQueryByte(raw: []const u8, index: *usize) !u8 {
    const byte = raw[index.*];
    if (byte == '+') {
        index.* += 1;
        return ' ';
    }
    if (byte != '%') {
        index.* += 1;
        return byte;
    }
    if (index.* + 2 >= raw.len) return error.InvalidSasQueryEncoding;
    const high = queryHexDigit(raw[index.* + 1]) orelse
        return error.InvalidSasQueryEncoding;
    const low = queryHexDigit(raw[index.* + 2]) orelse
        return error.InvalidSasQueryEncoding;
    index.* += 3;
    return high * 16 + low;
}

fn queryHexDigit(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

fn validateEntityValue(comptime T: type, value: T) !void {
    if (T == entity.DynamicEntity) {
        try request.validateEntityKey(value.partition_key);
        try request.validateEntityKey(value.row_key);
        if (value.properties.count() > entity.max_custom_properties)
            return error.TooManyProperties;
        var iterator = value.properties.iterator();
        while (iterator.next()) |entry| try entity.validatePropertyName(entry.key_ptr.*);
        return;
    }
    _ = entity_codec.EntityCodec(T);
    try request.validateEntityKey(@field(value, "partition_key"));
    try request.validateEntityKey(@field(value, "row_key"));
}

fn adaptEntityResponse(comptime T: type, raw: anytype) !responses.EntityResponse(T) {
    const arena_allocator = raw.arena.allocator();
    const body = raw.body orelse return error.MissingRawResponseBody;
    const decoded: T = if (T == entity.DynamicEntity)
        try entity_codec.dynamicFromJson(arena_allocator, body)
    else
        try entity_codec.EntityCodec(T).deserialize(arena_allocator, body);
    const etag = raw.headers.getFirst("ETag") orelse return error.MissingResponseHeader;
    return .{
        .value = decoded,
        .etag = etag,
        .status = raw.status,
        .headers = entityHeaders(&raw.headers),
        .metadata = try entityMetadata(arena_allocator, body),
        .raw_headers = raw.headers,
        .arena = raw.arena,
        .allocator = raw.allocator,
    };
}

fn entityHeaders(headers: *const responses.RawHeaders) responses.EntityHeaders {
    return .{
        .request_id = headers.getFirst("x-ms-request-id"),
        .client_request_id = headers.getFirst("x-ms-client-request-id"),
        .date = headers.getFirst("Date"),
        .api_version = headers.getFirst("x-ms-version"),
        .content_type = headers.getFirst("Content-Type"),
        .preference_applied = headers.getFirst("Preference-Applied"),
    };
}

fn entityMetadata(
    allocator: std.mem.Allocator,
    body: []const u8,
) !responses.EntityMetadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.ExpectedObject,
    };
    return .{
        .metadata = try copyJsonString(allocator, object.get("odata.metadata")),
        .type_name = try copyJsonString(allocator, object.get("odata.type")),
        .id = try copyJsonString(allocator, object.get("odata.id")),
        .etag = try copyJsonString(allocator, object.get("odata.etag")),
        .edit_link = try copyJsonString(allocator, object.get("odata.editLink")),
    };
}

fn copyJsonString(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const item = value orelse return null;
    return switch (item) {
        .string => |string| try allocator.dupe(u8, string),
        else => error.InvalidODataMetadata,
    };
}

const AllocationSizeLimiter = struct {
    child: std.mem.Allocator,
    max_allocation: usize,
    rejected_allocations: usize = 0,

    fn allocator(self: *AllocationSizeLimiter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *AllocationSizeLimiter = @ptrCast(@alignCast(context));
        if (len > self.max_allocation) {
            self.rejected_allocations += 1;
            return null;
        }
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *AllocationSizeLimiter = @ptrCast(@alignCast(context));
        if (new_len > self.max_allocation) {
            self.rejected_allocations += 1;
            return false;
        }
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *AllocationSizeLimiter = @ptrCast(@alignCast(context));
        if (new_len > self.max_allocation) {
            self.rejected_allocations += 1;
            return null;
        }
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *AllocationSizeLimiter = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

const TestCredential = struct {
    calls: usize = 0,
    credential: core.credentials.TokenCredential = .{ .getTokenFn = &getToken },

    fn asCredential(self: *TestCredential) *core.credentials.TokenCredential {
        return &self.credential;
    }

    fn getToken(
        credential: *core.credentials.TokenCredential,
        _: core.credentials.TokenRequestContext,
        _: core.context.Context,
        _: core.http.HttpRuntime,
    ) anyerror!core.credentials.AccessToken {
        const self: *TestCredential = @alignCast(
            @fieldParentPtr("credential", credential),
        );
        self.calls += 1;
        return .{ .token = "table-token", .expires_on = std.math.maxInt(i64) };
    }
};

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

const FailingMutationTransport = struct {
    calls: usize = 0,

    const vtable: core.http.HttpTransport.VTable = .{ .send = &send };

    fn asTransport(self: *FailingMutationTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(
        context: *anyopaque,
        _: *core.http.Request,
    ) anyerror!core.http.Response {
        const self: *FailingMutationTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        return error.InjectedTransportFailure;
    }
};

fn moveClient(client: TableClient) TableClient {
    return client;
}

const TestEntity = struct {
    partition_key: []const u8,
    row_key: []const u8,
    name: []const u8,
    active: bool,
    count: edm.EdmInt64,
    small_count: i32,
    ratio: f64,
    data: edm.EdmBinary,
    created: edm.EdmDateTime,
    id: edm.EdmGuid,
    timestamp: ?edm.EdmDateTime = null,
};

const edm = @import("edm.zig");

const entity_response_headers = &[_]core.http.MockTransport.HeaderPair{
    .{ .name = "ETag", .value = "W/\"datetime'2026-07-26T00%3A00%3A00Z'\"" },
    .{ .name = "x-ms-version", .value = "2019-02-02" },
    .{ .name = "x-ms-request-id", .value = "request-id" },
    .{ .name = "x-ms-client-request-id", .value = "client-id" },
    .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Preference-Applied", .value = "return-content" },
};

const mutation_response_headers = &[_]core.http.MockTransport.HeaderPair{
    .{ .name = "ETag", .value = "W/\"updated\"" },
    .{ .name = "x-ms-version", .value = "2019-02-02" },
    .{ .name = "x-ms-request-id", .value = "mutation-request" },
    .{ .name = "x-ms-client-request-id", .value = "mutation-client" },
    .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
};

const typed_entity_json =
    \\{"odata.metadata":"https://account/$metadata#Table123/@Element","odata.type":"account.Table123","odata.id":"https://account/Table123(PartitionKey='p',RowKey='r')","odata.etag":"W/\"tag\"","odata.editLink":"Table123(PartitionKey='p',RowKey='r')","PartitionKey":"p","RowKey":"r","name":"widget","active":true,"count":"9223372036854775807","count@odata.type":"Edm.Int64","small_count":7,"ratio":1.5,"data":"aGk=","data@odata.type":"Edm.Binary","created":"2026-07-26T00:00:00Z","created@odata.type":"Edm.DateTime","id":"01234567-89ab-cdef-0123-456789abcdef","id@odata.type":"Edm.Guid","Timestamp":"2026-07-26T00:00:01Z"}
;

fn testEntityValue() !TestEntity {
    return .{
        .partition_key = "p",
        .row_key = "r",
        .name = "widget",
        .active = true,
        .count = .{ .value = std.math.maxInt(i64) },
        .small_count = 7,
        .ratio = 1.5,
        .data = .{ .bytes = "hi" },
        .created = try edm.EdmDateTime.init("2026-07-26T00:00:00Z"),
        .id = try edm.EdmGuid.init("01234567-89ab-cdef-0123-456789abcdef"),
    };
}

test "typed and dynamic add share EDM wire behavior and preserve metadata" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 201, typed_entity_json);
    defer mock.deinit();
    mock.response_headers_list = entity_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
        },
    );
    defer client.deinit();

    var typed = try client.addEntity(allocator, try testEntityValue(), .{
        .protocol = .{ .metadata = .full_metadata, .client_request_id = "client-id" },
    });
    defer typed.deinit();
    try std.testing.expectEqual(@as(u16, 201), typed.status);
    try std.testing.expectEqualStrings("widget", typed.value.name);
    try std.testing.expectEqual(std.math.maxInt(i64), typed.value.count.value);
    try std.testing.expectEqualStrings("hi", typed.value.data.bytes);
    try std.testing.expectEqualStrings(entity_response_headers[0].value, typed.etag);
    try std.testing.expectEqualStrings("account.Table123", typed.metadata.type_name.?);
    try std.testing.expectEqualStrings("request-id", typed.headers.request_id.?);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"count@odata.type\":\"Edm.Int64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "odata%3Dfullmetadata") != null);

    var dynamic = try entity.DynamicEntity.init(allocator, "p", "r");
    defer dynamic.deinit();
    try dynamic.put("name", .{ .string = "widget" });
    try dynamic.put("count", .{ .int64 = .{ .value = std.math.maxInt(i64) } });
    mock.response_body = typed_entity_json;
    var dynamic_response = try client.addEntity(allocator, dynamic, .{});
    defer dynamic_response.deinit();
    try std.testing.expectEqualStrings("widget", dynamic_response.value.properties.get("name").?.string);
    try std.testing.expectEqual(std.math.maxInt(i64), dynamic_response.value.properties.get("count").?.int64.value);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"count@odata.type\":\"Edm.Int64\"") != null);
}

test "typed and dynamic add update and upsert payloads omit Timestamp exactly" {
    const ParityEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        name: []const u8,
        timestamp: ?edm.EdmDateTime = null,
    };
    const allocator = std.testing.allocator;
    const expected = "{\"PartitionKey\":\"p\",\"RowKey\":\"r\",\"name\":\"widget\"}";
    var mock = core.http.MockTransport.init(allocator, 201, expected);
    defer mock.deinit();
    mock.response_headers_list = entity_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
        },
    );
    defer client.deinit();
    const timestamp = try edm.EdmDateTime.init("2026-07-26T00:00:00Z");
    const typed = ParityEntity{
        .partition_key = "p",
        .row_key = "r",
        .name = "widget",
        .timestamp = timestamp,
    };
    var dynamic = try entity.DynamicEntity.init(allocator, "p", "r");
    defer dynamic.deinit();
    try dynamic.put("name", .{ .string = "widget" });
    try dynamic.setTimestamp(timestamp);

    var typed_add = try client.addEntity(allocator, typed, .{});
    typed_add.deinit();
    try std.testing.expectEqualStrings(expected, mock.last_body.?);
    var dynamic_add = try client.addEntity(allocator, dynamic, .{});
    dynamic_add.deinit();
    try std.testing.expectEqualStrings(expected, mock.last_body.?);

    mock.response_status = 204;
    mock.response_body = "";
    mock.response_headers_list = mutation_response_headers;
    var typed_update = try client.updateEntity(allocator, typed, .{});
    typed_update.deinit();
    try std.testing.expectEqualStrings(expected, mock.last_body.?);
    var dynamic_update = try client.updateEntity(allocator, dynamic, .{});
    dynamic_update.deinit();
    try std.testing.expectEqualStrings(expected, mock.last_body.?);

    var typed_upsert = try client.upsertEntity(allocator, typed, .{});
    typed_upsert.deinit();
    try std.testing.expectEqualStrings(expected, mock.last_body.?);
    var dynamic_upsert = try client.upsertEntity(allocator, dynamic, .{});
    dynamic_upsert.deinit();
    try std.testing.expectEqualStrings(expected, mock.last_body.?);
}

test "dynamic read retains Timestamp but read-then-update omits it" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"PartitionKey":"p","RowKey":"r","name":"server","Timestamp":"2026-07-26T00:00:00Z"}
    );
    defer mock.deinit();
    mock.response_headers_list = entity_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
        },
    );
    defer client.deinit();

    var read = try client.getEntityAs(entity.DynamicEntity, allocator, "p", "r", .{});
    defer read.deinit();
    try std.testing.expectEqualStrings(
        "2026-07-26T00:00:00Z",
        read.value.timestamp.?.value,
    );

    mock.response_status = 204;
    mock.response_body = "";
    mock.response_headers_list = mutation_response_headers;
    var updated = try client.updateEntity(allocator, read.value, .{});
    updated.deinit();
    try std.testing.expectEqualStrings(
        "{\"PartitionKey\":\"p\",\"RowKey\":\"r\",\"name\":\"server\"}",
        mock.last_body.?,
    );
}

test "get supports full minimal and no metadata responses" {
    const SimpleEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        name: []const u8,
        timestamp: ?edm.EdmDateTime = null,
    };
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"odata.metadata":"meta","odata.type":"type","PartitionKey":"p","RowKey":"r","name":"full"}
    );
    defer mock.deinit();
    mock.response_headers_list = entity_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
        },
    );
    defer client.deinit();

    var full = try client.getEntityAs(SimpleEntity, allocator, "p", "r", .{
        .protocol = .{ .metadata = .full_metadata },
    });
    defer full.deinit();
    try std.testing.expectEqualStrings("meta", full.metadata.metadata.?);
    try std.testing.expectEqualStrings("type", full.metadata.type_name.?);

    mock.response_body =
        \\{"odata.metadata":"meta","PartitionKey":"p","RowKey":"r","name":"minimal"}
    ;
    var minimal = try client.getEntityAs(SimpleEntity, allocator, "p", "r", .{
        .protocol = .{ .metadata = .minimal_metadata },
    });
    defer minimal.deinit();
    try std.testing.expectEqualStrings("minimal", minimal.value.name);
    try std.testing.expect(minimal.metadata.type_name == null);

    mock.response_body =
        \\{"PartitionKey":"p","RowKey":"r","name":"none"}
    ;
    var none = try client.getEntityAs(SimpleEntity, allocator, "p", "r", .{
        .protocol = .{ .metadata = .no_metadata },
    });
    defer none.deinit();
    try std.testing.expectEqualStrings("none", none.value.name);
    try std.testing.expect(none.metadata.metadata == null);
}

test "conditional delete preserves service failure and wildcard success" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 412,
        \\{"code":"UpdateConditionNotSatisfied","message":"etag mismatch"}
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-ms-request-id", .value = "condition-request" },
    };
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
        },
    );
    defer client.deinit();

    var failure = try client.deleteEntityResult(allocator, "p", "r", .{ .if_match = "W/\"old\"" });
    defer failure.deinit(allocator);
    switch (failure) {
        .failure => |table_error| {
            try std.testing.expectEqual(@as(u16, 412), table_error.status);
            try std.testing.expectEqualStrings("UpdateConditionNotSatisfied", table_error.code);
        },
        .success => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("W/\"old\"", mock.last_headers.get("If-Match").?);

    mock.response_status = 204;
    mock.response_body = "";
    mock.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
    };
    var success = try client.deleteEntityWithOptions(allocator, "p", "r", .{});
    defer success.deinit();
    try std.testing.expectEqual(@as(u16, 204), success.status);
    try std.testing.expectEqualStrings("*", mock.last_headers.get("If-Match").?);
}

test "typed and dynamic update and upsert use generated merge and replace operations" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 204, "");
    defer mock.deinit();
    mock.response_headers_list = mutation_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
        },
    );
    defer client.deinit();

    var typed = try client.updateEntity(allocator, try testEntityValue(), .{
        .mode = .merge,
        .if_match = "W/\"current\"",
        .protocol = .{ .client_request_id = "mutation-client" },
    });
    defer typed.deinit();
    try std.testing.expectEqual(@as(u16, 204), typed.status);
    try std.testing.expectEqualStrings("W/\"updated\"", typed.etag);
    try std.testing.expectEqualStrings("mutation-request", typed.headers.request_id.?);
    try std.testing.expectEqual(core.http.Method.PATCH, mock.last_method.?);
    try std.testing.expectEqualStrings("W/\"current\"", mock.last_headers.get("If-Match").?);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"count@odata.type\":\"Edm.Int64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"data@odata.type\":\"Edm.Binary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"created@odata.type\":\"Edm.DateTime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"id@odata.type\":\"Edm.Guid\"") != null);

    var dynamic = try entity.DynamicEntity.init(allocator, "p", "r");
    defer dynamic.deinit();
    try dynamic.put("name", .{ .string = "widget" });
    try dynamic.put("active", .{ .boolean = true });
    try dynamic.put("count", .{ .int64 = .{ .value = std.math.maxInt(i64) } });
    try dynamic.put("small_count", .{ .int32 = 7 });
    try dynamic.put("ratio", .{ .float64 = 1.5 });
    try dynamic.put("data", .{ .binary = .{ .bytes = "hi" } });
    try dynamic.put("created", .{ .datetime = try edm.EdmDateTime.init("2026-07-26T00:00:00Z") });
    try dynamic.put("id", .{ .guid = try edm.EdmGuid.init("01234567-89ab-cdef-0123-456789abcdef") });
    try dynamic.put("nullable", .null);
    var upserted = try client.upsertEntity(allocator, dynamic, .{ .mode = .replace });
    defer upserted.deinit();
    try std.testing.expectEqual(core.http.Method.PUT, mock.last_method.?);
    try std.testing.expect(mock.last_headers.get("If-Match") == null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"count@odata.type\":\"Edm.Int64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"data@odata.type\":\"Edm.Binary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"created@odata.type\":\"Edm.DateTime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"id@odata.type\":\"Edm.Guid\"") != null);
}

test "update existence and ETag failures remain structured while upsert creates" {
    const PartialEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        changed: []const u8,
    };
    const value = PartialEntity{ .partition_key = "p", .row_key = "r", .changed = "new" };
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 404,
        \\{"code":"ResourceNotFound","message":"missing"}
    );
    defer mock.deinit();
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-ms-request-id", .value = "missing-request" },
    };
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
        },
    );
    defer client.deinit();

    var missing = try client.updateEntityResult(allocator, value, .{});
    defer missing.deinit(allocator);
    switch (missing) {
        .failure => |table_error| {
            try std.testing.expectEqual(@as(u16, 404), table_error.status);
            try std.testing.expectEqualStrings("ResourceNotFound", table_error.code);
        },
        .success => return error.TestUnexpectedResult,
    }

    mock.response_status = 412;
    mock.response_body =
        \\{"code":"UpdateConditionNotSatisfied","message":"stale"}
    ;
    var stale = try client.updateEntityResult(allocator, value, .{
        .if_match = "W/\"stale\"",
    });
    defer stale.deinit(allocator);
    switch (stale) {
        .failure => |table_error| {
            try std.testing.expectEqual(@as(u16, 412), table_error.status);
            try std.testing.expectEqualStrings("UpdateConditionNotSatisfied", table_error.code);
        },
        .success => return error.TestUnexpectedResult,
    }

    mock.response_status = 204;
    mock.response_body = "";
    mock.response_headers_list = mutation_response_headers;
    var matching = try client.updateEntity(allocator, value, .{
        .mode = .replace,
        .if_match = "W/\"matching\"",
    });
    matching.deinit();
    try std.testing.expectEqualStrings("W/\"matching\"", mock.last_headers.get("If-Match").?);

    var created = try client.upsertEntity(allocator, value, .{ .mode = .merge });
    created.deinit();
    try std.testing.expectEqual(core.http.Method.PATCH, mock.last_method.?);
    try std.testing.expect(mock.last_headers.get("If-Match") == null);
}

test "merge preserves omitted properties and replace removes them by wire operation" {
    const PartialEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        changed: []const u8,
    };
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 204, "");
    defer mock.deinit();
    mock.response_headers_list = mutation_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
        },
    );
    defer client.deinit();
    const partial = PartialEntity{ .partition_key = "p", .row_key = "r", .changed = "new" };

    var merged = try client.upsertEntity(allocator, partial, .{ .mode = .merge });
    merged.deinit();
    try std.testing.expectEqual(core.http.Method.PATCH, mock.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "preserved") == null);

    var replaced = try client.upsertEntity(allocator, partial, .{ .mode = .replace });
    replaced.deinit();
    try std.testing.expectEqual(core.http.Method.PUT, mock.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "preserved") == null);
}

test "conditional mutation retries before transport and classifies ambiguity after entry" {
    const SimpleEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        name: []const u8,
    };
    const value = SimpleEntity{ .partition_key = "p", .row_key = "r", .name = "updated" };
    const allocator = std.testing.allocator;

    var mock = core.http.MockTransport.init(allocator, 204, "");
    defer mock.deinit();
    mock.response_headers_list = mutation_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
            .options = .{ .retry = .{
                .max_retries = 2,
                .initial_delay_ms = 0,
                .max_delay_ms = 0,
            } },
        },
    );
    defer client.deinit();
    var before_transport = PreTransportOncePolicy{};
    var response = try client.updateEntity(allocator, value, .{
        .if_match = "W/\"exact\"",
        .protocol = .{ .policies = &.{&before_transport.policy} },
    });
    response.deinit();
    try std.testing.expectEqual(@as(usize, 2), before_transport.calls);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    var exhausted = AlwaysFailPreTransportPolicy{};
    try std.testing.expectError(
        error.InjectedPreTransportFailure,
        client.updateEntityResult(allocator, value, .{
            .if_match = "W/\"exact\"",
            .protocol = .{ .policies = &.{&exhausted.policy} },
        }),
    );
    try std.testing.expectEqual(@as(usize, 3), exhausted.calls);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    var expired = PreTransportOncePolicy{};
    try std.testing.expectError(
        error.OperationTimedOut,
        client.updateEntityResult(allocator, value, .{
            .if_match = "W/\"exact\"",
            .protocol = .{
                .operation_timeout_ms = 0,
                .policies = &.{&expired.policy},
            },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), expired.calls);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    var tight_mock = core.http.MockTransport.init(allocator, 204, "");
    defer tight_mock.deinit();
    tight_mock.response_headers_list = mutation_response_headers;
    var tight_client = try TableClient.init(
        allocator,
        testingRuntime(tight_mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
            .options = .{
                .operation_timeout_ms = 1,
                .retry = .{
                    .max_retries = 2,
                    .initial_delay_ms = 100,
                    .max_delay_ms = 100,
                },
            },
        },
    );
    defer tight_client.deinit();
    var tight = AlwaysFailPreTransportPolicy{};
    try std.testing.expectError(
        error.OperationTimedOut,
        tight_client.updateEntityResult(allocator, value, .{
            .if_match = "W/\"exact\"",
            .protocol = .{ .policies = &.{&tight.policy} },
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), tight.calls);
    try std.testing.expectEqual(@as(usize, 0), tight_mock.call_count);

    var failing = FailingMutationTransport{};
    var conditional_client = try TableClient.init(
        allocator,
        testingRuntime(failing.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
            .options = .{ .retry = .{
                .max_retries = 2,
                .initial_delay_ms = 0,
                .max_delay_ms = 0,
            } },
        },
    );
    defer conditional_client.deinit();
    try std.testing.expectError(
        error.MutationOutcomeUnknown,
        conditional_client.updateEntityResult(allocator, value, .{
            .if_match = "W/\"exact\"",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), failing.calls);

    var safe_failing = FailingMutationTransport{};
    var safe_client = try TableClient.init(
        allocator,
        testingRuntime(safe_failing.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" },
            .table_name = "Table123",
            .options = .{ .retry = .{
                .max_retries = 2,
                .initial_delay_ms = 0,
                .max_delay_ms = 0,
            } },
        },
    );
    defer safe_client.deinit();
    try std.testing.expectError(
        error.MutationOutcomeUnknown,
        safe_client.upsertEntityResult(allocator, value, .{}),
    );
    try std.testing.expectEqual(@as(usize, 3), safe_failing.calls);
}

test "entity constraints and malformed success fail locally" {
    const SimpleEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        name: []const u8,
    };
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{");
    defer mock.deinit();
    mock.response_headers_list = entity_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" }, .table_name = "Table123" },
    );
    defer client.deinit();

    try std.testing.expectError(
        error.InvalidEntityKey,
        client.addEntityResult(allocator, SimpleEntity{
            .partition_key = "bad/key",
            .row_key = "r",
            .name = "invalid",
        }, .{}),
    );
    try std.testing.expectError(
        error.InvalidIfMatch,
        client.deleteEntityResult(allocator, "p", "r", .{ .if_match = "" }),
    );
    try std.testing.expectError(
        error.InvalidEntityKey,
        client.updateEntityResult(allocator, SimpleEntity{
            .partition_key = "bad/key",
            .row_key = "r",
            .name = "invalid",
        }, .{}),
    );
    try std.testing.expectError(
        error.InvalidIfMatch,
        client.updateEntityResult(allocator, SimpleEntity{
            .partition_key = "p",
            .row_key = "r",
            .name = "invalid",
        }, .{ .if_match = "" }),
    );
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);

    if (client.getEntityResult(SimpleEntity, allocator, "p", "r", .{})) |result| {
        var unexpected = result;
        unexpected.deinit(allocator);
        return error.TestExpectedMalformedPayload;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    mock.response_status = 204;
    mock.response_body = "";
    mock.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
    };
    try std.testing.expectError(
        error.MissingResponseHeader,
        client.upsertEntityResult(allocator, SimpleEntity{
            .partition_key = "p",
            .row_key = "r",
            .name = "malformed",
        }, .{}),
    );
}

test "entity query pager survives moving its source client" {
    const SimpleEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        name: []const u8,
    };
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"value":[{"PartitionKey":"p","RowKey":"r","name":"moved"}]}
    );
    defer mock.deinit();
    mock.response_headers_list = entity_response_headers;
    var table_client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=secret" }, .table_name = "Table123" },
    );
    var entity_pager = try table_client.queryEntities(SimpleEntity, allocator, .{});
    errdefer entity_pager.deinit();

    var moved_client = moveClient(table_client);
    table_client = undefined;
    defer moved_client.deinit();

    const page = (try entity_pager.next()).?;
    try std.testing.expectEqualStrings("moved", page.values[0].name);
    entity_pager.deinit();
}

test "dynamic entity enforces 252 custom properties regardless of timestamp" {
    const allocator = std.testing.allocator;
    var value = try entity.DynamicEntity.init(allocator, "p", "r");
    defer value.deinit();
    try value.setTimestamp(try edm.EdmDateTime.init("2026-07-26T00:00:00Z"));

    var name_buffer: [32]u8 = undefined;
    for (0..entity.max_custom_properties) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "property_{d}", .{index});
        try value.put(name, .null);
    }
    try validateEntityValue(entity.DynamicEntity, value);

    try value.put("overflow_property", .null);
    try std.testing.expectError(
        error.TooManyProperties,
        validateEntityValue(entity.DynamicEntity, value),
    );
}

test "original raw entity method signatures remain source compatible" {
    const RawKeyMethod = fn (
        *TableClient,
        std.mem.Allocator,
        []const u8,
        []const u8,
    ) anyerror!core.http.Response;
    const RawCreateMethod = fn (
        *TableClient,
        std.mem.Allocator,
        entity.TableEntity,
    ) anyerror!core.http.Response;
    const get_fn: *const RawKeyMethod = &TableClient.getEntity;
    const delete_fn: *const RawKeyMethod = &TableClient.deleteEntity;
    const create_fn: *const RawCreateMethod = &TableClient.createEntity;

    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=compatibility-secret" }, .table_name = "Table123" },
    );
    defer client.deinit();

    var get_response = try get_fn(&client, allocator, "p", "r");
    get_response.deinit();
    try std.testing.expectEqual(core.http.Method.GET, mock.last_method.?);

    mock.response_status = 201;
    var old_entity = entity.TableEntity.init(allocator, "p", "r");
    defer old_entity.deinit();
    try old_entity.put("Name", "old");
    var create_response = try create_fn(&client, allocator, old_entity);
    create_response.deinit();
    try std.testing.expectEqual(core.http.Method.POST, mock.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"Name\":\"old\"") != null);

    mock.response_status = 204;
    var delete_response = try delete_fn(&client, allocator, "p", "r");
    delete_response.deinit();
    try std.testing.expectEqual(core.http.Method.DELETE, mock.last_method.?);
    try std.testing.expectEqualStrings("*", mock.last_headers.get("If-Match").?);
}

test "raw calls do not copy large response bodies while typed adapters capture" {
    const SimpleEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        name: []const u8,
    };
    const allocator = std.testing.allocator;
    const large_body = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(large_body);
    @memset(large_body, 'x');

    var mock = core.http.MockTransport.init(allocator, 200, large_body);
    defer mock.deinit();
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=no-copy-secret" }, .table_name = "Table123" },
    );
    defer client.deinit();
    var limiter = AllocationSizeLimiter{
        .child = allocator,
        .max_allocation = 128 * 1024,
    };
    const limited = limiter.allocator();

    var get_response = try client.getEntity(limited, "p", "r");
    defer get_response.deinit();
    try std.testing.expectEqual(@as(usize, large_body.len), get_response.body.len);
    try std.testing.expectEqual(@as(usize, 0), limiter.rejected_allocations);

    mock.response_status = 500;
    var old_entity = entity.TableEntity.init(allocator, "p", "r");
    defer old_entity.deinit();
    var create_response = try client.createEntity(limited, old_entity);
    defer create_response.deinit();
    try std.testing.expectEqual(@as(u16, 500), create_response.status_code);
    try std.testing.expectEqualSlices(u8, large_body, create_response.body);
    try std.testing.expectEqual(@as(usize, 0), limiter.rejected_allocations);

    var delete_response = try client.deleteEntity(limited, "p", "r");
    defer delete_response.deinit();
    try std.testing.expectEqual(@as(u16, 500), delete_response.status_code);
    try std.testing.expectEqualSlices(u8, large_body, delete_response.body);
    try std.testing.expectEqual(@as(usize, 0), limiter.rejected_allocations);

    mock.response_status = 200;
    mock.response_headers_list = entity_response_headers;
    try std.testing.expectError(
        error.OutOfMemory,
        client.getEntityResult(SimpleEntity, limited, "p", "r", .{}),
    );
    try std.testing.expect(limiter.rejected_allocations > 0);

    mock.response_status = 412;
    mock.response_body =
        \\{"code":"UpdateConditionNotSatisfied","message":"etag mismatch"}
    ;
    mock.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-ms-request-id", .value = "captured-error" },
    };
    var result = try client.deleteEntityResult(limited, "p", "r", .{ .if_match = "W/\"old\"" });
    defer result.deinit(limited);
    switch (result) {
        .failure => |table_error| {
            try std.testing.expectEqualStrings("UpdateConditionNotSatisfied", table_error.code);
            try std.testing.expectEqualStrings("captured-error", table_error.request_id.?);
        },
        .success => return error.TestUnexpectedResult,
    }
}

fn testEntityCrudAllocationFailures(allocator: std.mem.Allocator) !void {
    const SimpleEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        name: []const u8,
    };
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"PartitionKey":"p","RowKey":"r","name":"owned"}
    );
    defer mock.deinit();
    mock.response_headers_list = entity_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=allocation-secret" },
            .table_name = "Table123",
            .options = .{ .retry = .{ .max_retries = 0 } },
        },
    );
    defer client.deinit();
    var response = try client.getEntityAs(SimpleEntity, allocator, "p", "r", .{});
    response.deinit();
}

test "entity CRUD allocation failure paths are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testEntityCrudAllocationFailures,
        .{},
    );
}

fn testEntityMutationAllocationFailures(allocator: std.mem.Allocator) !void {
    const SimpleEntity = struct {
        partition_key: []const u8,
        row_key: []const u8,
        name: []const u8,
    };
    var mock = core.http.MockTransport.init(allocator, 204, "");
    defer mock.deinit();
    mock.response_headers_list = mutation_response_headers;
    var client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1&sig=allocation-secret" },
            .table_name = "Table123",
            .options = .{ .retry = .{ .max_retries = 0 } },
        },
    );
    defer client.deinit();
    var response = client.upsertEntity(allocator, SimpleEntity{
        .partition_key = "p",
        .row_key = "r",
        .name = "owned",
    }, .{ .mode = .replace }) catch |err| {
        // The failing allocator can trip the mock after transport entry; the
        // production API correctly reports that outcome as ambiguous.
        if (err == error.MutationOutcomeUnknown) return error.OutOfMemory;
        return err;
    };
    response.deinit();
}

test "entity mutation allocation failure paths are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testEntityMutationAllocationFailures,
        .{},
    );
}

test "token client survives moves and applies all client options" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var credential = TestCredential{};

    var table_client = moveClient(try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://myaccount.table.core.windows.net", .credential = credential.asCredential() } },
            .table_name = "MyTable",
            .options = .{
                .api_version = "2020-test",
                .telemetry = .{ .application_id = "my-app/1.0" },
                .client_request_id = "fixed-request-id",
                .operation_timeout_ms = 4321,
            },
        },
    ));
    defer table_client.deinit();
    const stable_address = table_client.pipeline_state;
    table_client = moveClient(table_client);
    try std.testing.expect(table_client.pipeline_state == stable_address);

    var response = try table_client.getEntityRaw(allocator, "pk1", "rk1");
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expect(mock.last_headers.get("Authorization") != null);
    try std.testing.expectEqualStrings(
        "fixed-request-id",
        mock.last_headers.get("x-ms-client-request-id").?,
    );
    try std.testing.expectEqualStrings(
        "my-app/1.0 azsdk-zig-data-tables/0.3.0",
        mock.last_headers.get("User-Agent").?,
    );
    try std.testing.expectEqualStrings(
        "2020-test",
        mock.last_headers.get("x-ms-version").?,
    );
    try std.testing.expectEqual(@as(?u64, 4321), mock.last_operation_timeout_ms);
}

fn testAllocationFailures(allocator: std.mem.Allocator) !void {
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var credential = TestCredential{};
    var table_client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://myaccount.table.core.windows.net", .credential = credential.asCredential() } },
            .table_name = "MyTable",
            .options = .{
                .telemetry = .{ .application_id = "allocation-test" },
                .client_request_id = "allocation-request-id",
            },
        },
    );
    table_client.deinit();
}

test "token client construction failure paths are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testAllocationFailures,
        .{},
    );
}

test "token client rejects HTTP before credential and transport use" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var credential = TestCredential{};

    try std.testing.expectError(
        error.TokenAuthenticationRequiresHttps,
        TableClient.init(
            allocator,
            testingRuntime(mock.asTransport()),
            .{
                .authentication = .{ .token = .{ .endpoint = "http://127.0.0.1:10002/devstoreaccount1", .credential = credential.asCredential() } },
                .table_name = "MyTable",
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), credential.calls);
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "token client accepts HTTPS custom private endpoint" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var credential = TestCredential{};

    var table_client = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "HTTPS://tables.internal.example:8443/private/path", .credential = credential.asCredential() } },
            .table_name = "MyTable",
        },
    );
    defer table_client.deinit();

    try std.testing.expectEqualStrings(
        "HTTPS://tables.internal.example:8443/private/path",
        table_client.protocol.endpoint.base_url,
    );
    try std.testing.expectEqual(@as(usize, 0), credential.calls);
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "Shared Key and SAS constructors have isolated authentication behavior" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var credential = try auth.SharedKeyCredential.init(
        allocator,
        "account",
        "YWNjb3VudC1rZXk=",
    );
    defer credential.deinit();

    var shared = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .shared_key = .{ .endpoint = "https://account.table.core.windows.net", .credential = &credential } },
            .table_name = "Table123",
        },
    );
    defer shared.deinit();
    var shared_response = try shared.getEntityRaw(allocator, "pk", "rk");
    shared_response.deinit();
    try std.testing.expect(std.mem.startsWith(
        u8,
        mock.last_headers.get("Authorization").?,
        "SharedKeyLite account:",
    ));
    try std.testing.expect(mock.last_headers.get("x-ms-date") != null);

    var sas = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1%2F2&sig=a+b%3D&sp=r" }, .table_name = "Table123" },
    );
    defer sas.deinit();
    var sas_response = try sas.getEntityRaw(allocator, "pk", "rk");
    sas_response.deinit();
    try std.testing.expect(mock.last_headers.get("Authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "sv=1%2F2&sig=a+b%3D&sp=r") != null);
}

fn testSasOperationAllocationFailures(allocator: std.mem.Allocator) !void {
    var mock = core.http.MockTransport.init(allocator, 200, "{}");
    defer mock.deinit();
    var sas = try TableClient.init(
        allocator,
        testingRuntime(mock.asTransport()),
        .{
            .authentication = .{ .sas_url = "https://account.table.core.windows.net/Table123?sv=1%2F2&sig=allocation+SECRET%3D&sp=r&tn=Table123" },
            .table_name = "Table123",
            .options = .{ .retry = .{ .max_retries = 0 } },
        },
    );
    defer sas.deinit();
    var response = try sas.getEntityRaw(allocator, "pk", "rk");
    response.deinit();
}

test "SAS operation allocation failure paths are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testSasOperationAllocationFailures,
        .{},
    );
}

test "table SAS URL is exact and full URL initializes a credential-free client" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    var credential = try auth.SharedKeyCredential.init(
        allocator,
        "fakeaccount",
        "ZmFrZS1rZXk=",
    );
    defer credential.deinit();
    var shared = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .shared_key = .{ .endpoint = "https://fakeaccount.table.core.windows.net", .credential = &credential } },
            .table_name = "People",
        },
    );
    defer shared.deinit();
    const sas_url = try shared.getTableSasUrl(allocator, .{
        .accessPolicy = .{ .adHoc = .{
            .permissions = .{ .read = true },
            .startTime = .fromUnixSeconds(1_699_455_845),
            .expiryTime = .fromUnixSeconds(1_699_459_445),
        } },
        .startPartitionKey = "A",
        .startRowKey = "0",
        .endPartitionKey = "Z",
        .endRowKey = "9",
    });
    defer allocator.free(sas_url);
    try std.testing.expectEqualStrings(
        "https://fakeaccount.table.core.windows.net/People?epk=Z&erk=9&se=2023-11-08T16%3A04%3A05Z&sig=de3WKX%2BV7n%2BdT7OWKCwFJ%2BNDUwN7F6My1aWUKN2M%2B6Q%3D&sp=r&spk=A&spr=https&srk=0&st=2023-11-08T15%3A04%3A05Z&sv=2019-02-02&tn=people",
        sas_url,
    );

    var anonymous = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .sas_url = sas_url }, .table_name = "People" },
    );
    defer anonymous.deinit();
    try std.testing.expectEqualStrings(
        "https://fakeaccount.table.core.windows.net",
        anonymous.protocol.endpoint.base_url,
    );
    try std.testing.expectError(
        error.SasRequiresSharedKeyCredential,
        anonymous.getTableSasUrl(allocator, .{
            .accessPolicy = .{ .adHoc = .{
                .permissions = .{ .read = true },
                .expiryTime = .fromUnixSeconds(1_699_459_445),
            } },
        }),
    );
    var formatted: std.Io.Writer.Allocating = .init(allocator);
    defer formatted.deinit();
    try formatted.writer.print("{f}", .{anonymous});
    try std.testing.expectEqualStrings(
        "TableClient(https://fakeaccount.table.core.windows.net)",
        formatted.written(),
    );
    var response = try anonymous.getEntity(allocator, "A", "0");
    response.deinit();
    try std.testing.expect(transport.last_headers.get("Authorization") == null);
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.last_url.?,
        "https://fakeaccount.table.core.windows.net/People(PartitionKey='A',RowKey='0')?",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        transport.last_url.?,
        sas_url[(std.mem.indexOfScalar(u8, sas_url, '?').? + 1)..],
    ));
}

test "account SAS preserves a custom account path equal to the table name" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    const account_sas =
        "http://127.0.0.1:10002/People?sv=2019-02-02&ss=t&srt=o&sig=opaque%2Bvalue%3D";
    var table = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .sas_url = account_sas }, .table_name = "People" },
    );
    defer table.deinit();
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:10002/People",
        table.protocol.endpoint.base_url,
    );
    try std.testing.expectEqualStrings(
        "sv=2019-02-02&ss=t&srt=o&sig=opaque%2Bvalue%3D",
        table.protocol.endpoint.raw_query,
    );
    var response = try table.getEntity(allocator, "p", "r");
    response.deinit();
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.last_url.?,
        "http://127.0.0.1:10002/People/People(PartitionKey='p',RowKey='r')?",
    ));
}

test "table SAS scope uses decoded case-insensitive tn without changing query bytes" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    const table_sas =
        "http://127.0.0.1:10002/People/People?sv=2019-02-02&%54%6E=%50eople&sig=opaque%2Bvalue%3D";
    var table = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .sas_url = table_sas }, .table_name = "People" },
    );
    defer table.deinit();
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:10002/People",
        table.protocol.endpoint.base_url,
    );
    try std.testing.expectEqualStrings(
        "sv=2019-02-02&%54%6E=%50eople&sig=opaque%2Bvalue%3D",
        table.protocol.endpoint.raw_query,
    );
    var response = try table.getEntity(allocator, "p", "r");
    response.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        transport.last_url.?,
        "?sv=2019-02-02&%54%6E=%50eople&sig=opaque%2Bvalue%3D",
    ) != null);
}

test "table SAS scope rejects mismatched duplicate and malformed tn" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    try std.testing.expectError(
        error.SasTableNameMismatch,
        TableClient.init(
            allocator,
            testingRuntime(transport.asTransport()),
            .{
                .authentication = .{ .sas_url = "https://account.table.core.windows.net/Other?sv=1&tn=Other&sig=x" },
                .table_name = "People",
            },
        ),
    );
    try std.testing.expectError(
        error.DuplicateSasTableName,
        TableClient.init(
            allocator,
            testingRuntime(transport.asTransport()),
            .{
                .authentication = .{ .sas_url = "https://account.table.core.windows.net/People?tn=People&TN=%50eople&sig=x" },
                .table_name = "People",
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidTableSasUrl,
        TableClient.init(
            allocator,
            testingRuntime(transport.asTransport()),
            .{
                .authentication = .{ .sas_url = "https://account.table.core.windows.net?tn=People&sig=x" },
                .table_name = "People",
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidSasQueryEncoding,
        TableClient.init(
            allocator,
            testingRuntime(transport.asTransport()),
            .{
                .authentication = .{ .sas_url = "https://account.table.core.windows.net/People?t%ZZ=People&sig=x" },
                .table_name = "People",
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidSasQueryEncoding,
        TableClient.init(
            allocator,
            testingRuntime(transport.asTransport()),
            .{
                .authentication = .{ .sas_url = "https://account.table.core.windows.net/People?tn=Peop%ZZle&sig=x" },
                .table_name = "People",
            },
        ),
    );
}

test "stored access policies use generated XML and preserve response metadata" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 204, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "x-ms-request-id", .value = "set-policy-id" },
        .{ .name = "x-ms-client-request-id", .value = "temporary-id" },
    };
    var credential = TestCredential{};
    var table_client = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } },
            .table_name = "People",
        },
    );
    defer table_client.deinit();

    var set_response = try table_client.setAccessPolicy(
        allocator,
        &.{
            .{
                .id = "read<&>",
                .access_policy = .{
                    .start = try service_models.AccessPolicyTime.parse(
                        "2026-07-26T20:02:16.1234567+01:30",
                    ),
                    .expiry = try service_models.AccessPolicyTime.parse(
                        "2026-07-27T14:32:16.120-04:00",
                    ),
                    .permissions = .{ .table = .{ .read = true, .update = true } },
                },
            },
            .{
                .id = "future",
                .access_policy = .{ .permissions = .{ .raw = "ad" } },
            },
        },
        .{ .protocol = .{ .client_request_id = "temporary-id", .timeout = 17 } },
    );
    defer set_response.deinit();
    try std.testing.expectEqual(@as(u16, 204), set_response.status);
    try std.testing.expectEqualStrings(
        "set-policy-id",
        set_response.headers.getFirst("x-ms-request-id").?,
    );
    try std.testing.expectEqual(.PUT, transport.last_method.?);
    try std.testing.expectEqualStrings(
        "https://account.table.core.windows.net/People?comp=acl&timeout=17",
        transport.last_url.?,
    );
    try std.testing.expectEqualStrings(
        "application/xml",
        transport.last_headers.get("Content-Type").?,
    );
    try std.testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SignedIdentifiers><SignedIdentifier><Id>read&lt;&amp;&gt;</Id><AccessPolicy><Start>2026-07-26T18:32:16.1234567Z</Start><Expiry>2026-07-27T18:32:16.120Z</Expiry><Permission>ru</Permission></AccessPolicy></SignedIdentifier><SignedIdentifier><Id>future</Id><AccessPolicy><Start></Start><Expiry></Expiry><Permission>ad</Permission></AccessPolicy></SignedIdentifier></SignedIdentifiers>",
        transport.last_body.?,
    );

    transport.response_status = 200;
    transport.response_body =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SignedIdentifiers><SignedIdentifier><Id>read&lt;&amp;&gt;</Id><AccessPolicy><Start>2026-07-26T18:32:16.1234567Z</Start><Expiry>2026-07-27T18:32:16.120Z</Expiry><Permission>ru</Permission></AccessPolicy></SignedIdentifier><SignedIdentifier><Id>future</Id><AccessPolicy><Start></Start><Expiry></Expiry><Permission>rx</Permission></AccessPolicy></SignedIdentifier></SignedIdentifiers>";
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "x-ms-request-id", .value = "get-policy-id" },
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var get_response = try table_client.getAccessPolicy(
        allocator,
        .{ .protocol = .{ .timeout = 3 } },
    );
    defer get_response.deinit();
    try std.testing.expectEqual(@as(u16, 200), get_response.status);
    try std.testing.expectEqualStrings(
        "get-policy-id",
        get_response.headers.getFirst("x-ms-request-id").?,
    );
    try std.testing.expectEqual(@as(usize, 2), get_response.value.len);
    try std.testing.expectEqualStrings("read<&>", get_response.value[0].id);
    var time_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2026-07-26T18:32:16.1234567Z",
        try get_response.value[0].access_policy.start.?.format(&time_buffer),
    );
    var permission_buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ru",
        get_response.value[0].access_policy.permissions.string(&permission_buffer),
    );
    try std.testing.expect(get_response.value[1].access_policy.start == null);
    try std.testing.expect(get_response.value[1].access_policy.expiry == null);
    try std.testing.expectEqualStrings(
        "rx",
        get_response.value[1].access_policy.permissions.string(&permission_buffer),
    );
}

test "stored access policy limits preserve empty zero and five lists" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 204, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
    };
    var credential = TestCredential{};
    var table_client = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } },
            .table_name = "People",
        },
    );
    defer table_client.deinit();

    var empty_set = try table_client.setAccessPolicy(allocator, &.{}, .{});
    empty_set.deinit();
    try std.testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SignedIdentifiers></SignedIdentifiers>",
        transport.last_body.?,
    );

    const five = [_]service_models.SignedIdentifier{
        .{ .id = "one", .access_policy = .{} },
        .{ .id = "two", .access_policy = .{} },
        .{ .id = "three", .access_policy = .{} },
        .{ .id = "four", .access_policy = .{} },
        .{ .id = "x" ** 64, .access_policy = .{} },
    };
    var five_set = try table_client.setAccessPolicy(allocator, &five, .{});
    five_set.deinit();
    try std.testing.expectEqual(@as(usize, 2), transport.call_count);
    try std.testing.expectEqual(
        @as(usize, 5),
        std.mem.count(u8, transport.last_body.?, "<Start></Start><Expiry></Expiry><Permission></Permission>"),
    );

    try std.testing.expectError(
        error.InvalidSignedIdentifier,
        table_client.setAccessPolicyResult(
            std.testing.failing_allocator,
            &.{.{ .id = "雪" ** 65, .access_policy = .{} }},
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidSignedIdentifier,
        table_client.setAccessPolicyResult(
            std.testing.failing_allocator,
            &.{.{ .id = "\xff", .access_policy = .{} }},
            .{},
        ),
    );
    try std.testing.expectError(
        error.DuplicateSignedIdentifier,
        table_client.setAccessPolicyResult(
            std.testing.failing_allocator,
            &.{
                .{ .id = "duplicate", .access_policy = .{} },
                .{ .id = "duplicate", .access_policy = .{} },
            },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidAccessPolicyPermissions,
        table_client.setAccessPolicyResult(
            std.testing.failing_allocator,
            &.{.{
                .id = "permissions",
                .access_policy = .{ .permissions = .{ .raw = "rx" } },
            }},
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), transport.call_count);

    const six = five ++ [_]service_models.SignedIdentifier{
        .{ .id = "six", .access_policy = .{} },
    };
    try std.testing.expectError(
        error.TooManyStoredAccessPolicies,
        table_client.setAccessPolicyResult(allocator, &six, .{}),
    );
    try std.testing.expectEqual(@as(usize, 2), transport.call_count);

    transport.response_status = 200;
    transport.response_body =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SignedIdentifiers></SignedIdentifiers>";
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var empty_get = try table_client.getAccessPolicy(allocator, .{});
    defer empty_get.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_get.value.len);
}

test "stored policy identifiers generate SAS and policy calls use every auth mode" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 204, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
    };
    var shared_credential = try auth.SharedKeyCredential.init(
        allocator,
        "account",
        "YWNjb3VudC1rZXk=",
    );
    defer shared_credential.deinit();
    var shared = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .shared_key = .{ .endpoint = "https://account.table.core.windows.net", .credential = &shared_credential } },
            .table_name = "People",
        },
    );
    defer shared.deinit();
    const identifier = service_models.SignedIdentifier{
        .id = "stored-read",
        .access_policy = .{ .permissions = .{ .table = .{ .read = true } } },
    };
    var stored = try shared.setAccessPolicy(allocator, &.{identifier}, .{});
    stored.deinit();
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.last_headers.get("Authorization").?,
        "SharedKeyLite account:",
    ));
    const sas_url = try shared.getTableSasUrl(allocator, .{
        .accessPolicy = .{ .stored = identifier.id },
    });
    defer allocator.free(sas_url);
    try std.testing.expect(std.mem.indexOf(u8, sas_url, "si=stored-read") != null);
    try std.testing.expect(std.mem.indexOf(u8, sas_url, "sp=") == null);
    try std.testing.expect(std.mem.indexOf(u8, sas_url, "st=") == null);
    try std.testing.expect(std.mem.indexOf(u8, sas_url, "se=") == null);

    var anonymous = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .sas_url = sas_url }, .table_name = "People" },
    );
    defer anonymous.deinit();
    var sas_set = try anonymous.setAccessPolicy(allocator, &.{identifier}, .{});
    sas_set.deinit();
    try std.testing.expect(transport.last_headers.get("Authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, transport.last_url.?, "si=stored-read") != null);
}

test "stored policy malformed XML and service failures remain distinct" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(
        allocator,
        200,
        "<SignedIdentifiers><SignedIdentifier>",
    );
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var credential = TestCredential{};
    var table_client = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } },
            .table_name = "People",
        },
    );
    defer table_client.deinit();
    if (table_client.getAccessPolicyResult(allocator, .{})) |result| {
        var unexpected = result;
        unexpected.deinit(allocator);
        return error.ExpectedMalformedXmlFailure;
    } else |_| {}

    transport.response_status = 403;
    transport.response_body =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>AuthorizationFailure</Code><Message>denied</Message></Error>";
    transport.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/xml" },
        .{ .name = "x-ms-request-id", .value = "denied-id" },
    };
    var result = try table_client.setAccessPolicyResult(allocator, &.{}, .{});
    defer result.deinit(allocator);
    switch (result) {
        .failure => |failure| {
            try std.testing.expectEqual(@as(u16, 403), failure.status);
            try std.testing.expectEqualStrings("AuthorizationFailure", failure.code);
            try std.testing.expectEqualStrings("denied-id", failure.request_id.?);
        },
        .success => return error.TestUnexpectedResult,
    }
}

fn testAccessPolicyAllocationFailures(allocator: std.mem.Allocator) !void {
    var transport = core.http.MockTransport.init(
        allocator,
        200,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SignedIdentifiers><SignedIdentifier><Id>read</Id><AccessPolicy><Start>2026-07-26T18:32:16.1234567Z</Start><Expiry>2026-07-27T18:32:16Z</Expiry><Permission>r</Permission></AccessPolicy></SignedIdentifier></SignedIdentifiers>",
    );
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var credential = TestCredential{};
    var table_client = try TableClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } },
            .table_name = "People",
            .options = .{ .retry = .{ .max_retries = 0 } },
        },
    );
    defer table_client.deinit();
    var get_result = try table_client.getAccessPolicyResult(allocator, .{});
    get_result.deinit(allocator);

    transport.response_status = 204;
    transport.response_body = "";
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
    };
    var set_result = try table_client.setAccessPolicyResult(
        allocator,
        &.{.{
            .id = "read",
            .access_policy = .{
                .start = try service_models.AccessPolicyTime.parse("2026-07-26T18:32:16Z"),
                .permissions = .{ .raw = "rd" },
            },
        }},
        .{ .protocol = .{ .client_request_id = "temporary" } },
    );
    set_result.deinit(allocator);
}

test "stored policy allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testAccessPolicyAllocationFailures,
        .{},
    );
}
