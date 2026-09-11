//! Atomically insert two entities in one partition with the hand-written
//! Tables `$batch` transaction layer.

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

    var transaction = tables.TransactionBuilder.init(allocator);
    defer transaction.deinit();
    try transaction.add(support.ExampleEntity, .{
        .partition_key = "transaction",
        .row_key = "one",
        .name = "first",
        .count = 1,
    });
    try transaction.add(support.ExampleEntity, .{
        .partition_key = "transaction",
        .row_key = "two",
        .name = "second",
        .count = 2,
    });

    var response = try client.submitTransaction(allocator, &transaction, .{});
    defer response.deinit();
}
