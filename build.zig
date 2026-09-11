const std = @import("std");
const package_registry = @import("eng/packages.zig");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Run all package and workspace tests");
    const package_test_tail = addPackageTests(b);
    const direct_consumer = addFixtureTest(
        b,
        "eng/fixtures/direct_package_consumer",
        package_test_tail,
    );
    test_step.dependOn(&direct_consumer.step);

    addPackageToolSteps(b, test_step);
    addCodegenSteps(b);
    addRepositoryValidationSteps(b);
}

fn addPackageTests(b: *std.Build) ?*std.Build.Step {
    const order = package_registry.topologicalOrder(
        b.allocator,
        &package_registry.all,
    ) catch @panic("invalid package registry");
    defer b.allocator.free(order);

    var previous: ?*std.Build.Step = null;
    for (order) |index| {
        const package = package_registry.all[index];
        if (package.ownership != .main_owned or package.test_command == null) continue;
        const workspace_path = package.workspace_path orelse
            @panic("main-owned package is missing workspace_path");

        const package_tests = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            "test",
            "--summary",
            "all",
        });
        package_tests.setCwd(b.path(workspace_path));
        if (previous) |step| package_tests.step.dependOn(step);
        previous = &package_tests.step;
    }
    return previous;
}

fn addFixtureTest(
    b: *std.Build,
    path: []const u8,
    dependency: ?*std.Build.Step,
) *std.Build.Step.Run {
    const fixture_tests = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        "--summary",
        "all",
    });
    fixture_tests.setCwd(b.path(path));
    if (dependency) |dep| fixture_tests.step.dependOn(dep);
    return fixture_tests;
}

fn addPackageToolSteps(b: *std.Build, test_step: *std.Build.Step) void {
    const package_tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/package_tool_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(package_tool_tests).step);

    const package_tool = b.addExecutable(.{
        .name = "package-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/package_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const package_check_run = b.addRunArtifact(package_tool);
    package_check_run.addArg("check");
    package_check_run.setCwd(b.path("."));
    test_step.dependOn(&package_check_run.step);
    const package_check_step = b.step(
        "package-check",
        "Validate package metadata, documentation, licenses, and manifests",
    );
    package_check_step.dependOn(&package_check_run.step);

    const package_list_run = b.addRunArtifact(package_tool);
    package_list_run.addArg("list");
    package_list_run.setCwd(b.path("."));
    const package_list_step = b.step("package-list", "List packages in release order");
    package_list_step.dependOn(&package_list_run.step);

    const package_graph_run = b.addRunArtifact(package_tool);
    package_graph_run.addArg("graph");
    package_graph_run.setCwd(b.path("."));
    const package_graph_step = b.step("package-graph", "Print the package dependency graph");
    package_graph_step.dependOn(&package_graph_run.step);

    const package_matrix_run = b.addRunArtifact(package_tool);
    package_matrix_run.addArg("ci-matrix");
    package_matrix_run.setCwd(b.path("."));
    const package_matrix_step = b.step(
        "package-ci-matrix",
        "Print the independently buildable package CI matrix",
    );
    package_matrix_step.dependOn(&package_matrix_run.step);

    const history_tool = b.addExecutable(.{
        .name = "package-history-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/package_history_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const history_check_run = b.addRunArtifact(history_tool);
    history_check_run.addArg("check");
    history_check_run.setCwd(b.path("."));
    const history_check_step = b.step(
        "package-history-check",
        "Validate branch-owned package history mappings",
    );
    history_check_step.dependOn(&history_check_run.step);
    test_step.dependOn(&history_check_run.step);

    const branch_tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/package_branch_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(branch_tool_tests).step);

    const bootstrap_tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/package_bootstrap_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const bootstrap_unit_run = b.addRunArtifact(bootstrap_tool_tests);
    const bootstrap_fixtures = b.addSystemCommand(&.{
        "bash", "eng/fixtures/package_bootstrap/test.sh",
    });
    bootstrap_fixtures.setCwd(b.path("."));
    bootstrap_fixtures.step.dependOn(&bootstrap_unit_run.step);
    const bootstrap_test_step = b.step(
        "package-bootstrap-test",
        "Test sealed branch-native bootstrap against offline fixture repositories",
    );
    bootstrap_test_step.dependOn(&bootstrap_fixtures.step);
    test_step.dependOn(&bootstrap_fixtures.step);

    const candidate_manifest_tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/candidate_manifest_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(candidate_manifest_tool_tests).step);

    const example_compatibility_tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/example_compatibility_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(example_compatibility_tool_tests).step);

    const package_sync_run = b.addRunArtifact(package_tool);
    package_sync_run.addArg("sync-local");
    package_sync_run.setCwd(b.path("."));
    package_sync_run.has_side_effects = true;
    const package_sync_step = b.step(
        "package-sync",
        "Synchronize package licenses and local manifest identities",
    );
    package_sync_step.dependOn(&package_sync_run.step);
}

fn addCodegenSteps(b: *std.Build) void {
    const tspconfigs_exe = b.addExecutable(.{
        .name = "tspconfigs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/tspconfigs/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const tspconfigs_update_run = b.addRunArtifact(tspconfigs_exe);
    tspconfigs_update_run.addArg("update");
    tspconfigs_update_run.setCwd(b.path("."));
    tspconfigs_update_run.has_side_effects = true;
    const tspconfigs_update_step = b.step(
        "tspconfigs-update",
        "Reconcile codegen/tspconfigs.yaml against ../azure-rest-api-specs",
    );
    tspconfigs_update_step.dependOn(&tspconfigs_update_run.step);

    const tspconfigs_resolve_run = b.addRunArtifact(tspconfigs_exe);
    tspconfigs_resolve_run.addArg("resolve");
    tspconfigs_resolve_run.setCwd(b.path("."));
    tspconfigs_resolve_run.has_side_effects = true;
    const tspconfigs_resolve_step = b.step(
        "tspconfigs-resolve",
        "Fill in name/branch/zig_import by parsing each tspconfig.yaml",
    );
    tspconfigs_resolve_step.dependOn(&tspconfigs_resolve_run.step);
}

fn addRepositoryValidationSteps(b: *std.Build) void {
    const docs_check_exe = b.addExecutable(.{
        .name = "check-doc-links",
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/check_doc_links.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const docs_check = b.addRunArtifact(docs_check_exe);
    docs_check.setCwd(b.path("."));
    const docs_check_step = b.step(
        "docs-check",
        "Validate relative links in tracked Markdown documentation",
    );
    docs_check_step.dependOn(&docs_check.step);

    const release_tool = b.addExecutable(.{
        .name = "package-release",
        .root_module = b.createModule(.{
            .root_source_file = b.path("eng/release/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const release_self_test = b.addRunArtifact(release_tool);
    release_self_test.addArg("self-test");
    release_self_test.setCwd(b.path("."));
    release_self_test.has_side_effects = true;
    const release_self_test_step = b.step(
        "release-self-test",
        "Run the offline generic package release regression suite",
    );
    release_self_test_step.dependOn(&release_self_test.step);
}
