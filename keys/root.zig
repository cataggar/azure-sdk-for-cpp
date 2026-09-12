//! Azure Key Vault Keys and Cryptography clients.
//!
//! Uses the stable 2025-07-01 data-plane API, authenticated HTTP pipelines,
//! typed key/signature values, and base64url-without-padding JWK encoding.

const std = @import("std");
const serde = @import("serde");
const core = @import("azure_sdk_core");
const pipeline_mod = @import("azure_sdk_keyvault_pipeline");
const test_support = if (@import("builtin").is_test)
    @import("azure_sdk_keyvault_test_support")
else
    struct {};

const HttpPipeline = core.http.HttpPipeline;
const Request = core.http.Request;
const TokenCredential = core.credentials.TokenCredential;
const Result = core.errors.Result;

pub const api_version = "2025-07-01";
pub const default_scope = "https://vault.azure.net/.default";

pub const KeyType = enum {
    rsa,
    rsa_hsm,
    ec,
    ec_hsm,
    oct,
    oct_hsm,

    pub fn wireValue(self: KeyType) []const u8 {
        return switch (self) {
            .rsa => "RSA",
            .rsa_hsm => "RSA-HSM",
            .ec => "EC",
            .ec_hsm => "EC-HSM",
            .oct => "oct",
            .oct_hsm => "oct-HSM",
        };
    }

    pub fn parse(value: []const u8) !KeyType {
        inline for (std.meta.tags(KeyType)) |tag| {
            if (std.mem.eql(u8, value, tag.wireValue())) return tag;
        }
        return error.UnsupportedKeyType;
    }
};

pub const KeyOperation = enum {
    encrypt,
    decrypt,
    sign,
    verify,
    wrap_key,
    unwrap_key,
    import_key,
    export_key,

    pub fn wireValue(self: KeyOperation) []const u8 {
        return switch (self) {
            .encrypt => "encrypt",
            .decrypt => "decrypt",
            .sign => "sign",
            .verify => "verify",
            .wrap_key => "wrapKey",
            .unwrap_key => "unwrapKey",
            .import_key => "import",
            .export_key => "export",
        };
    }

    pub fn parse(value: []const u8) !KeyOperation {
        inline for (std.meta.tags(KeyOperation)) |tag| {
            if (std.mem.eql(u8, value, tag.wireValue())) return tag;
        }
        return error.UnsupportedKeyOperation;
    }
};

pub const SignatureAlgorithm = enum {
    rs256,
    rs384,
    rs512,
    ps256,
    ps384,
    ps512,
    es256,
    es256k,
    es384,
    es512,

    pub fn wireValue(self: SignatureAlgorithm) []const u8 {
        return switch (self) {
            .rs256 => "RS256",
            .rs384 => "RS384",
            .rs512 => "RS512",
            .ps256 => "PS256",
            .ps384 => "PS384",
            .ps512 => "PS512",
            .es256 => "ES256",
            .es256k => "ES256K",
            .es384 => "ES384",
            .es512 => "ES512",
        };
    }

    pub fn digestLength(self: SignatureAlgorithm) usize {
        return switch (self) {
            .rs256, .ps256, .es256, .es256k => 32,
            .rs384, .ps384, .es384 => 48,
            .rs512, .ps512, .es512 => 64,
        };
    }
};

pub const Tag = struct {
    name: []const u8,
    value: []const u8,
};

pub const RetryOptions = pipeline_mod.RetryOptions;

pub const KeyClientOptions = struct {
    retry: RetryOptions = .{},
    scope: []const u8 = default_scope,
    /// Borrowed tracing configuration; disabled by default. See PipelineState.
    instrumentation: ?core.tracing.InstrumentationOptions = null,
};

pub const CryptographyClientOptions = struct {
    retry: RetryOptions = .{},
    scope: []const u8 = default_scope,
    /// Borrowed tracing configuration; disabled by default. See PipelineState.
    instrumentation: ?core.tracing.InstrumentationOptions = null,
};

pub const CreateRsaKeyOptions = struct {
    key_type: KeyType = .rsa,
    key_size: u16 = 3072,
    operations: []const KeyOperation = &.{ .sign, .verify },
    enabled: bool = true,
    exportable: bool = false,
    tags: []const Tag = &.{},
};

pub const KeyProperties = struct {
    enabled: ?bool = null,
    not_before: ?i64 = null,
    expires_on: ?i64 = null,
    created_on: ?i64 = null,
    updated_on: ?i64 = null,
    exportable: ?bool = null,
    recovery_level: ?[]u8 = null,

    fn deinit(self: *KeyProperties, allocator: std.mem.Allocator) void {
        if (self.recovery_level) |value| allocator.free(value);
        self.recovery_level = null;
    }
};

pub const KeyReleasePolicy = struct {
    content_type: ?[]u8 = null,
    data: ?[]u8 = null,
    immutable: ?bool = null,

    fn deinit(self: *KeyReleasePolicy, allocator: std.mem.Allocator) void {
        if (self.content_type) |value| allocator.free(value);
        if (self.data) |value| allocator.free(value);
        self.content_type = null;
        self.data = null;
    }
};

pub const OwnedTag = struct {
    name: []u8,
    value: []u8,
};

pub const KeyVaultKey = struct {
    id: []u8,
    name: []u8,
    version: ?[]u8,
    key_type: ?KeyType,
    operations: []KeyOperation,
    modulus: ?[]u8,
    exponent: ?[]u8,
    properties: KeyProperties,
    tags: []OwnedTag,
    managed: ?bool,
    release_policy: ?KeyReleasePolicy,

    pub fn deinit(self: *KeyVaultKey, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.version) |value| allocator.free(value);
        allocator.free(self.operations);
        if (self.modulus) |value| allocator.free(value);
        if (self.exponent) |value| allocator.free(value);
        self.properties.deinit(allocator);
        for (self.tags) |tag| {
            allocator.free(tag.name);
            allocator.free(tag.value);
        }
        allocator.free(self.tags);
        if (self.release_policy) |*policy| policy.deinit(allocator);
        self.* = undefined;
    }

    pub fn hasOperation(self: KeyVaultKey, operation: KeyOperation) bool {
        return std.mem.indexOfScalar(KeyOperation, self.operations, operation) != null;
    }

    pub fn tagValue(self: KeyVaultKey, name: []const u8) ?[]const u8 {
        for (self.tags) |tag| {
            if (std.mem.eql(u8, tag.name, name)) return tag.value;
        }
        return null;
    }

    /// Reject Key Vault key states that are unsafe for a non-exportable SSH CA.
    pub fn validateSshCertificateAuthority(self: KeyVaultKey) !void {
        const key_type = self.key_type orelse return error.MissingKeyType;
        if (key_type != .rsa and key_type != .rsa_hsm) return error.KeyMustBeRsa;
        if (self.properties.enabled != true) return error.KeyMustBeEnabled;
        if (self.properties.exportable == true) return error.KeyMustNotBeExportable;
        if (self.release_policy != null) return error.KeyMustNotHaveReleasePolicy;
        if (self.hasOperation(.export_key)) return error.KeyMustNotAllowExport;
        if (!self.hasOperation(.sign)) return error.KeyMustAllowSign;
        if (!self.hasOperation(.verify)) return error.KeyMustAllowVerify;
        if (self.modulus == null or self.exponent == null) return error.KeyMustHaveRsaPublicMaterial;
        const modulus = self.modulus.?;
        if ((modulus.len != 256 and modulus.len != 384 and modulus.len != 512) or
            modulus[0] & 0x80 == 0)
        {
            return error.UnsupportedRsaKeySize;
        }
        if (self.version == null) return error.KeyMustHaveExplicitVersion;
    }
};

pub const Signature = struct {
    key_id: ?[]u8,
    bytes: []u8,

    pub fn deinit(self: *Signature, allocator: std.mem.Allocator) void {
        if (self.key_id) |value| allocator.free(value);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Client for Key Vault key management operations.
///
/// Runtime descriptors are copied by value. Their borrowed transport and
/// crypto contexts and the credential must outlive this client, all derived
/// cryptography clients and pagers, and every in-flight call. Derived clients
/// and pagers must be deinitialized before this client. The caller must
/// serialize every operation sharing this client's pipeline state, including
/// operations from derived clients and pagers.
pub const KeyClient = struct {
    vault_url: []u8,
    pipeline_state: *pipeline_mod.PipelineState,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        vault_url: []const u8,
        credential: *TokenCredential,
        runtime: core.http.HttpRuntime,
        options: KeyClientOptions,
    ) !KeyClient {
        const normalized_url = std.mem.trimEnd(u8, vault_url, "/");
        try validateVaultUrl(normalized_url);
        const owned_url = try allocator.dupe(u8, normalized_url);
        errdefer allocator.free(owned_url);
        const pipeline_state = try pipeline_mod.PipelineState.create(
            allocator,
            credential,
            runtime,
            options.retry,
            options.scope,
        );
        pipeline_state.setInstrumentation(options.instrumentation);
        return .{
            .vault_url = owned_url,
            .pipeline_state = pipeline_state,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KeyClient) void {
        self.allocator.free(self.vault_url);
        self.pipeline_state.deinit();
        self.* = undefined;
    }

    fn pipeline(self: *KeyClient) HttpPipeline {
        return self.pipeline_state.pipeline;
    }

    /// Creates a cryptography client that borrows this client's authenticated
    /// pipeline state. The returned client must not outlive this `KeyClient`.
    pub fn getCryptographyClient(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        key_id: []const u8,
    ) !CryptographyClient {
        try validateContinuationUrl(self.vault_url, key_id);
        return CryptographyClient.initBorrowed(
            allocator,
            key_id,
            self.pipeline_state,
        );
    }

    pub fn createRsaKey(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        options: CreateRsaKeyOptions,
    ) !KeyVaultKey {
        var result = try self.createRsaKeyResult(allocator, name, options);
        return result.unwrap(error.CreateKeyFailed);
    }

    pub fn createRsaKeyResult(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        options: CreateRsaKeyOptions,
    ) !Result(KeyVaultKey) {
        try validateKeyName(name);
        if (options.key_type != .rsa and options.key_type != .rsa_hsm)
            return error.KeyTypeMustBeRsa;
        if (options.key_size != 2048 and options.key_size != 3072 and options.key_size != 4096)
            return error.InvalidRsaKeySize;
        if (!options.enabled) return error.DisabledKeyNotAllowed;
        if (options.exportable) return error.ExportableKeyNotAllowed;
        try validateCaOperations(options.operations);
        try validateTags(options.tags);

        const operation_values = try allocator.alloc([]const u8, options.operations.len);
        defer allocator.free(operation_values);
        for (options.operations, 0..) |operation, index| {
            operation_values[index] = operation.wireValue();
        }

        const body = try serde.json.toSlice(allocator, CreateKeyRequest{
            .kty = options.key_type.wireValue(),
            .key_size = options.key_size,
            .key_ops = operation_values,
            .attributes = .{
                .enabled = options.enabled,
                .exportable = options.exportable,
            },
            .tags = .{ .values = options.tags },
        });
        defer allocator.free(body);

        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/keys/{s}/create?api-version={s}",
            .{ self.vault_url, name, api_version },
        );
        defer allocator.free(url);

        var req = Request.init(allocator, .POST, url);
        defer req.deinit();
        req.retryable = false;
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        req.body = body;

        var http_pipeline = self.pipeline();
        var response = try http_pipeline.send(&req);
        defer response.deinit();
        if (core.errors.errorFromResponse(allocator, response)) |azure_error|
            return .{ .err = azure_error };
        return .{ .ok = try parseKeyResponse(allocator, response.body) };
    }

    /// Compatibility wrapper for the previous string-based API.
    pub fn createKey(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        key_type: []const u8,
    ) !KeyVaultKey {
        return self.createRsaKey(allocator, name, .{
            .key_type = try KeyType.parse(key_type),
        });
    }

    pub fn getKey(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !KeyVaultKey {
        var result = try self.getKeyResult(allocator, name);
        return result.unwrap(error.GetKeyFailed);
    }

    pub fn getKeyResult(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !Result(KeyVaultKey) {
        try validateKeyName(name);
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/keys/{s}?api-version={s}",
            .{ self.vault_url, name, api_version },
        );
        defer allocator.free(url);
        return self.getAtUrl(allocator, url);
    }

    pub fn getKeyVersion(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
    ) !KeyVaultKey {
        var result = try self.getKeyVersionResult(allocator, name, version);
        return result.unwrap(error.GetKeyFailed);
    }

    pub fn getKeyVersionResult(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
    ) !Result(KeyVaultKey) {
        try validateKeyName(name);
        try validatePathSegment(version);
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/keys/{s}/{s}?api-version={s}",
            .{ self.vault_url, name, version, api_version },
        );
        defer allocator.free(url);
        return self.getAtUrl(allocator, url);
    }

    fn getAtUrl(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        url: []const u8,
    ) !Result(KeyVaultKey) {
        var req = Request.init(allocator, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var http_pipeline = self.pipeline();
        var response = try http_pipeline.send(&req);
        defer response.deinit();
        if (core.errors.errorFromResponse(allocator, response)) |azure_error|
            return .{ .err = azure_error };
        return .{ .ok = try parseKeyResponse(allocator, response.body) };
    }

    pub fn deleteKey(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !void {
        var result = try self.deleteKeyResult(allocator, name);
        _ = try result.unwrap(error.DeleteKeyFailed);
    }

    pub fn deleteKeyResult(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !Result(void) {
        try validateKeyName(name);
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/keys/{s}?api-version={s}",
            .{ self.vault_url, name, api_version },
        );
        defer allocator.free(url);

        var req = Request.init(allocator, .DELETE, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");
        var http_pipeline = self.pipeline();
        var response = try http_pipeline.send(&req);
        defer response.deinit();
        if (core.errors.errorFromResponse(allocator, response)) |azure_error|
            return .{ .err = azure_error };
        return .{ .ok = {} };
    }

    pub fn listKeys(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        max_results: ?u32,
    ) !KeyPager {
        const url = if (max_results) |count|
            try std.fmt.allocPrint(
                allocator,
                "{s}/keys?maxresults={d}&api-version={s}",
                .{ self.vault_url, count, api_version },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}/keys?api-version={s}",
                .{ self.vault_url, api_version },
            );
        defer allocator.free(url);
        return KeyPager.init(self.pipeline(), url, self.vault_url, allocator);
    }

    pub fn listKeyVersions(
        self: *KeyClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        max_results: ?u32,
    ) !KeyPager {
        try validateKeyName(name);
        const url = if (max_results) |count|
            try std.fmt.allocPrint(
                allocator,
                "{s}/keys/{s}/versions?maxresults={d}&api-version={s}",
                .{ self.vault_url, name, count, api_version },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}/keys/{s}/versions?api-version={s}",
                .{ self.vault_url, name, api_version },
            );
        defer allocator.free(url);
        return KeyPager.init(self.pipeline(), url, self.vault_url, allocator);
    }
};

/// Client for Key Vault service-side cryptography payload operations.
///
/// These operations send caller-provided digests to Key Vault; they do not
/// perform local hashing and are independent of transport TLS. The selected
/// runtime crypto provider remains available to pipeline policies and
/// credentials. A directly initialized client owns its pipeline state; a
/// client returned by `KeyClient.getCryptographyClient` borrows that state and
/// must be deinitialized before its parent. The caller must serialize its
/// operations with every other operation sharing the same pipeline state.
pub const CryptographyClient = struct {
    key_id: []u8,
    pipeline_state: *pipeline_mod.PipelineState,
    owns_pipeline_state: bool,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        key_id: []const u8,
        credential: *TokenCredential,
        runtime: core.http.HttpRuntime,
        options: CryptographyClientOptions,
    ) !CryptographyClient {
        const parsed_key_id = try parseKeyId(key_id);
        if (parsed_key_id.version == null) return error.VersionedKeyIdRequired;
        const owned_key_id = try allocator.dupe(u8, key_id);
        errdefer allocator.free(owned_key_id);
        const pipeline_state = try pipeline_mod.PipelineState.create(
            allocator,
            credential,
            runtime,
            options.retry,
            options.scope,
        );
        pipeline_state.setInstrumentation(options.instrumentation);
        return .{
            .key_id = owned_key_id,
            .pipeline_state = pipeline_state,
            .owns_pipeline_state = true,
            .allocator = allocator,
        };
    }

    fn initBorrowed(
        allocator: std.mem.Allocator,
        key_id: []const u8,
        pipeline_state: *pipeline_mod.PipelineState,
    ) !CryptographyClient {
        const parsed_key_id = try parseKeyId(key_id);
        if (parsed_key_id.version == null) return error.VersionedKeyIdRequired;
        return .{
            .key_id = try allocator.dupe(u8, key_id),
            .pipeline_state = pipeline_state,
            .owns_pipeline_state = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CryptographyClient) void {
        self.allocator.free(self.key_id);
        if (self.owns_pipeline_state) self.pipeline_state.deinit();
        self.* = undefined;
    }

    fn pipeline(self: *CryptographyClient) HttpPipeline {
        return self.pipeline_state.pipeline;
    }

    pub fn sign(
        self: *CryptographyClient,
        allocator: std.mem.Allocator,
        algorithm: SignatureAlgorithm,
        digest: []const u8,
    ) !Signature {
        var result = try self.signResult(allocator, algorithm, digest);
        return result.unwrap(error.SignFailed);
    }

    pub fn signResult(
        self: *CryptographyClient,
        allocator: std.mem.Allocator,
        algorithm: SignatureAlgorithm,
        digest: []const u8,
    ) !Result(Signature) {
        if (digest.len != algorithm.digestLength()) return error.InvalidDigestLength;
        const encoded_digest = try core.base64.urlEncode(allocator, digest);
        defer allocator.free(encoded_digest);
        const body = try serde.json.toSlice(allocator, CryptoRequest{
            .alg = algorithm.wireValue(),
            .value = encoded_digest,
        });
        defer allocator.free(body);

        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/sign?api-version={s}",
            .{ self.key_id, api_version },
        );
        defer allocator.free(url);
        var req = Request.init(allocator, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        req.body = body;

        var http_pipeline = self.pipeline();
        var response = try http_pipeline.send(&req);
        defer response.deinit();
        if (core.errors.errorFromResponse(allocator, response)) |azure_error|
            return .{ .err = azure_error };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = serde.json.fromSlice(CryptoResponse, arena.allocator(), response.body) catch
            return error.InvalidCryptoResponse;
        const encoded_signature = parsed.value orelse return error.MissingCryptoResult;
        if (parsed.kid) |kid| {
            if (!std.mem.eql(u8, kid, self.key_id)) return error.SignatureKeyIdMismatch;
        }
        const owned_key_id = if (parsed.kid) |kid| try allocator.dupe(u8, kid) else null;
        errdefer if (owned_key_id) |kid| allocator.free(kid);
        return .{ .ok = .{
            .key_id = owned_key_id,
            .bytes = try core.base64.urlDecode(allocator, encoded_signature),
        } };
    }
};

pub const KeyPager = struct {
    inner: core.pager.PipelinePager(KeyVaultKey),
    vault_url: []u8,
    allocator: std.mem.Allocator,

    /// Copies the pipeline runtime descriptors and borrows their backend and
    /// policy contexts. The originating client must outlive this pager.
    fn init(
        pipeline: HttpPipeline,
        initial_url: []const u8,
        vault_url: []const u8,
        allocator: std.mem.Allocator,
    ) !KeyPager {
        var inner = try core.pager.PipelinePager(KeyVaultKey).init(
            pipeline,
            initial_url,
            allocator,
            parseKeyListPage,
            "application/json",
        );
        errdefer inner.deinit();
        return .{
            .inner = inner,
            .vault_url = try allocator.dupe(u8, vault_url),
            .allocator = allocator,
        };
    }

    pub fn next(self: *KeyPager) !?[]KeyVaultKey {
        const items = (try self.inner.next()) orelse return null;
        if (self.inner.next_url) |next_url| {
            validateContinuationUrl(self.vault_url, next_url) catch |err| {
                self.allocator.free(next_url);
                self.inner.next_url = null;
                for (items) |*key| key.deinit(self.allocator);
                self.allocator.free(items);
                return err;
            };
        }
        return items;
    }

    pub fn deinit(self: *KeyPager) void {
        self.inner.deinit();
        self.allocator.free(self.vault_url);
        self.* = undefined;
    }
};

const CreateKeyRequest = struct {
    kty: []const u8,
    key_size: u16,
    key_ops: []const []const u8,
    attributes: CreateKeyAttributes,
    tags: TagsObject,
};

const CreateKeyAttributes = struct {
    enabled: bool,
    exportable: bool,
};

const TagsObject = struct {
    values: []const Tag,

    pub fn zerdeSerialize(
        self: TagsObject,
        serializer: anytype,
    ) @TypeOf(serializer.*).Error!void {
        var object = try serializer.beginStruct();
        for (self.values) |tag| {
            try object.serializeEntry(tag.name, tag.value);
        }
        try object.end();
    }
};

const CryptoRequest = struct {
    alg: []const u8,
    value: []const u8,
};

const CryptoResponse = struct {
    kid: ?[]const u8 = null,
    value: ?[]const u8 = null,
};

const KeyMaterialSchema = struct {
    kid: ?[]const u8 = null,
    kty: ?[]const u8 = null,
    key_ops: ?[]const []const u8 = null,
    n: ?[]const u8 = null,
    e: ?[]const u8 = null,
};

const KeyAttributesSchema = struct {
    enabled: ?bool = null,
    nbf: ?i64 = null,
    exp: ?i64 = null,
    created: ?i64 = null,
    updated: ?i64 = null,
    exportable: ?bool = null,
    recoveryLevel: ?[]const u8 = null,
};

const KeyReleasePolicySchema = struct {
    contentType: ?[]const u8 = null,
    data: ?[]const u8 = null,
    immutable: ?bool = null,
};

const KeyResponseSchema = struct {
    key: ?KeyMaterialSchema = null,
    attributes: ?KeyAttributesSchema = null,
    tags: ?std.StringHashMap([]const u8) = null,
    managed: ?bool = null,
    release_policy: ?KeyReleasePolicySchema = null,
};

const KeyItemSchema = struct {
    kid: ?[]const u8 = null,
    attributes: ?KeyAttributesSchema = null,
    tags: ?std.StringHashMap([]const u8) = null,
    managed: ?bool = null,
};

const KeyListSchema = struct {
    value: ?[]KeyItemSchema = null,
    nextLink: ?[]const u8 = null,
};

const ParsedKeyId = struct {
    name: []const u8,
    version: ?[]const u8,
};

fn parseKeyId(key_id: []const u8) !ParsedKeyId {
    if (!std.mem.startsWith(u8, key_id, "https://")) return error.InvalidKeyId;
    if (std.mem.indexOfAny(u8, key_id, "?#") != null) return error.InvalidKeyId;
    const marker = "/keys/";
    const marker_index = std.mem.indexOf(u8, key_id, marker) orelse return error.InvalidKeyId;
    const suffix = key_id[marker_index + marker.len ..];
    var parts = std.mem.splitScalar(u8, suffix, '/');
    const name = parts.next() orelse return error.InvalidKeyId;
    validateKeyName(name) catch return error.InvalidKeyId;
    const version = parts.next();
    if (version) |value| {
        validatePathSegment(value) catch return error.InvalidKeyId;
        if (parts.next() != null) return error.InvalidKeyId;
    }
    return .{ .name = name, .version = version };
}

fn parseKeyResponse(allocator: std.mem.Allocator, body: []const u8) !KeyVaultKey {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = serde.json.fromSlice(KeyResponseSchema, arena.allocator(), body) catch
        return error.InvalidKeyResponse;
    const material = parsed.key orelse return error.MissingKeyMaterial;
    const key_id = material.kid orelse return error.MissingKeyId;
    const id_parts = try parseKeyId(key_id);
    return buildOwnedKey(
        allocator,
        key_id,
        id_parts,
        material.kty,
        material.key_ops,
        material.n,
        material.e,
        parsed.attributes,
        parsed.tags,
        parsed.managed,
        parsed.release_policy,
    );
}

fn buildOwnedKey(
    allocator: std.mem.Allocator,
    key_id: []const u8,
    id_parts: ParsedKeyId,
    key_type: ?[]const u8,
    operations: ?[]const []const u8,
    modulus: ?[]const u8,
    exponent: ?[]const u8,
    attributes: ?KeyAttributesSchema,
    tags: ?std.StringHashMap([]const u8),
    managed: ?bool,
    release_policy: ?KeyReleasePolicySchema,
) !KeyVaultKey {
    const owned_id = try allocator.dupe(u8, key_id);
    errdefer allocator.free(owned_id);
    const owned_name = try allocator.dupe(u8, id_parts.name);
    errdefer allocator.free(owned_name);
    const owned_version = if (id_parts.version) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_version) |value| allocator.free(value);

    var key = KeyVaultKey{
        .id = owned_id,
        .name = owned_name,
        .version = owned_version,
        .key_type = if (key_type) |value| try KeyType.parse(value) else null,
        .operations = undefined,
        .modulus = null,
        .exponent = null,
        .properties = .{},
        .tags = undefined,
        .managed = managed,
        .release_policy = null,
    };

    const operation_values = operations orelse &.{};
    key.operations = try allocator.alloc(KeyOperation, operation_values.len);
    errdefer allocator.free(key.operations);
    for (operation_values, 0..) |operation, index| {
        key.operations[index] = try KeyOperation.parse(operation);
    }

    if (modulus) |value| key.modulus = try core.base64.urlDecode(allocator, value);
    errdefer if (key.modulus) |value| allocator.free(value);
    if (exponent) |value| key.exponent = try core.base64.urlDecode(allocator, value);
    errdefer if (key.exponent) |value| allocator.free(value);

    if (attributes) |value| {
        key.properties = .{
            .enabled = value.enabled,
            .not_before = value.nbf,
            .expires_on = value.exp,
            .created_on = value.created,
            .updated_on = value.updated,
            .exportable = value.exportable,
            .recovery_level = if (value.recoveryLevel) |level|
                try allocator.dupe(u8, level)
            else
                null,
        };
    }
    errdefer key.properties.deinit(allocator);

    key.tags = try copyTags(allocator, tags);
    errdefer {
        for (key.tags) |tag| {
            allocator.free(tag.name);
            allocator.free(tag.value);
        }
        allocator.free(key.tags);
    }

    if (release_policy) |value| {
        const content_type = if (value.contentType) |content_type|
            try allocator.dupe(u8, content_type)
        else
            null;
        errdefer if (content_type) |owned| allocator.free(owned);
        const data = if (value.data) |data|
            try allocator.dupe(u8, data)
        else
            null;
        errdefer if (data) |owned| allocator.free(owned);
        key.release_policy = .{
            .content_type = content_type,
            .data = data,
            .immutable = value.immutable,
        };
    }
    errdefer if (key.release_policy) |*policy| policy.deinit(allocator);
    return key;
}

fn copyTags(
    allocator: std.mem.Allocator,
    tags: ?std.StringHashMap([]const u8),
) ![]OwnedTag {
    const source = tags orelse return allocator.alloc(OwnedTag, 0);
    const result = try allocator.alloc(OwnedTag, source.count());
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |tag| {
            allocator.free(tag.name);
            allocator.free(tag.value);
        }
    }
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry.value_ptr.*);
        result[initialized] = .{
            .name = name,
            .value = value,
        };
        initialized += 1;
    }
    return result;
}

fn parseKeyListPage(
    allocator: std.mem.Allocator,
    body: []const u8,
) !core.pager.PageResult(KeyVaultKey) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = serde.json.fromSlice(KeyListSchema, arena.allocator(), body) catch
        return error.InvalidKeyListResponse;
    const items = parsed.value orelse &.{};
    const owned = try allocator.alloc(KeyVaultKey, items.len);
    errdefer allocator.free(owned);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |*key| key.deinit(allocator);
    }
    for (items, 0..) |item, index| {
        const key_id = item.kid orelse return error.MissingKeyId;
        owned[index] = try buildOwnedKey(
            allocator,
            key_id,
            try parseKeyId(key_id),
            null,
            null,
            null,
            null,
            item.attributes,
            item.tags,
            item.managed,
            null,
        );
        initialized += 1;
    }
    return .{
        .items = owned,
        .next_link = if (parsed.nextLink) |value|
            try allocator.dupe(u8, value)
        else
            null,
    };
}

fn hasOperation(operations: []const KeyOperation, expected: KeyOperation) bool {
    return std.mem.indexOfScalar(KeyOperation, operations, expected) != null;
}

fn validateCaOperations(operations: []const KeyOperation) !void {
    if (operations.len != 2) return error.OnlySignAndVerifyOperationsAllowed;
    if (!hasOperation(operations, .sign) or !hasOperation(operations, .verify))
        return error.SignAndVerifyOperationsRequired;
    if (operations[0] == operations[1]) return error.DuplicateKeyOperation;
}

fn validateKeyName(name: []const u8) !void {
    if (name.len == 0 or name.len > 127) return error.InvalidKeyName;
    for (name) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-')
            return error.InvalidKeyName;
    }
}

fn validateVaultUrl(vault_url: []const u8) !void {
    const uri = std.Uri.parse(vault_url) catch return error.InvalidVaultUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or
        uri.host == null or
        uri.user != null or
        uri.password != null or
        !uri.path.isEmpty() or
        uri.query != null or
        uri.fragment != null)
    {
        return error.InvalidVaultUrl;
    }
}

fn validateContinuationUrl(vault_url: []const u8, next_url: []const u8) !void {
    return pipeline_mod.validateHttpsOrigin(vault_url, next_url);
}

fn validatePathSegment(value: []const u8) !void {
    if (value.len == 0) return error.InvalidPathSegment;
    for (value) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-')
            return error.InvalidPathSegment;
    }
}

fn validateTags(tags: []const Tag) !void {
    for (tags, 0..) |tag, index| {
        if (tag.name.len == 0) return error.EmptyTagName;
        for (tags[index + 1 ..]) |other| {
            if (std.mem.eql(u8, tag.name, other.name)) return error.DuplicateTagName;
        }
    }
}

test "typed key values map to Key Vault wire values" {
    try std.testing.expectEqualStrings("RSA", KeyType.rsa.wireValue());
    try std.testing.expectEqualStrings("sign", KeyOperation.sign.wireValue());
    try std.testing.expectEqualStrings("RS512", SignatureAlgorithm.rs512.wireValue());
    try std.testing.expectEqual(@as(usize, 64), SignatureAlgorithm.rs512.digestLength());
}

test "create RSA key authenticates, escapes JSON, and disables retries" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(allocator, 200, key_response);
    defer service_mock.deinit();
    var client = try KeyClient.init(
        allocator,
        "https://vault.example/",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{ .scope = "https://vault.usgovcloudapi.net/.default" },
    );
    defer client.deinit();

    var key = try client.createRsaKey(allocator, "ssh-ca", .{
        .tags = &.{.{ .name = "operation-id", .value = "quoted \"value\"" }},
    });
    defer key.deinit(allocator);

    try std.testing.expectEqualStrings(
        "https://vault.example/keys/ssh-ca/create?api-version=2025-07-01",
        service_mock.last_url.?,
    );
    try std.testing.expectEqualStrings(
        "https://vault.usgovcloudapi.net/.default",
        credential.last_scope.?,
    );
    try std.testing.expectEqualStrings("Bearer test-token", service_mock.last_headers.get("Authorization").?);
    try std.testing.expectEqualStrings(
        "{\"kty\":\"RSA\",\"key_size\":3072,\"key_ops\":[\"sign\",\"verify\"],\"attributes\":{\"enabled\":true,\"exportable\":false},\"tags\":{\"operation-id\":\"quoted \\\"value\\\"\"}}",
        service_mock.last_body.?,
    );
    try std.testing.expect(!service_mock.last_retryable.?);
    try std.testing.expectEqualStrings("version1", key.version.?);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, key.modulus.?);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x01 }, key.exponent.?);
    try std.testing.expectEqualStrings("quoted \"value\"", key.tagValue("operation-id").?);
    try std.testing.expectError(error.UnsupportedRsaKeySize, key.validateSshCertificateAuthority());
    allocator.free(key.modulus.?);
    const modulus = try allocator.alloc(u8, 384);
    @memset(modulus, 0);
    modulus[0] = 0x80;
    key.modulus = modulus;
    try key.validateSshCertificateAuthority();
}

test "version-aware get and version listing preserve tags" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(allocator, 200, key_response);
    defer service_mock.deinit();
    var client = try KeyClient.init(
        allocator,
        "https://vault.example",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{},
    );
    defer client.deinit();

    var key = try client.getKeyVersion(allocator, "ssh-ca", "version1");
    defer key.deinit(allocator);
    try std.testing.expectEqualStrings(
        "https://vault.example/keys/ssh-ca/version1?api-version=2025-07-01",
        service_mock.last_url.?,
    );

    service_mock.response_status = 200;
    service_mock.response_body = key_list_response;
    var pager = try client.listKeyVersions(allocator, "ssh-ca", null);
    defer pager.deinit();
    const page = (try pager.next()).?;
    defer {
        for (page) |*item| item.deinit(allocator);
        allocator.free(page);
    }
    try std.testing.expectEqual(@as(usize, 1), page.len);
    try std.testing.expectEqualStrings("operation-123", page[0].tagValue("operation-id").?);
    try std.testing.expectEqualStrings(
        "https://vault.example/keys/ssh-ca/versions?api-version=2025-07-01",
        service_mock.last_url.?,
    );
}

test "RS512 signing uses exact digest and returns decoded signature bytes" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(
        allocator,
        200,
        "{\"kid\":\"https://vault.example/keys/ssh-ca/version1\",\"value\":\"-__-\"}",
    );
    defer service_mock.deinit();
    var probe = test_support.TracingProbe{};
    var tracing = try probe.createProvider();
    defer tracing.deinit() catch unreachable;
    var client = try CryptographyClient.init(
        allocator,
        "https://vault.example/keys/ssh-ca/version1",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{ .instrumentation = test_support.TracingProbe.options(&tracing) },
    );
    defer client.deinit();

    const digest = [_]u8{0} ** 64;
    var signature = try client.sign(allocator, .rs512, &digest);
    defer signature.deinit(allocator);
    try probe.expectSingleSpan(&tracing, &service_mock);
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff, 0xfe }, signature.bytes);
    try std.testing.expectEqualStrings("Bearer test-token", service_mock.last_headers.get("Authorization").?);
    try std.testing.expectEqualStrings(
        "{\"alg\":\"RS512\",\"value\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}",
        service_mock.last_body.?,
    );
    try std.testing.expect(service_mock.last_retryable.?);

    try std.testing.expectError(error.InvalidDigestLength, client.sign(allocator, .rs512, digest[0..63]));
}

test "Key Vault service errors remain structured" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(
        allocator,
        403,
        "{\"error\":{\"code\":\"Forbidden\",\"message\":\"Access denied\"}}",
    );
    defer service_mock.deinit();
    var client = try CryptographyClient.init(
        allocator,
        "https://vault.example/keys/ssh-ca/version1",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{ .retry = .{ .max_retries = 0 } },
    );
    defer client.deinit();

    const digest = [_]u8{0} ** 64;
    const cases = [_]struct {
        status: u16,
        code: []const u8,
        body: []const u8,
    }{
        .{
            .status = 403,
            .code = "Forbidden",
            .body = "{\"error\":{\"code\":\"Forbidden\",\"message\":\"Access denied\"}}",
        },
        .{
            .status = 404,
            .code = "KeyNotFound",
            .body = "{\"error\":{\"code\":\"KeyNotFound\",\"message\":\"Missing key\"}}",
        },
        .{
            .status = 429,
            .code = "Throttled",
            .body = "{\"error\":{\"code\":\"Throttled\",\"message\":\"Retry later\"}}",
        },
        .{
            .status = 400,
            .code = "BadParameter",
            .body = "{\"error\":{\"code\":\"BadParameter\",\"message\":\"Invalid algorithm\"}}",
        },
    };
    for (cases) |case| {
        service_mock.response_status = case.status;
        service_mock.response_body = case.body;
        var result = try client.signResult(allocator, .rs512, &digest);
        defer result.deinit(allocator);
        switch (result) {
            .ok => return error.ExpectedAzureError,
            .err => |azure_error| {
                try std.testing.expectEqual(case.status, azure_error.status_code);
                try std.testing.expectEqualStrings(case.code, azure_error.error_code.?);
            },
        }
    }
}

test "get retries transient responses but create does not" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.SequenceMockTransport.init(allocator, &.{
        .{ .status = 500, .body = "{}" },
        .{ .status = 200, .body = key_response },
    });
    var client = try KeyClient.init(
        allocator,
        "https://vault.example",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{ .retry = .{ .initial_delay_ms = 0 } },
    );
    defer client.deinit();

    var key = try client.getKey(allocator, "ssh-ca");
    key.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), service_mock.call_count);

    service_mock.call_count = 0;
    var create_result = try client.createRsaKeyResult(allocator, "ssh-ca", .{});
    defer create_result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), service_mock.call_count);
    try std.testing.expect(!create_result.isOk());
}

test "SSH CA validation rejects release policies and exportability" {
    const allocator = std.testing.allocator;
    var key = try parseKeyResponse(allocator, unsafe_key_response);
    defer key.deinit(allocator);
    try std.testing.expectError(error.KeyMustNotBeExportable, key.validateSshCertificateAuthority());
    key.properties.exportable = false;
    try std.testing.expectError(error.KeyMustNotHaveReleasePolicy, key.validateSshCertificateAuthority());
}

test "unsafe SSH CA create options fail before the network call" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(allocator, 200, key_response);
    defer service_mock.deinit();
    var client = try KeyClient.init(
        allocator,
        "https://vault.example",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{},
    );
    defer client.deinit();

    try std.testing.expectError(
        error.DisabledKeyNotAllowed,
        client.createRsaKey(allocator, "ssh-ca", .{ .enabled = false }),
    );
    try std.testing.expectError(
        error.ExportableKeyNotAllowed,
        client.createRsaKey(allocator, "ssh-ca", .{ .exportable = true }),
    );
    try std.testing.expectError(
        error.InvalidRsaKeySize,
        client.createRsaKey(allocator, "ssh-ca", .{ .key_size = 2056 }),
    );
    try std.testing.expectError(
        error.OnlySignAndVerifyOperationsAllowed,
        client.createRsaKey(allocator, "ssh-ca", .{
            .operations = &.{ .sign, .verify, .encrypt },
        }),
    );
    try std.testing.expect(service_mock.last_url == null);
    try std.testing.expectEqual(@as(usize, 0), credential.calls);
}

test "KeyClient requires an HTTPS vault origin" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(allocator, 200, key_response);
    defer service_mock.deinit();

    try std.testing.expectError(
        error.InvalidVaultUrl,
        KeyClient.init(
            allocator,
            "http://vault.example",
            credential.asCredential(),
            test_support.runtime(service_mock.asTransport()),
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidVaultUrl,
        KeyClient.init(
            allocator,
            "https://user@vault.example",
            credential.asCredential(),
            test_support.runtime(service_mock.asTransport()),
            .{},
        ),
    );
}

test "cryptography requires a version and verifies the response key id" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(
        allocator,
        200,
        "{\"kid\":\"https://vault.example/keys/ssh-ca/version2\",\"value\":\"-__-\"}",
    );
    defer service_mock.deinit();

    try std.testing.expectError(
        error.VersionedKeyIdRequired,
        CryptographyClient.init(
            allocator,
            "https://vault.example/keys/ssh-ca",
            credential.asCredential(),
            test_support.runtime(service_mock.asTransport()),
            .{},
        ),
    );

    var client = try CryptographyClient.init(
        allocator,
        "https://vault.example/keys/ssh-ca/version1",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{},
    );
    defer client.deinit();
    const digest = [_]u8{0} ** 64;
    try std.testing.expectError(
        error.SignatureKeyIdMismatch,
        client.sign(allocator, .rs512, &digest),
    );
}

test "sign retries throttling responses" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.SequenceMockTransport.init(allocator, &.{
        .{ .status = 429, .body = "{\"error\":{\"code\":\"Throttled\"}}" },
        .{
            .status = 200,
            .body = "{\"kid\":\"https://vault.example/keys/ssh-ca/version1\",\"value\":\"-__-\"}",
        },
    });
    var client = try CryptographyClient.init(
        allocator,
        "https://vault.example/keys/ssh-ca/version1",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{ .retry = .{ .initial_delay_ms = 0 } },
    );
    defer client.deinit();

    const digest = [_]u8{0} ** 64;
    var signature = try client.sign(allocator, .rs512, &digest);
    defer signature.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), service_mock.call_count);
}

test "key pager rejects cross-origin continuation URLs" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(
        allocator,
        200,
        "{\"value\":[],\"nextLink\":\"https://attacker.example/steal\"}",
    );
    defer service_mock.deinit();
    var client = try KeyClient.init(
        allocator,
        "https://vault.example",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{},
    );
    defer client.deinit();

    var pager = try client.listKeys(allocator, null);
    defer pager.deinit();
    try std.testing.expectError(error.InvalidContinuationUrl, pager.next());
    try std.testing.expectEqualStrings(
        "https://vault.example/keys?api-version=2025-07-01",
        service_mock.last_url.?,
    );
}

test "delete preserves structured Azure errors" {
    const allocator = std.testing.allocator;
    var credential = test_support.StaticCredential{};
    var service_mock = core.http.MockTransport.init(
        allocator,
        404,
        "{\"error\":{\"code\":\"KeyNotFound\",\"message\":\"Missing key\"}}",
    );
    defer service_mock.deinit();
    var client = try KeyClient.init(
        allocator,
        "https://vault.example",
        credential.asCredential(),
        test_support.runtime(service_mock.asTransport()),
        .{},
    );
    defer client.deinit();

    var result = try client.deleteKeyResult(allocator, "ssh-ca");
    defer result.deinit(allocator);
    switch (result) {
        .ok => return error.ExpectedAzureError,
        .err => |azure_error| {
            try std.testing.expectEqual(@as(u16, 404), azure_error.status_code);
            try std.testing.expectEqualStrings("KeyNotFound", azure_error.error_code.?);
        },
    }
}

const CryptoSpy = struct {
    random_calls: usize = 0,
    fail_random: bool = false,

    const vtable: core.crypto.CryptoProvider.VTable = .{
        .random_bytes = &randomBytes,
        .md5 = &md5,
        .sha256 = &sha256,
        .hmac_sha256 = &hmacSha256,
        .sha256_init = &sha256Init,
    };

    fn asProvider(self: *CryptoSpy) core.crypto.CryptoProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    fn randomBytes(context: *anyopaque, out: []u8) !void {
        const self: *CryptoSpy = @ptrCast(@alignCast(context));
        self.random_calls += 1;
        if (self.fail_random) return error.SelectedCryptoFailure;
        @memset(out, 0xa5);
    }

    fn md5(_: *anyopaque, _: []const u8, _: *core.crypto.Md5Digest) !void {
        return error.UnexpectedLocalCryptography;
    }

    fn sha256(_: *anyopaque, _: []const u8, _: *core.crypto.Sha256Digest) !void {
        return error.UnexpectedLocalCryptography;
    }

    fn hmacSha256(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: *core.crypto.HmacSha256Digest,
    ) !void {
        return error.UnexpectedLocalCryptography;
    }

    fn sha256Init(
        _: *anyopaque,
        _: std.mem.Allocator,
    ) !core.crypto.Sha256Operation {
        return error.UnexpectedLocalCryptography;
    }
};

test "derived cryptography client and pager preserve runtime providers" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(
        allocator,
        200,
        "{\"kid\":\"https://vault.example/keys/ssh-ca/version1\",\"value\":\"-__-\"}",
    );
    defer transport.deinit();
    var crypto_spy = CryptoSpy{};
    const runtime = core.http.HttpRuntime.init(
        transport.asTransport(),
        crypto_spy.asProvider(),
    );
    var credential = test_support.StaticCredential{};
    var client = try KeyClient.init(
        allocator,
        "https://vault.example",
        credential.asCredential(),
        runtime,
        .{ .retry = .{ .max_retries = 0 } },
    );
    defer client.deinit();

    var cryptography = try client.getCryptographyClient(
        allocator,
        "https://vault.example/keys/ssh-ca/version1",
    );
    defer cryptography.deinit();
    try std.testing.expect(!cryptography.owns_pipeline_state);
    try std.testing.expectEqual(client.pipeline_state, cryptography.pipeline_state);
    try std.testing.expectEqual(
        runtime.transport.context,
        cryptography.pipeline().runtime.transport.context,
    );
    try std.testing.expectEqual(
        runtime.crypto.context,
        cryptography.pipeline().runtime.crypto.context,
    );

    const digest = [_]u8{0} ** 64;
    var signature = try cryptography.sign(allocator, .rs512, &digest);
    defer signature.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), crypto_spy.random_calls);

    transport.response_body = key_list_response;
    var pager = try client.listKeys(allocator, null);
    defer pager.deinit();
    try std.testing.expectEqual(
        runtime.transport.context,
        pager.inner.pipeline.runtime.transport.context,
    );
    try std.testing.expectEqual(
        runtime.crypto.context,
        pager.inner.pipeline.runtime.crypto.context,
    );
}

test "selected crypto failure prevents derived cryptography transport dispatch" {
    const allocator = std.testing.allocator;
    var transport = core.http.MockTransport.init(
        allocator,
        200,
        "{\"kid\":\"https://vault.example/keys/ssh-ca/version1\",\"value\":\"-__-\"}",
    );
    defer transport.deinit();
    var crypto_spy = CryptoSpy{ .fail_random = true };
    const runtime = core.http.HttpRuntime.init(
        transport.asTransport(),
        crypto_spy.asProvider(),
    );
    var credential = test_support.StaticCredential{};
    var probe = test_support.TracingProbe{};
    var tracing = try probe.createProvider();
    defer tracing.deinit() catch unreachable;
    var client = try KeyClient.init(
        allocator,
        "https://vault.example",
        credential.asCredential(),
        runtime,
        .{
            .retry = .{ .max_retries = 0 },
            .instrumentation = test_support.TracingProbe.options(&tracing),
        },
    );
    defer client.deinit();
    var cryptography = try client.getCryptographyClient(
        allocator,
        "https://vault.example/keys/ssh-ca/version1",
    );
    defer cryptography.deinit();

    var request = Request.init(
        allocator,
        .POST,
        "https://vault.example/keys/ssh-ca/version1/sign?api-version=2025-07-01",
    );
    defer request.deinit();
    try request.setHeader("Authorization", "unchanged");
    var derived_pipeline = cryptography.pipeline();
    try std.testing.expectError(
        error.SelectedCryptoFailure,
        derived_pipeline.send(&request),
    );
    try std.testing.expectEqualStrings(
        "unchanged",
        request.getHeader("Authorization").?,
    );

    const digest = [_]u8{0} ** 64;
    try std.testing.expectError(
        error.SelectedCryptoFailure,
        cryptography.sign(allocator, .rs512, &digest),
    );
    try std.testing.expectEqual(@as(usize, 2), crypto_spy.random_calls);
    try std.testing.expectEqual(@as(usize, 0), credential.calls);
    try std.testing.expectEqual(@as(usize, 0), transport.call_count);
    try tracing.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    for (probe.statuses[0..probe.count]) |status|
        try std.testing.expectEqual(core.tracing.SpanStatus.@"error", status);
}

test "KeyClient tracing survives borrowed cryptography and pager teardown" {
    const allocator = std.testing.allocator;
    var mock = core.http.MockTransport.init(allocator, 200, key_response);
    defer mock.deinit();
    var probe = test_support.TracingProbe{};
    var tracing = try probe.createProvider();
    defer tracing.deinit() catch unreachable;
    var ids: [3][16]u8 = undefined;
    {
        const scope = try allocator.dupe(u8, "caller.keyvault");
        defer allocator.free(scope);
        const state = try allocator.dupe(u8, test_support.TracingProbe.parent.trace_state.?);
        defer allocator.free(state);
        var instrumentation = test_support.TracingProbe.options(&tracing);
        instrumentation.scope_name = scope;
        instrumentation.parent_context.?.trace_state = state;
        var credential = test_support.StaticCredential{};
        var client = try KeyClient.init(
            allocator,
            "https://vault.example",
            credential.asCredential(),
            test_support.runtime(mock.asTransport()),
            .{ .instrumentation = instrumentation },
        );
        defer client.deinit();
        var key = try client.getKeyVersion(allocator, "ssh-ca", "version1");
        defer key.deinit(allocator);
        try std.testing.expectEqualStrings("https://vault.example/keys/ssh-ca/version1", key.id);
        ids[0] = try test_support.TracingProbe.wireId(&mock);

        var cryptography = try client.getCryptographyClient(allocator, key.id);
        defer cryptography.deinit();
        try std.testing.expect(!cryptography.owns_pipeline_state);
        try std.testing.expectEqual(client.pipeline_state, cryptography.pipeline_state);
        mock.response_body = "{\"kid\":\"https://vault.example/keys/ssh-ca/version1\",\"value\":\"-__-\"}";
        const digest = [_]u8{0} ** 64;
        var signature = try cryptography.sign(allocator, .rs512, &digest);
        defer signature.deinit(allocator);
        try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff, 0xfe }, signature.bytes);
        ids[1] = try test_support.TracingProbe.wireId(&mock);

        mock.response_body = key_list_response;
        var pager = try client.listKeys(allocator, null);
        defer pager.deinit();
        const page = (try pager.next()) orelse return error.ExpectedPage;
        defer {
            for (page) |*entry| entry.deinit(allocator);
            allocator.free(page);
        }
        try std.testing.expectEqual(@as(usize, 1), page.len);
        try std.testing.expectEqualStrings("operation-123", page[0].tagValue("operation-id").?);
        ids[2] = try test_support.TracingProbe.wireId(&mock);
        try std.testing.expectEqual(@as(usize, 3), mock.call_count);
        try std.testing.expectEqual(@as(usize, 1), credential.calls);
        try std.testing.expectEqualStrings(default_scope, credential.last_scope.?);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expectEqual(@as(usize, 0), tracing.stats().active_spans);
    try std.testing.expectEqual(@as(usize, 3), tracing.stats().queued_spans);
    try tracing.forceFlush(1000);
    try std.testing.expectEqual(@as(usize, 3), probe.count);
    for (ids, 0..) |id, i| try std.testing.expectEqualStrings(&id, &probe.ids[i]);
    try tracing.shutdown(1000);
}

const key_response =
    \\{"key":{"kid":"https://vault.example/keys/ssh-ca/version1","kty":"RSA","key_ops":["sign","verify"],"n":"gAE","e":"AQAB"},"attributes":{"enabled":true,"exportable":false,"recoveryLevel":"Recoverable+Purgeable"},"tags":{"operation-id":"quoted \"value\""},"managed":false}
;

const key_list_response =
    \\{"value":[{"kid":"https://vault.example/keys/ssh-ca/version1","attributes":{"enabled":true,"exportable":false},"tags":{"operation-id":"operation-123"},"managed":false}]}
;

const unsafe_key_response =
    \\{"key":{"kid":"https://vault.example/keys/ssh-ca/version1","kty":"RSA","key_ops":["sign","verify"],"n":"gAE","e":"AQAB"},"attributes":{"enabled":true,"exportable":true},"release_policy":{"contentType":"application/json","data":"e30","immutable":true}}
;
