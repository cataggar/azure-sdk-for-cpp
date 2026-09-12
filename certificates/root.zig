const std = @import("std");
const core = @import("azure_sdk_core");
const serde = @import("serde");
const pipeline_mod = @import("azure_sdk_keyvault_pipeline");
const test_support = if (@import("builtin").is_test)
    @import("azure_sdk_keyvault_test_support")
else
    struct {};

// ─────────────────────────── Models ───────────────────────────

/// Pager type returned by `listCertificates`.
pub const CertificatePager = pipeline_mod.ValidatedPipelinePager(KeyVaultCertificate);

pub const CertificateProperties = struct {
    enabled: ?bool = null,
    not_before: ?i64 = null,
    expires_on: ?i64 = null,
    created_on: ?i64 = null,
};

pub const KeyVaultCertificate = struct {
    name: []const u8,
    id: ?[]const u8 = null,
    properties: CertificateProperties = .{},

    /// Free allocated `id`. `name` is NOT freed (borrows caller input).
    pub fn deinit(self: KeyVaultCertificate, allocator: std.mem.Allocator) void {
        if (self.id) |i| allocator.free(i);
    }
};

// ──────────────────── CertificateClient ───────────────────────

pub const CertificateClientOptions = struct {
    api_version: []const u8 = "7.6-preview.2",
    retry: pipeline_mod.RetryOptions = .{},
    scope: []const u8 = pipeline_mod.default_scope,
    /// Borrowed tracing configuration; disabled by default. See PipelineState.
    instrumentation: ?core.tracing.InstrumentationOptions = null,
};

/// Runtime descriptors are copied by value. Their borrowed transport and
/// crypto contexts and the credential must outlive this client and every
/// pager returned by it. The caller must serialize all operations sharing
/// this client's pipeline state, including pager operations.
pub const CertificateClient = struct {
    vault_url: []const u8,
    api_version: []const u8,
    pipeline_state: *pipeline_mod.PipelineState,

    pub fn init(
        allocator: std.mem.Allocator,
        vault_url: []const u8,
        credential: *core.credentials.TokenCredential,
        runtime: core.http.HttpRuntime,
        options: CertificateClientOptions,
    ) !CertificateClient {
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

    pub fn deinit(self: *CertificateClient) void {
        self.pipeline_state.deinit();
        self.* = undefined;
    }

    /// GET /certificates/{name}?api-version=...
    pub fn getCertificate(
        self: *CertificateClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !KeyVaultCertificate {
        var r = try self.getCertificateResult(allocator, name);
        return r.unwrap(error.CertificateNotFound);
    }

    /// Same as `getCertificate` but returns `Result(KeyVaultCertificate)`.
    pub fn getCertificateResult(
        self: *CertificateClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !core.errors.Result(KeyVaultCertificate) {
        const url = try self.buildUrl(allocator, &.{ "certificates", name });
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

        return .{ .ok = try parseCertificate(allocator, name, resp.body) };
    }

    /// POST /certificates/{name}/create?api-version=...
    pub fn createCertificate(
        self: *CertificateClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        subject: []const u8,
        issuer: []const u8,
    ) !KeyVaultCertificate {
        var r = try self.createCertificateResult(allocator, name, subject, issuer);
        return r.unwrap(error.CreateCertificateFailed);
    }

    /// Same as `createCertificate` but returns `Result(KeyVaultCertificate)`.
    pub fn createCertificateResult(
        self: *CertificateClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        subject: []const u8,
        issuer: []const u8,
    ) !core.errors.Result(KeyVaultCertificate) {
        const url = try self.buildUrl(allocator, &.{ "certificates", name, "create" });
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"policy\":{{\"x509_props\":{{\"subject\":\"{s}\"}},\"issuer\":{{\"name\":\"{s}\"}}}}}}",
            .{ subject, issuer },
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

        return .{ .ok = try parseCertificate(allocator, name, resp.body) };
    }

    /// DELETE /certificates/{name}?api-version=...
    pub fn deleteCertificate(
        self: *CertificateClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !void {
        var r = try self.deleteCertificateResult(allocator, name);
        try r.unwrap(error.DeleteCertificateFailed);
    }

    /// Same as `deleteCertificate` but returns `Result(void)`.
    pub fn deleteCertificateResult(
        self: *CertificateClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !core.errors.Result(void) {
        const url = try self.buildUrl(allocator, &.{ "certificates", name });
        defer allocator.free(url);

        var req = core.http.Request.init(allocator, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline_state.pipeline.send(&req);
        defer resp.deinit();

        if (resp.isSuccess()) return .{ .ok = {} };
        if (core.errors.errorFromResponse(allocator, resp)) |az_err| {
            return .{ .err = az_err };
        }
        return error.AzureRequestFailed;
    }

    /// GET /certificates?api-version=... — returns a pager over certificates.
    pub fn listCertificates(
        self: *CertificateClient,
        allocator: std.mem.Allocator,
    ) !CertificatePager {
        const url = try self.buildUrl(allocator, &.{"certificates"});
        defer allocator.free(url);

        return CertificatePager.init(
            self.pipeline_state.pipeline,
            url,
            self.vault_url,
            allocator,
            &parseCertificateListPage,
            &deinitCertificates,
            "application/json",
        );
    }

    fn buildUrl(self: *CertificateClient, allocator: std.mem.Allocator, path_segments: []const []const u8) ![]u8 {
        var base = self.vault_url;
        if (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];

        var total_len: usize = base.len;
        for (path_segments) |seg| total_len += 1 + seg.len;
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
};

// ─────────────────────────── Parsing ──────────────────────────

const CertAttributesSchema = struct {
    enabled: ?bool = null,
    nbf: ?i64 = null,
    exp: ?i64 = null,
    created: ?i64 = null,
};

const CertSchema = struct {
    id: ?[]const u8 = null,
    attributes: ?CertAttributesSchema = null,
};

fn parseCertificate(allocator: std.mem.Allocator, name: []const u8, body: []const u8) !KeyVaultCertificate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(CertSchema, arena.allocator(), body) catch
        return .{ .name = name };

    var cert = KeyVaultCertificate{ .name = name };
    if (parsed.id) |v| cert.id = try allocator.dupe(u8, v);
    if (parsed.attributes) |a| {
        cert.properties.enabled = a.enabled;
        cert.properties.not_before = a.nbf;
        cert.properties.expires_on = a.exp;
        cert.properties.created_on = a.created;
    }
    return cert;
}

const CertListEntrySchema = struct {
    id: ?[]const u8 = null,
};

const CertListSchema = struct {
    value: ?[]const CertListEntrySchema = null,
    nextLink: ?[]const u8 = null,
};

fn parseCertificateListPage(
    allocator: std.mem.Allocator,
    body: []const u8,
    origin: []const u8,
) !core.pager.PageResult(KeyVaultCertificate) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = serde.json.fromSlice(CertListSchema, arena.allocator(), body) catch
        return .{ .items = try allocator.alloc(KeyVaultCertificate, 0) };

    var next_link: ?[]u8 = null;
    if (parsed.nextLink) |nl| {
        if (nl.len > 0) {
            try pipeline_mod.validateHttpsOrigin(origin, nl);
            next_link = try allocator.dupe(u8, nl);
        }
    }

    const entries = parsed.value orelse
        return .{ .items = try allocator.alloc(KeyVaultCertificate, 0), .next_link = next_link };

    var result = try allocator.alloc(KeyVaultCertificate, entries.len);
    for (entries, 0..) |entry, i| {
        var cert = KeyVaultCertificate{ .name = "" };
        if (entry.id) |id| cert.id = try allocator.dupe(u8, id);
        result[i] = cert;
    }
    return .{ .items = result, .next_link = next_link };
}

fn deinitCertificates(
    allocator: std.mem.Allocator,
    certificates: []KeyVaultCertificate,
) void {
    for (certificates) |certificate| certificate.deinit(allocator);
    allocator.free(certificates);
}

// ─────────────────────────── Tests ────────────────────────────

test "CertificateClient getCertificate" {
    const allocator = std.testing.allocator;
    const body =
        \\{"id":"https://vault.azure.net/certificates/mycert/v1","attributes":{"enabled":true,"created":1700000000,"exp":1800000000}}
    ;
    var mock = core.http.MockTransport.init(allocator, 200, body);
    defer mock.deinit();

    var credential = test_support.StaticCredential{};
    var probe = test_support.TracingProbe{};
    var tracing = try probe.createProvider();
    defer tracing.deinit() catch unreachable;
    var client = try CertificateClient.init(
        allocator,
        "https://vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{ .instrumentation = test_support.TracingProbe.options(&tracing) },
    );
    defer client.deinit();

    const cert = try client.getCertificate(allocator, "mycert");
    defer allocator.free(cert.id.?);
    try probe.expectSingleSpan(&tracing, &mock);

    try std.testing.expectEqualStrings("mycert", cert.name);
    try std.testing.expectEqual(true, cert.properties.enabled.?);
    try std.testing.expectEqual(@as(i64, 1800000000), cert.properties.expires_on.?);
    try std.testing.expect(std.mem.find(u8, mock.last_url.?, "certificates/mycert?api-version=") != null);
}

test "CertificateClient pager rejects cross-origin continuation before dispatch" {
    const allocator = std.testing.allocator;
    const body =
        \\{"value":[{"id":"https://vault.azure.net/certificates/mycert/v1"}],"nextLink":"https://attacker.example/steal"}
    ;
    var mock = core.http.MockTransport.init(allocator, 200, body);
    defer mock.deinit();
    var credential = test_support.StaticCredential{};
    var client = try CertificateClient.init(
        allocator,
        "https://vault.azure.net",
        credential.asCredential(),
        test_support.runtime(mock.asTransport()),
        .{ .retry = .{ .max_retries = 0 } },
    );
    defer client.deinit();

    var pager = try client.listCertificates(allocator);
    defer pager.deinit();
    try std.testing.expectError(error.InvalidContinuationUrl, pager.next());
    try std.testing.expect(pager.next_url == null);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqualStrings(
        "https://vault.azure.net/certificates?api-version=7.6-preview.2",
        mock.last_url.?,
    );
}
