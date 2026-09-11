const std = @import("std");
const registry = @import("packages.zig");
const history = @import("package_history_map.zig");

// Ordered, exact fields keep the seal readable without accepting shell syntax.
const Seal = struct {
    format: []const u8 = "package-bootstrap-v1",
    package: []const u8,
    destination: []const u8,
    source_package: []const u8,
    source_tag: []const u8,
    source_commit: []const u8,
    repository: []const u8,
    fetch_url: []const u8,
    push_url: []const u8,
    tooling_commit: []const u8,
    metadata_sha256: []const u8,
    archive_sha256: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 3 and std.mem.eql(u8, args[1], "digest-file")) {
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(256 * 1024 * 1024));
        try print(init.io, "{s}\n", .{digest(text)});
        return 0;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "digest-text")) {
        try print(init.io, "{s}\n", .{digest(args[2])});
        return 0;
    }
    try registry.validate(allocator, &registry.all);
    try history.validate(allocator);
    if (args.len == 6 and std.mem.eql(u8, args[1], "target")) {
        const destination = try target(args[2]);
        try source(args[3], args[4], args[5]);
        if (std.mem.eql(u8, args[2], args[3])) return error.TemplateIsDestination;
        try print(init.io, "refs/heads/{s}\n", .{destination});
        return 0;
    }
    if (args.len == 13 and std.mem.eql(u8, args[1], "seal")) {
        const seal: Seal = .{
            .package = args[2],
            .destination = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{try target(args[2])}),
            .source_package = args[3],
            .source_tag = args[4],
            .source_commit = args[5],
            .repository = args[6],
            .fetch_url = args[7],
            .push_url = args[8],
            .tooling_commit = args[9],
            .metadata_sha256 = args[10],
            .archive_sha256 = args[11],
        };
        try validate(seal);
        const text = try render(allocator, seal);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[12], .data = text });
        try print(init.io, "{s}\n", .{digest(text)});
        return 0;
    }
    if (args.len == 9 and std.mem.eql(u8, args[1], "verify")) {
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(16 * 1024));
        try hex(args[3], 64);
        if (!std.mem.eql(u8, args[3], &digest(text))) return error.SealDigestMismatch;
        const seal = try parse(text);
        try validate(seal);
        if (!std.mem.eql(u8, seal.tooling_commit, args[4])) return error.ToolingRevisionMismatch;
        if (!std.mem.eql(u8, seal.metadata_sha256, args[5])) return error.MetadataDigestMismatch;
        if (!std.mem.eql(u8, seal.repository, args[6])) return error.RepositoryMismatch;
        if (!std.mem.eql(u8, seal.fetch_url, args[7]) or
            !std.mem.eql(u8, seal.push_url, args[8])) return error.RemoteUrlMismatch;
        try print(init.io, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            seal.package,    seal.destination,   seal.source_package,
            seal.source_tag, seal.source_commit, seal.archive_sha256,
        });
        return 0;
    }
    std.debug.print(
        "usage: package-bootstrap-tool target PACKAGE SOURCE_PACKAGE TAG COMMIT\n" ++
            "       package-bootstrap-tool seal PACKAGE SOURCE_PACKAGE TAG COMMIT REPOSITORY FETCH_URL PUSH_URL TOOLING_COMMIT METADATA_SHA256 ARCHIVE_SHA256 OUTPUT\n" ++
            "       package-bootstrap-tool verify MANIFEST SHA256 TOOLING_COMMIT METADATA_SHA256 REPOSITORY FETCH_URL PUSH_URL\n" ++
            "       package-bootstrap-tool digest-file PATH | digest-text TEXT\n",
        .{},
    );
    return 2;
}

fn target(name: []const u8) ![]const u8 {
    const index = registry.find(&registry.all, name) orelse return error.UnknownPackage;
    const package = registry.all[index];
    const provenance = history.find(name) orelse return error.MissingHistory;
    if (package.ownership != .branch_owned or package.workspace_path != null or
        provenance.origin != .branch_native or provenance.mappings.len != 0)
        return error.PackageIsNotBranchNative;
    if (!std.mem.eql(u8, package.branch, provenance.branch)) return error.HistoryBranchMismatch;
    return package.branch;
}

fn source(package: []const u8, tag: []const u8, commit: []const u8) !void {
    const index = registry.find(&registry.all, package) orelse return error.UnknownSourcePackage;
    if (registry.all[index].ownership != .branch_owned) return error.SourceIsNotBranchOwned;
    if (!std.mem.startsWith(u8, tag, package)) return error.SourceTagMismatch;
    const suffix = tag[package.len..];
    if (!std.mem.startsWith(u8, suffix, "/v")) return error.SourceTagMismatch;
    const version_text = suffix[2..];
    const version = std.SemanticVersion.parse(version_text) catch return error.InvalidReleaseTag;
    if (version.pre != null or version.build != null) return error.InvalidReleaseTag;
    for (version_text) |c| {
        if (!std.ascii.isDigit(c) and c != '.') return error.InvalidReleaseTag;
    }
    try hex(commit, 40);
}

fn validate(seal: Seal) !void {
    inline for (std.meta.fields(Seal)) |field| {
        const value = @field(seal, field.name);
        if (value.len == 0 or value.len > 2048) return error.InvalidSealValue;
        for (value) |c| {
            if (c < 0x21 or c > 0x7e) return error.InvalidSealValue;
        }
    }
    if (!std.mem.eql(u8, seal.format, "package-bootstrap-v1")) return error.UnknownSealFormat;
    const branch = try target(seal.package);
    if (!std.mem.startsWith(u8, seal.destination, "refs/heads/") or
        !std.mem.eql(u8, seal.destination["refs/heads/".len..], branch))
        return error.DestinationMismatch;
    if (std.mem.eql(u8, seal.package, seal.source_package)) return error.TemplateIsDestination;
    try source(seal.source_package, seal.source_tag, seal.source_commit);
    try hex(seal.tooling_commit, 40);
    try hex(seal.metadata_sha256, 64);
    try hex(seal.archive_sha256, 64);
}

fn parse(text: []const u8) !Seal {
    var seal: Seal = undefined;
    var lines = std.mem.splitScalar(u8, text, '\n');
    inline for (std.meta.fields(Seal)) |field| {
        const line = lines.next() orelse return error.MissingSealField;
        var fields = std.mem.splitScalar(u8, line, '\t');
        if (!std.mem.eql(u8, fields.next().?, field.name)) return error.UnexpectedSealField;
        @field(seal, field.name) = fields.next() orelse return error.MissingSealValue;
        if (fields.next() != null) return error.ExtraSealValue;
    }
    if (!std.mem.eql(u8, lines.next() orelse return error.MissingFinalNewline, "") or
        lines.next() != null) return error.ExtraSealField;
    return seal;
}

fn render(allocator: std.mem.Allocator, seal: Seal) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    inline for (std.meta.fields(Seal)) |field| {
        try output.writer.print("{s}\t{s}\n", .{ field.name, @field(seal, field.name) });
    }
    return output.toOwnedSlice();
}

fn hex(text: []const u8, length: usize) !void {
    if (text.len != length) return error.InvalidDigest;
    for (text) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.InvalidDigest;
    }
}

fn digest(text: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var file = std.Io.File.stdout();
    var writer = file.writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "bootstrap requires canonical explicit branch-native metadata" {
    try std.testing.expectEqualStrings("sdk/core_symcrypt", try target("azure_sdk_core_symcrypt"));
    try std.testing.expectError(error.UnknownPackage, target("sdk/core_symcrypt"));
    try std.testing.expectError(error.UnknownPackage, target("azure_sdk_not_registered"));
    try std.testing.expectError(error.PackageIsNotBranchNative, target("azure_sdk_core"));
}

test "source requires a known package release and full immutable commit" {
    try source("azure_sdk_testing", "azure_sdk_testing/v0.1.0", "a" ** 40);
    try std.testing.expectError(error.UnknownSourcePackage, source("unknown", "unknown/v0.1.0", "a" ** 40));
    try std.testing.expectError(error.SourceTagMismatch, source("azure_sdk_testing", "azure_sdk_core/v0.1.0", "a" ** 40));
    try std.testing.expectError(error.InvalidReleaseTag, source("azure_sdk_testing", "azure_sdk_testing/v0.1.0-rc1", "a" ** 40));
    try std.testing.expectError(error.InvalidDigest, source("azure_sdk_testing", "azure_sdk_testing/v0.1.0", "main"));
}

test "seal is strict ordered data and binds exact destination" {
    var seal: Seal = .{
        .package = "azure_sdk_core_symcrypt",
        .destination = "refs/heads/sdk/core_symcrypt",
        .source_package = "azure_sdk_testing",
        .source_tag = "azure_sdk_testing/v0.1.0",
        .source_commit = "a" ** 40,
        .repository = "github.com/cataggar/azure-sdk-for-zig",
        .fetch_url = "https://github.com/cataggar/azure-sdk-for-zig.git",
        .push_url = "git@github.com:cataggar/azure-sdk-for-zig.git",
        .tooling_commit = "b" ** 40,
        .metadata_sha256 = "c" ** 64,
        .archive_sha256 = "d" ** 64,
    };
    try validate(seal);
    const text = try render(std.testing.allocator, seal);
    defer std.testing.allocator.free(text);
    const parsed = try parse(text);
    try validate(parsed);
    try std.testing.expectEqualStrings(seal.destination, parsed.destination);
    try std.testing.expectError(error.UnexpectedSealField, parse("package\tazure_sdk_core_symcrypt\n"));
    const extra = try std.mem.concat(std.testing.allocator, u8, &.{ text, "format\textra\n" });
    defer std.testing.allocator.free(extra);
    try std.testing.expectError(error.ExtraSealField, parse(extra));
    seal.destination = "refs/heads/main";
    try std.testing.expectError(error.DestinationMismatch, validate(seal));
    seal.destination = "refs/heads/sdk/core_symcrypt";
    seal.source_tag = "azure_sdk_testing/v0.1.0\tignored";
    try std.testing.expectError(error.InvalidSealValue, validate(seal));
}
