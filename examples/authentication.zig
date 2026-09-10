//! Demonstrates Entra, Shared Key, SAS URL, connection-string, and Azurite
//! client construction. It only sends requests when the relevant environment
//! variables are set, so compiling and running it without credentials is safe.

const std = @import("std");
const core = @import("azure_sdk_core");
const tables = @import("azure_sdk_data_tables");
const support = @import("tables_example_support");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const env = init.environ_map;
    var transport = core.http.StdHttpTransport.init(allocator, init.io);
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(init.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());

    const endpoint = env.get("AZURE_DATA_TABLES_ENDPOINT");
    if (endpoint) |service_endpoint| {
        if (env.get("AZURE_TOKEN")) |bearer| {
            var credential = core.env_token.EnvTokenCredential.init(allocator, bearer);
            var client = try tables.TableServiceClient.init(
                allocator,
                runtime,
                .{ .authentication = .{ .token = .{
                    .endpoint = service_endpoint,
                    .credential = credential.asCredential(),
                } } },
            );
            defer client.deinit();
        }

        if (env.get("AZURE_DATA_TABLES_ACCOUNT_NAME")) |account_name| {
            const account_key = try support.required(env, "AZURE_DATA_TABLES_SHARED_KEY");
            var credential = try tables.SharedKeyCredential.init(
                allocator,
                account_name,
                account_key,
            );
            defer credential.deinit();
            var client = try tables.TableServiceClient.init(
                allocator,
                runtime,
                .{ .authentication = .{ .shared_key = .{
                    .endpoint = service_endpoint,
                    .credential = &credential,
                } } },
            );
            defer client.deinit();
        }
    }

    if (env.get("AZURE_DATA_TABLES_SAS_URL")) |sas_url| {
        var client = try tables.TableServiceClient.init(
            allocator,
            runtime,
            .{ .authentication = .{ .sas_url = sas_url } },
        );
        defer client.deinit();
    }

    if (env.get("AZURE_DATA_TABLES_CONNECTION_STRING")) |connection_string| {
        var client = try tables.TableServiceClient.init(
            allocator,
            runtime,
            .{ .authentication = .{ .connection_string = connection_string } },
        );
        defer client.deinit();
    }

    if (support.enabled(env, "AZURE_DATA_TABLES_AZURITE")) {
        var client = try tables.TableServiceClient.init(
            allocator,
            runtime,
            .{ .authentication = .{ .connection_string = "UseDevelopmentStorage=true" } },
        );
        defer client.deinit();
    }
}
