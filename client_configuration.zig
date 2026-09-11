const std = @import("std");
const core = @import("azure_sdk_core");
const auth = @import("auth.zig");
const connection_string = @import("connection_string.zig");
const options = @import("options.zig");
const pipeline = @import("pipeline.zig");
const request = @import("request.zig");

/// Construction-only state. A successful client takes `owned_credential`;
/// parsed strings are always released after the client copies its endpoint.
pub const Configuration = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    credential: union(enum) {
        token: *core.credentials.TokenCredential,
        shared_key: *auth.SharedKeyCredential,
        sas,
    },
    parsed: ?connection_string.Parsed = null,
    owned_credential: ?*auth.SharedKeyCredential = null,

    pub fn init(
        allocator: std.mem.Allocator,
        authentication: options.ClientAuthentication,
    ) !Configuration {
        var result: Configuration = .{
            .allocator = allocator,
            .endpoint = undefined,
            .credential = .sas,
        };
        errdefer result.deinit();
        switch (authentication) {
            .token => |value| {
                result.endpoint = value.endpoint;
                result.credential = .{ .token = value.credential };
            },
            .shared_key => |value| {
                result.endpoint = value.endpoint;
                result.credential = .{ .shared_key = value.credential };
            },
            .sas_url => |value| result.endpoint = value,
            .connection_string => |value| {
                result.parsed = try connection_string.parse(allocator, value);
                const parsed = &result.parsed.?;
                result.endpoint = parsed.endpoint;
                if (parsed.account_key) |key| {
                    const credential = try allocator.create(auth.SharedKeyCredential);
                    errdefer allocator.destroy(credential);
                    credential.* = try auth.SharedKeyCredential.init(allocator, parsed.account_name, key);
                    result.owned_credential = credential;
                    result.credential = .{ .shared_key = credential };
                }
            },
        }
        switch (result.credential) {
            .token => try request.validateTokenEndpoint(result.endpoint),
            .shared_key => try request.validateSharedKeyEndpoint(result.endpoint),
            .sas => try request.validateSasEndpoint(result.endpoint),
        }
        return result;
    }

    pub fn createPipeline(
        self: *const Configuration,
        runtime: core.http.HttpRuntime,
        client_options: options.TableClientOptions,
    ) !*pipeline.PipelineState {
        return switch (self.credential) {
            .token => |credential| pipeline.PipelineState.create(self.allocator, credential, runtime, client_options),
            .shared_key => |credential| pipeline.PipelineState.createSharedKey(self.allocator, credential, runtime, client_options),
            .sas => pipeline.PipelineState.createNoAuth(self.allocator, runtime, client_options),
        };
    }

    pub fn deinit(self: *Configuration) void {
        if (self.owned_credential) |credential| {
            credential.deinit();
            self.allocator.destroy(credential);
        }
        if (self.parsed) |*parsed| parsed.deinit();
        self.* = undefined;
    }
};
