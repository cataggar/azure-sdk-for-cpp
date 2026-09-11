//! Opt-in destructive Azure Storage Tables coverage. It never records
//! requests or responses, so account names, keys, bearer tokens, and SAS
//! queries cannot be persisted by this package.

const std = @import("std");
const core = @import("azure_sdk_core");
const tables = @import("azure_sdk_data_tables");

const Config = struct {
    endpoint: []const u8,
    secondary_endpoint: []const u8,
    bearer: []const u8,
    account_name: []const u8,
    account_key: []const u8,
    run_id: []const u8,

    fn fromEnvironment(env: *const std.process.Environ.Map) !?Config {
        const enabled = nonEmpty(env.get("AZURE_DATA_TABLES_LIVE_TESTS")) orelse
            return null;
        if (!std.mem.eql(u8, enabled, "1"))
            return error.InvalidDataTablesLiveTestOptIn;
        const endpoint = try required(env, "AZURE_DATA_TABLES_ENDPOINT");
        if (!std.mem.startsWith(u8, endpoint, "https://") or
            std.mem.endsWith(u8, endpoint, "/"))
        {
            return error.InvalidDataTablesLiveEndpoint;
        }
        const secondary_endpoint = try required(
            env,
            "AZURE_DATA_TABLES_SECONDARY_ENDPOINT",
        );
        if (!std.mem.startsWith(u8, secondary_endpoint, "https://") or
            std.mem.endsWith(u8, secondary_endpoint, "/"))
        {
            return error.InvalidDataTablesLiveSecondaryEndpoint;
        }
        const run_id = try required(env, "AZURE_DATA_TABLES_LIVE_TEST_RUN_ID");
        if (run_id.len > 50) return error.InvalidDataTablesLiveTestRunId;
        for (run_id) |byte| {
            if (!std.ascii.isAlphanumeric(byte))
                return error.InvalidDataTablesLiveTestRunId;
        }
        return .{
            .endpoint = endpoint,
            .secondary_endpoint = secondary_endpoint,
            .bearer = try required(env, "AZURE_TOKEN"),
            .account_name = try required(env, "AZURE_DATA_TABLES_ACCOUNT_NAME"),
            .account_key = try required(env, "AZURE_DATA_TABLES_SHARED_KEY"),
            .run_id = run_id,
        };
    }
};

test "live Entra, Shared Key, SAS, ACL, properties, and statistics" {
    const allocator = std.testing.allocator;
    var env = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer env.deinit();
    const config = (try Config.fromEnvironment(&env)) orelse
        return error.SkipZigTest;

    var table_name_buffer: [63]u8 = undefined;
    const table_name = try std.fmt.bufPrint(
        &table_name_buffer,
        "ZigTablesLive{s}",
        .{config.run_id},
    );

    var transport = core.http.StdHttpTransport.init(allocator, std.testing.io);
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
    try entraSmoke(allocator, config, runtime);

    var shared_key = try tables.SharedKeyCredential.init(
        allocator,
        config.account_name,
        config.account_key,
    );
    defer shared_key.deinit();
    var service = try tables.TableServiceClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .shared_key = .{ .endpoint = config.endpoint, .credential = &shared_key } } },
    );
    defer service.deinit();

    var created = try service.createTable(allocator, table_name, .{});
    defer created.deinit();
    var cleanup_needed = true;
    errdefer if (cleanup_needed)
        cleanupTableBestEffort(&service, allocator, table_name);
    {
        var table = try service.getTableClient(table_name);
        defer table.deinit();
        try aclSmoke(&table, allocator);
    }
    try sasSmoke(&service, allocator, runtime);
    try serviceAdministrationSmoke(
        allocator,
        &service,
        config.secondary_endpoint,
        &shared_key,
        runtime,
    );
    var deleted = try service.deleteTable(allocator, table_name, .{});
    defer deleted.deinit();
    try std.testing.expectEqual(@as(u16, 204), deleted.status);
    cleanup_needed = false;
}

fn entraSmoke(
    allocator: std.mem.Allocator,
    config: Config,
    runtime: core.http.HttpRuntime,
) !void {
    var credential = core.env_token.EnvTokenCredential.init(allocator, config.bearer);
    var service = try tables.TableServiceClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .token = .{ .endpoint = config.endpoint, .credential = credential.asCredential() } } },
    );
    defer service.deinit();
    var pager = try service.listTables(allocator, .{ .top = 1 });
    defer pager.deinit();
    _ = try pager.next();
}

fn aclSmoke(client: *tables.TableClient, allocator: std.mem.Allocator) !void {
    const identifiers = [_]tables.SignedIdentifier{.{
        .id = "live-read",
        .access_policy = .{
            .permissions = .{ .table = .{ .read = true } },
        },
    }};
    var set = try client.setAccessPolicy(allocator, &identifiers, .{});
    defer set.deinit();
    var fetched = try client.getAccessPolicy(allocator, .{});
    defer fetched.deinit();
    try std.testing.expectEqual(@as(usize, 1), fetched.value.len);
    try std.testing.expectEqualStrings("live-read", fetched.value[0].id);
    switch (fetched.value[0].access_policy.permissions) {
        .raw => |permissions| try std.testing.expectEqualStrings("r", permissions),
        .table => return error.UnexpectedNormalizedAccessPolicyPermissions,
    }
}

fn sasSmoke(
    service: *tables.TableServiceClient,
    allocator: std.mem.Allocator,
    runtime: core.http.HttpRuntime,
) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const now: i64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(threaded.io(), .real).toNanoseconds(),
        std.time.ns_per_s,
    ));
    const sas_url = try service.getAccountSasUrl(allocator, .{
        .permissions = .{ .read = true, .list = true },
        .resourceTypes = .{ .service = true, .container = true, .object = true },
        .expiryTime = tables.SasUtcTime.fromUnixSeconds(now + 900),
    });
    defer allocator.free(sas_url);
    var sas = try tables.TableServiceClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .sas_url = sas_url } },
    );
    defer sas.deinit();
    var pager = try sas.listTables(allocator, .{ .top = 1 });
    defer pager.deinit();
    _ = try pager.next();
}

fn serviceAdministrationSmoke(
    allocator: std.mem.Allocator,
    primary: *tables.TableServiceClient,
    secondary_endpoint: []const u8,
    shared_key: *tables.SharedKeyCredential,
    runtime: core.http.HttpRuntime,
) !void {
    var statistics_client = try tables.TableServiceClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .shared_key = .{ .endpoint = secondary_endpoint, .credential = shared_key } } },
    );
    defer statistics_client.deinit();
    var properties = try primary.getServiceProperties(allocator, .{});
    defer properties.deinit();

    var statistics = try statistics_client.getStatistics(allocator, .{});
    defer statistics.deinit();
}

/// Error unwinding preserves the original failure, but still tries to remove
/// the test table. Normal cleanup above always propagates an HTTP failure.
fn cleanupTableBestEffort(
    service: *tables.TableServiceClient,
    allocator: std.mem.Allocator,
    table_name: []const u8,
) void {
    var deleted = service.deleteTable(allocator, table_name, .{}) catch return;
    deleted.deinit();
}

fn required(env: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    return nonEmpty(env.get(name)) orelse error.DataTablesLiveEnvironmentRequired;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    if (value) |text| return if (text.len == 0) null else text;
    return null;
}
