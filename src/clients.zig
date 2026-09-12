//! Generated service clients.

const std = @import("std");
const serde = @import("serde");
const core = @import("azure_sdk_core");
const models = @import("models.zig");
const enums = @import("enums.zig");

// Keep raw-body ownership behind one helper so the generated shape can
// adopt the core streaming response API without changing status/header logic.
fn bufferRawResponseBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    return allocator.dupe(u8, body);
}

fn responseStatusExpected(status: u16, expected: []const u16) bool {
    if (expected.len == 0) return status >= 200 and status < 300;
    for (expected) |value| {
        if (status == value) return true;
    }
    return false;
}
const default_endpoint = "https://management.azure.com";
const default_api_version = "2025-09-01";

/// Azure VMware Solution API
pub const AVSClient = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,

    pub const InitOptions = struct {
        subscription_id: []const u8,
        endpoint: []const u8 = default_endpoint,
        api_version: []const u8 = default_api_version,
    };

    pub fn init(
        pipeline: core.http.HttpPipeline,
        options: InitOptions,
    ) AVSClient {
        return .{
            .endpoint = options.endpoint,
            .api_version = options.api_version,
            .pipeline = pipeline,
            .subscription_id = options.subscription_id,
        };
    }

    pub fn operations(self: *@This()) Operations {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
        };
    }

    pub fn addons(self: *@This()) Addons {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn authorizations(self: *@This()) Authorizations {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn cloudLinks(self: *@This()) CloudLinks {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn clusters(self: *@This()) Clusters {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn datastores(self: *@This()) Datastores {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn globalReachConnections(self: *@This()) GlobalReachConnections {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn hcxEnterpriseSites(self: *@This()) HcxEnterpriseSites {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn hosts(self: *@This()) Hosts {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn iscsiPaths(self: *@This()) IscsiPaths {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn licenses(self: *@This()) Licenses {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn locations(self: *@This()) Locations {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn maintenances(self: *@This()) Maintenances {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn placementPolicies(self: *@This()) PlacementPolicies {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn privateClouds(self: *@This()) PrivateClouds {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn provisionedNetworks(self: *@This()) ProvisionedNetworks {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn pureStoragePolicies(self: *@This()) PureStoragePolicies {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn scriptCmdlets(self: *@This()) ScriptCmdlets {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn scriptExecutions(self: *@This()) ScriptExecutions {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn scriptPackages(self: *@This()) ScriptPackages {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn serviceComponents(self: *@This()) ServiceComponents {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn skus(self: *@This()) Skus {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn virtualMachines(self: *@This()) VirtualMachines {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }

    pub fn workloadNetworks(self: *@This()) WorkloadNetworks {
        return .{
            .endpoint = self.endpoint,
            .api_version = self.api_version,
            .pipeline = self.pipeline,
            .subscription_id = self.subscription_id,
        };
    }
};

pub const Operations = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    /// List the operations for the provider
    pub fn list(self: *@This(), alloc: std.mem.Allocator) !core.pager.PipelinePager(models.Operation) {
        @setEvalBranchQuota(100_000);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/providers/Microsoft.AVS/operations", .{self.endpoint});
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.Operation).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.Operation),
            "application/json",
        );
    }
};

pub const Addons = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List Addon resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.Addon) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/addons", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.Addon).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.Addon),
            "application/json",
        );
    }
    /// Get a Addon
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, addon_name: []const u8) !models.Addon {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, addon_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/addons/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Addons.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Addon, alloc, resp.body);
    }
    /// Create a Addon
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, addon_name: []const u8, addon: models.Addon) !core.lro.TypedPoller(models.Addon) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, addon_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/addons/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, addon);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("Addons.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.Addon).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a Addon
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, addon_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, addon_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/addons/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("Addons.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const Authorizations = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List ExpressRouteAuthorization resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.ExpressRouteAuthorization) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/authorizations", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.ExpressRouteAuthorization).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.ExpressRouteAuthorization),
            "application/json",
        );
    }
    /// Get a ExpressRouteAuthorization
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, authorization_name: []const u8) !models.ExpressRouteAuthorization {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, authorization_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/authorizations/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Authorizations.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.ExpressRouteAuthorization, alloc, resp.body);
    }
    /// Create a ExpressRouteAuthorization
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, authorization_name: []const u8, authorization: models.ExpressRouteAuthorization) !core.lro.TypedPoller(models.ExpressRouteAuthorization) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, authorization_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/authorizations/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, authorization);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("Authorizations.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.ExpressRouteAuthorization).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a ExpressRouteAuthorization
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, authorization_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, authorization_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/authorizations/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("Authorizations.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const CloudLinks = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List CloudLink resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.CloudLink) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/cloudLinks", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.CloudLink).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.CloudLink),
            "application/json",
        );
    }
    /// Get a CloudLink
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cloud_link_name: []const u8) !models.CloudLink {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cloud_link_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/cloudLinks/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("CloudLinks.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.CloudLink, alloc, resp.body);
    }
    /// Create a CloudLink
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cloud_link_name: []const u8, cloud_link: models.CloudLink) !core.lro.TypedPoller(models.CloudLink) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cloud_link_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/cloudLinks/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, cloud_link);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("CloudLinks.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.CloudLink).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a CloudLink
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cloud_link_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cloud_link_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/cloudLinks/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("CloudLinks.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const Clusters = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List Cluster resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.Cluster) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.Cluster).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.Cluster),
            "application/json",
        );
    }
    /// Get a Cluster
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8) !models.Cluster {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Clusters.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Cluster, alloc, resp.body);
    }
    /// Create a Cluster
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, cluster: models.Cluster) !core.lro.TypedPoller(models.Cluster) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, cluster);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("Clusters.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.Cluster).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a Cluster
    pub fn update(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, cluster_update: models.ClusterUpdate) !core.lro.TypedPoller(models.Cluster) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, cluster_update);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("Clusters.update", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.Cluster).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a Cluster
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("Clusters.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// List hosts by zone in a cluster
    pub fn listZones(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8) !models.ClusterZoneList {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/listZones", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Clusters.listZones", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.ClusterZoneList, alloc, resp.body);
    }
};

pub const Datastores = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List Datastore resources by Cluster
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8) !core.pager.PipelinePager(models.Datastore) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/datastores", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.Datastore).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.Datastore),
            "application/json",
        );
    }
    /// Get a Datastore
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, datastore_name: []const u8) !models.Datastore {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, datastore_name);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/datastores/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Datastores.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Datastore, alloc, resp.body);
    }
    /// Create a Datastore
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, datastore_name: []const u8, datastore: models.Datastore) !core.lro.TypedPoller(models.Datastore) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, datastore_name);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/datastores/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, datastore);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("Datastores.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.Datastore).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a Datastore
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, datastore_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, datastore_name);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/datastores/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("Datastores.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const GlobalReachConnections = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List GlobalReachConnection resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.GlobalReachConnection) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/globalReachConnections", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.GlobalReachConnection).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.GlobalReachConnection),
            "application/json",
        );
    }
    /// Get a GlobalReachConnection
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, global_reach_connection_name: []const u8) !models.GlobalReachConnection {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, global_reach_connection_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/globalReachConnections/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("GlobalReachConnections.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.GlobalReachConnection, alloc, resp.body);
    }
    /// Create a GlobalReachConnection
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, global_reach_connection_name: []const u8, global_reach_connection: models.GlobalReachConnection) !core.lro.TypedPoller(models.GlobalReachConnection) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, global_reach_connection_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/globalReachConnections/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, global_reach_connection);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("GlobalReachConnections.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.GlobalReachConnection).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a GlobalReachConnection
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, global_reach_connection_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, global_reach_connection_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/globalReachConnections/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("GlobalReachConnections.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const HcxEnterpriseSites = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List HcxEnterpriseSite resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.HcxEnterpriseSite) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/hcxEnterpriseSites", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.HcxEnterpriseSite).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.HcxEnterpriseSite),
            "application/json",
        );
    }
    /// Get a HcxEnterpriseSite
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, hcx_enterprise_site_name: []const u8) !models.HcxEnterpriseSite {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, hcx_enterprise_site_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/hcxEnterpriseSites/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("HcxEnterpriseSites.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.HcxEnterpriseSite, alloc, resp.body);
    }
    /// Create a HcxEnterpriseSite
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, hcx_enterprise_site_name: []const u8, hcx_enterprise_site: models.HcxEnterpriseSite) !models.HcxEnterpriseSite {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, hcx_enterprise_site_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/hcxEnterpriseSites/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, hcx_enterprise_site);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("HcxEnterpriseSites.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.HcxEnterpriseSite, alloc, resp.body);
    }
    /// Delete a HcxEnterpriseSite
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, hcx_enterprise_site_name: []const u8) !void {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, hcx_enterprise_site_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/hcxEnterpriseSites/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 204 })) {
            core.pager.logHttpError("HcxEnterpriseSites.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return;
    }
};

pub const Hosts = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List Host resources by Cluster
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8) !core.pager.PipelinePager(models.Host) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/hosts", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.Host).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.Host),
            "application/json",
        );
    }
    /// Get a Host
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, host_id: []const u8) !models.Host {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, host_id);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/hosts/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Hosts.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Host, alloc, resp.body);
    }
};

pub const IscsiPaths = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List IscsiPath resources by PrivateCloud
    pub fn listByPrivateCloud(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.IscsiPath) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/iscsiPaths", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.IscsiPath).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.IscsiPath),
            "application/json",
        );
    }
    /// Get a IscsiPath
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !models.IscsiPath {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/iscsiPaths/default", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("IscsiPaths.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.IscsiPath, alloc, resp.body);
    }
    /// Create a IscsiPath
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, resource: models.IscsiPath) !core.lro.TypedPoller(models.IscsiPath) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/iscsiPaths/default", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, resource);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("IscsiPaths.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.IscsiPath).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a IscsiPath
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/iscsiPaths/default", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("IscsiPaths.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const Licenses = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List License resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.License) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/licenses", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.License).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.License),
            "application/json",
        );
    }
    /// Get a License
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, license_name: enums.LicenseName) !models.License {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, license_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/licenses/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Licenses.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.License, alloc, resp.body);
    }
    /// Create a License
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, license_name: enums.LicenseName, resource: models.License) !core.lro.TypedPoller(models.License) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, license_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/licenses/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, resource);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("Licenses.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.License).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a License
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, license_name: enums.LicenseName) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, license_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/licenses/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 202, 204 })) {
            core.pager.logHttpError("Licenses.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Just like ArmResourceActionSync, but with no request body.
    pub fn getProperties(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, license_name: enums.LicenseName) !models.LicenseProperties {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, license_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/licenses/{s}/getProperties", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Licenses.getProperties", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.LicenseProperties, alloc, resp.body);
    }
};

pub const Locations = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// Return trial status for subscription by region
    pub fn checkTrialAvailability(self: *@This(), alloc: std.mem.Allocator, location: []const u8, sku: ?models.Sku) !models.Trial {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, location);
        defer alloc.free(encoded_path_1);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/providers/Microsoft.AVS/locations/{s}/checkTrialAvailability", .{ self.endpoint, encoded_path_0, encoded_path_1 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        if (sku != null) try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        var body_json: ?[]u8 = null;
        defer if (body_json) |bytes| alloc.free(bytes);
        if (sku) |body| {
            const bytes = try serde.json.toSlice(alloc, body);
            body_json = bytes;
            req.body = bytes;
        }

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Locations.checkTrialAvailability", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Trial, alloc, resp.body);
    }
    /// Return quota for subscription by region
    pub fn checkQuotaAvailability(self: *@This(), alloc: std.mem.Allocator, location: []const u8) !models.Quota {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, location);
        defer alloc.free(encoded_path_1);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/providers/Microsoft.AVS/locations/{s}/checkQuotaAvailability", .{ self.endpoint, encoded_path_0, encoded_path_1 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Locations.checkQuotaAvailability", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Quota, alloc, resp.body);
    }
};

pub const Maintenances = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List Maintenance resources by subscription ID
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, state_name: ?enums.MaintenanceStateName, status: ?enums.MaintenanceStatusFilter, from: ?[]const u8, to: ?[]const u8) !core.pager.PipelinePager(models.Maintenance) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/maintenances", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        if (state_name) |query_value| {
            const sep: []const u8 = if (has_query) "&" else "?";
            const enc = try core.url.percentEncode(alloc, query_value.toWire());
            defer alloc.free(enc);
            try url_buf.print(alloc, "{s}stateName={s}", .{ sep, enc });
            has_query = true;
        }
        if (status) |query_value| {
            const sep: []const u8 = if (has_query) "&" else "?";
            const enc = try core.url.percentEncode(alloc, query_value.toWire());
            defer alloc.free(enc);
            try url_buf.print(alloc, "{s}status={s}", .{ sep, enc });
            has_query = true;
        }
        if (from) |query_value| {
            const sep: []const u8 = if (has_query) "&" else "?";
            const enc = try core.url.percentEncode(alloc, query_value);
            defer alloc.free(enc);
            try url_buf.print(alloc, "{s}from={s}", .{ sep, enc });
            has_query = true;
        }
        if (to) |query_value| {
            const sep: []const u8 = if (has_query) "&" else "?";
            const enc = try core.url.percentEncode(alloc, query_value);
            defer alloc.free(enc);
            try url_buf.print(alloc, "{s}to={s}", .{ sep, enc });
            has_query = true;
        }
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.Maintenance).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.Maintenance),
            "application/json",
        );
    }
    /// Get a Maintenance
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, maintenance_name: []const u8) !models.Maintenance {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, maintenance_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/maintenances/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Maintenances.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Maintenance, alloc, resp.body);
    }
    /// Reschedule a maintenance
    pub fn reschedule(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, maintenance_name: []const u8, body: models.MaintenanceReschedule) !models.Maintenance {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, maintenance_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/maintenances/{s}/reschedule", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, body);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Maintenances.reschedule", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Maintenance, alloc, resp.body);
    }
    /// Schedule a maintenance
    pub fn schedule(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, maintenance_name: []const u8, body: models.MaintenanceSchedule) !models.Maintenance {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, maintenance_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/maintenances/{s}/schedule", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, body);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Maintenances.schedule", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Maintenance, alloc, resp.body);
    }
    /// Initiate maintenance readiness checks
    pub fn initiateChecks(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, maintenance_name: []const u8) !models.Maintenance {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, maintenance_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/maintenances/{s}/initiateChecks", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("Maintenances.initiateChecks", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.Maintenance, alloc, resp.body);
    }
};

pub const PlacementPolicies = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List PlacementPolicy resources by Cluster
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8) !core.pager.PipelinePager(models.PlacementPolicy) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/placementPolicies", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.PlacementPolicy).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.PlacementPolicy),
            "application/json",
        );
    }
    /// Get a PlacementPolicy
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, placement_policy_name: []const u8) !models.PlacementPolicy {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, placement_policy_name);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/placementPolicies/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("PlacementPolicies.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.PlacementPolicy, alloc, resp.body);
    }
    /// Create a PlacementPolicy
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, placement_policy_name: []const u8, placement_policy: models.PlacementPolicy) !core.lro.TypedPoller(models.PlacementPolicy) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, placement_policy_name);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/placementPolicies/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, placement_policy);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("PlacementPolicies.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.PlacementPolicy).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a PlacementPolicy
    pub fn update(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, placement_policy_name: []const u8, placement_policy_update: models.PlacementPolicyUpdate) !core.lro.TypedPoller(models.PlacementPolicy) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, placement_policy_name);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/placementPolicies/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, placement_policy_update);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202 })) {
            core.pager.logHttpError("PlacementPolicies.update", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.PlacementPolicy).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a PlacementPolicy
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, placement_policy_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, placement_policy_name);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/placementPolicies/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("PlacementPolicies.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const PrivateClouds = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List PrivateCloud resources by resource group
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8) !core.pager.PipelinePager(models.PrivateCloud) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds", .{ self.endpoint, encoded_path_0, encoded_path_1 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.PrivateCloud).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.PrivateCloud),
            "application/json",
        );
    }
    /// List PrivateCloud resources by subscription ID
    pub fn listInSubscription(self: *@This(), alloc: std.mem.Allocator) !core.pager.PipelinePager(models.PrivateCloud) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/providers/Microsoft.AVS/privateClouds", .{ self.endpoint, encoded_path_0 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.PrivateCloud).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.PrivateCloud),
            "application/json",
        );
    }
    /// Get a PrivateCloud
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !models.PrivateCloud {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("PrivateClouds.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.PrivateCloud, alloc, resp.body);
    }
    /// Create a PrivateCloud
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, private_cloud: models.PrivateCloud) !core.lro.TypedPoller(models.PrivateCloud) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, private_cloud);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("PrivateClouds.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.PrivateCloud).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a PrivateCloud
    pub fn update(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, private_cloud_update: models.PrivateCloudUpdate) !core.lro.TypedPoller(models.PrivateCloud) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, private_cloud_update);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("PrivateClouds.update", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.PrivateCloud).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a PrivateCloud
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("PrivateClouds.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Rotate the vCenter password
    pub fn rotateVcenterPassword(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/rotateVcenterPassword", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 202, 204 })) {
            core.pager.logHttpError("PrivateClouds.rotateVcenterPassword", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Rotate the NSX-T Manager password
    pub fn rotateNsxtPassword(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/rotateNsxtPassword", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 202, 204 })) {
            core.pager.logHttpError("PrivateClouds.rotateNsxtPassword", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// List the admin credentials for the private cloud
    pub fn listAdminCredentials(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !models.AdminCredentials {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/listAdminCredentials", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("PrivateClouds.listAdminCredentials", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.AdminCredentials, alloc, resp.body);
    }
    /// Get the license for the private cloud
    pub fn getVcfLicense(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !models.VcfLicense {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/getVcfLicense", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("PrivateClouds.getVcfLicense", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.VcfLicense, alloc, resp.body);
    }
};

pub const ProvisionedNetworks = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List ProvisionedNetwork resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.ProvisionedNetwork) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/provisionedNetworks", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.ProvisionedNetwork).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.ProvisionedNetwork),
            "application/json",
        );
    }
    /// Get a ProvisionedNetwork
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, provisioned_network_name: []const u8) !models.ProvisionedNetwork {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, provisioned_network_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/provisionedNetworks/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("ProvisionedNetworks.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.ProvisionedNetwork, alloc, resp.body);
    }
};

pub const PureStoragePolicies = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List PureStoragePolicy resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.PureStoragePolicy) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/pureStoragePolicies", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.PureStoragePolicy).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.PureStoragePolicy),
            "application/json",
        );
    }
    /// Get a PureStoragePolicy
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, storage_policy_name: []const u8) !models.PureStoragePolicy {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, storage_policy_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/pureStoragePolicies/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("PureStoragePolicies.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.PureStoragePolicy, alloc, resp.body);
    }
    /// Create a PureStoragePolicy
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, storage_policy_name: []const u8, resource: models.PureStoragePolicy) !core.lro.TypedPoller(models.PureStoragePolicy) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, storage_policy_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/pureStoragePolicies/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, resource);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("PureStoragePolicies.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.PureStoragePolicy).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a PureStoragePolicy
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, storage_policy_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, storage_policy_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/pureStoragePolicies/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 202, 204 })) {
            core.pager.logHttpError("PureStoragePolicies.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const ScriptCmdlets = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List ScriptCmdlet resources by ScriptPackage
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, script_package_name: []const u8) !core.pager.PipelinePager(models.ScriptCmdlet) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, script_package_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptPackages/{s}/scriptCmdlets", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.ScriptCmdlet).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.ScriptCmdlet),
            "application/json",
        );
    }
    /// Get a ScriptCmdlet
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, script_package_name: []const u8, script_cmdlet_name: []const u8) !models.ScriptCmdlet {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, script_package_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, script_cmdlet_name);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptPackages/{s}/scriptCmdlets/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("ScriptCmdlets.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.ScriptCmdlet, alloc, resp.body);
    }
};

pub const ScriptExecutions = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List ScriptExecution resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.ScriptExecution) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptExecutions", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.ScriptExecution).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.ScriptExecution),
            "application/json",
        );
    }
    /// Get a ScriptExecution
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, script_execution_name: []const u8) !models.ScriptExecution {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, script_execution_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptExecutions/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("ScriptExecutions.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.ScriptExecution, alloc, resp.body);
    }
    /// Create a ScriptExecution
    pub fn createOrUpdate(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, script_execution_name: []const u8, script_execution: models.ScriptExecution) !core.lro.TypedPoller(models.ScriptExecution) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, script_execution_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptExecutions/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, script_execution);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("ScriptExecutions.createOrUpdate", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.ScriptExecution).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a ScriptExecution
    pub fn delete(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, script_execution_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, script_execution_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptExecutions/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("ScriptExecutions.delete", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Return the logs for a script execution resource
    pub fn getExecutionLogs(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, script_execution_name: []const u8, script_output_stream_type: ?[]const enums.ScriptOutputStreamType) !models.ScriptExecution {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, script_execution_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptExecutions/{s}/getExecutionLogs", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        if (script_output_stream_type != null) try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        var body_json: ?[]u8 = null;
        defer if (body_json) |bytes| alloc.free(bytes);
        if (script_output_stream_type) |body| {
            const bytes = try serde.json.toSlice(alloc, body);
            body_json = bytes;
            req.body = bytes;
        }

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("ScriptExecutions.getExecutionLogs", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.ScriptExecution, alloc, resp.body);
    }
};

pub const ScriptPackages = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List ScriptPackage resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.ScriptPackage) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptPackages", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.ScriptPackage).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.ScriptPackage),
            "application/json",
        );
    }
    /// Get a ScriptPackage
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, script_package_name: []const u8) !models.ScriptPackage {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, script_package_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/scriptPackages/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("ScriptPackages.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.ScriptPackage, alloc, resp.body);
    }
};

pub const ServiceComponents = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// Return service component availability
    pub fn checkAvailability(self: *@This(), alloc: std.mem.Allocator, location: []const u8, service_component_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, location);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, service_component_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/providers/Microsoft.AVS/locations/{s}/serviceComponents/{s}/checkAvailability", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{202})) {
            core.pager.logHttpError("ServiceComponents.checkAvailability", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const Skus = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// A list of SKUs.
    pub fn list(self: *@This(), alloc: std.mem.Allocator) !core.pager.PipelinePager(models.ResourceSku) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/providers/Microsoft.AVS/skus", .{ self.endpoint, encoded_path_0 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.ResourceSku).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.ResourceSku),
            "application/json",
        );
    }
};

pub const VirtualMachines = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// List VirtualMachine resources by Cluster
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8) !core.pager.PipelinePager(models.VirtualMachine) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/virtualMachines", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.VirtualMachine).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.VirtualMachine),
            "application/json",
        );
    }
    /// Get a VirtualMachine
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, virtual_machine_id: []const u8) !models.VirtualMachine {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, virtual_machine_id);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/virtualMachines/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("VirtualMachines.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.VirtualMachine, alloc, resp.body);
    }
    /// Enable or disable DRS-driven VM movement restriction
    pub fn restrictMovement(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, cluster_name: []const u8, virtual_machine_id: []const u8, restrict_movement: models.VirtualMachineRestrictMovement) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, cluster_name);
        defer alloc.free(encoded_path_3);
        const encoded_path_4 = try core.url.encodePathSegment(alloc, virtual_machine_id);
        defer alloc.free(encoded_path_4);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/clusters/{s}/virtualMachines/{s}/restrictMovement", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3, encoded_path_4 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .POST, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        const body_json = try serde.json.toSlice(alloc, restrict_movement);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{202})) {
            core.pager.logHttpError("VirtualMachines.restrictMovement", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};

pub const WorkloadNetworks = struct {
    endpoint: []const u8,
    api_version: []const u8,
    pipeline: core.http.HttpPipeline,
    subscription_id: []const u8,
    /// Get a WorkloadNetwork
    pub fn get(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !models.WorkloadNetwork {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.get", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetwork, alloc, resp.body);
    }
    /// List WorkloadNetwork resources by PrivateCloud
    pub fn list(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetwork) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetwork).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetwork),
            "application/json",
        );
    }
    /// List WorkloadNetworkDhcp resources by WorkloadNetwork
    pub fn listDhcp(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkDhcp) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dhcpConfigurations", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkDhcp).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkDhcp),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkDhcp
    pub fn getDhcp(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, dhcp_id: []const u8, private_cloud_name: []const u8) !models.WorkloadNetworkDhcp {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, dhcp_id);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dhcpConfigurations/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_3, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getDhcp", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkDhcp, alloc, resp.body);
    }
    /// Create a WorkloadNetworkDhcp
    pub fn createDhcp(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dhcp_id: []const u8, workload_network_dhcp: models.WorkloadNetworkDhcp) !core.lro.TypedPoller(models.WorkloadNetworkDhcp) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dhcp_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dhcpConfigurations/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_dhcp);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("WorkloadNetworks.createDhcp", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkDhcp).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a WorkloadNetworkDhcp
    pub fn updateDhcp(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dhcp_id: []const u8, workload_network_dhcp: models.WorkloadNetworkDhcp) !core.lro.TypedPoller(models.WorkloadNetworkDhcp) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dhcp_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dhcpConfigurations/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_dhcp);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202 })) {
            core.pager.logHttpError("WorkloadNetworks.updateDhcp", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkDhcp).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a WorkloadNetworkDhcp
    pub fn deleteDhcp(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dhcp_id: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dhcp_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dhcpConfigurations/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("WorkloadNetworks.deleteDhcp", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// List WorkloadNetworkDnsService resources by WorkloadNetwork
    pub fn listDnsServices(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkDnsService) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsServices", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkDnsService).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkDnsService),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkDnsService
    pub fn getDnsService(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dns_service_id: []const u8) !models.WorkloadNetworkDnsService {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dns_service_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsServices/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getDnsService", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkDnsService, alloc, resp.body);
    }
    /// Create a WorkloadNetworkDnsService
    pub fn createDnsService(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dns_service_id: []const u8, workload_network_dns_service: models.WorkloadNetworkDnsService) !core.lro.TypedPoller(models.WorkloadNetworkDnsService) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dns_service_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsServices/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_dns_service);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("WorkloadNetworks.createDnsService", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkDnsService).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a WorkloadNetworkDnsService
    pub fn updateDnsService(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dns_service_id: []const u8, workload_network_dns_service: models.WorkloadNetworkDnsService) !core.lro.TypedPoller(models.WorkloadNetworkDnsService) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dns_service_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsServices/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_dns_service);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202 })) {
            core.pager.logHttpError("WorkloadNetworks.updateDnsService", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkDnsService).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a WorkloadNetworkDnsService
    pub fn deleteDnsService(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, dns_service_id: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, dns_service_id);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsServices/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_3, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("WorkloadNetworks.deleteDnsService", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// List WorkloadNetworkDnsZone resources by WorkloadNetwork
    pub fn listDnsZones(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkDnsZone) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsZones", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkDnsZone).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkDnsZone),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkDnsZone
    pub fn getDnsZone(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dns_zone_id: []const u8) !models.WorkloadNetworkDnsZone {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dns_zone_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsZones/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getDnsZone", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkDnsZone, alloc, resp.body);
    }
    /// Create a WorkloadNetworkDnsZone
    pub fn createDnsZone(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dns_zone_id: []const u8, workload_network_dns_zone: models.WorkloadNetworkDnsZone) !core.lro.TypedPoller(models.WorkloadNetworkDnsZone) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dns_zone_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsZones/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_dns_zone);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("WorkloadNetworks.createDnsZone", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkDnsZone).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a WorkloadNetworkDnsZone
    pub fn updateDnsZone(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, dns_zone_id: []const u8, workload_network_dns_zone: models.WorkloadNetworkDnsZone) !core.lro.TypedPoller(models.WorkloadNetworkDnsZone) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, dns_zone_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsZones/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_dns_zone);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202 })) {
            core.pager.logHttpError("WorkloadNetworks.updateDnsZone", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkDnsZone).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a WorkloadNetworkDnsZone
    pub fn deleteDnsZone(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, dns_zone_id: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, dns_zone_id);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/dnsZones/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_3, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("WorkloadNetworks.deleteDnsZone", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// List WorkloadNetworkGateway resources by WorkloadNetwork
    pub fn listGateways(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkGateway) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/gateways", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkGateway).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkGateway),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkGateway
    pub fn getGateway(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, gateway_id: []const u8) !models.WorkloadNetworkGateway {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, gateway_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/gateways/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getGateway", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkGateway, alloc, resp.body);
    }
    /// List WorkloadNetworkPortMirroring resources by WorkloadNetwork
    pub fn listPortMirroring(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkPortMirroring) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/portMirroringProfiles", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkPortMirroring).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkPortMirroring),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkPortMirroring
    pub fn getPortMirroring(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, port_mirroring_id: []const u8) !models.WorkloadNetworkPortMirroring {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, port_mirroring_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/portMirroringProfiles/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getPortMirroring", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkPortMirroring, alloc, resp.body);
    }
    /// Create a WorkloadNetworkPortMirroring
    pub fn createPortMirroring(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, port_mirroring_id: []const u8, workload_network_port_mirroring: models.WorkloadNetworkPortMirroring) !core.lro.TypedPoller(models.WorkloadNetworkPortMirroring) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, port_mirroring_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/portMirroringProfiles/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_port_mirroring);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("WorkloadNetworks.createPortMirroring", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkPortMirroring).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a WorkloadNetworkPortMirroring
    pub fn updatePortMirroring(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, port_mirroring_id: []const u8, workload_network_port_mirroring: models.WorkloadNetworkPortMirroring) !core.lro.TypedPoller(models.WorkloadNetworkPortMirroring) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, port_mirroring_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/portMirroringProfiles/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_port_mirroring);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202 })) {
            core.pager.logHttpError("WorkloadNetworks.updatePortMirroring", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkPortMirroring).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a WorkloadNetworkPortMirroring
    pub fn deletePortMirroring(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, port_mirroring_id: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, port_mirroring_id);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/portMirroringProfiles/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_3, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("WorkloadNetworks.deletePortMirroring", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// List WorkloadNetworkPublicIP resources by WorkloadNetwork
    pub fn listPublicIPs(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkPublicIP) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/publicIPs", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkPublicIP).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkPublicIP),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkPublicIP
    pub fn getPublicIP(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, public_ip_id: []const u8) !models.WorkloadNetworkPublicIP {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, public_ip_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/publicIPs/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getPublicIP", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkPublicIP, alloc, resp.body);
    }
    /// Create a WorkloadNetworkPublicIP
    pub fn createPublicIP(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, public_ip_id: []const u8, workload_network_public_ip: models.WorkloadNetworkPublicIP) !core.lro.TypedPoller(models.WorkloadNetworkPublicIP) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, public_ip_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/publicIPs/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_public_ip);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("WorkloadNetworks.createPublicIP", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkPublicIP).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a WorkloadNetworkPublicIP
    pub fn deletePublicIP(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, public_ip_id: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, public_ip_id);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/publicIPs/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_3, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("WorkloadNetworks.deletePublicIP", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// List WorkloadNetworkSegment resources by WorkloadNetwork
    pub fn listSegments(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkSegment) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/segments", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkSegment).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkSegment),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkSegment
    pub fn getSegment(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, segment_id: []const u8) !models.WorkloadNetworkSegment {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, segment_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/segments/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getSegment", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkSegment, alloc, resp.body);
    }
    /// Create a WorkloadNetworkSegment
    pub fn createSegments(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, segment_id: []const u8, workload_network_segment: models.WorkloadNetworkSegment) !core.lro.TypedPoller(models.WorkloadNetworkSegment) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, segment_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/segments/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_segment);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("WorkloadNetworks.createSegments", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkSegment).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a WorkloadNetworkSegment
    pub fn updateSegments(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, segment_id: []const u8, workload_network_segment: models.WorkloadNetworkSegment) !core.lro.TypedPoller(models.WorkloadNetworkSegment) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, segment_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/segments/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_segment);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202 })) {
            core.pager.logHttpError("WorkloadNetworks.updateSegments", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkSegment).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a WorkloadNetworkSegment
    pub fn deleteSegment(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, segment_id: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, segment_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/segments/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("WorkloadNetworks.deleteSegment", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
    /// List WorkloadNetworkVirtualMachine resources by WorkloadNetwork
    pub fn listVirtualMachines(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkVirtualMachine) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/virtualMachines", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkVirtualMachine).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkVirtualMachine),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkVirtualMachine
    pub fn getVirtualMachine(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, virtual_machine_id: []const u8) !models.WorkloadNetworkVirtualMachine {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, virtual_machine_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/virtualMachines/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getVirtualMachine", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkVirtualMachine, alloc, resp.body);
    }
    /// List WorkloadNetworkVMGroup resources by WorkloadNetwork
    pub fn listVMGroups(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8) !core.pager.PipelinePager(models.WorkloadNetworkVMGroup) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/vmGroups", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        return core.pager.PipelinePager(models.WorkloadNetworkVMGroup).init(
            self.pipeline,
            url,
            alloc,
            core.pager.listPageParser(models.WorkloadNetworkVMGroup),
            "application/json",
        );
    }
    /// Get a WorkloadNetworkVMGroup
    pub fn getVMGroup(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, vm_group_id: []const u8) !models.WorkloadNetworkVMGroup {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, vm_group_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/vmGroups/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .GET, url);
        defer req.deinit();
        try req.setHeader("Accept", "application/json");

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{200})) {
            core.pager.logHttpError("WorkloadNetworks.getVMGroup", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try serde.json.fromSlice(models.WorkloadNetworkVMGroup, alloc, resp.body);
    }
    /// Create a WorkloadNetworkVMGroup
    pub fn createVMGroup(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, vm_group_id: []const u8, workload_network_vm_group: models.WorkloadNetworkVMGroup) !core.lro.TypedPoller(models.WorkloadNetworkVMGroup) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, vm_group_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/vmGroups/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PUT, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_vm_group);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 201 })) {
            core.pager.logHttpError("WorkloadNetworks.createVMGroup", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkVMGroup).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Update a WorkloadNetworkVMGroup
    pub fn updateVMGroup(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, private_cloud_name: []const u8, vm_group_id: []const u8, workload_network_vm_group: models.WorkloadNetworkVMGroup) !core.lro.TypedPoller(models.WorkloadNetworkVMGroup) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, vm_group_id);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/vmGroups/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_2, encoded_path_3 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .PATCH, url);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "application/json");
        const body_json = try serde.json.toSlice(alloc, workload_network_vm_group);
        defer alloc.free(body_json);
        req.body = body_json;

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202 })) {
            core.pager.logHttpError("WorkloadNetworks.updateVMGroup", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(models.WorkloadNetworkVMGroup).init(alloc, self.pipeline, resp, url, .{});
    }
    /// Delete a WorkloadNetworkVMGroup
    pub fn deleteVMGroup(self: *@This(), alloc: std.mem.Allocator, resource_group_name: []const u8, vm_group_id: []const u8, private_cloud_name: []const u8) !core.lro.TypedPoller(void) {
        @setEvalBranchQuota(100_000);
        const encoded_path_0 = try core.url.encodePathSegment(alloc, self.subscription_id);
        defer alloc.free(encoded_path_0);
        const encoded_path_1 = try core.url.encodePathSegment(alloc, resource_group_name);
        defer alloc.free(encoded_path_1);
        const encoded_path_2 = try core.url.encodePathSegment(alloc, vm_group_id);
        defer alloc.free(encoded_path_2);
        const encoded_path_3 = try core.url.encodePathSegment(alloc, private_cloud_name);
        defer alloc.free(encoded_path_3);
        const base_url = try std.fmt.allocPrint(alloc, "{s}/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.AVS/privateClouds/{s}/workloadNetworks/default/vmGroups/{s}", .{ self.endpoint, encoded_path_0, encoded_path_1, encoded_path_3, encoded_path_2 });
        defer alloc.free(base_url);
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(alloc);
        try url_buf.appendSlice(alloc, base_url);
        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        const encoded_query_0 = try core.url.percentEncode(alloc, self.api_version);
        defer alloc.free(encoded_query_0);
        try url_buf.print(alloc, "{s}api-version={s}", .{ if (has_query) "&" else "?", encoded_query_0 });
        has_query = true;
        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);
        var req = core.http.Request.init(alloc, .DELETE, url);
        defer req.deinit();

        var resp = try self.pipeline.send(&req);
        defer resp.deinit();

        if (!responseStatusExpected(resp.status_code, &.{ 200, 202, 204 })) {
            core.pager.logHttpError("WorkloadNetworks.deleteVMGroup", resp.status_code, resp.body);
            return error.AzureRequestFailed;
        }
        return try core.lro.TypedPoller(void).init(alloc, self.pipeline, resp, url, .{});
    }
};
