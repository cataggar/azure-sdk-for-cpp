///! Azure Cosmos DB (NoSQL) client.
///!
///! Provides `CosmosClient`, `DatabaseClient`, and `ContainerClient`
///! for account, database, and container/item operations via REST API.
const std = @import("std");
const core = @import("azure_sdk_core");
const serde = @import("serde");

pub const cosmos_scope = "https://cosmos.azure.com/.default";
pub const user_agent = "azsdk-zig-data-cosmos/0.3.0";

// ─────────────────────── Enums ───────────────────────

pub const ConsistencyLevel = enum {
    strong,
    bounded_staleness,
    session,
    consistent_prefix,
    eventual,

    pub fn toString(self: ConsistencyLevel) []const u8 {
        return switch (self) {
            .strong => "Strong",
            .bounded_staleness => "BoundedStaleness",
            .session => "Session",
            .consistent_prefix => "ConsistentPrefix",
            .eventual => "Eventual",
        };
    }
};

// ─────────────────────── Models ───────────────────────

pub const Database = struct {
    id: []const u8,
    rid: ?[]const u8 = null,
    self_link: ?[]const u8 = null,
    etag: ?[]const u8 = null,

    /// Free any strings duped into `allocator` by parseDatabaseResponse /
    /// parseDatabaseList. `id` is duped for list results; not for
    /// single-resource fetches (where it's a borrow of the caller's input).
    pub fn deinit(self: Database, allocator: std.mem.Allocator, owns_id: bool) void {
        if (owns_id) allocator.free(self.id);
        if (self.rid) |s| allocator.free(s);
        if (self.self_link) |s| allocator.free(s);
        if (self.etag) |s| allocator.free(s);
    }
};

pub const ContainerProperties = struct {
    id: []const u8,
    partition_key_paths: []const []const u8 = &.{},
    rid: ?[]const u8 = null,
    self_link: ?[]const u8 = null,
    etag: ?[]const u8 = null,

    pub fn deinit(self: ContainerProperties, allocator: std.mem.Allocator, owns_id: bool) void {
        if (owns_id) allocator.free(self.id);
        if (self.rid) |s| allocator.free(s);
        if (self.self_link) |s| allocator.free(s);
        if (self.etag) |s| allocator.free(s);
    }
};

pub const CosmosItem = struct {
    id: []const u8,
    partition_key: []const u8,
    body: []const u8,
};

pub const QueryResult = struct {
    documents: []const []const u8,
    continuation_token: ?[]const u8 = null,

    pub fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        for (self.documents) |document| allocator.free(document);
        allocator.free(self.documents);
        if (self.continuation_token) |token| allocator.free(token);
        self.* = undefined;
    }
};

pub const ThroughputProperties = struct {
    max_throughput: ?u32 = null,
};

// ─────────────────── CosmosClient ────────────────────

pub const TimeSource = struct {
    context: *anyopaque,
    nowFn: *const fn (context: *anyopaque) i64,

    pub fn now(self: TimeSource) i64 {
        return self.nowFn(self.context);
    }
};

pub const CosmosClientOptions = struct {
    api_version: []const u8 = "2018-12-31",
    consistency_level: ?ConsistencyLevel = null,
    policies: []const *core.http.HttpPolicy = &.{},
    time_source: ?TimeSource = null,
    /// Disabled by default. The provider, scope strings, and parent tracestate
    /// are borrowed and must outlive this client and its derived clients.
    instrumentation: ?core.tracing.InstrumentationOptions = null,
};

/// Account-level client for Azure Cosmos DB.
///
/// The endpoint, credential, caller policies, and runtime backend contexts are
/// borrowed and must outlive the client and in-flight calls. Runtime
/// descriptors are copied by value. Derived database and container clients
/// borrow heap-stable policy state and must not outlive this client. Calls
/// sharing this client must be serialized because the bearer-token cache and
/// the standard transport are mutable. Authenticated endpoints must use HTTPS.
pub const CosmosClient = struct {
    endpoint: []const u8,
    api_version: []const u8,
    consistency_level: ?ConsistencyLevel,
    pipeline: core.http.HttpPipeline,
    pipeline_state: *PipelineState,

    pub fn init(
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        credential: *core.credentials.TokenCredential,
        runtime: core.http.HttpRuntime,
        options: CosmosClientOptions,
    ) !CosmosClient {
        try core.url.validateHttpsUrl(endpoint, &.{});
        const state = try PipelineState.create(
            allocator,
            credential,
            runtime,
            options,
        );
        return .{
            .endpoint = endpoint,
            .api_version = options.api_version,
            .consistency_level = options.consistency_level,
            .pipeline = state.pipeline,
            .pipeline_state = state,
        };
    }

    pub fn deinit(self: *CosmosClient) void {
        self.pipeline_state.deinit();
        self.* = undefined;
    }

    /// Get a DatabaseClient for a specific database.
    pub fn database(self: *CosmosClient, database_id: []const u8) DatabaseClient {
        return .{
            .endpoint = self.endpoint,
            .database_id = database_id,
            .api_version = self.api_version,
            .consistency_level = self.consistency_level,
            .pipeline = self.pipeline,
            .non_idempotent_max_retries = self.pipeline_state.retry.max_retries,
        };
    }

    /// Create a new database. A failure after transport dispatch returns
    /// `error.CosmosCreateOutcomeUnknown`; the request is never replayed.
    pub fn createDatabase(self: *CosmosClient, allocator: std.mem.Allocator, database_id: []const u8) !Database {
        var r = try self.createDatabaseResult(allocator, database_id);
        return r.unwrap(error.CreateDatabaseFailed);
    }

    /// Same as `createDatabase` but returns `Result(Database)`.
    pub fn createDatabaseResult(self: *CosmosClient, allocator: std.mem.Allocator, database_id: []const u8) !core.errors.Result(Database) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs", .{self.endpoint});
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\"}}", .{database_id});
        defer allocator.free(body);

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try self.setCommonHeaders(&req);
        req.body = body;

        var resp = try sendNonIdempotent(
            &self.pipeline,
            &req,
            self.pipeline_state.retry.max_retries,
        );
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = parseDatabaseResponse(allocator, database_id, resp.body) };
    }

    /// Delete a database.
    pub fn deleteDatabase(self: *CosmosClient, allocator: std.mem.Allocator, database_id: []const u8) !void {
        var r = try self.deleteDatabaseResult(allocator, database_id);
        try r.unwrap(error.DeleteDatabaseFailed);
    }

    /// Same as `deleteDatabase` but returns `Result(void)`.
    pub fn deleteDatabaseResult(self: *CosmosClient, allocator: std.mem.Allocator, database_id: []const u8) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs/{s}", .{ self.endpoint, database_id });
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();
        try self.setCommonHeaders(&req);

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// List all databases.
    pub fn listDatabases(self: *CosmosClient, allocator: std.mem.Allocator) ![]Database {
        var r = try self.listDatabasesResult(allocator);
        return r.unwrap(error.ListDatabasesFailed);
    }

    /// Same as `listDatabases` but returns `Result([]Database)`.
    pub fn listDatabasesResult(self: *CosmosClient, allocator: std.mem.Allocator) !core.errors.Result([]Database) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs", .{self.endpoint});
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .GET, url);
        defer req.deinit();
        try self.setCommonHeaders(&req);

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try parseDatabaseList(allocator, resp.body) };
    }

    fn setCommonHeaders(self: *CosmosClient, req: *core.http.Request) !void {
        try req.setHeader("x-ms-version", self.api_version);
        if (self.consistency_level) |cl| {
            try req.setHeader("x-ms-consistency-level", cl.toString());
        }
    }
};

const PipelineState = struct {
    allocator: std.mem.Allocator,
    request_id: core.http.RequestIdPolicy,
    telemetry: core.http.TelemetryPolicy,
    retry: core.http.RetryPolicy,
    date: CosmosDatePolicy,
    authentication: CosmosAuthorizationPolicy,
    policy_ptrs: []*core.http.HttpPolicy,
    pipeline: core.http.HttpPipeline,

    fn create(
        allocator: std.mem.Allocator,
        credential: *core.credentials.TokenCredential,
        runtime: core.http.HttpRuntime,
        options: CosmosClientOptions,
    ) !*PipelineState {
        const state = try allocator.create(PipelineState);
        errdefer allocator.destroy(state);
        const policy_ptrs = try allocator.alloc(
            *core.http.HttpPolicy,
            5 + options.policies.len,
        );
        errdefer allocator.free(policy_ptrs);

        state.* = .{
            .allocator = allocator,
            .request_id = core.http.RequestIdPolicy.init(),
            .telemetry = core.http.TelemetryPolicy.init(user_agent),
            .retry = core.http.RetryPolicy.init(),
            .date = CosmosDatePolicy.init(options.time_source),
            .authentication = CosmosAuthorizationPolicy.init(
                allocator,
                credential,
            ),
            .policy_ptrs = policy_ptrs,
            .pipeline = undefined,
        };
        policy_ptrs[0] = state.request_id.asPolicy();
        policy_ptrs[1] = state.telemetry.asPolicy();
        policy_ptrs[2] = state.retry.asPolicy();
        policy_ptrs[3] = state.date.asPolicy();
        policy_ptrs[4] = state.authentication.asPolicy();
        @memcpy(policy_ptrs[5..], options.policies);
        state.pipeline = core.http.HttpPipeline.init(runtime, policy_ptrs);
        state.pipeline.setInstrumentation(options.instrumentation);
        return state;
    }

    fn deinit(self: *PipelineState) void {
        const allocator = self.allocator;
        self.authentication.deinit();
        allocator.free(self.policy_ptrs);
        allocator.destroy(self);
    }
};

/// Sets the required current RFC 1123 UTC date after the retry policy so each
/// attempt receives a freshly generated value.
const CosmosDatePolicy = struct {
    time_source: ?TimeSource,
    policy: core.http.HttpPolicy = .{
        .processFn = &process,
        .prepareFn = &prepare,
    },

    fn init(time_source: ?TimeSource) CosmosDatePolicy {
        return .{ .time_source = time_source };
    }

    fn asPolicy(self: *CosmosDatePolicy) *core.http.HttpPolicy {
        return &self.policy;
    }

    fn process(
        policy: *core.http.HttpPolicy,
        request: *core.http.Request,
        next: []*core.http.HttpPolicy,
        runtime: core.http.HttpRuntime,
    ) anyerror!core.http.Response {
        try prepare(policy, request, runtime);
        return callNext(request, next, runtime);
    }

    fn prepare(
        policy: *core.http.HttpPolicy,
        request: *core.http.Request,
        _: core.http.HttpRuntime,
    ) anyerror!void {
        const self: *CosmosDatePolicy =
            @alignCast(@fieldParentPtr("policy", policy));
        var date: [32]u8 = undefined;
        const date_value = formatHttpDate(
            &date,
            if (self.time_source) |source| source.now() else unixTimestampSeconds(),
        );
        try request.setHeader("x-ms-date", date_value);
    }
};

/// Applies Cosmos DB's percent-encoded Microsoft Entra authorization value.
///
/// The credential and runtime contexts are borrowed. Cached token state is
/// owned by this policy and calls must be serialized.
const CosmosAuthorizationPolicy = struct {
    allocator: std.mem.Allocator,
    credential: *core.credentials.TokenCredential,
    cached_token: ?[]u8 = null,
    cached_expires_on: i64 = 0,
    policy: core.http.HttpPolicy,

    fn init(
        allocator: std.mem.Allocator,
        credential: *core.credentials.TokenCredential,
    ) CosmosAuthorizationPolicy {
        return .{
            .allocator = allocator,
            .credential = credential,
            .policy = .{
                .processFn = &process,
                .prepareFn = &prepare,
            },
        };
    }

    fn asPolicy(self: *CosmosAuthorizationPolicy) *core.http.HttpPolicy {
        return &self.policy;
    }

    fn deinit(self: *CosmosAuthorizationPolicy) void {
        if (self.cached_token) |token| {
            wipe(token);
            self.allocator.free(token);
        }
    }

    fn process(
        policy: *core.http.HttpPolicy,
        request: *core.http.Request,
        next: []*core.http.HttpPolicy,
        runtime: core.http.HttpRuntime,
    ) anyerror!core.http.Response {
        try prepare(policy, request, runtime);
        return callNext(request, next, runtime);
    }

    fn prepare(
        policy: *core.http.HttpPolicy,
        request: *core.http.Request,
        runtime: core.http.HttpRuntime,
    ) anyerror!void {
        const self: *CosmosAuthorizationPolicy =
            @alignCast(@fieldParentPtr("policy", policy));
        const now = unixTimestampSeconds();
        if (self.cached_token == null or now >= self.cached_expires_on - 300) {
            var fresh = try self.credential.getToken(
                .{ .scopes = &.{cosmos_scope} },
                core.context.Context.none,
                runtime,
            );
            defer fresh.deinit();
            const replacement = try self.allocator.dupe(u8, fresh.token);
            if (self.cached_token) |old| {
                wipe(old);
                self.allocator.free(old);
            }
            self.cached_token = replacement;
            self.cached_expires_on = fresh.expires_on;
        }

        const raw = try std.fmt.allocPrint(
            self.allocator,
            "type=aad&ver=1.0&sig={s}",
            .{self.cached_token.?},
        );
        defer {
            wipe(raw);
            self.allocator.free(raw);
        }
        const encoded = try core.url.percentEncode(self.allocator, raw);
        defer {
            wipe(encoded);
            self.allocator.free(encoded);
        }
        try request.setHeader("Authorization", encoded);
    }
};

fn wipe(bytes: []u8) void {
    const volatile_bytes: []volatile u8 = bytes;
    @memset(volatile_bytes, 0);
}

fn callNext(
    request: *core.http.Request,
    next: []*core.http.HttpPolicy,
    runtime: core.http.HttpRuntime,
) !core.http.Response {
    if (next.len == 0) return runtime.transport.send(request);
    return next[0].process(request, next[1..], runtime);
}

fn sendNonIdempotent(
    pipeline: *core.http.HttpPipeline,
    request: *core.http.Request,
    max_retries: u32,
) !core.http.Response {
    const old_retryable = request.retryable;
    const old_redirect_policy = request.redirect_policy;
    request.retryable = false;
    request.redirect_policy = .not_allowed;
    defer {
        request.retryable = old_retryable;
        request.redirect_policy = old_redirect_policy;
    }

    var attempt: u32 = 0;
    while (true) {
        const result = pipeline.send(request);
        if (result) |response| return response else |err| {
            if (request.transport_started)
                return error.CosmosCreateOutcomeUnknown;
            if (!isRetryablePreTransportError(err) or attempt >= max_retries)
                return err;
            attempt += 1;
        }
    }
}

fn isRetryablePreTransportError(failure: anyerror) bool {
    return switch (failure) {
        error.OutOfMemory,
        error.OperationTimedOut,
        error.OperationCancelled,
        error.InvalidHttpHeaderName,
        error.InvalidHttpHeaderValue,
        error.InvalidUrl,
        error.HttpsRequired,
        error.UnexpectedHost,
        => false,
        else => true,
    };
}

fn unixTimestampSeconds() i64 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return std.Io.Timestamp.now(threaded.io(), .real).toSeconds();
}

fn formatHttpDate(buffer: *[32]u8, timestamp: i64) []const u8 {
    const days = @divFloor(timestamp, 86_400);
    const seconds: u64 = @intCast(@mod(timestamp, 86_400));
    const z = days + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) -
            @divFloor(doe, 146_096),
        365,
    );
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    year += if (month <= 2) @as(i64, 1) else @as(i64, 0);
    const weekdays = [_][]const u8{
        "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed",
    };
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    return std.fmt.bufPrint(
        buffer,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekdays[@intCast(@mod(days, 7))],
            @as(u64, @intCast(day)),
            months[@intCast(month - 1)],
            @as(u64, @intCast(year)),
            seconds / 3600,
            (seconds / 60) % 60,
            seconds % 60,
        },
    ) catch unreachable;
}

// ─────────────────── DatabaseClient ──────────────────

/// Database-level client for container operations.
pub const DatabaseClient = struct {
    endpoint: []const u8,
    database_id: []const u8,
    api_version: []const u8,
    consistency_level: ?ConsistencyLevel,
    pipeline: core.http.HttpPipeline,
    non_idempotent_max_retries: u32,

    /// Get a ContainerClient for a specific container.
    pub fn container(self: *DatabaseClient, container_id: []const u8) ContainerClient {
        return .{
            .endpoint = self.endpoint,
            .database_id = self.database_id,
            .container_id = container_id,
            .api_version = self.api_version,
            .consistency_level = self.consistency_level,
            .pipeline = self.pipeline,
            .non_idempotent_max_retries = self.non_idempotent_max_retries,
        };
    }

    /// Create a new container. A failure after transport dispatch returns
    /// `error.CosmosCreateOutcomeUnknown`; the request is never replayed.
    pub fn createContainer(self: *DatabaseClient, allocator: std.mem.Allocator, container_id: []const u8, partition_key_path: []const u8) !ContainerProperties {
        var r = try self.createContainerResult(allocator, container_id, partition_key_path);
        return r.unwrap(error.CreateContainerFailed);
    }

    /// Same as `createContainer` but returns `Result(ContainerProperties)`.
    pub fn createContainerResult(self: *DatabaseClient, allocator: std.mem.Allocator, container_id: []const u8, partition_key_path: []const u8) !core.errors.Result(ContainerProperties) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs/{s}/colls", .{ self.endpoint, self.database_id });
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","partitionKey":{{"paths":["{s}"],"kind":"Hash"}}}}
        , .{ container_id, partition_key_path });
        defer allocator.free(body);

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try self.setCommonHeaders(&req);
        req.body = body;

        var resp = try sendNonIdempotent(
            &self.pipeline,
            &req,
            self.non_idempotent_max_retries,
        );
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = .{ .id = container_id, .partition_key_paths = &.{partition_key_path} } };
    }

    /// Delete a container.
    pub fn deleteContainer(self: *DatabaseClient, allocator: std.mem.Allocator, container_id: []const u8) !void {
        var r = try self.deleteContainerResult(allocator, container_id);
        try r.unwrap(error.DeleteContainerFailed);
    }

    /// Same as `deleteContainer` but returns `Result(void)`.
    pub fn deleteContainerResult(self: *DatabaseClient, allocator: std.mem.Allocator, container_id: []const u8) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs/{s}/colls/{s}", .{ self.endpoint, self.database_id, container_id });
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();
        try self.setCommonHeaders(&req);

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// List all containers in this database.
    pub fn listContainers(self: *DatabaseClient, allocator: std.mem.Allocator) ![]ContainerProperties {
        var r = try self.listContainersResult(allocator);
        return r.unwrap(error.ListContainersFailed);
    }

    /// Same as `listContainers` but returns `Result([]ContainerProperties)`.
    pub fn listContainersResult(self: *DatabaseClient, allocator: std.mem.Allocator) !core.errors.Result([]ContainerProperties) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs/{s}/colls", .{ self.endpoint, self.database_id });
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .GET, url);
        defer req.deinit();
        try self.setCommonHeaders(&req);

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try parseContainerList(allocator, resp.body) };
    }

    /// Get a specific container.
    pub fn getContainer(self: *DatabaseClient, allocator: std.mem.Allocator, container_id: []const u8) !ContainerProperties {
        var r = try self.getContainerResult(allocator, container_id);
        return r.unwrap(error.GetContainerFailed);
    }

    /// Same as `getContainer` but returns `Result(ContainerProperties)`.
    pub fn getContainerResult(self: *DatabaseClient, allocator: std.mem.Allocator, container_id: []const u8) !core.errors.Result(ContainerProperties) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs/{s}/colls/{s}", .{ self.endpoint, self.database_id, container_id });
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .GET, url);
        defer req.deinit();
        try self.setCommonHeaders(&req);

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = parseContainerResponse(allocator, container_id, resp.body) };
    }

    fn setCommonHeaders(self: *DatabaseClient, req: *core.http.Request) !void {
        try req.setHeader("x-ms-version", self.api_version);
        if (self.consistency_level) |cl| {
            try req.setHeader("x-ms-consistency-level", cl.toString());
        }
    }
};

// ─────────────────── ContainerClient ─────────────────

/// Container-level client for item CRUD and queries.
pub const ContainerClient = struct {
    endpoint: []const u8,
    database_id: []const u8,
    container_id: []const u8,
    api_version: []const u8,
    consistency_level: ?ConsistencyLevel,
    pipeline: core.http.HttpPipeline,
    non_idempotent_max_retries: u32,

    /// Create (insert) an item. A failure after transport dispatch returns
    /// `error.CosmosCreateOutcomeUnknown`; the request is never replayed.
    pub fn createItem(self: *ContainerClient, allocator: std.mem.Allocator, item: CosmosItem) !void {
        var r = try self.createItemResult(allocator, item);
        try r.unwrap(error.CreateItemFailed);
    }

    /// Same as `createItem` but returns `Result(void)`.
    pub fn createItemResult(self: *ContainerClient, allocator: std.mem.Allocator, item: CosmosItem) !core.errors.Result(void) {
        const url = try self.buildDocsUrl(allocator);
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try self.setCommonHeaders(&req);
        try req.setHeader("x-ms-documentdb-partitionkey", item.partition_key);
        req.body = item.body;

        var resp = try sendNonIdempotent(
            &self.pipeline,
            &req,
            self.non_idempotent_max_retries,
        );
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// Read an item by id and partition key.
    pub fn readItem(self: *ContainerClient, allocator: std.mem.Allocator, item_id: []const u8, partition_key: []const u8) ![]const u8 {
        var r = try self.readItemResult(allocator, item_id, partition_key);
        return r.unwrap(error.ReadItemFailed);
    }

    /// Same as `readItem` but returns `Result([]const u8)`.
    pub fn readItemResult(self: *ContainerClient, allocator: std.mem.Allocator, item_id: []const u8, partition_key: []const u8) !core.errors.Result([]const u8) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs/{s}/colls/{s}/docs/{s}", .{ self.endpoint, self.database_id, self.container_id, item_id });
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .GET, url);
        defer req.deinit();
        try self.setCommonHeaders(&req);
        try req.setHeader("x-ms-documentdb-partitionkey", partition_key);

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try allocator.dupe(u8, resp.body) };
    }

    /// Replace (update) an item.
    pub fn replaceItem(self: *ContainerClient, allocator: std.mem.Allocator, item: CosmosItem) !void {
        var r = try self.replaceItemResult(allocator, item);
        try r.unwrap(error.ReplaceItemFailed);
    }

    /// Same as `replaceItem` but returns `Result(void)`.
    pub fn replaceItemResult(self: *ContainerClient, allocator: std.mem.Allocator, item: CosmosItem) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs/{s}/colls/{s}/docs/{s}", .{ self.endpoint, self.database_id, self.container_id, item.id });
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try self.setCommonHeaders(&req);
        try req.setHeader("x-ms-documentdb-partitionkey", item.partition_key);
        req.body = item.body;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// Upsert (create or replace) an item.
    pub fn upsertItem(self: *ContainerClient, allocator: std.mem.Allocator, item: CosmosItem) !void {
        var r = try self.upsertItemResult(allocator, item);
        try r.unwrap(error.UpsertItemFailed);
    }

    /// Same as `upsertItem` but returns `Result(void)`.
    pub fn upsertItemResult(self: *ContainerClient, allocator: std.mem.Allocator, item: CosmosItem) !core.errors.Result(void) {
        const url = try self.buildDocsUrl(allocator);
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try self.setCommonHeaders(&req);
        try req.setHeader("x-ms-documentdb-partitionkey", item.partition_key);
        try req.setHeader("x-ms-documentdb-is-upsert", "true");
        req.body = item.body;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// Delete an item.
    pub fn deleteItem(self: *ContainerClient, allocator: std.mem.Allocator, item_id: []const u8, partition_key: []const u8) !void {
        var r = try self.deleteItemResult(allocator, item_id, partition_key);
        try r.unwrap(error.DeleteItemFailed);
    }

    /// Same as `deleteItem` but returns `Result(void)`.
    pub fn deleteItemResult(self: *ContainerClient, allocator: std.mem.Allocator, item_id: []const u8, partition_key: []const u8) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(allocator, "{s}/dbs/{s}/colls/{s}/docs/{s}", .{ self.endpoint, self.database_id, self.container_id, item_id });
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();
        try self.setCommonHeaders(&req);
        try req.setHeader("x-ms-documentdb-partitionkey", partition_key);

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// Execute a SQL query against the container.
    pub fn queryItems(self: *ContainerClient, allocator: std.mem.Allocator, query: []const u8) !QueryResult {
        var r = try self.queryItemsResult(allocator, query);
        return r.unwrap(error.QueryFailed);
    }

    /// Same as `queryItems` but returns `Result(QueryResult)`.
    pub fn queryItemsResult(self: *ContainerClient, allocator: std.mem.Allocator, query: []const u8) !core.errors.Result(QueryResult) {
        const url = try self.buildDocsUrl(allocator);
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(allocator, "{{\"query\":\"{s}\"}}", .{query});
        defer allocator.free(body);

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/query+json");
        try self.setCommonHeaders(&req);
        try req.setHeader("x-ms-documentdb-isquery", "true");
        try req.setHeader("x-ms-max-item-count", "100");
        req.body = body;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        var result = try parseQueryResult(allocator, resp.body);
        errdefer result.deinit(allocator);
        if (resp.getHeader("x-ms-continuation")) |token| {
            try replaceContinuationToken(
                allocator,
                &result.continuation_token,
                token,
            );
        }
        return .{ .ok = result };
    }

    fn buildDocsUrl(self: *ContainerClient, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/dbs/{s}/colls/{s}/docs", .{ self.endpoint, self.database_id, self.container_id });
    }

    fn setCommonHeaders(self: *ContainerClient, req: *core.http.Request) !void {
        try req.setHeader("x-ms-version", self.api_version);
        if (self.consistency_level) |cl| {
            try req.setHeader("x-ms-consistency-level", cl.toString());
        }
    }
};

fn replaceContinuationToken(
    allocator: std.mem.Allocator,
    current: *?[]const u8,
    value: []const u8,
) !void {
    const replacement = try allocator.dupe(u8, value);
    if (current.*) |old| allocator.free(old);
    current.* = replacement;
}

// ─────────────────── JSON Parsing ────────────────────

const ResourceMetaSchema = struct {
    _rid: ?[]const u8 = null,
    _etag: ?[]const u8 = null,
};

fn parseDatabaseResponse(allocator: std.mem.Allocator, id: []const u8, body: []const u8) Database {
    var db = Database{ .id = id };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (serde.json.fromSlice(ResourceMetaSchema, arena.allocator(), body)) |parsed| {
        if (parsed._rid) |s| db.rid = allocator.dupe(u8, s) catch null;
        if (parsed._etag) |s| db.etag = allocator.dupe(u8, s) catch null;
    } else |_| {}
    return db;
}

const IdListEntrySchema = struct {
    id: ?[]const u8 = null,
};

const DatabaseListSchema = struct {
    Databases: ?[]const IdListEntrySchema = null,
};

fn parseDatabaseList(allocator: std.mem.Allocator, body: []const u8) ![]Database {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(DatabaseListSchema, arena.allocator(), body) catch
        return allocator.alloc(Database, 0);
    const entries = parsed.Databases orelse return allocator.alloc(Database, 0);

    var result = try allocator.alloc(Database, entries.len);
    var n: usize = 0;
    errdefer {
        for (result[0..n]) |db| allocator.free(db.id);
        allocator.free(result);
    }
    for (entries) |entry| {
        const id_str = entry.id orelse continue;
        result[n] = .{ .id = try allocator.dupe(u8, id_str) };
        n += 1;
    }
    return result[0..n];
}

fn parseContainerResponse(allocator: std.mem.Allocator, id: []const u8, body: []const u8) ContainerProperties {
    var props = ContainerProperties{ .id = id };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (serde.json.fromSlice(ResourceMetaSchema, arena.allocator(), body)) |parsed| {
        if (parsed._rid) |s| props.rid = allocator.dupe(u8, s) catch null;
        if (parsed._etag) |s| props.etag = allocator.dupe(u8, s) catch null;
    } else |_| {}
    return props;
}

const ContainerListSchema = struct {
    DocumentCollections: ?[]const IdListEntrySchema = null,
};

fn parseContainerList(allocator: std.mem.Allocator, body: []const u8) ![]ContainerProperties {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(ContainerListSchema, arena.allocator(), body) catch
        return allocator.alloc(ContainerProperties, 0);
    const entries = parsed.DocumentCollections orelse return allocator.alloc(ContainerProperties, 0);

    var result = try allocator.alloc(ContainerProperties, entries.len);
    var n: usize = 0;
    errdefer {
        for (result[0..n]) |c| allocator.free(c.id);
        allocator.free(result);
    }
    for (entries) |entry| {
        const id_str = entry.id orelse continue;
        result[n] = .{ .id = try allocator.dupe(u8, id_str) };
        n += 1;
    }
    return result[0..n];
}

const QueryResultMetaSchema = struct {
    _continuation: ?[]const u8 = null,
};

fn parseQueryResult(allocator: std.mem.Allocator, body: []const u8) !QueryResult {
    // Parse document bodies from {"Documents":[...], "_count": N}.
    // We do NOT use a typed schema for the document array because callers
    // want raw JSON-encoded document substrings (each document is then
    // re-parsed by the user with whatever schema they need). Slicing the
    // raw body avoids a round-trip through serde.Value -> JSON.
    var docs = std.ArrayList([]const u8).empty;
    errdefer docs.deinit(allocator);

    const docs_start = std.mem.find(u8, body, "\"Documents\":[") orelse
        return .{ .documents = try allocator.alloc([]const u8, 0) };
    const array_start = docs_start + "\"Documents\":[".len;
    const array_end = std.mem.findScalarPos(u8, body, array_start, ']') orelse
        return .{ .documents = try allocator.alloc([]const u8, 0) };
    const array_content = body[array_start..array_end];

    var depth: u32 = 0;
    var obj_start: ?usize = null;
    for (array_content, 0..) |ch, i| {
        if (ch == '{') {
            if (depth == 0) obj_start = i;
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
            if (depth == 0) {
                if (obj_start) |start| {
                    try docs.append(allocator, try allocator.dupe(u8, array_content[start .. i + 1]));
                }
                obj_start = null;
            }
        }
    }

    // Use serde for the simple `_continuation` field on the top-level envelope.
    var meta_arena = std.heap.ArenaAllocator.init(allocator);
    defer meta_arena.deinit();
    var continuation: ?[]const u8 = null;
    if (serde.json.fromSlice(QueryResultMetaSchema, meta_arena.allocator(), body)) |meta| {
        if (meta._continuation) |s| continuation = try allocator.dupe(u8, s);
    } else |_| {}

    return .{
        .documents = try docs.toOwnedSlice(allocator),
        .continuation_token = continuation,
    };
}

// ─────────────────────── Tests ───────────────────────

test "ConsistencyLevel toString" {
    try std.testing.expectEqualStrings("Strong", ConsistencyLevel.strong.toString());
    try std.testing.expectEqualStrings("Session", ConsistencyLevel.session.toString());
    try std.testing.expectEqualStrings("Eventual", ConsistencyLevel.eventual.toString());
}

var testing_crypto_provider = core.crypto.StdCryptoProvider.init(std.testing.io);

fn testGetToken(
    _: *core.credentials.TokenCredential,
    request_context: core.credentials.TokenRequestContext,
    _: core.context.Context,
    _: core.http.HttpRuntime,
) anyerror!core.credentials.AccessToken {
    try std.testing.expectEqual(@as(usize, 1), request_context.scopes.len);
    try std.testing.expectEqualStrings(cosmos_scope, request_context.scopes[0]);
    return .{ .token = "test-token", .expires_on = 4_102_444_800 };
}

var testing_credential = core.credentials.TokenCredential{
    .getTokenFn = &testGetToken,
};

fn testingRuntime(transport: core.http.HttpTransport) core.http.HttpRuntime {
    return .init(transport, testing_crypto_provider.asProvider());
}

fn createTestClient(mock: *core.http.MockTransport) !CosmosClient {
    return CosmosClient.init(
        mock.allocator,
        "https://myaccount.documents.azure.com",
        &testing_credential,
        testingRuntime(mock.asTransport()),
        .{},
    );
}

test "CosmosClient createDatabase" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 201,
        \\{"id":"testdb","_rid":"abc","_etag":"\"00000000-0000-0000-0000-000000000000\""}
    );
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    const db = try client.createDatabase(allocator, "testdb");
    defer db.deinit(allocator, false);
    try std.testing.expectEqualStrings("testdb", db.id);
    try std.testing.expectEqual(core.http.Method.POST, mock.last_method.?);
    try std.testing.expect(std.mem.endsWith(u8, mock.last_url.?, "/dbs"));
    try std.testing.expect(mock.last_headers.get("x-ms-date") != null);
}

test "CosmosClient deleteDatabase" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 204, "");
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    try client.deleteDatabase(allocator, "testdb");
    try std.testing.expectEqual(core.http.Method.DELETE, mock.last_method.?);
    try std.testing.expect(std.mem.endsWith(u8, mock.last_url.?, "/dbs/testdb"));
}

test "CosmosClient listDatabases" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"Databases":[{"id":"db1"},{"id":"db2"}],"_count":2}
    );
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    const dbs = try client.listDatabases(allocator);
    defer {
        for (dbs) |db| allocator.free(db.id);
        allocator.free(dbs);
    }
    try std.testing.expectEqual(@as(usize, 2), dbs.len);
    try std.testing.expectEqualStrings("db1", dbs[0].id);
    try std.testing.expectEqualStrings("db2", dbs[1].id);
}

test "CosmosClient database returns DatabaseClient" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "");
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db_client = client.database("mydb");
    try std.testing.expectEqualStrings("mydb", db_client.database_id);

    // Verify DatabaseClient can create a ContainerClient.
    const ctr_client = db_client.container("myctr");
    try std.testing.expectEqualStrings("myctr", ctr_client.container_id);
    try std.testing.expectEqualStrings("mydb", ctr_client.database_id);
}

test "DatabaseClient createContainer" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 201,
        \\{"id":"myctr","_rid":"xyz"}
    );
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db = client.database("mydb");
    const ctr = try db.createContainer(allocator, "myctr", "/pk");
    // createContainer assembles the struct locally from the inputs — no
    // allocations to free.
    try std.testing.expectEqualStrings("myctr", ctr.id);
    try std.testing.expect(std.mem.find(u8, mock.last_url.?, "/dbs/mydb/colls") != null);
}

test "DatabaseClient listContainers" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"DocumentCollections":[{"id":"c1"},{"id":"c2"},{"id":"c3"}],"_count":3}
    );
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db = client.database("mydb");
    const containers = try db.listContainers(allocator);
    defer {
        for (containers) |c| allocator.free(c.id);
        allocator.free(containers);
    }
    try std.testing.expectEqual(@as(usize, 3), containers.len);
    try std.testing.expectEqualStrings("c1", containers[0].id);
}

test "ContainerClient createItem" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 201,
        \\{"id":"item1"}
    );
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db = client.database("mydb");
    var ctr = db.container("myctr");
    try ctr.createItem(allocator, .{
        .id = "item1",
        .partition_key = "[ \"pk1\" ]",
        .body =
        \\{"id":"item1","pk":"pk1","name":"test"}
        ,
    });
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqual(core.http.Method.POST, mock.last_method.?);
    try std.testing.expect(std.mem.endsWith(u8, mock.last_url.?, "/docs"));
    try std.testing.expectEqualStrings(
        "[ \"pk1\" ]",
        mock.last_headers.get("x-ms-documentdb-partitionkey").?,
    );
}

test "ContainerClient readItem" {
    const allocator = std.testing.allocator;
    const expected_body =
        \\{ "id": "item1", "values": [1e+02,9007199254740993], "name": "\u0074est" }
    ;
    var mock = core.http.MockTransport.init(allocator, 200, expected_body);
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db = client.database("mydb");
    var ctr = db.container("myctr");
    const body = try ctr.readItem(allocator, "item1", "[ \"pk1\" ]");
    defer allocator.free(body);
    try std.testing.expectEqualStrings(expected_body, body);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqual(core.http.Method.GET, mock.last_method.?);
    try std.testing.expectEqualStrings(
        "[ \"pk1\" ]",
        mock.last_headers.get("x-ms-documentdb-partitionkey").?,
    );
}

test "ContainerClient upsertItem" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"id":"item1"}
    );
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db = client.database("mydb");
    var ctr = db.container("myctr");
    try ctr.upsertItem(allocator, .{
        .id = "item1",
        .partition_key = "[\"pk1\"]",
        .body =
        \\{"id":"item1","pk":"pk1"}
        ,
    });
    try std.testing.expectEqual(core.http.Method.POST, mock.last_method.?);
}

test "ContainerClient deleteItem" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 204, "");
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db = client.database("mydb");
    var ctr = db.container("myctr");
    try ctr.deleteItem(allocator, "item1", "[\"pk1\"]");
    try std.testing.expectEqual(core.http.Method.DELETE, mock.last_method.?);
    try std.testing.expect(std.mem.endsWith(u8, mock.last_url.?, "/docs/item1"));
}

test "ContainerClient queryItems" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"Documents":[{"id":"a","val":1e+02},{"id":"b","val":9007199254740993}],"_count":2}
    );
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db = client.database("mydb");
    var ctr = db.container("myctr");
    var result = try ctr.queryItems(allocator, "SELECT * FROM c");
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.documents.len);
    try std.testing.expectEqualStrings("{\"id\":\"a\",\"val\":1e+02}", result.documents[0]);
    try std.testing.expectEqualStrings("{\"id\":\"b\",\"val\":9007199254740993}", result.documents[1]);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqual(core.http.Method.POST, mock.last_method.?);
    try std.testing.expectEqualStrings("true", mock.last_headers.get("x-ms-documentdb-isquery").?);
    try std.testing.expectEqualStrings("100", mock.last_headers.get("x-ms-max-item-count").?);
}

test "ContainerClient readItem 404" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 404,
        \\{"code":"NotFound","message":"Entity not found"}
    );
    defer mock.deinit();
    var client = try createTestClient(&mock);
    defer client.deinit();
    var db = client.database("mydb");
    var ctr = db.container("myctr");
    const result = ctr.readItem(allocator, "missing", "[\"pk\"]");
    try std.testing.expectError(error.ReadItemFailed, result);
}

test "CosmosClient with consistency level" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"Databases":[],"_count":0}
    );
    defer mock.deinit();
    var client = try CosmosClient.init(
        allocator,
        "https://myaccount.documents.azure.com",
        &testing_credential,
        testingRuntime(mock.asTransport()),
        .{ .consistency_level = .session },
    );
    defer client.deinit();
    const dbs = try client.listDatabases(allocator);
    defer allocator.free(dbs);
    try std.testing.expectEqual(@as(usize, 0), dbs.len);
    try std.testing.expectEqualStrings(
        "Session",
        mock.last_headers.get("x-ms-consistency-level").?,
    );
}

const RuntimeCredentialSpy = struct {
    credential: core.credentials.TokenCredential,
    expected_transport_context: *anyopaque,
    expected_crypto_context: *anyopaque,
    calls: usize = 0,

    fn init(runtime: core.http.HttpRuntime) RuntimeCredentialSpy {
        return .{
            .credential = .{ .getTokenFn = &getToken },
            .expected_transport_context = runtime.transport.context,
            .expected_crypto_context = runtime.crypto.context,
        };
    }

    fn asCredential(self: *RuntimeCredentialSpy) *core.credentials.TokenCredential {
        return &self.credential;
    }

    fn getToken(
        credential: *core.credentials.TokenCredential,
        request_context: core.credentials.TokenRequestContext,
        _: core.context.Context,
        runtime: core.http.HttpRuntime,
    ) anyerror!core.credentials.AccessToken {
        const self: *RuntimeCredentialSpy =
            @alignCast(@fieldParentPtr("credential", credential));
        self.calls += 1;
        try std.testing.expectEqual(@as(usize, 1), request_context.scopes.len);
        try std.testing.expectEqualStrings(cosmos_scope, request_context.scopes[0]);
        try std.testing.expectEqual(
            self.expected_transport_context,
            runtime.transport.context,
        );
        try std.testing.expectEqual(
            self.expected_crypto_context,
            runtime.crypto.context,
        );
        return .{ .token = "runtime-token", .expires_on = 4_102_444_800 };
    }
};

const CryptoProviderSpy = struct {
    random_calls: usize = 0,
    fail_random: bool = false,

    const vtable: core.crypto.CryptoProvider.VTable = .{
        .random_bytes = &randomBytes,
        .md5 = &md5,
        .sha256 = &sha256,
        .hmac_sha256 = &hmacSha256,
        .sha256_init = &sha256Init,
    };

    fn asProvider(self: *CryptoProviderSpy) core.crypto.CryptoProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    fn randomBytes(context: *anyopaque, out: []u8) !void {
        const self: *CryptoProviderSpy = @ptrCast(@alignCast(context));
        self.random_calls += 1;
        if (self.fail_random) return error.InjectedCryptoFailure;
        @memset(out, 0xa5);
    }

    fn md5(_: *anyopaque, _: []const u8, out: *core.crypto.Md5Digest) !void {
        @memset(out, 0);
    }

    fn sha256(_: *anyopaque, _: []const u8, out: *core.crypto.Sha256Digest) !void {
        @memset(out, 0);
    }

    fn hmacSha256(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        out: *core.crypto.HmacSha256Digest,
    ) !void {
        @memset(out, 0);
    }

    fn sha256Init(
        _: *anyopaque,
        _: std.mem.Allocator,
    ) !core.crypto.Sha256Operation {
        return error.Unused;
    }
};

const IncrementingTimeSource = struct {
    timestamp: i64,
    calls: usize = 0,

    fn now(context: *anyopaque) i64 {
        const self: *IncrementingTimeSource = @ptrCast(@alignCast(context));
        const value = self.timestamp + @as(i64, @intCast(self.calls));
        self.calls += 1;
        return value;
    }

    fn asTimeSource(self: *IncrementingTimeSource) TimeSource {
        return .{ .context = self, .nowFn = &now };
    }
};

const DateCapturingTransport = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,
    dates: [2][32]u8 = undefined,
    date_lengths: [2]usize = .{0} ** 2,

    const vtable: core.http.HttpTransport.VTable = .{ .send = &send };

    fn asTransport(self: *DateCapturingTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(
        context: *anyopaque,
        request: *core.http.Request,
    ) anyerror!core.http.Response {
        const self: *DateCapturingTransport = @ptrCast(@alignCast(context));
        const index = self.calls;
        if (index >= self.dates.len) return error.TooManyTestCalls;
        const date = request.getHeader("x-ms-date") orelse
            return error.MissingCosmosDate;
        if (date.len > self.dates[index].len)
            return error.InvalidCosmosDate;
        @memcpy(self.dates[index][0..date.len], date);
        self.date_lengths[index] = date.len;
        self.calls += 1;

        const body = try self.allocator.dupe(
            u8,
            if (index == 0) "{}" else "{\"Databases\":[],\"_count\":0}",
        );
        return .{
            .status_code = if (index == 0) 500 else 200,
            .headers = std.StringHashMap([]const u8).init(self.allocator),
            .body = body,
            .allocator = self.allocator,
        };
    }
};

const PreTransportOncePolicy = struct {
    calls: usize = 0,
    policy: core.http.HttpPolicy = .{ .processFn = &process },

    fn process(
        policy: *core.http.HttpPolicy,
        request: *core.http.Request,
        next: []*core.http.HttpPolicy,
        runtime: core.http.HttpRuntime,
    ) anyerror!core.http.Response {
        const self: *PreTransportOncePolicy =
            @alignCast(@fieldParentPtr("policy", policy));
        self.calls += 1;
        if (self.calls == 1) return error.InjectedPreTransportFailure;
        return callNext(request, next, runtime);
    }
};

const FailingCreateTransport = struct {
    calls: usize = 0,

    const vtable: core.http.HttpTransport.VTable = .{ .send = &send };

    fn asTransport(self: *FailingCreateTransport) core.http.HttpTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(
        context: *anyopaque,
        _: *core.http.Request,
    ) anyerror!core.http.Response {
        const self: *FailingCreateTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        return error.InjectedTransportFailure;
    }
};

test "CosmosClient rejects non-HTTPS authenticated endpoints" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();

    try std.testing.expectError(
        error.HttpsRequired,
        CosmosClient.init(
            allocator,
            "http://localhost:8081",
            &testing_credential,
            testingRuntime(transport.asTransport()),
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);
}

test "x-ms-date is regenerated for every retry attempt" {
    const allocator = std.testing.allocator;
    var transport = DateCapturingTransport{ .allocator = allocator };
    var clock = IncrementingTimeSource{ .timestamp = 1_700_000_000 };
    var client = try CosmosClient.init(
        allocator,
        "https://myaccount.documents.azure.com",
        &testing_credential,
        testingRuntime(transport.asTransport()),
        .{ .time_source = clock.asTimeSource() },
    );
    defer client.deinit();
    client.pipeline_state.retry.max_retries = 1;
    client.pipeline_state.retry.initial_delay_ms = 0;
    client.pipeline_state.retry.max_delay_ms = 0;

    const databases = try client.listDatabases(allocator);
    defer allocator.free(databases);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expectEqual(@as(usize, 2), clock.calls);
    try std.testing.expectEqualStrings(
        "Tue, 14 Nov 2023 22:13:20 GMT",
        transport.dates[0][0..transport.date_lengths[0]],
    );
    try std.testing.expectEqualStrings(
        "Tue, 14 Nov 2023 22:13:21 GMT",
        transport.dates[1][0..transport.date_lengths[1]],
    );
}

test "non-idempotent creates retry only before transport starts" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 201,
        \\{"id":"testdb"}
    );
    defer transport.deinit();
    var pre_transport = PreTransportOncePolicy{};
    var client = try CosmosClient.init(
        allocator,
        "https://myaccount.documents.azure.com",
        &testing_credential,
        testingRuntime(transport.asTransport()),
        .{ .policies = &.{&pre_transport.policy} },
    );
    defer client.deinit();
    client.pipeline_state.retry.max_retries = 1;

    const database = try client.createDatabase(allocator, "testdb");
    try std.testing.expectEqualStrings("testdb", database.id);
    try std.testing.expectEqual(@as(usize, 2), pre_transport.calls);
    try std.testing.expectEqual(@as(usize, 1), transport.call_count);
}

test "non-idempotent creates are not replayed after transport starts" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |instrumented| {
        var transport = FailingCreateTransport{};
        const runtime = testingRuntime(transport.asTransport());
        var probe = TracingProbe{};
        var tracing = try probe.createProvider(runtime.crypto);
        defer tracing.deinit() catch unreachable;
        var client = try CosmosClient.init(
            allocator,
            "https://myaccount.documents.azure.com",
            &testing_credential,
            runtime,
            .{ .instrumentation = if (instrumented) TracingProbe.options(&tracing) else null },
        );
        defer client.deinit();

        try std.testing.expectError(
            error.CosmosCreateOutcomeUnknown,
            client.createDatabase(allocator, "testdb"),
        );
        try std.testing.expectEqual(@as(usize, 1), transport.calls);

        var database = client.database("testdb");
        try std.testing.expectError(
            error.CosmosCreateOutcomeUnknown,
            database.createContainer(allocator, "testcontainer", "/pk"),
        );
        try std.testing.expectEqual(@as(usize, 2), transport.calls);

        var container = database.container("testcontainer");
        try std.testing.expectError(
            error.CosmosCreateOutcomeUnknown,
            container.createItem(allocator, .{
                .id = "item1",
                .partition_key = "[\"pk1\"]",
                .body = "{\"id\":\"item1\",\"pk\":\"pk1\"}",
            }),
        );
        try std.testing.expectEqual(@as(usize, 3), transport.calls);
        try tracing.forceFlush(1000);
        try std.testing.expectEqual(@as(usize, if (instrumented) 3 else 0), probe.count);
        for (probe.statuses[0..probe.count]) |status|
            try std.testing.expectEqual(core.tracing.SpanStatus.@"error", status);
    }
}

test "non-idempotent creates do not follow 307 or 308 redirects" {
    const allocator = std.testing.allocator;
    for ([_]u16{ 307, 308 }) |status| {
        const redirect_headers = [_]core.http.MockTransport.HeaderPair{
            .{
                .name = "Location",
                .value = "https://myaccount.documents.azure.com/redirected",
            },
        };
        const responses = [_]core.http.SequenceMockTransport.CannedResponse{
            .{
                .status = status,
                .body = "{\"code\":\"Redirect\",\"message\":\"not followed\"}",
                .headers = &redirect_headers,
            },
        };
        var transport = core.http.SequenceMockTransport.init(
            allocator,
            &responses,
        );
        var client = try CosmosClient.init(
            allocator,
            "https://myaccount.documents.azure.com",
            &testing_credential,
            testingRuntime(transport.asTransport()),
            .{},
        );
        defer client.deinit();

        var result = try client.createDatabaseResult(allocator, "testdb");
        defer result.deinit(allocator);
        switch (result) {
            .err => |failure| try std.testing.expectEqual(
                status,
                failure.status_code,
            ),
            .ok => return error.ExpectedRedirectFailure,
        }
        try std.testing.expectEqual(@as(usize, 1), transport.call_count);
        try std.testing.expectEqual(
            core.http.Method.POST,
            transport.captured_methods[0].?,
        );
    }
}

test "derived clients preserve the selected runtime and authentication" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200,
        \\{"DocumentCollections":[],"_count":0}
    );
    defer transport.deinit();
    var crypto = CryptoProviderSpy{};
    const runtime = core.http.HttpRuntime.init(
        transport.asTransport(),
        crypto.asProvider(),
    );
    var credential = RuntimeCredentialSpy.init(runtime);
    var client = try CosmosClient.init(
        allocator,
        "https://myaccount.documents.azure.com",
        credential.asCredential(),
        runtime,
        .{},
    );
    defer client.deinit();

    var database = client.database("mydb");
    const container = database.container("mycontainer");
    try std.testing.expectEqual(
        runtime.transport.context,
        database.pipeline.runtime.transport.context,
    );
    try std.testing.expectEqual(
        runtime.crypto.context,
        container.pipeline.runtime.crypto.context,
    );

    const containers = try database.listContainers(allocator);
    defer allocator.free(containers);
    try std.testing.expectEqual(@as(usize, 1), crypto.random_calls);
    try std.testing.expectEqual(@as(usize, 1), credential.calls);
    try std.testing.expectEqual(@as(usize, 1), transport.call_count);
    try std.testing.expect(
        transport.last_headers.get("x-ms-client-request-id") != null,
    );
    try std.testing.expectEqualStrings(
        "type%3Daad%26ver%3D1.0%26sig%3Druntime-token",
        transport.last_headers.get("Authorization").?,
    );
}

test "crypto provider failure is atomic before authentication and send" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200,
        \\{"Databases":[],"_count":0}
    );
    defer transport.deinit();
    var crypto = CryptoProviderSpy{ .fail_random = true };
    const runtime = core.http.HttpRuntime.init(
        transport.asTransport(),
        crypto.asProvider(),
    );
    var credential = RuntimeCredentialSpy.init(runtime);
    var client = try CosmosClient.init(
        allocator,
        "https://myaccount.documents.azure.com",
        credential.asCredential(),
        runtime,
        .{},
    );
    defer client.deinit();

    try std.testing.expectError(
        error.InjectedCryptoFailure,
        client.listDatabases(allocator),
    );
    try std.testing.expectEqual(@as(usize, 1), crypto.random_calls);
    try std.testing.expectEqual(@as(usize, 0), credential.calls);
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);
}

test "query continuation comes from the response header" {
    const allocator = std.testing.allocator;
    const header_token = "opaque%2B/+==:[]";
    var transport = core.http.MockTransport.init(allocator, 200,
        \\{"Documents":[{"id":"a"}],"_continuation":"body-token"}
    );
    defer transport.deinit();
    const headers = [_]core.http.MockTransport.HeaderPair{
        .{ .name = "x-ms-continuation", .value = header_token },
    };
    transport.response_headers_list = &headers;
    var client = try createTestClient(&transport);
    defer client.deinit();
    var database = client.database("mydb");
    var container = database.container("mycontainer");

    var result = try container.queryItems(allocator, "SELECT * FROM c");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings(
        header_token,
        result.continuation_token.?,
    );
    try std.testing.expectEqual(@as(usize, 1), transport.call_count);
}

test "continuation replacement preserves the old token on allocation failure" {
    const allocator = std.testing.allocator;
    const old = try allocator.dupe(u8, "body-token");
    var current: ?[]const u8 = old;
    var failing = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        replaceContinuationToken(
            failing.allocator(),
            &current,
            "header-token",
        ),
    );
    try std.testing.expectEqual(old.ptr, current.?.ptr);
    try std.testing.expectEqualStrings("body-token", current.?);

    try replaceContinuationToken(allocator, &current, "header-token");
    defer allocator.free(current.?);
    try std.testing.expectEqualStrings("header-token", current.?);
}

const TracingProbe = struct {
    exporter: core.tracing.SpanExporter = .{ .exportFn = exportBatch },
    count: usize = 0,
    ids: [8][16]u8 = undefined,
    statuses: [8]core.tracing.SpanStatus = undefined,

    const parent: core.tracing.TraceContext = .{
        .trace_id = "0af7651916cd43dd8448eb211c80319c".*,
        .span_id = "b7ad6b7169203331".*,
        .trace_flags = 1,
        .trace_state = "vendor=value",
    };

    fn createProvider(self: *TracingProbe, crypto: core.crypto.CryptoProvider) !core.tracing.ExportingTracerProvider {
        return .init(std.testing.allocator, std.testing.io, crypto, &self.exporter, .{
            .max_spans = 8,
            .max_queued_spans = 8,
        });
    }

    fn options(provider: *core.tracing.ExportingTracerProvider) core.tracing.InstrumentationOptions {
        return .{
            .provider = provider.asProvider(),
            .scope_name = "caller.cosmos",
            .scope_version = "caller-version",
            .namespace = "Caller.Cosmos",
            .parent_context = parent,
        };
    }

    fn wireId(mock: *core.http.MockTransport) ![16]u8 {
        const context = core.tracing.TraceContext.parseTraceparent(
            mock.last_headers.get("traceparent") orelse return error.MissingTraceparent,
        ) orelse return error.InvalidTraceparent;
        try std.testing.expectEqualStrings(&parent.trace_id, &context.trace_id);
        try std.testing.expect(!std.mem.eql(u8, &parent.span_id, &context.span_id));
        try std.testing.expectEqualStrings(parent.trace_state.?, mock.last_headers.get("tracestate").?);
        return context.span_id;
    }

    fn exportBatch(exporter: *core.tracing.SpanExporter, batch: []const core.tracing.SpanData, _: core.tracing.ExportContext) !void {
        const self: *TracingProbe = @fieldParentPtr("exporter", exporter);
        for (batch) |data| {
            try std.testing.expect(self.count < self.ids.len);
            try std.testing.expectEqualStrings("caller.cosmos", data.scope_name);
            try std.testing.expectEqualStrings("caller-version", data.scope_version);
            try std.testing.expectEqualStrings(&parent.trace_id, &data.context.trace_id);
            try std.testing.expectEqualStrings(&parent.span_id, &data.parent_span_id.?);
            var namespace_seen = false;
            for (data.attributes) |attribute| {
                if (attribute.value == .string and std.mem.eql(u8, attribute.value.string, "Caller.Cosmos"))
                    namespace_seen = true;
            }
            try std.testing.expect(namespace_seen);
            self.ids[self.count] = data.context.span_id;
            self.statuses[self.count] = data.status;
            self.count += 1;
        }
    }
};

const FailingTracingProvider = struct {
    provider: core.tracing.TracerProvider = .{ .getTracerFn = getTracer },
    tracer: core.tracing.Tracer = .{ .startSpanFn = startSpan },
    attempts: usize = 0,

    fn getTracer(provider: *core.tracing.TracerProvider, _: []const u8, _: []const u8) *core.tracing.Tracer {
        const self: *FailingTracingProvider = @fieldParentPtr("provider", provider);
        return &self.tracer;
    }

    fn startSpan(tracer: *core.tracing.Tracer, _: []const u8, _: core.tracing.SpanKind) !*core.tracing.Span {
        const self: *FailingTracingProvider = @fieldParentPtr("tracer", tracer);
        self.attempts += 1;
        return error.InjectedTracingFailure;
    }
};

test "Cosmos tracing inherits through clients without changing raw read create or query data" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, "{\"Databases\":[{\"id\":\"db\"}]}");
    defer mock.deinit();
    const runtime = testingRuntime(mock.asTransport());
    var probe = TracingProbe{};
    var tracing = try probe.createProvider(runtime.crypto);
    defer tracing.deinit() catch unreachable;
    var ids: [5][16]u8 = undefined;
    {
        const scope = try allocator.dupe(u8, "caller.cosmos");
        defer allocator.free(scope);
        const state = try allocator.dupe(u8, TracingProbe.parent.trace_state.?);
        defer allocator.free(state);
        var instrumentation = TracingProbe.options(&tracing);
        instrumentation.scope_name = scope;
        instrumentation.parent_context.?.trace_state = state;
        var client = try CosmosClient.init(
            allocator,
            "https://myaccount.documents.azure.com",
            &testing_credential,
            runtime,
            .{ .instrumentation = instrumentation },
        );
        defer client.deinit();
        const databases = try client.listDatabases(allocator);
        defer {
            for (databases) |entry| entry.deinit(allocator, true);
            allocator.free(databases);
        }
        try std.testing.expectEqual(@as(usize, 1), databases.len);
        ids[0] = try TracingProbe.wireId(&mock);
        var database = client.database("db");
        mock.response_body = "{\"DocumentCollections\":[{\"id\":\"container\"}]}";
        const containers = try database.listContainers(allocator);
        defer {
            for (containers) |entry| entry.deinit(allocator, true);
            allocator.free(containers);
        }
        try std.testing.expectEqual(@as(usize, 1), containers.len);
        ids[1] = try TracingProbe.wireId(&mock);
        var container = database.container("container");
        const document = "{ \"id\":\"item\", \"nested\":[true,{\"text\":\"a\\\"b\"}], \"n\":1e+02 }";
        const partition = "[\"a\\\"b\",null,1e+02]";
        mock.response_body = document;
        const body = try container.readItem(allocator, "item", partition);
        defer allocator.free(body);
        try std.testing.expectEqualStrings(document, body);
        try std.testing.expectEqualStrings(partition, mock.last_headers.get("x-ms-documentdb-partitionkey").?);
        ids[2] = try TracingProbe.wireId(&mock);

        const token = "opaque%2B/+==:[]";
        const headers = [_]core.http.MockTransport.HeaderPair{
            .{ .name = "x-ms-continuation", .value = token },
        };
        mock.response_headers_list = &headers;
        mock.response_body = "{\"Documents\":[{\"id\":\"item\",\"n\":1e+02}],\"_continuation\":\"body-token\"}";
        var page = try container.queryItems(allocator, "SELECT * FROM c");
        defer page.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), page.documents.len);
        try std.testing.expectEqualStrings("{\"id\":\"item\",\"n\":1e+02}", page.documents[0]);
        try std.testing.expectEqualStrings(token, page.continuation_token.?);
        ids[3] = try TracingProbe.wireId(&mock);

        mock.response_body = "{}";
        try container.createItem(allocator, .{ .id = "item", .partition_key = partition, .body = document });
        try std.testing.expectEqualStrings(document, mock.last_body.?);
        try std.testing.expectEqualStrings(partition, mock.last_headers.get("x-ms-documentdb-partitionkey").?);
        ids[4] = try TracingProbe.wireId(&mock);
        try std.testing.expectEqual(@as(usize, 5), mock.call_count);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expectEqual(@as(usize, 0), tracing.stats().active_spans);
    try std.testing.expectEqual(@as(usize, 5), tracing.stats().queued_spans);
    try tracing.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 5), probe.count);
    for (ids, 0..) |id, i| try std.testing.expectEqualStrings(&id, &probe.ids[i]);
    try tracing.shutdown(1000);
}

test "disabled or failing Cosmos tracing preserves read results and request counts" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |instrumented| {
        for ([_]u16{ 200, 404 }) |status| {
            var mock = core.http.MockTransport.init(allocator, status, "{\"id\":\"item\"}");
            defer mock.deinit();
            var tracing = FailingTracingProvider{};
            var client = try CosmosClient.init(
                allocator,
                "https://myaccount.documents.azure.com",
                &testing_credential,
                testingRuntime(mock.asTransport()),
                .{ .instrumentation = if (instrumented) .{
                    .provider = &tracing.provider,
                    .scope_name = "caller.cosmos",
                } else null },
            );
            defer client.deinit();
            var database = client.database("db");
            var container = database.container("container");
            if (status == 200) {
                const body = try container.readItem(allocator, "item", "[\"pk\"]");
                defer allocator.free(body);
                try std.testing.expectEqualStrings("{\"id\":\"item\"}", body);
            } else {
                try std.testing.expectError(error.ReadItemFailed, container.readItem(allocator, "item", "[\"pk\"]"));
            }
            try std.testing.expectEqual(@as(usize, 1), mock.call_count);
            try std.testing.expectEqual(@as(usize, @intFromBool(instrumented)), tracing.attempts);
            try std.testing.expect(mock.last_headers.get("traceparent") == null);
            try std.testing.expect(mock.last_headers.get("tracestate") == null);
        }
    }
}
