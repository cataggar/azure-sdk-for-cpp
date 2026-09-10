const core = @import("azure_sdk_core");
const protocol = @import("azure_rest_data_tables");
const auth = @import("auth.zig");

pub const latest_api_version = "2019-02-02";
pub const MetadataFormat = protocol.enums.OdataMetadataFormat;

/// SDK settings shared by generated protocol calls.
pub const ProtocolOptions = struct {
    metadata: ?MetadataFormat = null,
    client_request_id: ?[]const u8 = null,
    /// Server-side timeout, in seconds.
    timeout: ?i32 = null,
    /// End-to-end client budget. A blocking in-flight send may exceed it.
    operation_timeout_ms: ?u64 = null,
    /// Per-call policies run before the client's configured pipeline.
    policies: []const *core.http.HttpPolicy = &.{},
};

pub const QueryEntitiesOptions = struct {
    protocol: ProtocolOptions = .{},
    top: ?i32 = null,
    select: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    next_partition_key: ?[]const u8 = null,
    next_row_key: ?[]const u8 = null,
};

pub const QueryEntityOptions = struct {
    protocol: ProtocolOptions = .{},
    select: ?[]const u8 = null,
    filter: ?[]const u8 = null,
};

pub const CreateTableOptions = struct {
    protocol: ProtocolOptions = .{},
    prefer: ?protocol.enums.ResponseFormat = null,
};

pub const DeleteTableOptions = struct {
    protocol: ProtocolOptions = .{},
};

pub const GetAccessPolicyOptions = struct {
    protocol: ProtocolOptions = .{},
};

pub const SetAccessPolicyOptions = struct {
    protocol: ProtocolOptions = .{},
};

pub const ListTablesOptions = struct {
    protocol: ProtocolOptions = .{},
    top: ?i32 = null,
    select: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    /// Opaque value from `x-ms-continuation-NextTableName`.
    continuation_token: ?[]const u8 = null,
};

pub const AddEntityOptions = struct {
    protocol: ProtocolOptions = .{},
};

pub const GetEntityOptions = QueryEntityOptions;

pub const DeleteEntityOptions = struct {
    protocol: ProtocolOptions = .{},
    /// `"*"` performs an unconditional delete; an entity ETag makes it
    /// conditional.
    if_match: []const u8 = "*",
};

/// Selects the service's closed set of entity mutation semantics.
pub const UpdateMode = enum {
    /// Preserve properties omitted from the request body.
    merge,
    /// Remove properties omitted from the request body.
    replace,
};

pub const UpdateEntityOptions = struct {
    protocol: ProtocolOptions = .{},
    mode: UpdateMode = .merge,
    /// `"*"` updates the current entity unconditionally; an entity ETag makes
    /// the update conditional.
    if_match: []const u8 = "*",
};

pub const UpsertEntityOptions = struct {
    protocol: ProtocolOptions = .{},
    mode: UpdateMode = .merge,
};

pub const SetServicePropertiesOptions = struct {
    protocol: ProtocolOptions = .{},
};
pub const GetServicePropertiesOptions = struct {
    protocol: ProtocolOptions = .{},
};
pub const GetStatisticsOptions = struct {
    protocol: ProtocolOptions = .{},
};

/// Explicit boundaries are primarily useful for deterministic wire tests.
/// Normal transaction submissions generate unpredictable MIME boundaries
/// through the client's borrowed runtime crypto provider.
pub const TransactionBoundaries = struct {
    batch: []const u8,
    changeset: []const u8,
};

pub const TransactionOptions = struct {
    protocol: ProtocolOptions = .{},
    /// Explicit boundaries bypass runtime randomness for deterministic
    /// fixtures. Both values are borrowed for the submission call.
    boundaries: ?TransactionBoundaries = null,
};

pub const RetryOptions = struct {
    max_retries: u32 = 3,
    initial_delay_ms: u64 = 800,
    max_delay_ms: u64 = 60_000,
};

pub const TelemetryOptions = struct {
    /// Optional application identifier prepended to the SDK user agent.
    application_id: ?[]const u8 = null,
};

/// Selects the endpoint and authentication together, without ambiguous mixes.
///
/// Input strings are borrowed only during client initialization. Explicit
/// credentials remain borrowed for the lifetime of the client and its derived
/// clients. Connection-string account keys become client-owned credentials.
pub const ClientAuthentication = union(enum) {
    token: struct {
        endpoint: []const u8,
        credential: *core.credentials.TokenCredential,
    },
    shared_key: struct {
        endpoint: []const u8,
        credential: *auth.SharedKeyCredential,
    },
    /// A complete signed URL. Its encoded query is preserved verbatim.
    sas_url: []const u8,
    connection_string: []const u8,

    pub fn format(_: ClientAuthentication, writer: anytype) !void {
        try writer.writeAll("TablesAuthentication(***)");
    }
};

pub const TableClientInitOptions = struct {
    authentication: ClientAuthentication,
    table_name: []const u8,
    options: TableClientOptions = .{},
};

pub const TableServiceClientInitOptions = struct {
    authentication: ClientAuthentication,
    options: TableServiceClientOptions = .{},
};

/// Settings copied or applied by client initialization.
///
/// Policy objects and the transport are borrowed and must outlive the owning
/// client. All string values and the policy pointer list are copied.
pub const TableClientOptions = struct {
    api_version: []const u8 = latest_api_version,
    retry: RetryOptions = .{},
    telemetry: TelemetryOptions = .{},
    /// Default request ID. Per-operation IDs take precedence.
    client_request_id: ?[]const u8 = null,
    /// Default end-to-end budget. Per-operation budgets take precedence.
    operation_timeout_ms: ?u64 = null,
    /// Policies run once per retry. SAS query authentication is appended only
    /// after these policies, immediately before the transport.
    policies: []const *core.http.HttpPolicy = &.{},
};

pub const TableServiceClientOptions = TableClientOptions;
