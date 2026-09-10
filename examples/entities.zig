//! Typed CRUD, dynamic entities, paging, and conditional ETag update.
//!
//! Run with `AZURE_DATA_TABLES_CONNECTION_STRING` and
//! `AZURE_DATA_TABLES_TABLE`; use a disposable table because this example
//! creates and deletes sample entities.

const std = @import("std");
const core = @import("azure_sdk_core");
const tables = @import("azure_sdk_data_tables");
const support = @import("tables_example_support");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const env = init.environ_map;
    const connection_string = try support.required(
        env,
        "AZURE_DATA_TABLES_CONNECTION_STRING",
    );
    const table_name = try support.required(env, "AZURE_DATA_TABLES_TABLE");

    var transport = core.http.StdHttpTransport.init(allocator, init.io);
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(init.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
    var client = try tables.TableClient.init(
        allocator,
        runtime,
        .{
            .authentication = .{ .connection_string = connection_string },
            .table_name = table_name,
        },
    );
    defer client.deinit();

    const typed = support.ExampleEntity{
        .partition_key = "examples",
        .row_key = "typed",
        .name = "typed entity",
        .count = 1,
    };
    var inserted = try client.addEntity(allocator, typed, .{});
    defer inserted.deinit();

    var fetched = try client.getEntityAs(
        support.ExampleEntity,
        allocator,
        typed.partition_key,
        typed.row_key,
        .{},
    );
    defer fetched.deinit();

    var updated = try client.updateEntity(allocator, .{
        .partition_key = typed.partition_key,
        .row_key = typed.row_key,
        .name = fetched.value.name,
        .count = fetched.value.count + 1,
    }, .{
        .mode = .merge,
        .if_match = fetched.etag,
    });
    defer updated.deinit();

    var dynamic = try tables.DynamicEntity.init(allocator, "examples", "dynamic");
    defer dynamic.deinit();
    try dynamic.put("Name", .{ .string = "runtime schema" });
    try dynamic.put("Enabled", .{ .boolean = true });
    var dynamic_inserted = try client.addEntity(allocator, dynamic, .{});
    defer dynamic_inserted.deinit();

    var pager = try client.queryEntities(support.ExampleEntity, allocator, .{
        .filter = "PartitionKey eq 'examples'",
        .top = 10,
    });
    defer pager.deinit();
    while (try pager.next()) |page| {
        for (page.values) |entity| _ = entity.count;
    }
}
