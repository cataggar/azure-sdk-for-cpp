//! Stable authenticated pipeline state shared by Key Vault clients.

const std = @import("std");
const core = @import("azure_sdk_core");

pub const default_scope = "https://vault.azure.net/.default";

pub const RetryOptions = struct {
    max_retries: u32 = 3,
    initial_delay_ms: u64 = 800,
    max_delay_ms: u64 = 60_000,
};

/// Heap-owned policy state for a Key Vault client and its derived clients.
///
/// Runtime descriptors are copied by value. Their transport and crypto
/// contexts, the credential, and all policy backend state are borrowed and
/// must outlive the owning client, every derived client and pager, and all
/// in-flight calls. Because Core's bearer-token cache is mutable and
/// unsynchronized, the caller must serialize every operation sharing this
/// state, including operations from derived clients and pagers, regardless of
/// whether the borrowed transport and crypto implementations are synchronized.
pub const PipelineState = struct {
    allocator: std.mem.Allocator,
    scope: []u8,
    scopes: [1][]const u8,
    retry: core.http.RetryPolicy,
    request_id: core.http.RequestIdPolicy,
    auth: core.http.BearerTokenAuthPolicy,
    policies: [3]*core.http.HttpPolicy,
    pipeline: core.http.HttpPipeline,

    /// Creates an uninstrumented pipeline. Client constructors configure
    /// instrumentation before exposing this state to any borrowers.
    pub fn create(
        allocator: std.mem.Allocator,
        credential: *core.credentials.TokenCredential,
        runtime: core.http.HttpRuntime,
        retry_options: RetryOptions,
        scope: []const u8,
    ) !*PipelineState {
        const state = try allocator.create(PipelineState);
        errdefer allocator.destroy(state);
        const owned_scope = try allocator.dupe(u8, scope);
        errdefer allocator.free(owned_scope);

        state.* = .{
            .allocator = allocator,
            .scope = owned_scope,
            .scopes = .{owned_scope},
            .retry = core.http.RetryPolicy.init(),
            .request_id = core.http.RequestIdPolicy.init(),
            .auth = undefined,
            .policies = undefined,
            .pipeline = undefined,
        };
        state.retry.max_retries = retry_options.max_retries;
        state.retry.initial_delay_ms = retry_options.initial_delay_ms;
        state.retry.max_delay_ms = retry_options.max_delay_ms;
        state.auth = core.http.BearerTokenAuthPolicy.init(
            allocator,
            credential,
            &state.scopes,
        );
        state.policies = .{
            state.retry.asPolicy(),
            state.request_id.asPolicy(),
            state.auth.asPolicy(),
        };
        state.pipeline = core.http.HttpPipeline.init(runtime, &state.policies);
        return state;
    }

    /// Configure before creating any derived client or pager. The provider,
    /// scope strings, and parent tracestate remain caller-owned and must
    /// outlive every borrower. This state never flushes or shuts them down.
    pub fn setInstrumentation(
        self: *PipelineState,
        options: ?core.tracing.InstrumentationOptions,
    ) void {
        self.pipeline.setInstrumentation(options);
    }

    pub fn deinit(self: *PipelineState) void {
        const allocator = self.allocator;
        self.auth.deinit();
        allocator.free(self.scope);
        allocator.destroy(self);
    }
};

/// Require an absolute HTTPS continuation URL on the original effective
/// scheme, host, and port. Userinfo and fragments are never accepted.
pub fn validateHttpsOrigin(expected_origin: []const u8, candidate_url: []const u8) !void {
    const expected = std.Uri.parse(expected_origin) catch
        return error.InvalidContinuationUrl;
    const candidate = std.Uri.parse(candidate_url) catch
        return error.InvalidContinuationUrl;
    if (!std.ascii.eqlIgnoreCase(expected.scheme, "https") or
        expected.host == null or
        expected.user != null or
        expected.password != null or
        expected.fragment != null or
        !std.ascii.eqlIgnoreCase(candidate.scheme, "https") or
        candidate.host == null or
        candidate.user != null or
        candidate.password != null or
        candidate.fragment != null)
    {
        return error.InvalidContinuationUrl;
    }

    var expected_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var candidate_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const expected_host = expected.getHost(&expected_host_buffer) catch
        return error.InvalidContinuationUrl;
    const candidate_host = candidate.getHost(&candidate_host_buffer) catch
        return error.InvalidContinuationUrl;
    if (!std.ascii.eqlIgnoreCase(expected_host.bytes, candidate_host.bytes))
        return error.InvalidContinuationUrl;
    if ((expected.port orelse 443) != (candidate.port orelse 443))
        return error.InvalidContinuationUrl;
}

/// Authenticated pager that validates every continuation before retaining it.
pub fn ValidatedPipelinePager(comptime T: type) type {
    return struct {
        pipeline: core.http.HttpPipeline,
        next_url: ?[]u8,
        origin: []u8,
        allocator: std.mem.Allocator,
        accept_header: []const u8,
        pager: core.pager.Pager(T),
        parseFn: *const fn (
            allocator: std.mem.Allocator,
            body: []const u8,
            origin: []const u8,
        ) anyerror!core.pager.PageResult(T),
        deinitItemsFn: *const fn (allocator: std.mem.Allocator, items: []T) void,

        const Self = @This();

        pub fn init(
            pipeline: core.http.HttpPipeline,
            initial_url: []const u8,
            origin: []const u8,
            allocator: std.mem.Allocator,
            parseFn: *const fn (
                std.mem.Allocator,
                []const u8,
                []const u8,
            ) anyerror!core.pager.PageResult(T),
            deinitItemsFn: *const fn (std.mem.Allocator, []T) void,
            accept_header: []const u8,
        ) !Self {
            try validateHttpsOrigin(origin, initial_url);
            const owned_url = try allocator.dupe(u8, initial_url);
            errdefer allocator.free(owned_url);
            return .{
                .pipeline = pipeline,
                .next_url = owned_url,
                .origin = try allocator.dupe(u8, origin),
                .allocator = allocator,
                .accept_header = accept_header,
                .pager = .{ .nextFn = &nextImpl, .deinitFn = &deinitImpl },
                .parseFn = parseFn,
                .deinitItemsFn = deinitItemsFn,
            };
        }

        pub fn asPager(self: *Self) *core.pager.Pager(T) {
            return &self.pager;
        }

        pub fn next(self: *Self) !?[]T {
            return self.asPager().next();
        }

        pub fn deinit(self: *Self) void {
            if (self.next_url) |url| self.allocator.free(url);
            self.next_url = null;
            self.allocator.free(self.origin);
        }

        fn nextImpl(pager_ptr: *core.pager.Pager(T)) anyerror!?[]T {
            const self: *Self = @alignCast(@fieldParentPtr("pager", pager_ptr));
            const url = self.next_url orelse return null;

            var request = core.http.Request.init(self.allocator, .GET, url);
            defer request.deinit();
            try request.setHeader("Accept", self.accept_header);

            var response = try self.pipeline.send(&request);
            defer response.deinit();

            self.allocator.free(url);
            self.next_url = null;

            if (!response.isSuccess()) {
                core.pager.logHttpError(
                    "ValidatedPipelinePager.next",
                    response.status_code,
                    response.body,
                );
                return error.PageFetchFailed;
            }

            const result = self.parseFn(
                self.allocator,
                response.body,
                self.origin,
            ) catch |err| {
                core.pager.logHttpError(
                    "ValidatedPipelinePager.next parse failed",
                    response.status_code,
                    response.body,
                );
                return err;
            };
            if (result.next_link) |next_link| {
                validateHttpsOrigin(self.origin, next_link) catch |err| {
                    self.allocator.free(next_link);
                    self.deinitItemsFn(self.allocator, result.items);
                    return err;
                };
                self.next_url = next_link;
            }
            return result.items;
        }

        fn deinitImpl(pager_ptr: *core.pager.Pager(T)) void {
            const self: *Self = @alignCast(@fieldParentPtr("pager", pager_ptr));
            self.deinit();
        }
    };
}
