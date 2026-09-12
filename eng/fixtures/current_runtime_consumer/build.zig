const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("azure_sdk_core", .{
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "azure_sdk_core", .module = core.module("azure_sdk_core") },
                .{
                    .name = "azure_sdk_core_http_conformance",
                    .module = core.module("azure_sdk_core_http_conformance"),
                },
                .{
                    .name = "azure_sdk_core_crypto_conformance",
                    .module = core.module("azure_sdk_core_crypto_conformance"),
                },
            },
        }),
    });
    const test_step = b.step("test", "Test the fetched Core runtime and conformance modules");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
