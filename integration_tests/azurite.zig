//! Opt-in Azurite coverage. Set `AZURE_DATA_TABLES_AZURITE_TESTS=1` and a
//! unique alphanumeric `AZURE_DATA_TABLES_AZURITE_TEST_RUN_ID` to run it.

const std = @import("std");
const core = @import("azure_sdk_core");
const tables = @import("azure_sdk_data_tables");

const Entity = struct {
    partition_key: []const u8,
    row_key: []const u8,
    name: []const u8,
    count: i32,
};

const Config = struct {
    connection_string: []const u8,
    run_id: []const u8,

    fn fromEnvironment(env: *const std.process.Environ.Map) !?Config {
        const enabled = nonEmpty(env.get("AZURE_DATA_TABLES_AZURITE_TESTS")) orelse
            return null;
        if (!std.mem.eql(u8, enabled, "1"))
            return error.InvalidAzuriteTestOptIn;
        const run_id = nonEmpty(env.get("AZURE_DATA_TABLES_AZURITE_TEST_RUN_ID")) orelse
            return error.AzuriteTestRunIdRequired;
        if (run_id.len > 50) return error.InvalidAzuriteTestRunId;
        for (run_id) |byte| {
            if (!std.ascii.isAlphanumeric(byte)) return error.InvalidAzuriteTestRunId;
        }
        return .{
            .connection_string = nonEmpty(
                env.get("AZURE_DATA_TABLES_AZURITE_CONNECTION_STRING"),
            ) orelse "UseDevelopmentStorage=true",
            .run_id = run_id,
        };
    }
};

test "Azurite table lifecycle, CRUD, query paging, ETag, and batch" {
    const allocator = std.testing.allocator;
    var env = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer env.deinit();
    const config = (try Config.fromEnvironment(&env)) orelse
        return error.SkipZigTest;

    var table_name_buffer: [63]u8 = undefined;
    const table_name = try std.fmt.bufPrint(
        &table_name_buffer,
        "ZigTables{s}",
        .{config.run_id},
    );

    var transport = core.http.StdHttpTransport.init(allocator, std.testing.io);
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
    var service = try tables.TableServiceClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .connection_string = config.connection_string } },
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
        try typedCrudAndEtag(&table, allocator);
        try dynamicEntityAndPaging(&table, allocator);
        try batch(&table, allocator);
    }

    var deleted = try service.deleteTable(allocator, table_name, .{});
    defer deleted.deinit();
    try std.testing.expectEqual(@as(u16, 204), deleted.status);
    cleanup_needed = false;
}

fn typedCrudAndEtag(client: *tables.TableClient, allocator: std.mem.Allocator) !void {
    const initial = Entity{
        .partition_key = "typed",
        .row_key = "one",
        .name = "first",
        .count = 1,
    };
    var inserted = try client.addEntity(allocator, initial, .{});
    defer inserted.deinit();

    var fetched = try client.getEntityAs(
        Entity,
        allocator,
        initial.partition_key,
        initial.row_key,
        .{},
    );
    defer fetched.deinit();
    try std.testing.expectEqual(@as(i32, 1), fetched.value.count);

    var updated = try client.updateEntity(allocator, .{
        .partition_key = initial.partition_key,
        .row_key = initial.row_key,
        .name = initial.name,
        .count = @as(i32, 2),
    }, .{
        .mode = .merge,
        .if_match = fetched.etag,
    });
    defer updated.deinit();

    var stale = try client.updateEntityResult(allocator, .{
        .partition_key = initial.partition_key,
        .row_key = initial.row_key,
        .name = initial.name,
        .count = @as(i32, 3),
    }, .{
        .mode = .merge,
        .if_match = fetched.etag,
    });
    defer stale.deinit(allocator);
    switch (stale) {
        .failure => |failure| try std.testing.expectEqualStrings(
            tables.TableErrorCode.update_condition_not_satisfied,
            failure.code,
        ),
        .success => return error.ExpectedConditionalUpdateFailure,
    }
}

fn dynamicEntityAndPaging(client: *tables.TableClient, allocator: std.mem.Allocator) !void {
    var dynamic = try tables.DynamicEntity.init(allocator, "dynamic", "one");
    defer dynamic.deinit();
    try dynamic.put("Name", .{ .string = "runtime" });
    try dynamic.put("Count", .{ .int32 = 1 });
    var inserted_dynamic = try client.addEntity(allocator, dynamic, .{});
    defer inserted_dynamic.deinit();

    const rows = [_]Entity{
        .{ .partition_key = "page", .row_key = "one", .name = "one", .count = 1 },
        .{ .partition_key = "page", .row_key = "two", .name = "two", .count = 2 },
        .{ .partition_key = "page", .row_key = "three", .name = "three", .count = 3 },
    };
    for (rows) |row| {
        var inserted = try client.addEntity(allocator, row, .{});
        defer inserted.deinit();
    }

    var pager = try client.queryEntities(Entity, allocator, .{
        .filter = "PartitionKey eq 'page'",
        .top = 1,
    });
    defer pager.deinit();
    var count: usize = 0;
    var page_count: usize = 0;
    while (try pager.next()) |page| {
        page_count += 1;
        count += page.values.len;
    }
    try std.testing.expectEqual(@as(usize, rows.len), count);
    try std.testing.expect(page_count >= 2);
}

fn batch(client: *tables.TableClient, allocator: std.mem.Allocator) !void {
    var builder = tables.TransactionBuilder.init(allocator);
    defer builder.deinit();
    try builder.add(Entity, .{
        .partition_key = "batch",
        .row_key = "one",
        .name = "one",
        .count = 1,
    });
    try builder.add(Entity, .{
        .partition_key = "batch",
        .row_key = "two",
        .name = "two",
        .count = 2,
    });
    var result = try client.submitTransactionResult(allocator, &builder, .{});
    defer result.deinit(allocator);
    switch (result) {
        .success => |response| {
            try std.testing.expectEqual(@as(usize, 2), response.operations.len);
        },
        .failure => |failure| {
            std.debug.print("Azurite batch failed: {f}\n", .{failure});
            return error.AzuriteBatchFailed;
        },
    }
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

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    if (value) |text| return if (text.len == 0) null else text;
    return null;
}
