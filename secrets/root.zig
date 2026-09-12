const std = @import("std");
const core = @import("azure_sdk_core");
const serde = @import("serde");
const pipeline_mod = @import("azure_sdk_keyvault_pipeline");
const test_support = if (@import("builtin").is_test)
    @import("azure_sdk_keyvault_test_support")
else
    struct {};

/// Pager type returned by `listSecrets`.
pub const SecretNamePager = pipeline_mod.ValidatedPipelinePager([]const u8);

// ─────────────────────────── Models ───────────────────────────

pub const SecretProperties = struct {
    enabled: ?bool = null,
    not_before: ?i64 = null,
    expires_on: ?i64 = null,
    created_on: ?i64 = null,
    updated_on: ?i64 = null,
    content_type: ?[]const u8 = null,
    version: ?[]const u8 = null,
    recovery_level: ?[]const u8 = null,
};

pub const KeyVaultSecret = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    id: ?[]const u8 = null,
    properties: SecretProperties = .{},

    /// Free the allocated `value`, `id`, and `properties.content_type`
    /// strings. `name` is NOT freed — by convention for single-resource
    /// fetches it's a borrow of the caller's input string (and the same
    /// pointer the caller passed to `getSecret(..., name)`).
    pub fn deinit(self: KeyVaultSecret, allocator: std.mem.Allocator) void {
        if (self.value) |v| allocator.free(v);
        if (self.id) |i| allocator.free(i);
        if (self.properties.content_type) |c| allocator.free(c);
    }
};

pub const DeletedSecret = struct {
    name: []const u8,
    recovery_id: ?[]const u8 = null,
    deleted_date: ?i64 = null,
    scheduled_purge_date: ?i64 = null,
};

// ─────────────────────────── Client ───────────────────────────

pub const SecretClientOptions = struct {
    api_version: []const u8 = "7.6-preview.2",
    retry: pipeline_mod.RetryOptions = .{},
    scope: []const u8 = pipeline_mod.default_scope,
    /// Borrowed tracing configuration; disabled by default. See PipelineState.
    instrumentation: ?core.tracing.InstrumentationOptions = null,
};

/// Client for Azure Key Vault Secrets.
///
/// Runtime descriptors are copied by value. Their borrowed transport and
/// crypto contexts and the credential must outlive this client and every
/// pager returned by it. Keep the client alive until its pagers are
/// deinitialized. The caller must serialize all operations sharing this
/// client's pipeline state, including pager operations.
pub const SecretClient = struct {
    vault_url: []const u8,
    api_version: []const u8,
    pipeline_state: *pipeline_mod.PipelineState,

    pub fn init(
        allocator: std.mem.Allocator,
        vault_url: []const u8,
        credential: *core.credentials.TokenCredential,
        runtime: core.http.HttpRuntime,
        options: SecretClientOptions,
    ) !SecretClient {
        const pipeline_state = try pipeline_mod.PipelineState.create(
            allocator,
            credential,
            runtime,
            options.retry,
            options.scope,
        );
        pipeline_state.setInstrumentation(options.instrumentation);
        return .{
            .vault_url = vault_url,
            .api_version = options.api_version,
            .pipeline_state = pipeline_state,
        };
    }

    pub fn deinit(self: *SecretClient) void {
        self.pipeline_state.deinit();
        self.* = undefined;
    }

    /// GET /secrets/{name}?api-version=...
    ///
    /// Thin wrapper over `getSecretResult` that logs Azure errors via
    /// `std.log.warn` and returns `error.SecretNotFound` on any
    /// non-success status. Use `getSecretResult` if you need to branch
    /// on the specific Azure `error_code`.
    pub fn getSecret(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !KeyVaultSecret {
        var r = try self.getSecretResult(allocator, name);
        return r.unwrap(error.SecretNotFound);
    }

    /// Same as `getSecret`, but returns the typed `AzureError` on
    /// Azure-side failures rather than a generic `error.SecretNotFound`.
    ///
    /// Use this when you need to branch on `AzureError.error_code` —
    /// for example, to distinguish `"SecretNotFound"` (expected) from
    /// `"Forbidden"` (a real failure).
    ///
    /// Note: this method does NOT call `logErrorResponse` — the caller
    /// receives the structured error directly and can log or suppress
    /// as appropriate.
    pub fn getSecretResult(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !core.errors.Result(KeyVaultSecret) {
        const url = try self.buildUrl(allocator, &.{ "secrets", name }, null);
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline_state.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try parseSecret(allocator, name, resp.body) };
    }

    /// PUT /secrets/{name}?api-version=...
    /// Body: {"value": "..."}
    pub fn setSecret(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
    ) !KeyVaultSecret {
        var r = try self.setSecretResult(allocator, name, value);
        return r.unwrap(error.SetSecretFailed);
    }

    /// Same as `setSecret` but returns `Result(KeyVaultSecret)`.
    pub fn setSecretResult(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
    ) !core.errors.Result(KeyVaultSecret) {
        const url = try self.buildUrl(allocator, &.{ "secrets", name }, null);
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(allocator, "{{\"value\":\"{s}\"}}", .{value});
        defer allocator.free(body);

        var req = core.http.Request.init(allocator, .PUT, url);
        defer req.deinit();
        req.retryable = false;
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        req.body = body;

        var resp = try self.pipeline_state.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try parseSecret(allocator, name, resp.body) };
    }

    /// DELETE /secrets/{name}?api-version=...
    pub fn deleteSecret(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !DeletedSecret {
        var r = try self.deleteSecretResult(allocator, name);
        return r.unwrap(error.DeleteSecretFailed);
    }

    /// Same as `deleteSecret` but returns `Result(DeletedSecret)`.
    pub fn deleteSecretResult(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !core.errors.Result(DeletedSecret) {
        const url = try self.buildUrl(allocator, &.{ "secrets", name }, null);
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline_state.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = .{ .name = name } };
    }

    /// DELETE /deletedsecrets/{name}?api-version=...  → 204
    pub fn purgeDeletedSecret(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !void {
        var r = try self.purgeDeletedSecretResult(allocator, name);
        try r.unwrap(error.PurgeFailed);
    }

    /// Same as `purgeDeletedSecret` but returns `Result(void)`.
    pub fn purgeDeletedSecretResult(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !core.errors.Result(void) {
        const url = try self.buildUrl(allocator, &.{ "deletedsecrets", name }, null);
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline_state.pipeline.send(&req);
        defer resp.deinit();

        if (resp.status_code == 204 or resp.isSuccess()) {
            return .{ .ok = {} };
        }
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// POST /deletedsecrets/{name}/recover?api-version=...
    pub fn recoverDeletedSecret(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !KeyVaultSecret {
        var r = try self.recoverDeletedSecretResult(allocator, name);
        return r.unwrap(error.RecoverFailed);
    }

    /// Same as `recoverDeletedSecret` but returns `Result(KeyVaultSecret)`.
    pub fn recoverDeletedSecretResult(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !core.errors.Result(KeyVaultSecret) {
        const url = try self.buildUrl(allocator, &.{ "deletedsecrets", name, "recover" }, null);
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline_state.pipeline.send(&req);
        defer resp.deinit();

        if (!resp.isSuccess()) {
            if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
                return .{ .err = az_err };
            }
            return error.AzureRequestFailed;
        }

        return .{ .ok = try parseSecret(allocator, name, resp.body) };
    }

    // ──── Helpers ────

    fn buildUrl(
        self: *SecretClient,
        allocator: std.mem.Allocator,
        path_segments: []const []const u8,
        _: ?[]const u8,
    ) ![]u8 {
        // Start with vault_url (strip trailing slash).
        var base = self.vault_url;
        if (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];

        var total_len: usize = base.len;
        for (path_segments) |seg| total_len += 1 + seg.len;
        // ?api-version=...
        total_len += "?api-version=".len + self.api_version.len;

        var buf = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        @memcpy(buf[pos..][0..base.len], base);
        pos += base.len;
        for (path_segments) |seg| {
            buf[pos] = '/';
            pos += 1;
            @memcpy(buf[pos..][0..seg.len], seg);
            pos += seg.len;
        }
        const suffix = "?api-version=";
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
        @memcpy(buf[pos..][0..self.api_version.len], self.api_version);
        return buf;
    }

    /// GET /secrets?api-version=... — returns a pager over secret names.
    ///
    /// Usage:
    ///   var pager = try client.listSecrets(allocator);
    ///   defer pager.deinit();
    ///   while (try pager.next()) |names| {
    ///       defer allocator.free(names);
    ///       for (names) |name| { defer allocator.free(name); ... }
    ///   }
    pub fn listSecrets(
        self: *SecretClient,
        allocator: std.mem.Allocator,
    ) !SecretNamePager {
        const url = try self.buildUrl(allocator, &.{"secrets"}, null);
        defer allocator.free(url);

        return SecretNamePager.init(
            self.pipeline_state.pipeline,
            url,
            self.vault_url,
            allocator,
            &parseSecretListPage,
            &deinitSecretNames,
            "application/json",
        );
    }
};

/// Wire format of a Key Vault Secret response.
const SecretSchema = struct {
    value: ?[]const u8 = null,
    id: ?[]const u8 = null,
    contentType: ?[]const u8 = null,
    attributes: ?AttributesSchema = null,

    const AttributesSchema = struct {
        enabled: ?bool = null,
        exp: ?i64 = null,
        nbf: ?i64 = null,
        created: ?i64 = null,
        updated: ?i64 = null,
    };
};

/// Parse a JSON secret response into a KeyVaultSecret.
fn parseSecret(allocator: std.mem.Allocator, name: []const u8, body: []const u8) !KeyVaultSecret {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(SecretSchema, arena.allocator(), body) catch
        return .{ .name = name };

    var secret = KeyVaultSecret{ .name = name };
    if (parsed.value) |v| secret.value = try allocator.dupe(u8, v);
    if (parsed.id) |v| secret.id = try allocator.dupe(u8, v);
    if (parsed.contentType) |v| secret.properties.content_type = try allocator.dupe(u8, v);
    if (parsed.attributes) |a| {
        secret.properties.enabled = a.enabled;
        secret.properties.expires_on = a.exp;
        secret.properties.not_before = a.nbf;
        secret.properties.created_on = a.created;
        secret.properties.updated_on = a.updated;
    }
    return secret;
}

/// Wire format of a single entry in a list-secrets response.
const SecretListEntry = struct {
    id: ?[]const u8 = null,
};

/// Wire format of a paged list-secrets response.
const SecretListSchema = struct {
    value: ?[]const SecretListEntry = null,
    nextLink: ?[]const u8 = null,
};

/// Parse a JSON list-secrets response into a PageResult.
/// Format: {"value":[{"id":"https://.../secrets/name1"}, ...], "nextLink":"https://..."}
fn parseSecretListPage(
    allocator: std.mem.Allocator,
    body: []const u8,
    origin: []const u8,
) !core.pager.PageResult([]const u8) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(SecretListSchema, arena.allocator(), body) catch
        return .{ .items = try allocator.alloc([]const u8, 0) };

    var next_link: ?[]u8 = null;
    if (parsed.nextLink) |nl| {
        if (nl.len > 0) {
            try pipeline_mod.validateHttpsOrigin(origin, nl);
            next_link = try allocator.dupe(u8, nl);
        }
    }

    const entries = parsed.value orelse
        return .{ .items = try allocator.alloc([]const u8, 0), .next_link = next_link };

    var names = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| {
        if (entry.id) |id_str| {
            if (std.mem.findScalarLast(u8, id_str, '/')) |slash| {
                names[i] = try allocator.dupe(u8, id_str[slash + 1 ..]);
                continue;
            }
        }
        names[i] = try allocator.dupe(u8, "");
    }

    return .{ .items = names, .next_link = next_link };
}

fn deinitSecretNames(allocator: std.mem.Allocator, names: [][]const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

test "SecretClient getSecretResult: ok path" {
    const allocator = std.testing.allocator;
    const body =
        \\{"value":"my-secret-value","id":"https://myvault.vault.azure.net/secrets/mysecret/abc123"}
    ;
    var mock = core.http.MockTransport.init(allocator, 200, body);
    defer mock.deinit();

    var credential = test_support.StaticCredential{};

    var client = try SecretClient.init(
        allocator,
        "https://myvault.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{},
    );
    defer client.deinit();

    var r = try client.getSecretResult(allocator, "mysecret");
    defer r.deinit(allocator);

    try std.testing.expect(r.isOk());
    try std.testing.expectEqualStrings("my-secret-value", r.ok.value.?);
}

test "SecretClient getSecretResult: err path surfaces SecretNotFound code" {
    const allocator = std.testing.allocator;
    const body =
        \\{"error":{"code":"SecretNotFound","message":"Secret not found"}}
    ;
    var mock = core.http.MockTransport.init(allocator, 404, body);
    defer mock.deinit();

    var credential = test_support.StaticCredential{};

    var client = try SecretClient.init(
        allocator,
        "https://myvault.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{},
    );
    defer client.deinit();

    var r = try client.getSecretResult(allocator, "missing");
    defer r.deinit(allocator);

    try std.testing.expect(!r.isOk());
    try std.testing.expectEqualStrings("SecretNotFound", r.errorCode().?);
    try std.testing.expectEqual(@as(u16, 404), r.err.status_code);
    try std.testing.expectEqualStrings("Secret not found", r.err.message.?);
}

test "SecretClient getSecretResult: err path with no parseable body" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 500, "Internal Server Error");
    defer mock.deinit();

    var credential = test_support.StaticCredential{};

    var client = try SecretClient.init(
        allocator,
        "https://myvault.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{},
    );
    defer client.deinit();

    var r = try client.getSecretResult(allocator, "boom");
    defer r.deinit(allocator);

    try std.testing.expect(!r.isOk());
    // No JSON envelope in the body → error_code/message stay null, but
    // status_code is still populated so callers can branch on HTTP class.
    try std.testing.expectEqual(@as(u16, 500), r.err.status_code);
    try std.testing.expectEqual(@as(?[]const u8, null), r.errorCode());
    try std.testing.expectEqual(@as(?[]const u8, null), r.err.message);
}

// ─────────────────────────── Tests ───────────────────────────

test "SecretClient getSecret" {
    const allocator = std.testing.allocator;
    const body =
        \\{"value":"my-secret-value","id":"https://myvault.vault.azure.net/secrets/mysecret/abc123","attributes":{"enabled":true,"created":1700000000,"updated":1700000001}}
    ;
    var mock = core.http.MockTransport.init(allocator, 200, body);
    defer mock.deinit();

    var credential = test_support.StaticCredential{};

    var client = try SecretClient.init(
        allocator,
        "https://myvault.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{},
    );
    defer client.deinit();

    const secret = try client.getSecret(allocator, "mysecret");
    defer allocator.free(secret.value.?);
    defer allocator.free(secret.id.?);

    try std.testing.expectEqualStrings("mysecret", secret.name);
    try std.testing.expectEqualStrings("my-secret-value", secret.value.?);
    try std.testing.expectEqual(true, secret.properties.enabled.?);
    try std.testing.expect(std.mem.find(u8, mock.last_url.?, "secrets/mysecret?api-version=") != null);
}

test "SecretClient setSecret" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"value":"new-val","id":"https://v.vault.azure.net/secrets/s/v1"}
    );
    defer mock.deinit();

    var credential = test_support.StaticCredential{};

    var client = try SecretClient.init(
        allocator,
        "https://v.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{},
    );
    defer client.deinit();

    const secret = try client.setSecret(allocator, "s", "new-val");
    defer allocator.free(secret.value.?);
    defer allocator.free(secret.id.?);

    try std.testing.expectEqualStrings("new-val", secret.value.?);
    try std.testing.expectEqual(core.http.Method.PUT, mock.last_method.?);
    try std.testing.expect(!mock.last_retryable.?);
}

test "SecretClient getSecret 404" {
    const allocator = std.testing.allocator;
    const body =
        \\{"error":{"code":"SecretNotFound","message":"Secret not found"}}
    ;
    var mock = core.http.MockTransport.init(allocator, 404, body);
    defer mock.deinit();

    var credential = test_support.StaticCredential{};

    var client = try SecretClient.init(
        allocator,
        "https://myvault.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{},
    );
    defer client.deinit();

    const result = client.getSecret(allocator, "nonexistent");
    try std.testing.expectError(error.SecretNotFound, result);
}

test "SecretClient setSecret failure" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 403,
        \\{"error":{"code":"Forbidden","message":"Access denied"}}
    );
    defer mock.deinit();

    var credential = test_support.StaticCredential{};

    var client = try SecretClient.init(
        allocator,
        "https://myvault.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{},
    );
    defer client.deinit();

    const result = client.setSecret(allocator, "s", "val");
    try std.testing.expectError(error.SetSecretFailed, result);
}

test "SecretClient setSecret does not retry ambiguous transient failure" {
    const allocator = std.testing.allocator;
    var mock = core.http.SequenceMockTransport.init(allocator, &.{
        .{
            .status = 500,
            .body = "{\"error\":{\"code\":\"InternalServerError\"}}",
        },
        .{
            .status = 200,
            .body = "{\"value\":\"duplicate\",\"id\":\"https://v.vault.azure.net/secrets/s/v2\"}",
        },
    });
    var credential = test_support.StaticCredential{};
    var client = try SecretClient.init(
        allocator,
        "https://v.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{ .retry = .{ .initial_delay_ms = 0 } },
    );
    defer client.deinit();

    var result = try client.setSecretResult(allocator, "s", "value");
    defer result.deinit(allocator);
    try std.testing.expect(!result.isOk());
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "SecretClient listSecrets" {
    const allocator = std.testing.allocator;
    const body =
        \\{"value":[{"id":"https://v.vault.azure.net/secrets/secret1"},{"id":"https://v.vault.azure.net/secrets/secret2"}],"nextLink":"https://v.vault.azure.net/secrets?$skiptoken=abc"}
    ;
    var mock = core.http.MockTransport.init(allocator, 200, body);
    defer mock.deinit();

    var credential = test_support.StaticCredential{};

    var client = try SecretClient.init(
        allocator,
        "https://v.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{},
    );
    defer client.deinit();

    var pager = try client.listSecrets(allocator);
    defer pager.deinit();

    const names = (try pager.next()) orelse return error.ExpectedPage;
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("secret1", names[0]);
    try std.testing.expectEqualStrings("secret2", names[1]);

    // Pager should have a next_url set from nextLink (but we'd need a
    // SequenceMockTransport to actually fetch the second page).
    try std.testing.expect(pager.next_url != null);
}

test "SecretClient pager rejects cross-origin continuation before dispatch" {
    const allocator = std.testing.allocator;
    const body =
        \\{"value":[{"id":"https://v.vault.azure.net/secrets/secret1"}],"nextLink":"https://attacker.example/steal"}
    ;
    var mock = core.http.MockTransport.init(allocator, 200, body);
    defer mock.deinit();
    var credential = test_support.StaticCredential{};
    var client = try SecretClient.init(
        allocator,
        "https://v.vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{ .retry = .{ .max_retries = 0 } },
    );
    defer client.deinit();

    var pager = try client.listSecrets(allocator);
    defer pager.deinit();
    try std.testing.expectError(error.InvalidContinuationUrl, pager.next());
    try std.testing.expect(pager.next_url == null);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqualStrings(
        "https://v.vault.azure.net/secrets?api-version=7.6-preview.2",
        mock.last_url.?,
    );
}

test "SecretClient pager inherits tracing and retains opaque continuation data" {
    const allocator = std.testing.allocator;
    const continuation = "https://v.vault.azure.net/secrets?$skiptoken=opaque%2B%2F%3D";
    var mock = core.http.MockTransport.init(
        allocator,
        200,
        "{\"value\":[{\"id\":\"https://v.vault.azure.net/secrets/one\"}],\"nextLink\":\"" ++ continuation ++ "\"}",
    );
    defer mock.deinit();
    var probe = test_support.TracingProbe{};
    var tracing = try probe.createProvider();
    defer tracing.deinit() catch unreachable;
    var ids: [2][16]u8 = undefined;
    {
        var credential = test_support.StaticCredential{};
        var client = try SecretClient.init(
            allocator,
            "https://v.vault.azure.net",
            credential.asCredential(),
            test_support.runtime(mock.asTransport()),
            .{ .instrumentation = test_support.TracingProbe.options(&tracing) },
        );
        defer client.deinit();
        var pager = try client.listSecrets(allocator);
        defer pager.deinit();
        const names = (try pager.next()) orelse return error.ExpectedPage;
        defer {
            for (names) |name| allocator.free(name);
            allocator.free(names);
        }
        try std.testing.expectEqual(@as(usize, 1), names.len);
        try std.testing.expectEqualStrings("one", names[0]);
        try std.testing.expectEqualStrings(continuation, pager.next_url.?);
        ids[0] = try test_support.TracingProbe.wireId(&mock);
        mock.response_body = "{\"value\":[]}";
        const last = (try pager.next()) orelse return error.ExpectedPage;
        defer allocator.free(last);
        try std.testing.expectEqual(@as(usize, 0), last.len);
        try std.testing.expectEqualStrings(continuation, mock.last_url.?);
        ids[1] = try test_support.TracingProbe.wireId(&mock);
        try std.testing.expect((try pager.next()) == null);
        try std.testing.expectEqual(@as(usize, 2), mock.call_count);
        try std.testing.expectEqualStrings(pipeline_mod.default_scope, credential.last_scope.?);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expectEqual(@as(usize, 0), tracing.stats().active_spans);
    try std.testing.expectEqual(@as(usize, 2), tracing.stats().queued_spans);
    try tracing.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    for (ids, 0..) |id, i| try std.testing.expectEqualStrings(&id, &probe.ids[i]);
    try tracing.shutdown(1000);
}

test "disabled or failing tracing preserves SecretClient structured results" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |instrumented| {
        for ([_]u16{ 200, 404 }) |status| {
            var mock = core.http.MockTransport.init(
                allocator,
                status,
                if (status == 200) "{\"value\":\"secret-value\"}" else "{\"error\":{\"code\":\"SecretNotFound\"}}",
            );
            defer mock.deinit();
            var credential = test_support.StaticCredential{};
            var tracing = test_support.FailingTracingProvider{};
            var client = try SecretClient.init(
                allocator,
                "https://v.vault.azure.net",
                credential.asCredential(),
                test_support.runtime(mock.asTransport()),
                .{ .instrumentation = if (instrumented) .{
                    .provider = &tracing.provider,
                    .scope_name = "caller.keyvault",
                } else null },
            );
            defer client.deinit();
            var result = try client.getSecretResult(allocator, "secret");
            defer result.deinit(allocator);
            if (status == 200) {
                try std.testing.expect(result.isOk());
                try std.testing.expectEqualStrings("secret-value", result.ok.value.?);
            } else {
                try std.testing.expect(!result.isOk());
                try std.testing.expectEqual(@as(u16, 404), result.err.status_code);
                try std.testing.expectEqualStrings("SecretNotFound", result.errorCode().?);
            }
            try std.testing.expectEqual(@as(usize, 1), mock.call_count);
            try std.testing.expectEqual(@as(usize, @intFromBool(instrumented)), tracing.attempts);
            try std.testing.expect(mock.last_headers.get("traceparent") == null);
            try std.testing.expect(mock.last_headers.get("tracestate") == null);
        }
    }
}
