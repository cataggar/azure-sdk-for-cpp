const std = @import("std");
const core = @import("azure_sdk_core");

var testing_crypto_provider = core.crypto.StdCryptoProvider.init(std.testing.io);

fn testingRuntime(http_transport: core.http.HttpTransport) core.http.HttpRuntime {
    return .init(http_transport, testing_crypto_provider.asProvider());
}
const auth = @import("auth.zig");
const Configuration = @import("client_configuration.zig").Configuration;
const client = @import("client.zig");
const options = @import("options.zig");
const pipeline = @import("pipeline.zig");
const protocol_client = @import("protocol_client.zig");
const request = @import("request.zig");
const sas = @import("sas.zig");
const pager = @import("pager.zig");
const responses = @import("responses.zig");
const service_models = @import("service_models.zig");

/// Client for Azure Table Service operations (list/create/delete tables).
///
/// Explicit credentials, configured policies, and runtime backend contexts
/// are borrowed and must outlive the client and in-flight calls. The client owns
/// its endpoint, API version, policy pointer list, bearer-token cache, and any
/// credential created from a connection string.
/// Calls must be serialized because the token cache and standard transport are
/// mutable and not thread-safe.
pub const TableServiceClient = struct {
    allocator: std.mem.Allocator,
    protocol: protocol_client.ProtocolClient,
    pipeline_state: *pipeline.PipelineState,
    owned_credential: ?*auth.SharedKeyCredential = null,

    pub const Options = options.TableServiceClientOptions;
    pub const InitOptions = options.TableServiceClientInitOptions;

    pub fn init(
        allocator: std.mem.Allocator,
        runtime: core.http.HttpRuntime,
        init_options: InitOptions,
    ) !TableServiceClient {
        var configuration = try Configuration.init(allocator, init_options.authentication);
        defer configuration.deinit();
        const state = try configuration.createPipeline(runtime, init_options.options);
        errdefer state.deinit();
        const protocol = try protocol_client.ProtocolClient.init(
            allocator,
            configuration.endpoint,
            state.pipeline,
            .{
                .api_version = init_options.options.api_version,
                .endpoint_query_is_sas = state.usesSas(),
            },
        );
        const owned_credential = configuration.owned_credential;
        configuration.owned_credential = null;
        return .{
            .allocator = allocator,
            .protocol = protocol,
            .pipeline_state = state,
            .owned_credential = owned_credential,
        };
    }

    /// Creates a table client that shares this service client's pipeline,
    /// bearer-token cache, and transport. The returned client must be
    /// deinitialized before, and may not outlive, this service client.
    pub fn getTableClient(
        self: *TableServiceClient,
        table_name: []const u8,
    ) !client.TableClient {
        try request.validateTableName(table_name);
        const sas_endpoint = if (self.protocol.endpoint.has_query)
            try std.fmt.allocPrint(
                self.allocator,
                "{s}?{s}",
                .{
                    self.protocol.endpoint.base_url,
                    self.protocol.endpoint.raw_query,
                },
            )
        else
            null;
        defer if (sas_endpoint) |endpoint| self.allocator.free(endpoint);
        var protocol = try protocol_client.ProtocolClient.init(
            self.allocator,
            sas_endpoint orelse self.protocol.endpoint.base_url,
            self.pipeline_state.pipeline,
            .{
                .api_version = self.protocol.api_version,
                .endpoint_query_is_sas = self.pipeline_state.usesSas(),
                .mutation_retry = self.pipeline_state.retryOptions(),
                .default_operation_timeout_ms = self.pipeline_state.operationTimeoutMs(),
            },
        );
        errdefer protocol.deinit();
        return .{
            .allocator = self.allocator,
            .protocol = protocol,
            .table_name = try self.allocator.dupe(u8, table_name),
            .pipeline_state = self.pipeline_state,
            .owns_pipeline_state = false,
        };
    }

    pub fn deinit(self: *TableServiceClient) void {
        self.protocol.deinit();
        self.pipeline_state.deinit();
        if (self.owned_credential) |credential| {
            credential.deinit();
            self.allocator.destroy(credential);
        }
        self.* = undefined;
    }

    /// Formats a query-redacted endpoint so SAS signatures never enter logs.
    pub fn format(self: TableServiceClient, writer: anytype) !void {
        try writer.print("TableServiceClient({s})", .{self.protocol.endpoint.base_url});
    }

    /// Generates a full Table-service account SAS URL. This is available only
    /// on a Shared Key client; the returned URL is secret and caller-owned.
    pub fn getAccountSasUrl(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        signature_values: sas.AccountSignatureValues,
    ) ![]u8 {
        const credential = self.pipeline_state.sharedKeyCredential() orelse
            return error.SasRequiresSharedKeyCredential;
        var parameters = try signature_values.sign(
            allocator,
            credential,
            self.pipeline_state.pipeline.runtime.crypto,
        );
        defer parameters.deinit();
        const service_url = try std.fmt.allocPrint(
            allocator,
            "{s}/",
            .{self.protocol.endpoint.base_url},
        );
        defer allocator.free(service_url);
        return parameters.appendToUrl(allocator, service_url);
    }
    pub fn createTableResult(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        table_name: []const u8,
        create_options: options.CreateTableOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.CreateTableResponse)) {
        return self.protocol.createTable(allocator, table_name, create_options);
    }

    pub fn createTable(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        table_name: []const u8,
        create_options: options.CreateTableOptions,
    ) !responses.SdkResponse(protocol_client.CreateTableResponse) {
        return responses.unwrapCreateTable(
            responses.SdkResponse(protocol_client.CreateTableResponse),
            try self.createTableResult(allocator, table_name, create_options),
        );
    }

    pub fn deleteTableResult(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        table_name: []const u8,
        delete_options: options.DeleteTableOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.DeleteTableResponse)) {
        return self.protocol.deleteTable(allocator, table_name, delete_options);
    }

    pub fn deleteTable(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        table_name: []const u8,
        delete_options: options.DeleteTableOptions,
    ) !responses.SdkResponse(protocol_client.DeleteTableResponse) {
        return responses.unwrapDeleteTable(
            responses.SdkResponse(protocol_client.DeleteTableResponse),
            try self.deleteTableResult(allocator, table_name, delete_options),
        );
    }

    pub fn setServicePropertiesResult(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        properties: service_models.ServiceProperties,
        set_options: options.SetServicePropertiesOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.SetServicePropertiesResponse)) {
        return self.protocol.setServiceProperties(allocator, properties, set_options.protocol);
    }

    pub fn setServiceProperties(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        properties: service_models.ServiceProperties,
        set_options: options.SetServicePropertiesOptions,
    ) !responses.SdkResponse(protocol_client.SetServicePropertiesResponse) {
        return responses.unwrapSetServiceProperties(
            responses.SdkResponse(protocol_client.SetServicePropertiesResponse),
            try self.setServicePropertiesResult(allocator, properties, set_options),
        );
    }

    /// Compatibility spelling for the Table service's service-properties API.
    pub fn setPropertiesResult(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        properties: service_models.ServiceProperties,
        set_options: options.SetServicePropertiesOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.SetServicePropertiesResponse)) {
        return self.setServicePropertiesResult(allocator, properties, set_options);
    }

    /// Compatibility spelling for the Table service's service-properties API.
    pub fn setProperties(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        properties: service_models.ServiceProperties,
        set_options: options.SetServicePropertiesOptions,
    ) !responses.SdkResponse(protocol_client.SetServicePropertiesResponse) {
        return self.setServiceProperties(allocator, properties, set_options);
    }

    pub fn getServicePropertiesResult(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        get_options: options.GetServicePropertiesOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.GetServicePropertiesResponse)) {
        return self.protocol.getServiceProperties(allocator, get_options.protocol);
    }

    pub fn getServiceProperties(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        get_options: options.GetServicePropertiesOptions,
    ) !responses.SdkResponse(protocol_client.GetServicePropertiesResponse) {
        return responses.unwrapGetServiceProperties(
            responses.SdkResponse(protocol_client.GetServicePropertiesResponse),
            try self.getServicePropertiesResult(allocator, get_options),
        );
    }

    /// Compatibility spelling for the Table service's service-properties API.
    pub fn getPropertiesResult(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        get_options: options.GetServicePropertiesOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.GetServicePropertiesResponse)) {
        return self.getServicePropertiesResult(allocator, get_options);
    }

    /// Compatibility spelling for the Table service's service-properties API.
    pub fn getProperties(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        get_options: options.GetServicePropertiesOptions,
    ) !responses.SdkResponse(protocol_client.GetServicePropertiesResponse) {
        return self.getServiceProperties(allocator, get_options);
    }

    pub fn getStatisticsResult(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        get_options: options.GetStatisticsOptions,
    ) !responses.TableResult(responses.SdkResponse(protocol_client.GetStatisticsResponse)) {
        return self.protocol.getStatistics(allocator, get_options.protocol);
    }

    pub fn getStatistics(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        get_options: options.GetStatisticsOptions,
    ) !responses.SdkResponse(protocol_client.GetStatisticsResponse) {
        return responses.unwrapGetStatistics(
            responses.SdkResponse(protocol_client.GetStatisticsResponse),
            try self.getStatisticsResult(allocator, get_options),
        );
    }

    pub fn listTables(
        self: *TableServiceClient,
        allocator: std.mem.Allocator,
        list_options: options.ListTablesOptions,
    ) !pager.TablePager {
        return pager.TablePager.init(allocator, &self.protocol, list_options);
    }
};

const BodyCapturePolicy = struct {
    allocator: std.mem.Allocator,
    body: ?[]u8 = null,
    policy: core.http.HttpPolicy = .{ .processFn = &process },

    fn deinit(self: *BodyCapturePolicy) void {
        if (self.body) |body| self.allocator.free(body);
        self.* = undefined;
    }

    fn process(
        policy: *core.http.HttpPolicy,
        req: *core.http.Request,
        next: []*core.http.HttpPolicy,
        runtime: core.http.HttpRuntime,
    ) anyerror!core.http.Response {
        const self: *BodyCapturePolicy = @alignCast(@fieldParentPtr("policy", policy));
        const response = if (next.len == 0) try runtime.transport.send(req) else try next[0].process(req, next[1..], runtime);
        if (self.body) |body| self.allocator.free(body);
        self.body = if (req.body) |body| try self.allocator.dupe(u8, body) else null;
        return response;
    }
};

const CountingCredential = struct {
    calls: usize = 0,
    credential: core.credentials.TokenCredential = .{ .getTokenFn = &getToken },

    fn asCredential(self: *CountingCredential) *core.credentials.TokenCredential {
        return &self.credential;
    }

    fn getToken(
        credential: *core.credentials.TokenCredential,
        context: core.credentials.TokenRequestContext,
        _: core.context.Context,
        _: core.http.HttpRuntime,
    ) anyerror!core.credentials.AccessToken {
        const self: *CountingCredential = @alignCast(
            @fieldParentPtr("credential", credential),
        );
        if (context.scopes.len != 1 or
            !std.mem.eql(u8, context.scopes[0], @import("auth.zig").storage_scope))
        {
            return error.UnexpectedTokenScope;
        }
        self.calls += 1;
        return .{ .token = "shared-token", .expires_on = std.math.maxInt(i64) };
    }
};

const CountingCryptoProvider = struct {
    inner: core.crypto.CryptoProvider,
    hmac_calls: usize = 0,
    random_calls: usize = 0,
    fail_random: bool = false,
    fail_hmac: bool = false,

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

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn randomBytes(context: *anyopaque, out: []u8) !void {
        const counting = fromContext(context);
        counting.random_calls += 1;
        if (counting.fail_random) return error.CryptoEntropyFailure;
        return counting.inner.randomBytes(out);
    }

    fn md5(
        context: *anyopaque,
        data: []const u8,
        out: *core.crypto.Md5Digest,
    ) !void {
        out.* = try fromContext(context).inner.md5(data);
    }

    fn sha256(
        context: *anyopaque,
        data: []const u8,
        out: *core.crypto.Sha256Digest,
    ) !void {
        out.* = try fromContext(context).inner.sha256(data);
    }

    fn hmacSha256(
        context: *anyopaque,
        key: []const u8,
        message: []const u8,
        out: *core.crypto.HmacSha256Digest,
    ) !void {
        const counting = fromContext(context);
        counting.hmac_calls += 1;
        if (counting.fail_hmac) return error.CryptoSigningFailure;
        out.* = try counting.inner.hmacSha256(key, message);
    }

    fn sha256Init(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) !core.crypto.Sha256Operation {
        return fromContext(context).inner.sha256Init(allocator);
    }
};

const MovedServicePager = struct {
    service: TableServiceClient,
    table_pager: pager.TablePager,
};

test "canonical direct and derived clients preserve provider failures before dispatch" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    var standard = core.crypto.StdCryptoProvider.init(std.testing.io);
    var crypto = CountingCryptoProvider{ .inner = standard.asProvider() };
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.provider());
    var key = try auth.SharedKeyCredential.init(allocator, "account", "YWNjb3VudC1rZXk=");
    defer key.deinit();
    const inputs = [_]options.ClientAuthentication{
        .{ .shared_key = .{ .endpoint = "https://account.table.core.windows.net", .credential = &key } },
        .{ .connection_string = "AccountName=account;AccountKey=YWNjb3VudC1rZXk=;TableEndpoint=https://account.table.core.windows.net" },
    };
    for (inputs) |input| {
        var direct = try client.TableClient.init(allocator, runtime, .{
            .authentication = input,
            .table_name = "People",
            .options = .{ .retry = .{ .max_retries = 0 } },
        });
        defer direct.deinit();
        var service = try TableServiceClient.init(allocator, runtime, .{
            .authentication = input,
            .options = .{ .retry = .{ .max_retries = 0 } },
        });
        defer service.deinit();
        var derived = try service.getTableClient("People");
        defer derived.deinit();
        for ([_]*client.TableClient{ &direct, &derived }) |table| {
            const dispatched = transport.call_count;
            const random_calls = crypto.random_calls;
            const hmac_calls = crypto.hmac_calls;
            crypto.fail_random = true;
            try std.testing.expectError(error.CryptoEntropyFailure, table.getEntityRaw(allocator, "p", "r"));
            try std.testing.expectEqual(dispatched, transport.call_count);
            try std.testing.expectEqual(random_calls + 1, crypto.random_calls);
            try std.testing.expectEqual(hmac_calls, crypto.hmac_calls);
            crypto.fail_random = false;
            crypto.fail_hmac = true;
            try std.testing.expectError(error.CryptoSigningFailure, table.getEntityRaw(allocator, "p", "r"));
            try std.testing.expectEqual(dispatched, transport.call_count);
            try std.testing.expectEqual(hmac_calls + 1, crypto.hmac_calls);
            crypto.fail_hmac = false;
            var response = try table.getEntityRaw(allocator, "p", "r");
            response.deinit();
            try std.testing.expectEqual(dispatched + 1, transport.call_count);
            try std.testing.expect(std.mem.startsWith(u8, transport.last_headers.get("Authorization").?, "SharedKeyLite account:"));
        }
    }
}

fn moveServiceWithPager(
    service: TableServiceClient,
    allocator: std.mem.Allocator,
) !MovedServicePager {
    var relocated = service;
    const table_pager = try relocated.listTables(allocator, .{});
    return .{ .service = relocated, .table_pager = table_pager };
}

test "derived clients share token cache and transport and borrow pipeline state" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    var credential = CountingCredential{};

    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } } },
    );
    defer service.deinit();
    const shared_state = service.pipeline_state;

    var first = try service.getTableClient("FirstTable");
    try std.testing.expect(first.pipeline_state == shared_state);
    var first_response = try first.getEntity(allocator, "pk", "rk");
    first_response.deinit();
    first.deinit();

    var second = try service.getTableClient("SecondTable");
    defer second.deinit();
    var second_response = try second.getEntity(allocator, "pk", "rk");
    second_response.deinit();

    try std.testing.expectEqual(@as(usize, 1), credential.calls);
    try std.testing.expectEqual(@as(usize, 2), transport.call_count);
}

test "table pager survives a service client move across continuation pages" {
    const allocator = std.testing.allocator;
    const pages = [_]core.http.SequenceMockTransport.CannedResponse{
        .{
            .status = 200,
            .body = "{\"value\":[{\"TableName\":\"First\"}]}",
            .headers = &.{
                .{ .name = "x-ms-version", .value = "2019-02-02" },
                .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "x-ms-continuation-NextTableName", .value = "Second" },
            },
        },
        .{
            .status = 200,
            .body = "{\"value\":[{\"TableName\":\"Second\"}]}",
            .headers = &.{
                .{ .name = "x-ms-version", .value = "2019-02-02" },
                .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        },
    };
    var transport = core.http.SequenceMockTransport.init(allocator, &pages);
    var credential = CountingCredential{};
    var source = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } } },
    );
    var moved = try moveServiceWithPager(source, allocator);
    source = undefined;
    defer moved.service.deinit();
    defer moved.table_pager.deinit();

    const first = try moved.table_pager.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("First", switch (first.?.value) {
        .status_200 => |value| value.body.value.?[0].table_name.?,
    });
    const second = try moved.table_pager.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("Second", switch (second.?.value) {
        .status_200 => |value| value.body.value.?[0].table_name.?,
    });
    try std.testing.expectEqual(@as(usize, 2), transport.call_count);
    try std.testing.expectEqual(@as(usize, 1), credential.calls);
}

test "token service client rejects HTTP before credential and transport use" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    var credential = CountingCredential{};

    try std.testing.expectError(
        error.TokenAuthenticationRequiresHttps,
        TableServiceClient.init(
            allocator,
            testingRuntime(transport.asTransport()),
            .{ .authentication = .{ .token = .{ .endpoint = "http://tables.private.example:10002/account", .credential = credential.asCredential() } } },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), credential.calls);
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);
}

test "token service client accepts HTTPS custom private endpoint" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    var credential = CountingCredential{};

    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .token = .{ .endpoint = "https://tables.private.example:8443/account/path/", .credential = credential.asCredential() } } },
    );
    defer service.deinit();

    try std.testing.expectEqualStrings(
        "https://tables.private.example:8443/account/path",
        service.protocol.endpoint.base_url,
    );
    try std.testing.expectEqual(@as(usize, 0), credential.calls);
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);
}

test "connection-string account SAS uses selected runtime crypto provider" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    var standard_crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    var counting_crypto = CountingCryptoProvider{
        .inner = standard_crypto.asProvider(),
    };
    const runtime = core.http.HttpRuntime.init(
        transport.asTransport(),
        counting_crypto.provider(),
    );
    var shared = try TableServiceClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .connection_string = "DefaultEndpointsProtocol=https;AccountName=fakeaccount;" ++
            "AccountKey=ZmFrZS1rZXk=;EndpointSuffix=core.windows.net" } },
    );
    defer shared.deinit();

    const sas_url = try shared.getAccountSasUrl(allocator, .{
        .permissions = .{ .read = true, .list = true },
        .resourceTypes = .{ .service = true, .container = true },
        .startTime = .fromUnixSeconds(1_699_455_845),
        .expiryTime = .fromUnixSeconds(1_699_459_445),
    });
    defer allocator.free(sas_url);
    try std.testing.expectEqualStrings(
        "https://fakeaccount.table.core.windows.net/?se=2023-11-08T16%3A04%3A05Z&sig=%2BUBePkRnknhwbw%2FT4HuUIu0YAlJlq7mt6Lrfwpestjo%3D&sp=rl&spr=https&srt=sc&ss=t&st=2023-11-08T15%3A04%3A05Z&sv=2019-02-02",
        sas_url,
    );
    try std.testing.expectEqual(@as(usize, 1), counting_crypto.hmac_calls);

    var anonymous = try TableServiceClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .sas_url = sas_url } },
    );
    defer anonymous.deinit();
    try std.testing.expectError(
        error.SasRequiresSharedKeyCredential,
        anonymous.getAccountSasUrl(allocator, .{
            .permissions = .{ .read = true },
            .resourceTypes = .{ .service = true },
            .expiryTime = .fromUnixSeconds(1_699_459_445),
        }),
    );
    var table = try anonymous.getTableClient("People");
    defer table.deinit();
    var response = try table.getEntity(allocator, "p", "r");
    response.deinit();
    try std.testing.expect(transport.last_headers.get("Authorization") == null);
    const signed_query = sas_url[(std.mem.indexOfScalar(u8, sas_url, '?').? + 1)..];
    const sent_query = transport.last_url.?[(std.mem.indexOfScalar(u8, transport.last_url.?, '?').? + 1)..];
    try std.testing.expectEqualStrings(signed_query, sent_query);
}

test "table lifecycle result variants preserve generated responses and service errors" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 204, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
        .{ .name = "x-ms-request-id", .value = "create-id" },
    };
    var credential = CountingCredential{};
    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } },
            .options = .{ .client_request_id = "lifecycle-request" },
        },
    );
    defer service.deinit();

    var created = try service.createTable(allocator, "Table123", .{
        .protocol = .{ .metadata = .full_metadata, .timeout = 13 },
    });
    defer created.deinit();
    try std.testing.expectEqual(@as(u16, 204), created.status);
    try std.testing.expectEqualStrings("create-id", created.headers.getFirst("x-ms-request-id").?);
    try std.testing.expect(std.mem.startsWith(u8, transport.last_headers.get("Authorization").?, "Bearer "));
    try std.testing.expectEqualStrings("lifecycle-request", transport.last_headers.get("x-ms-client-request-id").?);
    try std.testing.expectEqual(@as(usize, 1), credential.calls);
    try std.testing.expectEqualStrings(
        "https://account.table.core.windows.net/Tables?$format=application%2Fjson%3Bodata%3Dfullmetadata&timeout=13",
        transport.last_url.?,
    );

    transport.response_status = 409;
    transport.response_body = "{\"odata.error\":{\"code\":\"TableAlreadyExists\",\"message\":{\"value\":\"exists\"}}}";
    transport.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-ms-request-id", .value = "already-exists" },
    };
    var duplicate = try service.createTableResult(allocator, "Table123", .{});
    defer duplicate.deinit(allocator);
    switch (duplicate) {
        .failure => |failure| {
            try std.testing.expectEqualStrings("TableAlreadyExists", failure.code);
            try std.testing.expectEqual(@as(u16, 409), failure.status);
            try std.testing.expectEqualStrings("already-exists", failure.request_id.?);
        },
        .success => return error.TestUnexpectedResult,
    }
}

test "table lifecycle validates names before transport and table clients are convenient" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 204, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
    };
    var credential = CountingCredential{};
    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } } },
    );
    defer service.deinit();

    try std.testing.expectError(
        error.InvalidTableName,
        service.deleteTableResult(allocator, "not-valid", .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);

    var table_client = try service.getTableClient("Table123");
    defer table_client.deinit();
    var deleted = try table_client.deleteTable(allocator, .{
        .protocol = .{ .timeout = 11 },
    });
    defer deleted.deinit();
    try std.testing.expectEqual(@as(u16, 204), deleted.status);
    try std.testing.expectEqualStrings(
        "https://account.table.core.windows.net/Tables('Table123')?timeout=11",
        transport.last_url.?,
    );
}

test "table lifecycle uses Shared Key and SAS pipeline authentication" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 204, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
    };
    var shared_credential = try auth.SharedKeyCredential.init(
        allocator,
        "account",
        "YWNjb3VudC1rZXk=",
    );
    defer shared_credential.deinit();
    var shared = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .shared_key = .{ .endpoint = "https://account.table.core.windows.net", .credential = &shared_credential } } },
    );
    defer shared.deinit();
    var created = try shared.createTable(allocator, "Table123", .{});
    created.deinit();
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.last_headers.get("Authorization").?,
        "SharedKeyLite account:",
    ));

    var sas_client = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .sas_url = "https://account.table.core.windows.net?sv=1%2F2&sig=secret%3D&sp=r" } },
    );
    defer sas_client.deinit();
    var deleted = try sas_client.deleteTable(allocator, "Table123", .{});
    deleted.deinit();
    try std.testing.expect(transport.last_headers.get("Authorization") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        transport.last_url.?,
        "sv=1%2F2&sig=secret%3D&sp=r",
    ) != null);
}

test "table lifecycle retains all documented table service failure codes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { status: u16, code: []const u8 }{
        .{ .status = 409, .code = "TableAlreadyExists" },
        .{ .status = 409, .code = "TableBeingDeleted" },
        .{ .status = 404, .code = "TableNotFound" },
    };
    for (cases) |case| {
        var transport = core.http.MockTransport.init(
            allocator,
            case.status,
            "{\"odata.error\":{\"code\":\"TablePlaceholder\",\"message\":{\"value\":\"failed\"}}}",
        );
        defer transport.deinit();
        transport.response_body = try std.fmt.allocPrint(
            allocator,
            "{{\"odata.error\":{{\"code\":\"{s}\",\"message\":{{\"value\":\"failed\"}}}}}}",
            .{case.code},
        );
        defer allocator.free(transport.response_body);
        transport.response_headers_list = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-ms-request-id", .value = "failure-id" },
        };
        var credential = CountingCredential{};
        var service = try TableServiceClient.init(
            allocator,
            testingRuntime(transport.asTransport()),
            .{ .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } } },
        );
        defer service.deinit();

        var result = try service.createTableResult(allocator, "Table123", .{});
        defer result.deinit(allocator);
        switch (result) {
            .failure => |failure| {
                try std.testing.expectEqualStrings(case.code, failure.code);
                try std.testing.expectEqual(case.status, failure.status);
                try std.testing.expectEqualStrings("failure-id", failure.request_id.?);
            },
            .success => return error.TestUnexpectedResult,
        }
    }
}

fn testLifecycleAllocationFailures(allocator: std.mem.Allocator) !void {
    var transport = core.http.MockTransport.init(allocator, 204, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 00:00:00 GMT" },
    };
    var credential = CountingCredential{};
    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } },
            .options = .{ .retry = .{ .max_retries = 0 } },
        },
    );
    defer service.deinit();
    var result = try service.createTableResult(allocator, "Table123", .{});
    result.deinit(allocator);
}

test "table lifecycle result allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testLifecycleAllocationFailures,
        .{},
    );
}

test "service properties use generated XML and preserve response metadata" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 202, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "x-ms-request-id", .value = "set-properties-id" },
    };
    var capture = BodyCapturePolicy{ .allocator = allocator };
    defer capture.deinit();
    var credential = CountingCredential{};
    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } },
            .options = .{ .policies = &.{&capture.policy} },
        },
    );
    defer service.deinit();

    var set_response = try service.setServiceProperties(allocator, .{
        .logging = .{
            .version = "1.0",
            .delete = true,
            .read = false,
            .write = true,
            .retention_policy = .{ .enabled = true, .days = 7 },
        },
        .hour_metrics = .{
            .version = "1.0",
            .enabled = true,
            .include_apis = true,
            .retention_policy = .{ .enabled = false },
        },
        .cors = .{ .items = &.{.{
            .allowed_origins = "https://example.test",
            .allowed_methods = "GET,PUT",
            .allowed_headers = "x-ms-meta-*",
            .exposed_headers = "x-ms-request-id",
            .max_age_in_seconds = 60,
        }} },
    }, .{ .protocol = .{ .client_request_id = "set-client-id", .timeout = 30 } });
    defer set_response.deinit();
    try std.testing.expectEqual(@as(u16, 202), set_response.status);
    try std.testing.expectEqualStrings("set-properties-id", set_response.headers.getFirst("x-ms-request-id").?);
    try std.testing.expectEqualStrings(
        "https://account.table.core.windows.net?restype=service&comp=properties&timeout=30",
        transport.last_url.?,
    );
    try std.testing.expectEqualStrings("set-client-id", transport.last_headers.get("x-ms-client-request-id").?);
    try std.testing.expect(std.mem.startsWith(u8, transport.last_headers.get("Authorization").?, "Bearer "));
    try std.testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><StorageServiceProperties><Logging><Version>1.0</Version><Delete>true</Delete><Read>false</Read><Write>true</Write><RetentionPolicy><Enabled>true</Enabled><Days>7</Days></RetentionPolicy></Logging><HourMetrics><Version>1.0</Version><Enabled>true</Enabled><IncludeAPIs>true</IncludeAPIs><RetentionPolicy><Enabled>false</Enabled></RetentionPolicy></HourMetrics><Cors><CorsRule><AllowedOrigins>https://example.test</AllowedOrigins><AllowedMethods>GET,PUT</AllowedMethods><AllowedHeaders>x-ms-meta-*</AllowedHeaders><ExposedHeaders>x-ms-request-id</ExposedHeaders><MaxAgeInSeconds>60</MaxAgeInSeconds></CorsRule></Cors></StorageServiceProperties>",
        capture.body.?,
    );

    transport.response_status = 200;
    transport.response_body =
        "<StorageServiceProperties><Logging><Version>1.0</Version><Delete>true</Delete><Read>false</Read><Write>true</Write><RetentionPolicy><Enabled>true</Enabled><Days>7</Days></RetentionPolicy></Logging><HourMetrics><Version>1.0</Version><Enabled>false</Enabled><IncludeAPIs>false</IncludeAPIs><RetentionPolicy><Enabled>false</Enabled><Days>7</Days></RetentionPolicy></HourMetrics><Cors><CorsRule><AllowedOrigins>https://example.test</AllowedOrigins><AllowedMethods>GET</AllowedMethods><AllowedHeaders>*</AllowedHeaders><ExposedHeaders>x-ms-request-id</ExposedHeaders><MaxAgeInSeconds>60</MaxAgeInSeconds></CorsRule></Cors></StorageServiceProperties>";
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "x-ms-request-id", .value = "get-properties-id" },
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var get_response = try service.getServiceProperties(allocator, .{});
    defer get_response.deinit();
    try std.testing.expectEqual(@as(u16, 200), get_response.status);
    try std.testing.expectEqualStrings("get-properties-id", get_response.headers.getFirst("x-ms-request-id").?);
    switch (get_response.value) {
        .status_200 => |response| {
            try std.testing.expectEqual(@as(usize, 1), response.body.cors.?.items.len);
            try std.testing.expectEqualStrings("https://example.test", response.body.cors.?.items[0].allowed_origins);
            try std.testing.expectEqual(@as(?i32, 7), response.body.logging.?.retention_policy.days);
            try std.testing.expectEqual(false, response.body.hour_metrics.?.enabled);
            try std.testing.expectEqual(@as(?bool, false), response.body.hour_metrics.?.include_apis);
            try std.testing.expectEqual(@as(?i32, 7), response.body.hour_metrics.?.retention_policy.?.days);

            transport.response_status = 202;
            transport.response_body = "";
            transport.response_headers_list = &.{
                .{ .name = "x-ms-version", .value = "2019-02-02" },
            };
            var roundtrip = try service.setServiceProperties(allocator, response.body, .{});
            defer roundtrip.deinit();
            try std.testing.expectEqualStrings(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><StorageServiceProperties><Logging><Version>1.0</Version><Delete>true</Delete><Read>false</Read><Write>true</Write><RetentionPolicy><Enabled>true</Enabled><Days>7</Days></RetentionPolicy></Logging><HourMetrics><Version>1.0</Version><Enabled>false</Enabled><RetentionPolicy><Enabled>false</Enabled><Days>7</Days></RetentionPolicy></HourMetrics><Cors><CorsRule><AllowedOrigins>https://example.test</AllowedOrigins><AllowedMethods>GET</AllowedMethods><AllowedHeaders>*</AllowedHeaders><ExposedHeaders>x-ms-request-id</ExposedHeaders><MaxAgeInSeconds>60</MaxAgeInSeconds></CorsRule></Cors></StorageServiceProperties>",
                capture.body.?,
            );
        },
    }
}

test "service administration validates before transport and returns structured failures" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 202, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
    };
    var credential = CountingCredential{};
    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } } },
    );
    defer service.deinit();

    try std.testing.expectError(
        error.InvalidRetentionDays,
        service.setServiceProperties(allocator, .{
            .minute_metrics = .{
                .version = "1.0",
                .enabled = true,
                .include_apis = false,
                .retention_policy = .{ .enabled = true, .days = 0 },
            },
        }, .{}),
    );
    try std.testing.expectError(
        error.InvalidTimeout,
        service.getServiceProperties(allocator, .{ .protocol = .{ .timeout = 0 } }),
    );
    try std.testing.expectError(error.StatisticsRequireSecondaryEndpoint, service.getStatistics(allocator, .{}));
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);

    transport.response_status = 400;
    transport.response_body = "<Error><Code>InvalidXmlDocument</Code><Message>bad XML</Message></Error>";
    transport.response_headers_list = &.{
        .{ .name = "Content-Type", .value = "application/xml" },
        .{ .name = "x-ms-request-id", .value = "bad-properties-id" },
    };
    var result = try service.getServicePropertiesResult(allocator, .{});
    defer result.deinit(allocator);
    switch (result) {
        .failure => |failure| {
            try std.testing.expectEqual(@as(u16, 400), failure.status);
            try std.testing.expectEqualStrings("InvalidXmlDocument", failure.code);
            try std.testing.expectEqualStrings("bad-properties-id", failure.request_id.?);
        },
        .success => return error.TestUnexpectedResult,
    }
}

test "secondary statistics preserve unknown replication status and UTC time" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(
        allocator,
        200,
        "<StorageServiceStats><GeoReplication><Status>future-status</Status><LastSyncTime>Wed, 23 Oct 2013 22:05:54 GMT</LastSyncTime></GeoReplication></StorageServiceStats>",
    );
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "Date", .value = "Sun, 26 Jul 2026 18:32:16 GMT" },
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "x-ms-request-id", .value = "stats-id" },
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var credential = CountingCredential{};
    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .token = .{ .endpoint = "https://account-secondary.table.core.windows.net", .credential = credential.asCredential() } } },
    );
    defer service.deinit();

    var response = try service.getStatistics(allocator, .{ .protocol = .{ .timeout = 5 } });
    defer response.deinit();
    try std.testing.expectEqualStrings(
        "https://account-secondary.table.core.windows.net?restype=service&comp=stats&timeout=5",
        transport.last_url.?,
    );
    try std.testing.expectEqualStrings("stats-id", response.headers.getFirst("x-ms-request-id").?);
    switch (response.value) {
        .status_200 => |stats| switch (stats.body.geo_replication.?.status.?) {
            .unrecognized => |value| try std.testing.expectEqualStrings("future-status", value),
            else => return error.TestUnexpectedResult,
        },
    }

    transport.response_body =
        "<StorageServiceStats><GeoReplication><Status>bootstrap</Status><LastSyncTime></LastSyncTime></GeoReplication></StorageServiceStats>";
    var unavailable = try service.getStatistics(allocator, .{});
    defer unavailable.deinit();
    switch (unavailable.value) {
        .status_200 => |stats| {
            try std.testing.expectEqual(@as(usize, 0), stats.body.geo_replication.?.last_sync_time.?.len);
        },
    }
}

test "malformed service properties XML is released on decode failure" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "<StorageServiceProperties><Logging>");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
        .{ .name = "Content-Type", .value = "application/xml" },
    };
    var credential = CountingCredential{};
    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{ .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } } },
    );
    defer service.deinit();

    if (service.getServiceProperties(allocator, .{})) |value| {
        var response = value;
        response.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn testServiceAdminAllocationFailures(allocator: std.mem.Allocator) !void {
    var transport = core.http.MockTransport.init(allocator, 202, "");
    defer transport.deinit();
    transport.response_headers_list = &.{
        .{ .name = "x-ms-version", .value = "2019-02-02" },
    };
    var credential = CountingCredential{};
    var service = try TableServiceClient.init(
        allocator,
        testingRuntime(transport.asTransport()),
        .{
            .authentication = .{ .token = .{ .endpoint = "https://account.table.core.windows.net", .credential = credential.asCredential() } },
            .options = .{ .retry = .{ .max_retries = 0 } },
        },
    );
    defer service.deinit();
    var response = try service.setServiceProperties(allocator, .{
        .logging = .{
            .version = "1.0",
            .delete = false,
            .read = true,
            .write = false,
            .retention_policy = .{ .enabled = false },
        },
    }, .{});
    response.deinit();
}

test "service administration allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testServiceAdminAllocationFailures,
        .{},
    );
}
