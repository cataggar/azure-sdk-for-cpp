const std = @import("std");
const core = @import("azure_sdk_core");
const serde = @import("serde");
const pipeline_mod = @import("azure_sdk_keyvault_pipeline");
const test_support = if (@import("builtin").is_test)
    @import("azure_sdk_keyvault_test_support")
else
    struct {};

/// Pager type returned by `listSettings`.
pub const AdminSettingPager = core.pager.PipelinePager(AdminSetting);

pub const AdminSetting = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

// ──────────────────────── BackupClient ────────────────────────

pub const BackupClientOptions = struct {
    api_version: []const u8 = "7.6-preview.2",
    retry: pipeline_mod.RetryOptions = .{},
    scope: []const u8 = pipeline_mod.default_scope,
    /// Borrowed tracing configuration; disabled by default. See PipelineState.
    instrumentation: ?core.tracing.InstrumentationOptions = null,
};

/// Runtime descriptors are copied by value. Their borrowed transport and
/// crypto contexts and the credential must outlive this client and every
/// in-flight operation. The caller must serialize every operation sharing
/// this client's pipeline state.
pub const BackupClient = struct {
    vault_url: []const u8,
    api_version: []const u8,
    pipeline_state: *pipeline_mod.PipelineState,

    pub fn init(
        allocator: std.mem.Allocator,
        vault_url: []const u8,
        credential: *core.credentials.TokenCredential,
        runtime: core.http.HttpRuntime,
        options: BackupClientOptions,
    ) !BackupClient {
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

    pub fn deinit(self: *BackupClient) void {
        self.pipeline_state.deinit();
        self.* = undefined;
    }

    /// POST /backup?api-version=... — begins a full backup (LRO stub returning operation ID).
    pub fn beginBackup(
        self: *BackupClient,
        allocator: std.mem.Allocator,
        storage_uri: []const u8,
        sas_token: []const u8,
    ) ![]const u8 {
        var r = try self.beginBackupResult(allocator, storage_uri, sas_token);
        return r.unwrap(error.BeginBackupFailed);
    }

    /// Same as `beginBackup` but returns `Result([]const u8)`.
    pub fn beginBackupResult(
        self: *BackupClient,
        allocator: std.mem.Allocator,
        storage_uri: []const u8,
        sas_token: []const u8,
    ) !core.errors.Result([]const u8) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/backup?api-version={s}",
            .{ self.vault_url, self.api_version },
        );
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"storageResourceUri\":\"{s}\",\"token\":\"{s}\"}}",
            .{ storage_uri, sas_token },
        );
        defer allocator.free(body);

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
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

        return .{ .ok = try parseOperationId(allocator, resp.body) };
    }

    /// POST /restore?api-version=... — begins a restore (LRO stub returning operation ID).
    pub fn beginRestore(
        self: *BackupClient,
        allocator: std.mem.Allocator,
        backup_uri: []const u8,
        sas_token: []const u8,
    ) ![]const u8 {
        var r = try self.beginRestoreResult(allocator, backup_uri, sas_token);
        return r.unwrap(error.BeginRestoreFailed);
    }

    /// Same as `beginRestore` but returns `Result([]const u8)`.
    pub fn beginRestoreResult(
        self: *BackupClient,
        allocator: std.mem.Allocator,
        backup_uri: []const u8,
        sas_token: []const u8,
    ) !core.errors.Result([]const u8) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/restore?api-version={s}",
            .{ self.vault_url, self.api_version },
        );
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"sasTokenParameters\":{{\"storageResourceUri\":\"{s}\",\"token\":\"{s}\"}}}}",
            .{ backup_uri, sas_token },
        );
        defer allocator.free(body);

        var req = core.http.Request.init(allocator, .POST, url);
        defer req.deinit();
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

        return .{ .ok = try parseOperationId(allocator, resp.body) };
    }

    /// Wait for a backup operation to complete by polling the operation URL.
    pub fn waitForBackup(
        self: *BackupClient,
        allocator: std.mem.Allocator,
        operation_url: []const u8,
    ) !core.lro.PollResult {
        return core.lro.pollUntilDone(
            allocator,
            &self.pipeline_state.pipeline,
            operation_url,
            2000,
            60,
        );
    }

    /// Wait for a restore operation to complete by polling the operation URL.
    pub fn waitForRestore(
        self: *BackupClient,
        allocator: std.mem.Allocator,
        operation_url: []const u8,
    ) !core.lro.PollResult {
        return core.lro.pollUntilDone(
            allocator,
            &self.pipeline_state.pipeline,
            operation_url,
            2000,
            60,
        );
    }
};

// ──────────────────────── SettingsClient ──────────────────────

pub const SettingsClientOptions = struct {
    api_version: []const u8 = "7.6-preview.2",
    retry: pipeline_mod.RetryOptions = .{},
    scope: []const u8 = pipeline_mod.default_scope,
    /// Borrowed tracing configuration; disabled by default. See PipelineState.
    instrumentation: ?core.tracing.InstrumentationOptions = null,
};

/// Runtime descriptors are copied by value. Their borrowed transport and
/// crypto contexts and the credential must outlive this client and every
/// pager returned by it. The caller must serialize every operation sharing
/// this client's pipeline state, including pager operations.
pub const SettingsClient = struct {
    vault_url: []const u8,
    api_version: []const u8,
    pipeline_state: *pipeline_mod.PipelineState,

    pub fn init(
        allocator: std.mem.Allocator,
        vault_url: []const u8,
        credential: *core.credentials.TokenCredential,
        runtime: core.http.HttpRuntime,
        options: SettingsClientOptions,
    ) !SettingsClient {
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

    pub fn deinit(self: *SettingsClient) void {
        self.pipeline_state.deinit();
        self.* = undefined;
    }

    /// GET /settings/{name}?api-version=...
    pub fn getSetting(
        self: *SettingsClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) ![]const u8 {
        var r = try self.getSettingResult(allocator, name);
        return r.unwrap(error.GetSettingFailed);
    }

    /// Same as `getSetting` but returns `Result([]const u8)`.
    pub fn getSettingResult(
        self: *SettingsClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !core.errors.Result([]const u8) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/settings/{s}?api-version={s}",
            .{ self.vault_url, name, self.api_version },
        );
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

        return .{ .ok = try parseSettingValue(allocator, resp.body) };
    }

    /// PATCH /settings/{name}?api-version=...
    pub fn updateSetting(
        self: *SettingsClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
    ) !void {
        var r = try self.updateSettingResult(allocator, name, value);
        try r.unwrap(error.UpdateSettingFailed);
    }

    /// Same as `updateSetting` but returns `Result(void)`.
    pub fn updateSettingResult(
        self: *SettingsClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
    ) !core.errors.Result(void) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/settings/{s}?api-version={s}",
            .{ self.vault_url, name, self.api_version },
        );
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(allocator, "{{\"value\":\"{s}\"}}", .{value});
        defer allocator.free(body);

        var req = core.http.Request.init(allocator, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        req.body = body;

        var resp = try self.pipeline_state.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// GET /settings?api-version=... — returns a pager over admin settings.
    pub fn listSettings(
        self: *SettingsClient,
        allocator: std.mem.Allocator,
    ) !AdminSettingPager {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/settings?api-version={s}",
            .{ self.vault_url, self.api_version },
        );
        defer allocator.free(url);

        return AdminSettingPager.init(
            self.pipeline_state.pipeline,
            url,
            allocator,
            &parseAdminSettingListPage,
            "application/json",
        );
    }
};

// ─────────────────────────── Parsing ──────────────────────────

fn parseOperationId(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Schema = struct { jobId: ?[]const u8 = null };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(Schema, arena.allocator(), body) catch
        return error.ParseFailed;
    const job_id = parsed.jobId orelse return error.ParseFailed;
    return allocator.dupe(u8, job_id);
}

fn parseSettingValue(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Schema = struct { value: ?[]const u8 = null };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(Schema, arena.allocator(), body) catch
        return error.ParseFailed;
    const value = parsed.value orelse return error.ParseFailed;
    return allocator.dupe(u8, value);
}

const AdminSettingEntrySchema = struct {
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
};

const AdminSettingListSchema = struct {
    value: ?[]const AdminSettingEntrySchema = null,
};

fn parseAdminSettingListPage(allocator: std.mem.Allocator, body: []const u8) !core.pager.PageResult(AdminSetting) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(AdminSettingListSchema, arena.allocator(), body) catch
        return .{ .items = try allocator.alloc(AdminSetting, 0) };

    const entries = parsed.value orelse return .{ .items = try allocator.alloc(AdminSetting, 0) };

    var result = try allocator.alloc(AdminSetting, entries.len);
    for (entries, 0..) |entry, i| {
        var setting = AdminSetting{ .name = "" };
        if (entry.name) |n| setting.name = try allocator.dupe(u8, n);
        if (entry.value) |v| setting.value = try allocator.dupe(u8, v);
        result[i] = setting;
    }
    return .{ .items = result };
}

// ─────────────────────────── Tests ────────────────────────────

test "BackupClient beginBackup" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 202,
        \\{"jobId":"backup-op-001","status":"InProgress"}
    );
    defer mock.deinit();

    var credential = test_support.StaticCredential{};
    var probe = test_support.TracingProbe{};
    var tracing = try probe.createProvider();
    defer tracing.deinit() catch unreachable;
    var client = try BackupClient.init(
        allocator,
        "https://vault.managedhsm.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{ .instrumentation = test_support.TracingProbe.options(&tracing) },
    );
    defer client.deinit();

    const op_id = try client.beginBackup(allocator, "https://storage.blob.core.windows.net/backup", "sas-token");
    defer allocator.free(op_id);
    try probe.expectSingleSpan(&tracing, &mock);

    try std.testing.expectEqualStrings("backup-op-001", op_id);
    try std.testing.expectEqual(core.http.Method.POST, mock.last_method.?);
    try std.testing.expect(std.mem.find(u8, mock.last_url.?, "/backup?api-version=") != null);
}

test "SettingsClient getSetting" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200,
        \\{"value":"true","name":"AllowKeyManagementOperationsThroughARM"}
    );
    defer mock.deinit();

    var credential = test_support.StaticCredential{};
    var probe = test_support.TracingProbe{};
    var tracing = try probe.createProvider();
    defer tracing.deinit() catch unreachable;
    var client = try SettingsClient.init(
        allocator,
        "https://vault.managedhsm.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{ .instrumentation = test_support.TracingProbe.options(&tracing) },
    );
    defer client.deinit();

    const value = try client.getSetting(allocator, "AllowKeyManagementOperationsThroughARM");
    defer allocator.free(value);
    try probe.expectSingleSpan(&tracing, &mock);

    try std.testing.expectEqualStrings("true", value);
    try std.testing.expect(std.mem.find(u8, mock.last_url.?, "settings/AllowKeyManagementOperationsThroughARM") != null);
}
