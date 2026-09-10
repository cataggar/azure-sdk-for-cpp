const std = @import("std");

pub const Kind = enum {
    rest,
    sdk,
};

pub const SourceOwnership = enum {
    main_owned,
    branch_owned,
};

pub const Package = struct {
    kind: Kind,
    ownership: SourceOwnership = .branch_owned,
    workspace_path: ?[]const u8 = null,
    historical_source_path: []const u8,
    root_source_file: []const u8,
    name: []const u8,
    module_name: []const u8,
    branch: []const u8,
    identity_override: bool = false,
    historical_names: []const []const u8 = &.{},
    dependencies: []const []const u8 = &.{},
    external_dependencies: []const []const u8 = &.{},
    publish_paths: []const []const u8 = &.{},
    test_command: ?[]const u8 = "zig build test --summary all",
    examples_command: ?[]const u8 = null,
    live_test_command: ?[]const u8 = null,
    regeneration_command: ?[]const u8 = null,
};

pub const all = [_]Package{
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/core/amqp",
        .root_source_file = "root.zig",
        .name = "azure_sdk_amqp",
        .module_name = "azure_sdk_amqp",
        .branch = "sdk/amqp",
        .identity_override = true,
        .historical_names = &.{"azure_sdk_core_amqp"},
        .external_dependencies = &.{"uamqp"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "transport.zig",
            "performative.zig",
            "connection.zig",
            "message.zig",
            "link.zig",
            "rpc.zig",
            "cbs.zig",
            "management.zig",
            "test_peer.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/core",
        .root_source_file = "root.zig",
        .name = "azure_sdk_core",
        .module_name = "azure_sdk_core",
        .branch = "sdk/core",
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "crypto.zig",
            "http.zig",
            "arm",
            "credentials",
            "http",
            "conformance",
            "identity",
            "tracing",
            "perf",
            "base64.zig",
            "case_insensitive_map.zig",
            "cloud.zig",
            "context.zig",
            "datetime.zig",
            "dotenv.zig",
            "errors.zig",
            "lro.zig",
            "open_enum.zig",
            "fixed_enum.zig",
            "pager.zig",
            "response.zig",
            "safe_debug.zig",
            "url.zig",
            "uuid.zig",
            "wasi_adapter_test.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/core_symcrypt",
        .root_source_file = "root.zig",
        .name = "azure_sdk_core_symcrypt",
        .module_name = "azure_sdk_core_symcrypt",
        .branch = "sdk/core_symcrypt",
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"zig_symcrypt"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "conformance",
            "examples",
            "README.md",
            "LICENSE.txt",
        },
        .test_command = "zig build source-check -Dsource_only=true",
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/core/testing",
        .root_source_file = "root.zig",
        .name = "azure_sdk_testing",
        .module_name = "azure_sdk_testing",
        .branch = "sdk/testing",
        .identity_override = true,
        .historical_names = &.{"azure_sdk_core_testing"},
        .dependencies = &.{"azure_sdk_core"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "conformance_test.zig",
            "root.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .rest,
        .historical_source_path = "rest/arm_avs",
        .root_source_file = "src/root.zig",
        .name = "azure_rest_arm_avs",
        .module_name = "azure_rest_arm_avs",
        .branch = "rest/arm_avs",
        .historical_names = &.{"arm_avs"},
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "src",
            "examples",
            "README.md",
            "LICENSE.txt",
        },
        .examples_command = "zig build examples",
        .regeneration_command = "codegen/scripts/sync.sh arm_avs",
    },
    .{
        .kind = .rest,
        .historical_source_path = "rest/keyvault_secrets",
        .root_source_file = "src/root.zig",
        .name = "azure_rest_keyvault_secrets",
        .module_name = "azure_rest_keyvault_secrets",
        .branch = "rest/keyvault_secrets",
        .historical_names = &.{"keyvault_secrets"},
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "src",
            "README.md",
            "LICENSE.txt",
        },
        .regeneration_command = "codegen/scripts/sync.sh keyvault_secrets",
    },
    .{
        .kind = .rest,
        .historical_source_path = "rest/container_registry",
        .root_source_file = "src/root.zig",
        .name = "azure_rest_container_registry",
        .module_name = "azure_rest_container_registry",
        .branch = "rest/container_registry",
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "src",
            "README.md",
            "LICENSE.txt",
        },
        .regeneration_command = "(cd codegen/cli && zig build generate-container-registry-package)",
    },
    .{
        .kind = .rest,
        .historical_source_path = "rest/data_tables",
        .root_source_file = "src/root.zig",
        .name = "azure_rest_data_tables",
        .module_name = "azure_rest_data_tables",
        .branch = "rest/data_tables",
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "src",
            "README.md",
            "LICENSE.txt",
        },
        .regeneration_command = "(cd codegen/cli && zig build generate-data-tables-package)",
    },
    .{
        .kind = .rest,
        .historical_source_path = "rest/devops",
        .root_source_file = "src/root.zig",
        .name = "azure_rest_devops",
        .module_name = "azure_rest_devops",
        .branch = "rest/devops",
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "src",
            "README.md",
            "LICENSE.txt",
        },
        .regeneration_command = "(cd codegen/cli && zig build generate-devops-package)",
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/container_registry",
        .root_source_file = "src/root.zig",
        .name = "azure_sdk_container_registry",
        .module_name = "azure_sdk_container_registry",
        .branch = "sdk/container_registry",
        .dependencies = &.{
            "azure_sdk_core",
            "azure_rest_container_registry",
        },
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "src",
            "examples",
            "live_tests",
            "README.md",
            "LICENSE.txt",
        },
        .examples_command = "zig build examples",
        .live_test_command = "zig build live-test",
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/devops",
        .root_source_file = "src/root.zig",
        .name = "azure_sdk_devops",
        .module_name = "azure_sdk_devops",
        .branch = "sdk/devops",
        .dependencies = &.{
            "azure_sdk_core",
            "azure_rest_devops",
        },
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "src",
            "examples",
            "live_tests",
            "README.md",
            "LICENSE.txt",
        },
        .examples_command = "zig build examples",
        .live_test_command = "zig build live-test",
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/storage/common",
        .root_source_file = "root.zig",
        .name = "azure_sdk_storage_common",
        .module_name = "azure_sdk_storage_common",
        .branch = "sdk/storage_common",
        .dependencies = &.{"azure_sdk_core"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "sas.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/storage/blobs",
        .root_source_file = "root.zig",
        .name = "azure_sdk_storage_blobs",
        .module_name = "azure_sdk_storage_blobs",
        .branch = "sdk/storage_blobs",
        .dependencies = &.{
            "azure_sdk_core",
            "azure_sdk_storage_common",
        },
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "sas.zig",
            "convenience.zig",
            "container_client.zig",
            "src",
            "examples",
            "README.md",
            "LICENSE.txt",
        },
        .examples_command = "zig build examples",
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/storage/queues",
        .root_source_file = "root.zig",
        .name = "azure_sdk_storage_queues",
        .module_name = "azure_sdk_storage_queues",
        .branch = "sdk/storage_queues",
        .dependencies = &.{
            "azure_sdk_core",
            "azure_sdk_storage_common",
        },
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "sas.zig",
            "examples",
            "README.md",
            "LICENSE.txt",
        },
        .examples_command = "zig build examples",
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/storage/files/shares",
        .root_source_file = "root.zig",
        .name = "azure_sdk_storage_files_shares",
        .module_name = "azure_sdk_storage_files_shares",
        .branch = "sdk/storage_files_shares",
        .dependencies = &.{"azure_sdk_core"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/storage/files/datalake",
        .root_source_file = "root.zig",
        .name = "azure_sdk_storage_files_datalake",
        .module_name = "azure_sdk_storage_files_datalake",
        .branch = "sdk/storage_files_datalake",
        .dependencies = &.{"azure_sdk_core"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/keyvault",
        .root_source_file = "root.zig",
        .name = "azure_sdk_keyvault",
        .module_name = "azure_sdk_keyvault",
        .branch = "sdk/keyvault",
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "pipeline.zig",
            "test_support.zig",
            "secrets",
            "keys",
            "certificates",
            "administration",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/data/tables",
        .root_source_file = "root.zig",
        .name = "azure_sdk_data_tables",
        .module_name = "azure_sdk_data_tables",
        .branch = "sdk/data_tables",
        .dependencies = &.{ "azure_sdk_core", "azure_rest_data_tables" },
        .external_dependencies = &.{"serde"},
        .examples_command = "zig build examples",
        .live_test_command = "zig build live-test",
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "auth.zig",
            "client.zig",
            "client_configuration.zig",
            "connection_string.zig",
            "construction_test.zig",
            "edm.zig",
            "entity.zig",
            "entity_codec.zig",
            "entity_codec_compile_fail_duplicate_wire_name.zig",
            "entity_codec_compile_fail_missing_keys.zig",
            "entity_codec_compile_fail_invalid_wire_name.zig",
            "entity_codec_compile_fail_reserved_wire_name.zig",
            "entity_codec_compile_fail_invalid_timestamp.zig",
            "entity_codec_compile_fail_too_many_properties.zig",
            "entity_codec_compile_fail_unsupported_type.zig",
            "errors.zig",
            "options.zig",
            "pager.zig",
            "pipeline.zig",
            "protocol_client.zig",
            "request.zig",
            "responses.zig",
            "sas.zig",
            "service_client.zig",
            "service_admin_models.zig",
            "service_models.zig",
            "transaction.zig",
            "examples",
            "integration_tests",
            "live_tests",
            "scripts",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/data/cosmos",
        .root_source_file = "root.zig",
        .name = "azure_sdk_data_cosmos",
        .module_name = "azure_sdk_data_cosmos",
        .branch = "sdk/data_cosmos",
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/data/appconfiguration",
        .root_source_file = "root.zig",
        .name = "azure_sdk_data_appconfiguration",
        .module_name = "azure_sdk_data_appconfiguration",
        .branch = "sdk/data_appconfiguration",
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/attestation",
        .root_source_file = "root.zig",
        .name = "azure_sdk_attestation",
        .module_name = "azure_sdk_attestation",
        .branch = "sdk/attestation",
        .dependencies = &.{"azure_sdk_core"},
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/messaging/common",
        .root_source_file = "root.zig",
        .name = "azure_sdk_messaging_common",
        .module_name = "azure_sdk_messaging_common",
        .branch = "sdk/messaging_common",
        .dependencies = &.{"azure_sdk_core"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "sas.zig",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/messaging/eventhubs",
        .root_source_file = "root.zig",
        .name = "azure_sdk_eventhubs",
        .module_name = "azure_sdk_eventhubs",
        .branch = "sdk/eventhubs",
        .identity_override = true,
        .dependencies = &.{
            "azure_sdk_core",
            "azure_sdk_messaging_common",
            "azure_sdk_storage_blobs",
            "azure_sdk_amqp",
        },
        .external_dependencies = &.{"serde"},
        .examples_command = "zig build examples",
        .live_test_command = "zig build live-test",
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "event_data.zig",
            "batch.zig",
            "sender.zig",
            "position.zig",
            "receiver.zig",
            "recovery.zig",
            "load_balancer.zig",
            "processor.zig",
            "connection_options.zig",
            "errors.zig",
            "checkpoint.zig",
            "checkpoint_store.zig",
            "management.zig",
            "checkpoint_store_blob",
            "examples",
            "live_tests",
            "benchmarks",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/messaging/servicebus",
        .root_source_file = "root.zig",
        .name = "azure_sdk_servicebus",
        .module_name = "azure_sdk_servicebus",
        .branch = "sdk/servicebus",
        .identity_override = true,
        .dependencies = &.{
            "azure_sdk_core",
            "azure_sdk_messaging_common",
            "azure_sdk_amqp",
        },
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "message.zig",
            "admin.zig",
            "amqp_transport.zig",
            "management.zig",
            "benchmarks",
            "README.md",
            "LICENSE.txt",
        },
    },
    .{
        .kind = .sdk,
        .historical_source_path = "sdk/kusto",
        .root_source_file = "root.zig",
        .name = "azure_sdk_kusto",
        .module_name = "azure_sdk_kusto",
        .branch = "sdk/kusto",
        .dependencies = &.{
            "azure_sdk_core",
            "azure_sdk_storage_common",
            "azure_sdk_storage_blobs",
            "azure_sdk_storage_queues",
        },
        .external_dependencies = &.{"serde"},
        .publish_paths = &.{
            ".gitignore",
            "build.zig",
            "build.zig.zon",
            "root.zig",
            "common",
            "data",
            "ingest",
            "README.md",
            "LICENSE.txt",
        },
    },
};

pub fn find(entries: []const Package, name: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index;
    }
    return null;
}

/// Release tags are `<package>/v<version>`. The version is the package
/// manifest's, which is the only place a package's version is declared.
pub fn tagAlloc(
    allocator: std.mem.Allocator,
    entry: Package,
    version: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/v{s}", .{ entry.name, version });
}

pub fn validate(allocator: std.mem.Allocator, entries: []const Package) !void {
    if (entries.len == 0) return error.EmptyRegistry;

    for (entries, 0..) |entry, index| {
        try validateEntry(allocator, entry);
        for (entries[index + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.name, other.name)) return error.DuplicatePackageName;
            if (std.mem.eql(u8, entry.module_name, other.module_name)) return error.DuplicateModuleName;
            if (std.mem.eql(u8, entry.historical_source_path, other.historical_source_path)) {
                return error.DuplicateSourcePath;
            }
            if (std.mem.eql(u8, entry.branch, other.branch)) return error.DuplicateBranch;
        }
        for (entry.dependencies) |dependency| {
            if (std.mem.eql(u8, dependency, entry.name)) return error.DependencyCycle;
            if (find(entries, dependency) == null) return error.UnknownDependency;
        }
    }

    const states = try allocator.alloc(VisitState, entries.len);
    defer allocator.free(states);
    @memset(states, .unvisited);
    for (entries, 0..) |_, index| try visit(entries, states, index);
}

pub fn topologicalOrder(
    allocator: std.mem.Allocator,
    entries: []const Package,
) ![]usize {
    try validate(allocator, entries);

    const indegrees = try allocator.alloc(usize, entries.len);
    defer allocator.free(indegrees);
    const emitted = try allocator.alloc(bool, entries.len);
    defer allocator.free(emitted);
    @memset(emitted, false);
    for (entries, 0..) |entry, index| indegrees[index] = entry.dependencies.len;

    var order: std.ArrayList(usize) = .empty;
    errdefer order.deinit(allocator);
    while (order.items.len < entries.len) {
        const next = for (entries, 0..) |_, index| {
            if (!emitted[index] and indegrees[index] == 0) break index;
        } else return error.DependencyCycle;

        emitted[next] = true;
        try order.append(allocator, next);
        for (entries, 0..) |entry, index| {
            if (emitted[index]) continue;
            for (entry.dependencies) |dependency| {
                if (std.mem.eql(u8, dependency, entries[next].name)) {
                    indegrees[index] -= 1;
                    break;
                }
            }
        }
    }
    return order.toOwnedSlice(allocator);
}

const VisitState = enum {
    unvisited,
    visiting,
    visited,
};

fn visit(entries: []const Package, states: []VisitState, index: usize) !void {
    switch (states[index]) {
        .visited => return,
        .visiting => return error.DependencyCycle,
        .unvisited => {},
    }
    states[index] = .visiting;
    for (entries[index].dependencies) |dependency| {
        try visit(entries, states, find(entries, dependency).?);
    }
    states[index] = .visited;
}

fn validateEntry(allocator: std.mem.Allocator, entry: Package) !void {
    if (!std.mem.eql(u8, entry.name, entry.module_name)) {
        return error.PackageModuleMismatch;
    }
    try validatePath(entry.historical_source_path);
    if (entry.workspace_path) |workspace_path| try validatePath(workspace_path);
    switch (entry.ownership) {
        .main_owned => {
            const workspace_path = entry.workspace_path orelse
                return error.MissingWorkspacePath;
            if (!std.mem.eql(u8, workspace_path, entry.historical_source_path)) {
                return error.WorkspaceHistoryPathMismatch;
            }
        },
        .branch_owned => {
            if (entry.workspace_path != null) return error.UnexpectedWorkspacePath;
        },
    }
    try validatePath(entry.root_source_file);
    try validateIdentifier(entry.name);
    try validateBranch(entry.branch);
    if (entry.test_command == null or entry.test_command.?.len == 0) {
        return error.MissingTestCommand;
    }
    if (entry.publish_paths.len == 0) return error.MissingPublishPaths;
    for (entry.publish_paths, 0..) |publish_path, index| {
        try validatePath(publish_path);
        for (entry.publish_paths[index + 1 ..]) |other| {
            if (std.mem.eql(u8, publish_path, other)) {
                return error.DuplicatePublishPath;
            }
        }
    }
    for ([_][]const u8{
        "build.zig",
        "build.zig.zon",
        "README.md",
        "LICENSE.txt",
    }) |required_path| {
        if (!contains(entry.publish_paths, required_path)) {
            return error.MissingRequiredPublishPath;
        }
    }
    for (entry.historical_names, 0..) |historical_name, index| {
        try validateIdentifier(historical_name);
        if (std.mem.eql(u8, historical_name, entry.name)) {
            return error.InvalidHistoricalName;
        }
        for (entry.historical_names[index + 1 ..]) |other| {
            if (std.mem.eql(u8, historical_name, other)) {
                return error.DuplicateHistoricalName;
            }
        }
    }

    if (entry.identity_override) return;

    const prefix = switch (entry.kind) {
        .sdk => "sdk/",
        .rest => "rest/",
    };
    if (!std.mem.startsWith(u8, entry.historical_source_path, prefix)) {
        return error.InvalidSourcePath;
    }
    const suffix = entry.historical_source_path[prefix.len..];
    const identifier = try allocator.dupe(u8, suffix);
    defer allocator.free(identifier);
    std.mem.replaceScalar(u8, identifier, '/', '_');

    const expected_name = try std.fmt.allocPrint(
        allocator,
        "azure_{s}_{s}",
        .{ @tagName(entry.kind), identifier },
    );
    defer allocator.free(expected_name);
    if (!std.mem.eql(u8, entry.name, expected_name)) return error.InvalidPackageName;

    const expected_branch = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ @tagName(entry.kind), identifier },
    );
    defer allocator.free(expected_branch);
    if (!std.mem.eql(u8, entry.branch, expected_branch)) return error.InvalidBranch;
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) {
        return error.InvalidSourcePath;
    }
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or
            std.mem.eql(u8, segment, ".") or
            std.mem.eql(u8, segment, ".."))
        {
            return error.InvalidSourcePath;
        }
    }
}

fn validateIdentifier(identifier: []const u8) !void {
    if (identifier.len == 0) return error.InvalidPackageName;
    if (identifier.len > 32) return error.PackageNameTooLong;
    for (identifier) |byte| switch (byte) {
        'a'...'z', '0'...'9', '_' => {},
        else => return error.InvalidPackageName,
    };
}

fn validateBranch(branch: []const u8) !void {
    try validatePath(branch);
    if (!std.mem.startsWith(u8, branch, "sdk/") and
        !std.mem.startsWith(u8, branch, "rest/"))
    {
        return error.InvalidBranch;
    }
}

fn contains(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, wanted)) return true;
    }
    return false;
}
