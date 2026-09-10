const std = @import("std");
const core = @import("azure_sdk_core");
const auth = @import("auth.zig");
const options = @import("options.zig");
const TableClient = @import("client.zig").TableClient;
const TableServiceClient = @import("service_client.zig").TableServiceClient;

const shared_connection = "AccountName=account;AccountKey=YWNjb3VudC1rZXk=;" ++
    "TableEndpoint=https://account.table.core.windows.net";
const sas_query = "sv=1%2F2&sig=a+b%3D&sp=r";
const sas_url = "https://account.table.core.windows.net?" ++ sas_query;
const sas_connection = "TableEndpoint=https://account.table.core.windows.net;" ++
    "SharedAccessSignature=" ++ sas_query;

const Mode = enum { token, shared_key, sas, connection_key, connection_sas, development };

fn authentication(
    mode: Mode,
    token: *core.credentials.TokenCredential,
    key: *auth.SharedKeyCredential,
) options.ClientAuthentication {
    return switch (mode) {
        .token => .{ .token = .{
            .endpoint = "https://account.table.core.windows.net",
            .credential = token,
        } },
        .shared_key => .{ .shared_key = .{
            .endpoint = "https://account.table.core.windows.net",
            .credential = key,
        } },
        .sas => .{ .sas_url = sas_url },
        .connection_key => .{ .connection_string = shared_connection },
        .connection_sas => .{ .connection_string = sas_connection },
        .development => .{ .connection_string = "UseDevelopmentStorage=true" },
    };
}

fn constructionAllocationFixture(allocator: std.mem.Allocator, mode: Mode) !void {
    var transport = core.http.MockTransport.init(std.testing.allocator, 200, "{}");
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
    var token = core.env_token.EnvTokenCredential.init(std.testing.allocator, "unused-token");
    var key = try auth.SharedKeyCredential.init(std.testing.allocator, "account", "YWNjb3VudC1rZXk=");
    defer key.deinit();
    const input = authentication(mode, token.asCredential(), &key);
    const defaults: options.TableClientOptions = .{
        .client_request_id = "construction-request",
        .telemetry = .{ .application_id = "construction-test" },
        .retry = .{ .max_retries = 2, .initial_delay_ms = 0, .max_delay_ms = 0 },
        .operation_timeout_ms = 1234,
    };
    var direct = try TableClient.init(allocator, runtime, .{
        .authentication = input,
        .table_name = "People",
        .options = defaults,
    });
    defer direct.deinit();
    var service = try TableServiceClient.init(allocator, runtime, .{
        .authentication = input,
        .options = defaults,
    });
    defer service.deinit();
    var derived = try service.getTableClient("People");
    defer derived.deinit();

    const owns_key = mode == .connection_key or mode == .development;
    try std.testing.expectEqual(owns_key, direct.owned_credential != null);
    try std.testing.expectEqual(owns_key, service.owned_credential != null);
    try std.testing.expect(derived.owned_credential == null);
    try std.testing.expect(!derived.owns_pipeline_state);
    try std.testing.expect(direct.owns_pipeline_state);
    try std.testing.expect(derived.pipeline_state == service.pipeline_state);
    try std.testing.expectEqual(runtime.crypto.context, derived.protocol.pipeline.runtime.crypto.context);
    try std.testing.expectEqual(runtime.transport.context, derived.protocol.pipeline.runtime.transport.context);
    try std.testing.expectEqual(defaults.operation_timeout_ms, derived.pipeline_state.operationTimeoutMs());
    try std.testing.expectEqual(defaults.retry.max_retries, derived.pipeline_state.retryOptions().max_retries);
    if (mode == .shared_key) {
        try std.testing.expect(direct.pipeline_state.sharedKeyCredential().? == &key);
        try std.testing.expect(service.pipeline_state.sharedKeyCredential().? == &key);
    }
    if (mode == .sas or mode == .connection_sas) {
        try std.testing.expectEqualStrings(sas_query, direct.protocol.endpoint.raw_query);
        try std.testing.expectEqualStrings(sas_query, derived.protocol.endpoint.raw_query);
    }
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);
}

test "all canonical authentication paths and derived construction are allocation-safe" {
    inline for (std.meta.tags(Mode)) |mode| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, constructionAllocationFixture, .{mode});
    }
}

test "clients expose one initializer without legacy constructor wrappers" {
    inline for (.{ TableClient, TableServiceClient }) |Client| {
        inline for (@typeInfo(Client).@"struct".decls) |declaration| {
            if (std.mem.startsWith(u8, declaration.name, "init")) {
                try std.testing.expectEqualStrings("init", declaration.name);
            }
        }
        try std.testing.expect(@hasDecl(Client, "init"));
    }
}

test "connection-string clients own inputs and derived state survives parent moves" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
    inline for (.{ shared_connection, sas_connection }) |source| {
        const input = try allocator.dupe(u8, source);
        defer allocator.free(input);
        var original = try TableServiceClient.init(allocator, runtime, .{
            .authentication = .{ .connection_string = input },
        });
        var service = original;
        original = undefined;
        defer service.deinit();
        @memset(input, 'x');

        var child_name = "People".*;
        var first = try service.getTableClient(&child_name);
        @memset(&child_name, 'x');
        try std.testing.expectEqualStrings("People", first.table_name);
        try std.testing.expectEqualStrings("https://account.table.core.windows.net", first.protocol.endpoint.base_url);
        var response = try first.getEntityRaw(allocator, "p", "r");
        response.deinit();
        first.deinit();
        var second = try service.getTableClient("People");
        defer second.deinit();
        var second_response = try second.getEntityRaw(allocator, "p", "r");
        second_response.deinit();
        if (service.owned_credential) |credential| {
            try std.testing.expect(second.pipeline_state.sharedKeyCredential().? == credential);
            try std.testing.expect(std.mem.startsWith(u8, transport.last_headers.get("Authorization").?, "SharedKeyLite account:"));
        } else {
            try std.testing.expect(transport.last_headers.get("Authorization") == null);
            try std.testing.expect(std.mem.endsWith(u8, transport.last_url.?, sas_query));
        }
    }
}

test "canonical authentication retains endpoint and malformed-input distinctions" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(allocator, 200, "{}");
    defer transport.deinit();
    var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
    const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
    var token = core.env_token.EnvTokenCredential.init(allocator, "unused-token");
    var key = try auth.SharedKeyCredential.init(allocator, "account", "YWNjb3VudC1rZXk=");
    defer key.deinit();
    const cases = [_]struct { input: options.ClientAuthentication, failure: anyerror }{
        .{ .input = .{ .token = .{ .endpoint = "http://127.0.0.1:10002/account", .credential = token.asCredential() } }, .failure = error.TokenAuthenticationRequiresHttps },
        .{ .input = .{ .shared_key = .{ .endpoint = "http://account.table.core.windows.net", .credential = &key } }, .failure = error.CleartextEndpointRequiresLocalEmulator },
        .{ .input = .{ .sas_url = "http://account.table.core.windows.net?sig=x" }, .failure = error.CleartextEndpointRequiresLocalEmulator },
        .{ .input = .{ .sas_url = "https://account.table.core.windows.net" }, .failure = error.MissingSasQuery },
        .{ .input = .{ .connection_string = "AccountName=account;AccountName=other;AccountKey=YQ==" }, .failure = error.DuplicateConnectionStringKey },
        .{ .input = .{ .connection_string = "AccountName=account;AccountKey=YQ==;SharedAccessSignature=sv=1&sig=x" }, .failure = error.InvalidConnectionString },
        .{ .input = .{ .connection_string = "AccountName=account;AccountKey=***" }, .failure = error.InvalidAccountKey },
    };
    for (cases) |case| {
        try std.testing.expectError(case.failure, TableServiceClient.init(allocator, runtime, .{ .authentication = case.input }));
        try std.testing.expectError(case.failure, TableClient.init(allocator, runtime, .{ .authentication = case.input, .table_name = "People" }));
    }
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);
}

fn RejectedConfigurationFixture(comptime Client: type) type {
    return struct {
        fn run(allocator: std.mem.Allocator) !void {
            var transport = core.http.MockTransport.init(std.testing.allocator, 200, "{}");
            defer transport.deinit();
            var crypto = core.crypto.StdCryptoProvider.init(std.testing.io);
            const runtime = core.http.HttpRuntime.init(transport.asTransport(), crypto.asProvider());
            var init_options: Client.InitOptions = undefined;
            init_options.authentication = .{ .connection_string = shared_connection };
            init_options.options = .{ .client_request_id = "invalid\r\nrequest-id" };
            if (Client == TableClient) init_options.table_name = "People";
            if (Client.init(allocator, runtime, init_options)) |value| {
                var unexpected = value;
                unexpected.deinit();
                return error.ExpectedInvalidClientRequestId;
            } else |err| switch (err) {
                error.InvalidClientRequestId => {},
                else => return err,
            }
            try std.testing.expectEqual(@as(usize, 0), transport.call_count);
        }
    };
}

test "rejected options release connection-string credentials at every allocation failure" {
    inline for (.{ TableClient, TableServiceClient }) |Client| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, RejectedConfigurationFixture(Client).run, .{});
    }
}
