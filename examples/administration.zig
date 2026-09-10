//! Stored access policies, service properties, and optional geo statistics.
//!
//! `AZURE_DATA_TABLES_ALLOW_SERVICE_PROPERTIES_WRITE=1` is required before
//! this example changes account-wide service properties.
//! `AZURE_DATA_TABLES_SECONDARY_CONNECTION_STRING` is an optional complete
//! connection string targeting a conventional read-access secondary endpoint.

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
    var service = try tables.TableServiceClient.init(
        allocator,
        runtime,
        .{ .authentication = .{ .connection_string = connection_string } },
    );
    defer service.deinit();
    var table = try service.getTableClient(table_name);
    defer table.deinit();

    const identifiers = [_]tables.SignedIdentifier{.{
        .id = "example-read",
        .access_policy = .{
            .permissions = .{ .table = .{ .read = true } },
        },
    }};
    var set_acl = try table.setAccessPolicy(allocator, &identifiers, .{});
    defer set_acl.deinit();
    var acl = try table.getAccessPolicy(allocator, .{});
    defer acl.deinit();

    var properties = try service.getServiceProperties(allocator, .{});
    defer properties.deinit();

    // Statistics require an account-secondary endpoint. A separate complete
    // connection string preserves the exact custom suffix/path and auth mode.
    if (env.get("AZURE_DATA_TABLES_SECONDARY_CONNECTION_STRING")) |secondary_connection_string| {
        if (secondary_connection_string.len != 0) {
            var secondary = try tables.TableServiceClient.init(
                allocator,
                runtime,
                .{ .authentication = .{ .connection_string = secondary_connection_string } },
            );
            defer secondary.deinit();
            var statistics = try secondary.getStatistics(allocator, .{});
            defer statistics.deinit();
        }
    }

    const update = tables.ServiceProperties{
        .minute_metrics = .{
            .version = "1.0",
            .enabled = false,
            .retention_policy = .{ .enabled = false },
        },
    };
    if (support.enabled(env, "AZURE_DATA_TABLES_ALLOW_SERVICE_PROPERTIES_WRITE")) {
        var changed = try service.setServiceProperties(allocator, update, .{});
        defer changed.deinit();
    }
}
