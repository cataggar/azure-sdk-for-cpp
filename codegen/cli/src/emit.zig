//! Emitter: walks a `CodeModel` and writes a tree of Zig source files
//! plus `build.zig` / `build.zig.zon` / `README.md` for an orphan
//! branch.
//!
//! The output looks like:
//!
//!   <out-dir>/
//!     build.zig
//!     build.zig.zon
//!     README.md
//!     tsp-location.yaml      (optional, written when caller supplies)
//!     src/
//!       root.zig             # re-exports
//!       clients.zig          # one struct per client
//!       models.zig
//!       enums.zig

const std = @import("std");
const cm = @import("codemodel");
const naming = @import("naming.zig");
const types = @import("types.zig");
const ids = @import("identifiers.zig");

pub const CodeModel = cm.CodeModel;

pub const EmitOptions = struct {
    /// Optional override of the package name. Defaults to
    /// `code_model.package_name`.
    package_name: ?[]const u8 = null,
    /// Optional human-readable label used in `README.md`'s H1 and the
    /// top-of-file doc comment in `src/root.zig`. Defaults to whatever
    /// `package_name` resolves to.
    ///
    /// In practice operators set this to the dash-cased package label
    /// (e.g. `arm-avs`, `keyvault-secrets`) so the docs read naturally
    /// while Zig module identifiers stay snake_case. Source: stripped
    /// from the `js:` field in `codegen/tspconfigs.yaml`
    /// (e.g. `@azure/arm-avs` → `arm-avs`).
    display_name: ?[]const u8 = null,
    /// Commit SHA of the independently published `azure_sdk_core` package
    /// that the generated `build.zig.zon` should pin. May be null during
    /// local development; in that case the generated
    /// build.zig.zon references `azure_sdk_core` by a local `path =` entry
    /// pointing relative to the worktree root.
    azure_sdk_core_commit: ?[]const u8 = null,
    /// Zig package hash for `azure_sdk_core_commit`. Required whenever a
    /// commit is supplied so release output is complete and reproducible.
    azure_sdk_core_hash: ?[]const u8 = null,
    /// Local path used for the `azure_sdk_core` dependency when
    /// `azure_sdk_core_commit` is null. Defaults to a sibling Core package
    /// worktree used by orphan package development.
    azure_sdk_core_path: []const u8 = "../azure-sdk-core",
    /// Run the in-process formatter (`std.zig.Ast.parse` +
    /// `renderAlloc`) on every `.zig` and `.zon` file before writing
    /// it out. Set to `false` to skip — useful when debugging emitter
    /// output that the parser rejects, since unparseable text would
    /// otherwise be written through as-is anyway (we fall back on
    /// parse failure to keep build errors visible).
    run_zig_fmt: bool = true,
    /// Markdown inserted between the `README.md` H1 and the API-area
    /// table written by `emitPackageShell`. Multi-area packages use it to
    /// describe the service and its regeneration contract; when null a
    /// generic "generated package" blurb is used instead.
    readme_intro: ?[]const u8 = null,
};

pub fn emit(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    model: cm.CodeModel,
    opts: EmitOptions,
) !void {
    try out_dir.createDirPath(io, "src");

    const pkg_name = opts.package_name orelse model.package_name;
    const display_name = opts.display_name orelse pkg_name;

    {
        const s = try renderRoot(allocator, model, display_name);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "src/root.zig", s, opts.run_zig_fmt);
    }
    {
        const s = try renderClients(allocator, model);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "src/clients.zig", s, opts.run_zig_fmt);
    }
    {
        const s = try renderModels(allocator, model);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "src/models.zig", s, opts.run_zig_fmt);
    }
    {
        const s = try renderEnums(allocator, model);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "src/enums.zig", s, opts.run_zig_fmt);
    }
    {
        const s = try renderBuildZig(allocator, pkg_name);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "build.zig", s, opts.run_zig_fmt);
    }
    {
        const s = try renderBuildZigZon(
            allocator,
            pkg_name,
            model.package_version,
            opts.azure_sdk_core_commit,
            opts.azure_sdk_core_hash,
            opts.azure_sdk_core_path,
        );
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "build.zig.zon", s, opts.run_zig_fmt);
    }
    {
        const s = try renderReadme(allocator, display_name, model);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "README.md", s, opts.run_zig_fmt);
    }
    // Operator-owned test file. The emitter writes a stub the first
    // time a package is generated; on subsequent regenerations the
    // sync helper marks it as operator-managed (SKIP-and-warn) so
    // operator-added tests are preserved.
    try writeFile(
        allocator,
        io,
        out_dir,
        "src/clients_test.zig",
        \\//! Tests for the generated `clients.zig`.
        \\//!
        \\//! Kept in a separate file so the emitter can overwrite
        \\//! `clients.zig` without losing test coverage. Wired into the
        \\//! package's test step via `root.zig`.
        \\//!
        \\//! This file is **operator-owned**: `codegen/scripts/sync.sh`
        \\//! marks it as operator-managed and never overwrites an
        \\//! existing copy. Add tests freely.
        \\
        \\const std = @import("std");
        \\
    ,
        opts.run_zig_fmt,
    );
    try writeFile(allocator, io, out_dir, ".gitignore", "zig-cache/\nzig-out/\nzig-pkg/\n.zig-cache/\n", opts.run_zig_fmt);
}

/// One API area inside a multi-namespace package.
pub const Namespace = struct {
    /// Directory name under `src/` and the identifier the aggregating
    /// root re-exports it as (e.g. `git`, `build`, `work_item_tracking`).
    name: []const u8,
    /// Human-readable label used in the namespace's doc comment.
    display_name: []const u8,
    model: cm.CodeModel,
};

/// Emit one API area into `<out_dir>/src/<namespace.name>/`.
///
/// Services like Azure DevOps publish dozens of independent areas that
/// share a host, an auth scheme and a release cadence, so they ship as a
/// single package rather than 59 of them. Each area keeps its own
/// `clients.zig` / `models.zig` / `enums.zig` — models collide across
/// areas (`Build.Timeline` vs `Work.Timeline`), and sibling imports stay
/// relative, so nothing has to be renamed.
///
/// Use `emitPackageShell` to write the `build.zig` / `build.zig.zon` /
/// aggregating `src/root.zig` that tie the namespaces together.
pub fn emitNamespace(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    namespace: Namespace,
    opts: EmitOptions,
) !void {
    const dir = try std.fmt.allocPrint(allocator, "src/{s}", .{namespace.name});
    defer allocator.free(dir);
    try out_dir.createDirPath(io, dir);

    const files = .{
        .{ "root.zig", try renderNamespaceRoot(allocator, namespace) },
        .{ "clients.zig", try renderClients(allocator, namespace.model) },
        .{ "models.zig", try renderModels(allocator, namespace.model) },
        .{ "enums.zig", try renderEnums(allocator, namespace.model) },
    };
    inline for (files) |file| {
        defer allocator.free(file[1]);
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, file[0] });
        defer allocator.free(sub_path);
        try writeFile(allocator, io, out_dir, sub_path, file[1], opts.run_zig_fmt);
    }
}

/// Write the package-level files for a multi-namespace package: the
/// aggregating `src/root.zig`, `build.zig`, `build.zig.zon`, `README.md`
/// and `.gitignore`.
pub fn emitPackageShell(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    package_version: []const u8,
    namespaces: []const Namespace,
    opts: EmitOptions,
) !void {
    const pkg_name = opts.package_name orelse return error.MissingPackageName;
    const display_name = opts.display_name orelse pkg_name;

    try out_dir.createDirPath(io, "src");
    {
        const s = try renderAggregateRoot(allocator, display_name, namespaces);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "src/root.zig", s, opts.run_zig_fmt);
    }
    {
        const s = try renderBuildZig(allocator, pkg_name);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "build.zig", s, opts.run_zig_fmt);
    }
    {
        const s = try renderBuildZigZon(
            allocator,
            pkg_name,
            package_version,
            opts.azure_sdk_core_commit,
            opts.azure_sdk_core_hash,
            opts.azure_sdk_core_path,
        );
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "build.zig.zon", s, opts.run_zig_fmt);
    }
    {
        const s = try renderNamespaceReadme(allocator, display_name, namespaces, opts.readme_intro);
        defer allocator.free(s);
        try writeFile(allocator, io, out_dir, "README.md", s, opts.run_zig_fmt);
    }
    try writeFile(allocator, io, out_dir, ".gitignore", "zig-cache/\nzig-out/\nzig-pkg/\n.zig-cache/\n", opts.run_zig_fmt);
}

/// Write `content` to `<out_dir>/<sub_path>`. When `fmt_enabled` is true
/// and the path looks like Zig (`.zig`) or ZON (`.zig.zon`), run the
/// in-process formatter (std.zig.Ast.parse + renderAlloc) first.
/// Parse failures fall back to writing the raw content so the operator
/// can diagnose them via the next `zig build` instead of having them
/// swallowed silently.
fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    sub_path: []const u8,
    content: []const u8,
    fmt_enabled: bool,
) !void {
    if (fmt_enabled) {
        const mode: ?std.zig.Ast.Mode =
            if (std.mem.endsWith(u8, sub_path, ".zon")) .zon else if (std.mem.endsWith(u8, sub_path, ".zig")) .zig else null;
        if (mode) |m| {
            if (try maybeFormat(allocator, content, m)) |formatted| {
                defer allocator.free(formatted);
                try out_dir.writeFile(io, .{ .sub_path = sub_path, .data = formatted });
                return;
            }
        }
    }
    try out_dir.writeFile(io, .{ .sub_path = sub_path, .data = content });
}

/// Parse + re-render `source` with `std.zig.Ast`. Returns null when the
/// parser reports any error — callers should fall back to writing the
/// raw source so build failures stay visible.
fn maybeFormat(
    allocator: std.mem.Allocator,
    source: []const u8,
    mode: std.zig.Ast.Mode,
) !?[]u8 {
    const zsource = try allocator.dupeZ(u8, source);
    defer allocator.free(zsource);
    var tree = try std.zig.Ast.parse(allocator, zsource, mode);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return null;
    return try tree.renderAlloc(allocator);
}

// ─── root.zig ─────────────────────────────────────────────────────────

/// Per-area `src/<area>/root.zig`. Unlike the single-package root it
/// carries no `clients_test.zig` import — operator-owned tests live once
/// at the package level, not once per area.
fn renderNamespaceRoot(allocator: std.mem.Allocator, namespace: Namespace) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        \\//! {[name]s} — generated from TypeSpec.
        \\//!
        \\//! Do not edit by hand. Regenerate with `codegen`.
        \\
        \\const clients = @import("clients.zig");
        \\pub const models = @import("models.zig");
        \\pub const enums = @import("enums.zig");
        \\
    , .{ .name = namespace.display_name });

    for (namespace.model.clients) |c| {
        try w.print("pub const {s} = clients.{s};\n", .{ c.name, c.name });
    }
    return try aw.toOwnedSlice();
}

/// Aggregating `src/root.zig` for a multi-namespace package. Area names
/// are quoted when they collide with a Zig keyword — Azure DevOps has an
/// area literally called `test`.
fn renderAggregateRoot(
    allocator: std.mem.Allocator,
    display_name: []const u8,
    namespaces: []const Namespace,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        \\//! {[name]s} — generated from TypeSpec.
        \\//!
        \\//! Do not edit by hand. Regenerate with `codegen`.
        \\//!
        \\//! Each API area is a namespace with its own clients, models and
        \\//! enums; area names are the ones Azure DevOps uses in its REST
        \\//! documentation.
        \\
        \\
    , .{ .name = display_name });

    for (namespaces) |ns| {
        const id = try ids.quoteIfNeeded(allocator, ns.name);
        defer allocator.free(id);
        try w.print("pub const {s} = @import(\"{s}/root.zig\");\n", .{ id, ns.name });
    }

    try w.writeAll(
        \\
        \\test {
        \\    _ = @import("clients_test.zig");
        \\}
        \\
    );
    return try aw.toOwnedSlice();
}

fn renderNamespaceReadme(
    allocator: std.mem.Allocator,
    display_name: []const u8,
    namespaces: []const Namespace,
    intro: ?[]const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("# {s}\n\n", .{display_name});
    try w.writeAll(intro orelse
        \\Generated Azure SDK client for Zig.
        \\
        \\Do not edit generated package files by hand — they will be
        \\overwritten on the next regeneration.
        \\
    );
    try w.writeAll("\n## API areas\n\n");
    for (namespaces) |ns| {
        var clients: usize = 0;
        var methods: usize = 0;
        for (ns.model.clients) |c| {
            clients += 1;
            methods += c.methods.len;
        }
        try w.print("- `{s}` — {d} clients, {d} operations\n", .{ ns.name, clients, methods });
    }
    return try aw.toOwnedSlice();
}

fn renderRoot(allocator: std.mem.Allocator, model: cm.CodeModel, display_name: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        \\//! {[name]s} — generated from TypeSpec.
        \\//!
        \\//! Do not edit by hand. Regenerate with `codegen`.
        \\
        \\const clients = @import("clients.zig");
        \\pub const models = @import("models.zig");
        \\pub const enums = @import("enums.zig");
        \\
    , .{ .name = display_name });

    // Re-export every client type. Callers reach sub-clients through
    // accessor methods on their parent, but a hand-written SDK still has
    // to *name* the type to store one in a struct field, so the names
    // are exported too.
    for (model.clients) |c| {
        try w.print("pub const {s} = clients.{s};\n", .{ c.name, c.name });
    }

    // Pull in an operator-owned test file (if it exists) so package
    // tests stay reachable from `zig build test` across regenerations.
    // The file itself is hand-written and never overwritten by the
    // emitter; if it does not exist, the build will fail loudly — drop
    // the import or land a `clients_test.zig` in `src/`.
    try w.writeAll(
        \\
        \\test {
        \\    _ = @import("clients_test.zig");
        \\}
        \\
    );
    return try aw.toOwnedSlice();
}

// ─── clients.zig ──────────────────────────────────────────────────────

pub fn renderClients(allocator: std.mem.Allocator, model: cm.CodeModel) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\//! Generated service clients.
        \\
        \\const std = @import("std");
        \\const serde = @import("serde");
        \\const core = @import("azure_sdk_core");
        \\const models = @import("models.zig");
        \\const enums = @import("enums.zig");
        \\
        \\// Keep raw-body ownership behind one helper so the generated shape can
        \\// adopt the core streaming response API without changing status/header logic.
        \\fn bufferRawResponseBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
        \\    return allocator.dupe(u8, body);
        \\}
        \\
        \\fn responseStatusExpected(status: u16, expected: []const u16) bool {
        \\    if (expected.len == 0) return status >= 200 and status < 300;
        \\    for (expected) |value| {
        \\        if (status == value) return true;
        \\    }
        \\    return false;
        \\}
        \\
    );
    if (hasODataStringPathParameter(model)) {
        try w.writeAll(
            \\fn encodeODataStringLiteral(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
            \\    var escaped: std.ArrayList(u8) = .empty;
            \\    defer escaped.deinit(allocator);
            \\    for (value) |byte| {
            \\        try escaped.append(allocator, byte);
            \\        if (byte == '\'') try escaped.append(allocator, '\'');
            \\    }
            \\    return core.url.encodePathSegment(allocator, escaped.items);
            \\}
            \\
        );
    }

    // Per-family constants (endpoint default, api-version default, auth
    // scopes) emitted next to the root client so callers can override
    // them via `InitOptions`.
    for (model.clients) |c| {
        if (!c.is_root) continue;
        try renderRootConstants(w, c);
    }

    for (model.clients) |c| {
        try renderClient(allocator, w, model, c);
        try w.writeAll("\n");
    }
    return try aw.toOwnedSlice();
}

fn hasODataStringPathParameter(model: cm.CodeModel) bool {
    for (model.clients) |client| {
        for (client.methods) |method| {
            for (method.path_parameters) |parameter| {
                if (std.mem.eql(u8, parameter.path_encoding orelse "", "odata-string")) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Declarations and parameter names the emitter puts on every client.
///
/// Zig rejects a function parameter that shadows a container-level
/// declaration, so a generated accessor or method sharing one of these
/// names would not compile — Azure DevOps has a `build` operation group
/// literally called `Options`, which collides with `init(…, options:
/// InitOptions)`. Such names get an `_op` suffix.
const reserved_members = [_][]const u8{
    "alloc",    "allocator", "api_version", "deinit",
    "endpoint", "init",      "InitOptions", "options",
    "pipeline", "self",
};

/// Renders `name` as a client member, avoiding the emitter's own names.
/// Caller owns the returned slice.
fn memberName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    for (reserved_members) |reserved| {
        if (std.mem.eql(u8, name, reserved)) {
            return std.fmt.allocPrint(allocator, "{s}_op", .{name});
        }
    }
    return ids.quoteIfNeeded(allocator, name);
}

/// Local names the emitter declares in every generated method body.
///
/// A user parameter sharing one of these would shadow (or be shadowed by)
/// an emitter-owned local or capture — Azure DevOps' `WorkItemIcons.get`
/// takes a query parameter literally named `v`, which is why the optional
/// query-append capture is `query_value` and is reserved here. Such
/// parameters get a `_param` suffix.
const reserved_locals = [_][]const u8{
    "alloc",   "base_url", "core",        "enums",
    "models",  "req",      "query_value", "resp",
    "self",    "serde",    "std",         "has_query",
    "url_buf",
};

/// Renders `name` as a generated method parameter, avoiding the locals the
/// emitter declares in method bodies. Caller owns the returned slice.
fn paramName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    for (reserved_locals) |reserved| {
        if (std.mem.eql(u8, name, reserved)) {
            return std.fmt.allocPrint(allocator, "{s}_param", .{name});
        }
    }
    return ids.quoteIfNeeded(allocator, name);
}

/// Response headers deduplicated by generated field name.
///
/// Azure DevOps declares the same response header more than once on some
/// operations (`build`'s `GetBuildLog` lists `Content-Type` twice), which
/// would emit a struct with a duplicate field. Caller owns the slice.
fn uniqueResponseHeaders(
    allocator: std.mem.Allocator,
    headers: []const cm.ResponseHeader,
) ![]cm.ResponseHeader {
    var kept: std.ArrayList(cm.ResponseHeader) = .empty;
    errdefer kept.deinit(allocator);
    next: for (headers) |header| {
        for (kept.items) |existing| {
            if (std.mem.eql(u8, existing.name, header.name)) continue :next;
        }
        try kept.append(allocator, header);
    }
    return kept.toOwnedSlice(allocator);
}

fn renderRootConstants(w: *std.Io.Writer, c: cm.Client) !void {
    if (c.endpoint.default_value) |ep| {
        try w.print("const default_endpoint = \"{s}\";\n", .{ep});
    }
    if (c.api_version_default) |ver| {
        try w.print("const default_api_version = \"{s}\";\n", .{ver});
    }
    try w.writeByte('\n');
}

fn renderClient(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    c: cm.Client,
) !void {
    if (c.doc) |d| try renderDocComment(w, d);
    try w.print("pub const {s} = struct {{\n", .{c.name});

    // Common state — present on root *and* sub-clients so the
    // accessor on the root can splat-assign in one literal.
    try w.writeAll(
        \\    endpoint: []const u8,
        \\    api_version: []const u8,
        \\    pipeline: core.http.HttpPipeline,
        \\
    );
    for (c.init_parameters) |p| {
        const id = try ids.quoteIfNeeded(allocator, p.name);
        defer allocator.free(id);
        const ty = try renderFieldType(allocator, p.param_type, p.optional, .clients);
        defer allocator.free(ty);
        try w.print("    {s}: {s},\n", .{ id, ty });
    }

    if (c.is_root) {
        try renderRootInit(allocator, w, c);
    }

    for (c.sub_clients) |sc| {
        try renderSubClientAccessor(allocator, w, model, c, sc);
    }

    for (c.methods) |m| {
        if (usesProtocolResult(m)) {
            try renderProtocolResultType(allocator, w, m);
        }
    }

    for (c.methods) |m| {
        try renderMethod(allocator, w, model, c, m);
    }

    try w.writeAll("};\n");
}

fn renderRootInit(allocator: std.mem.Allocator, w: *std.Io.Writer, c: cm.Client) !void {
    try w.writeAll(
        \\
        \\    pub const InitOptions = struct {
        \\
    );
    for (c.init_parameters) |p| {
        const id = try ids.quoteIfNeeded(allocator, p.name);
        defer allocator.free(id);
        const ty = try renderFieldType(allocator, p.param_type, p.optional, .clients);
        defer allocator.free(ty);
        try w.print("        {s}: {s},\n", .{ id, ty });
    }
    if (c.endpoint.default_value != null) {
        try w.writeAll("        endpoint: []const u8 = default_endpoint,\n");
    } else {
        try w.writeAll("        endpoint: []const u8,\n");
    }
    if (c.api_version_default != null) {
        try w.writeAll("        api_version: []const u8 = default_api_version,\n");
    } else {
        try w.writeAll("        api_version: []const u8,\n");
    }
    try w.writeAll(
        \\    };
        \\
        \\
    );
    try w.print(
        \\    pub fn init(
        \\        pipeline: core.http.HttpPipeline,
        \\        options: InitOptions,
        \\    ) {s} {{
        \\        return .{{
        \\            .endpoint = options.endpoint,
        \\            .api_version = options.api_version,
        \\            .pipeline = pipeline,
        \\
    , .{c.name});
    for (c.init_parameters) |p| {
        const id = try ids.quoteIfNeeded(allocator, p.name);
        defer allocator.free(id);
        try w.print("            .{s} = options.{s},\n", .{ id, id });
    }
    try w.writeAll(
        \\        };
        \\    }
        \\
    );
}

fn renderSubClientAccessor(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    parent: cm.Client,
    sc: cm.SubClient,
) !void {
    const child = for (model.clients) |client| {
        if (std.mem.eql(u8, client.name, sc.client_name)) break client;
    } else return error.UnknownSubClient;
    const accessor = try memberName(allocator, sc.accessor_camel);
    defer allocator.free(accessor);
    try w.print(
        \\
        \\    pub fn {[acc]s}(self: *@This()) {[name]s} {{
        \\        return .{{
        \\            .endpoint = self.endpoint,
        \\            .api_version = self.api_version,
        \\            .pipeline = self.pipeline,
        \\
    , .{ .acc = accessor, .name = sc.client_name });
    for (child.init_parameters) |p| {
        const inherited = for (parent.init_parameters) |parameter| {
            if (std.mem.eql(u8, parameter.name, p.name)) break true;
        } else false;
        if (!inherited) return error.MissingSubClientParameter;
        const id = try ids.quoteIfNeeded(allocator, p.name);
        defer allocator.free(id);
        try w.print("            .{s} = self.{s},\n", .{ id, id });
    }
    try w.writeAll(
        \\        };
        \\    }
        \\
    );
}

// ─── method bodies ────────────────────────────────────────────────────

/// True when any success response of `m` is XML (content-type
/// `application/xml`). Used to route XML list operations to `XmlPager`.
fn responseIsXml(m: cm.Method) bool {
    for (m.responses) |response| {
        for (response.content_types) |ct| {
            if (std.mem.indexOf(u8, ct, "xml") != null) return true;
        }
    }
    return false;
}

/// The envelope model returned by an XML list operation's success response.
/// The convenient `m.response` collapses a paging op to the item array, so
/// the page envelope (e.g. `ListContainersResponse`) is read from the
/// protocol response variants instead.
fn xmlEnvelopeTypeRef(m: cm.Method) ?cm.TypeRef {
    for (m.responses) |response| {
        if (response.response_type) |t| {
            if (t.isModel()) return t;
        }
    }
    return null;
}

fn usesProtocolResult(m: cm.Method) bool {
    if (m.long_running != null or m.responses.len == 0) return false;
    for (m.responses) |response| {
        if (response.headers.len > 0 or std.mem.eql(u8, response.body_kind, "raw")) return true;
        for (response.status_codes) |status| {
            switch (status) {
                .integer => |value| if (value < 200 or value >= 300) return true,
                else => {},
            }
        }
    }
    const first = m.responses[0];
    for (m.responses[1..]) |response| {
        if (!responseShapesEquivalent(first, response)) return true;
    }
    return false;
}

fn responseShapesEquivalent(a: cm.ResponseVariant, b: cm.ResponseVariant) bool {
    if (!std.mem.eql(u8, a.body_kind, b.body_kind)) return false;
    return typeRefsEquivalent(a.response_type, b.response_type);
}

fn typeRefsEquivalent(a: ?cm.TypeRef, b: ?cm.TypeRef) bool {
    if (a == null or b == null) return a == null and b == null;
    const left = a.?;
    const right = b.?;
    if (!std.mem.eql(u8, left.kind, right.kind)) return false;
    return jsonValuesEquivalent(left.value, right.value);
}

fn jsonValuesEquivalent(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .integer => |value| value == b.integer,
        .float => |value| value == b.float,
        .number_string => |value| std.mem.eql(u8, value, b.number_string),
        .string => |value| std.mem.eql(u8, value, b.string),
        .array => |values| blk: {
            if (values.items.len != b.array.items.len) break :blk false;
            for (values.items, b.array.items) |left, right| {
                if (!jsonValuesEquivalent(left, right)) break :blk false;
            }
            break :blk true;
        },
        .object => |values| blk: {
            if (values.count() != b.object.count()) break :blk false;
            var iterator = values.iterator();
            while (iterator.next()) |entry| {
                const right = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEquivalent(entry.value_ptr.*, right)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn protocolResultName(allocator: std.mem.Allocator, m: cm.Method) ![]u8 {
    const pascal = try naming.toPascalCase(allocator, m.name);
    defer allocator.free(pascal);
    return try std.fmt.allocPrint(allocator, "{s}Result", .{pascal});
}

fn renderProtocolResultType(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    m: cm.Method,
) !void {
    const result_name = try protocolResultName(allocator, m);
    defer allocator.free(result_name);
    try w.print("\n    pub const {s} = union(enum) {{\n", .{result_name});
    for (m.responses) |response| {
        for (response.status_codes) |status| {
            const code = statusInteger(status) orelse continue;
            try w.print("        status_{d}: struct {{\n", .{code});
            try w.print("            status: u16 = {d},\n", .{code});
            try w.writeAll("            headers: struct {\n");
            const headers = try uniqueResponseHeaders(allocator, response.headers);
            defer allocator.free(headers);
            for (headers) |header| {
                const id = try ids.quoteIfNeeded(allocator, header.name);
                defer allocator.free(id);
                const ty = try renderFieldType(allocator, header.header_type, header.optional, .clients);
                defer allocator.free(ty);
                if (header.optional) {
                    try w.print("                {s}: {s} = null,\n", .{ id, ty });
                } else {
                    try w.print("                {s}: {s},\n", .{ id, ty });
                }
            }
            try w.writeAll("            },\n");
            const body_ty = try responseBodyType(allocator, response);
            defer allocator.free(body_ty);
            try w.print("            body: {s},\n", .{body_ty});
            try w.writeAll("        },\n");
        }
    }
    try w.writeAll("    };\n");
}

fn statusInteger(status: std.json.Value) ?u16 {
    return switch (status) {
        .integer => |value| if (value >= 0 and value <= std.math.maxInt(u16))
            @intCast(value)
        else
            null,
        else => null,
    };
}

fn responseBodyType(
    allocator: std.mem.Allocator,
    response: cm.ResponseVariant,
) ![]u8 {
    if (std.mem.eql(u8, response.body_kind, "none") or response.response_type == null) {
        return try allocator.dupe(u8, "void");
    }
    if (std.mem.eql(u8, response.body_kind, "raw") or
        std.mem.eql(u8, response.body_kind, "multipart"))
    {
        return try allocator.dupe(u8, "[]const u8");
    }
    return try types.renderType(allocator, response.response_type.?, .clients);
}

fn renderMethod(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    c: cm.Client,
    m: cm.Method,
) !void {
    if (m.doc) |d| try renderDocComment(w, d);

    // Return type depends on method kind.
    const ReturnKind = enum { void_op, value_op, list_op, xml_list_op, lro_op, protocol_op };
    const ret_kind: ReturnKind = if (m.long_running != null)
        .lro_op
    else if ((std.mem.eql(u8, m.kind, "paging") or std.mem.eql(u8, m.kind, "lropaging")) and responseIsXml(m))
        .xml_list_op
    else if (usesProtocolResult(m))
        .protocol_op
    else if (std.mem.eql(u8, m.kind, "paging") or std.mem.eql(u8, m.kind, "lropaging"))
        .list_op
    else if (m.response.response_type == null)
        .void_op
    else
        .value_op;

    const ret_str = try renderReturnType(allocator, m, ret_kind);
    defer allocator.free(ret_str);

    // Signature: `pub fn <name>(self: *@This(), alloc: std.mem.Allocator, <user params>) !<ret> {`
    const method_name = try memberName(allocator, m.name_camel);
    defer allocator.free(method_name);
    try w.print("\n    pub fn {s}(self: *@This(), alloc: std.mem.Allocator", .{method_name});
    for (m.user_parameters) |p| {
        const id = try paramName(allocator, p.name);
        defer allocator.free(id);
        const ty = try renderFieldType(allocator, p.param_type, p.optional, .clients);
        defer allocator.free(ty);
        try w.print(", {s}: {s}", .{ id, ty });
    }
    try w.print(") !{s} {{\n", .{ret_str});

    // serde walks the whole reachable model graph at comptime. Azure
    // DevOps models are deep enough (a `Build` reaches several hundred
    // structs) to exceed Zig's default 1000-branch budget, and the quota
    // has to be raised in the function that triggers the evaluation.
    try w.writeAll("        @setEvalBranchQuota(100_000);\n");

    // URL build (path + query) — shared by every kind. XML list pagers own
    // the `marker` query pair, so it is excluded from the base URL here.
    try renderUrlBuild(allocator, w, m, ret_kind == .xml_list_op);

    switch (ret_kind) {
        .list_op => try renderListBody(allocator, w, m),
        .xml_list_op => try renderXmlListBody(allocator, w, m),
        .void_op => try renderVoidBody(allocator, w, model, c, m),
        .value_op => try renderValueBody(allocator, w, model, c, m),
        .lro_op => try renderLroBody(allocator, w, model, c, m),
        .protocol_op => try renderProtocolBody(allocator, w, model, c, m),
    }

    try w.writeAll("    }\n");
}

fn renderReturnType(allocator: std.mem.Allocator, m: cm.Method, kind: anytype) ![]u8 {
    return switch (kind) {
        .void_op => try allocator.dupe(u8, "void"),
        .value_op => blk: {
            const t = m.response.response_type.?;
            const ty = try types.renderType(allocator, t, .clients);
            break :blk ty;
        },
        .list_op => blk: {
            // Item type from paging metadata when the envelope is the
            // standard `{ value, nextLink }` shape; otherwise fall back
            // to the response type (already an array).
            const item_type_ref: ?cm.TypeRef = if (m.paging) |p| p.item_type else null;
            if (item_type_ref) |it| {
                const ty = try types.renderType(allocator, it, .clients);
                defer allocator.free(ty);
                break :blk try std.fmt.allocPrint(allocator, "core.pager.PipelinePager({s})", .{ty});
            }
            // No item_type? Fall back to the response type's element.
            if (m.response.response_type) |t| {
                const ty = try types.renderType(allocator, t, .clients);
                defer allocator.free(ty);
                // ty is `[]const X`. Strip the prefix to get X.
                const prefix = "[]const ";
                if (std.mem.startsWith(u8, ty, prefix)) {
                    const elem = ty[prefix.len..];
                    break :blk try std.fmt.allocPrint(allocator, "core.pager.PipelinePager({s})", .{elem});
                }
                break :blk try std.fmt.allocPrint(allocator, "core.pager.PipelinePager({s})", .{ty});
            }
            break :blk try allocator.dupe(u8, "core.pager.PipelinePager(std.json.Value)");
        },
        .xml_list_op => blk: {
            // Each page is the whole XML envelope model (mirrors
            // azure-sdk-for-rust's `Pager<ListContainersResponse, XmlFormat>`).
            // The convenient `m.response` collapses to the item array, so the
            // envelope comes from the protocol response variant.
            if (xmlEnvelopeTypeRef(m)) |t| {
                const ty = try types.renderType(allocator, t, .clients);
                defer allocator.free(ty);
                break :blk try std.fmt.allocPrint(allocator, "core.pager.XmlPager({s})", .{ty});
            }
            break :blk try allocator.dupe(u8, "core.pager.XmlPager(std.json.Value)");
        },
        .lro_op => blk: {
            const final = if (m.long_running) |l| l.final_response_type else null;
            if (final) |t| {
                const ty = try types.renderType(allocator, t, .clients);
                defer allocator.free(ty);
                break :blk try std.fmt.allocPrint(allocator, "core.lro.TypedPoller({s})", .{ty});
            }
            break :blk try allocator.dupe(u8, "core.lro.TypedPoller(void)");
        },
        .protocol_op => blk: {
            const result_name = try protocolResultName(allocator, m);
            break :blk result_name;
        },
    };
}

/// Render the `const url = ...` block. Path placeholders are
/// substituted by walking the operation path character-by-character
/// and replacing `{<wire_name>}` runs with `{s}`. Required query
/// parameters are appended inline to the head `allocPrint`. Optional
/// query parameters (typed as `?T` in the Zig signature) are
/// appended afterwards, each gated by `if (param) |query_value| { ... }`, with
/// values percent-encoded via `core.url.percentEncode`. The final
/// owned `[]u8` is exposed as `const url` and freed via `defer`.
fn renderUrlBuild(allocator: std.mem.Allocator, w: *std.Io.Writer, m: cm.Method, exclude_marker: bool) !void {
    var fmt_buf: std.ArrayList(u8) = .empty;
    defer fmt_buf.deinit(allocator);
    var args_buf: std.ArrayList(u8) = .empty;
    defer args_buf.deinit(allocator);

    var greedy_index: ?usize = null;
    for (m.path_parameters, 0..) |parameter, index| {
        const source = try sourceExpression(allocator, parameter.source);
        defer allocator.free(source);
        const encoding = parameter.path_encoding orelse
            if (parameter.allow_reserved orelse false) "greedy" else "segment";
        if (std.mem.eql(u8, encoding, "greedy")) {
            greedy_index = index;
            try w.print(
                \\        const encoded_path_{d} = try core.url.expandGreedyPathValue(alloc, {s});
                \\        defer alloc.free(encoded_path_{d});
                \\
            , .{ index, source, index });
        } else if (std.mem.eql(u8, encoding, "repository")) {
            try w.print(
                \\        const encoded_path_{d} = try core.url.encodeRepositoryName(alloc, {s});
                \\        defer alloc.free(encoded_path_{d});
                \\
            , .{ index, source, index });
        } else if (std.mem.eql(u8, encoding, "odata-string")) {
            try w.print(
                \\        const encoded_path_{d} = try encodeODataStringLiteral(alloc, {s});
                \\        defer alloc.free(encoded_path_{d});
                \\
            , .{ index, source, index });
        } else {
            try w.print(
                \\        const encoded_path_{d} = try core.url.encodePathSegment(alloc, {s});
                \\        defer alloc.free(encoded_path_{d});
                \\
            , .{ index, source, index });
        }
    }

    const is_single_greedy = greedy_index != null and
        m.path_parameters.len == 1 and
        std.mem.startsWith(u8, m.path, "/{") and
        std.mem.endsWith(u8, m.path, "}");
    if (is_single_greedy) {
        try w.print(
            \\        const endpoint_uri = std.Uri.parse(self.endpoint) catch return error.InvalidUrl;
            \\        var endpoint_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
            \\        const endpoint_host = endpoint_uri.getHost(&endpoint_host_buffer) catch return error.InvalidUrl;
            \\        const base_url = try core.url.resolveAndValidateUrl(
            \\            alloc,
            \\            self.endpoint,
            \\            encoded_path_{d},
            \\            &.{{endpoint_host.bytes}},
            \\        );
            \\        defer alloc.free(base_url);
            \\
        , .{greedy_index.?});
    } else {
        try fmt_buf.appendSlice(allocator, "{s}");
        try args_buf.appendSlice(allocator, "self.endpoint");
        var i: usize = 0;
        while (i < m.path.len) {
            if (m.path[i] == '{') {
                const close = std.mem.indexOfScalarPos(u8, m.path, i + 1, '}') orelse break;
                const wire_name = m.path[i + 1 .. close];
                const parameter_index = pathParameterIndex(m.path_parameters, wire_name) orelse {
                    try fmt_buf.appendSlice(allocator, "<missing-path>");
                    i = close + 1;
                    continue;
                };
                try fmt_buf.appendSlice(allocator, "{s}");
                try args_buf.print(allocator, ", encoded_path_{d}", .{parameter_index});
                i = close + 1;
            } else {
                try fmt_buf.append(allocator, m.path[i]);
                i += 1;
            }
        }
        try w.print(
            \\        const base_url = try std.fmt.allocPrint(alloc, "{s}", .{{ {s} }});
            \\        defer alloc.free(base_url);
            \\
        , .{ fmt_buf.items, args_buf.items });
    }

    if (m.query_parameters.len == 0) {
        try w.writeAll("        const url = base_url;\n");
        return;
    }

    try w.writeAll(
        \\        var url_buf: std.ArrayList(u8) = .empty;
        \\        defer url_buf.deinit(alloc);
        \\        try url_buf.appendSlice(alloc, base_url);
        \\        var has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
        \\
    );

    for (m.query_parameters, 0..) |qp, index| {
        if (exclude_marker and std.mem.eql(u8, qp.wire_name, "marker")) continue;
        if (queryParamArrayElement(m, qp)) |elem| {
            try renderArrayQueryAppend(allocator, w, qp, elem);
        } else if (qp.optional and qp.source.name != null) {
            const user_id = try paramName(allocator, qp.source.name.?);
            defer allocator.free(user_id);
            try renderOptionalAppendNoRequired(w, user_id, qp.wire_name, innerOptionKind(m, qp));
        } else {
            try renderRequiredQueryAppend(allocator, w, m, qp, index);
        }
    }

    try w.writeAll(
        \\        const url = try url_buf.toOwnedSlice(alloc);
        \\        defer alloc.free(url);
        \\
    );
}

fn pathParameterIndex(params: []const cm.WireParameter, wire_name: []const u8) ?usize {
    for (params, 0..) |parameter, index| {
        if (std.mem.eql(u8, parameter.wire_name, wire_name)) return index;
    }
    return null;
}

fn renderRequiredQueryAppend(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    m: cm.Method,
    qp: cm.WireParameter,
    index: usize,
) !void {
    const expr = try sourceExpression(allocator, qp.source);
    defer allocator.free(expr);
    const kind = sourceKind(m, qp.source);
    switch (kind) {
        .string_like => try w.print(
            \\        const encoded_query_{d} = try core.url.percentEncode(alloc, {s});
            \\        defer alloc.free(encoded_query_{d});
            \\        try url_buf.print(alloc, "{{s}}{s}={{s}}", .{{ if (has_query) "&" else "?", encoded_query_{d} }});
            \\        has_query = true;
            \\
        , .{ index, expr, index, qp.wire_name, index }),
        .enum_or_union => try w.print(
            \\        const encoded_query_{d} = try core.url.percentEncode(alloc, {s}.toWire());
            \\        defer alloc.free(encoded_query_{d});
            \\        try url_buf.print(alloc, "{{s}}{s}={{s}}", .{{ if (has_query) "&" else "?", encoded_query_{d} }});
            \\        has_query = true;
            \\
        , .{ index, expr, index, qp.wire_name, index }),
        .numeric => try w.print(
            \\        try url_buf.print(alloc, "{{s}}{s}={{d}}", .{{ if (has_query) "&" else "?", {s} }});
            \\        has_query = true;
            \\
        , .{ qp.wire_name, expr }),
        .boolean => try w.print(
            \\        try url_buf.print(alloc, "{{s}}{s}={{}}", .{{ if (has_query) "&" else "?", {s} }});
            \\        has_query = true;
            \\
        , .{ qp.wire_name, expr }),
    }
}

fn sourceKind(m: cm.Method, source: cm.WireSource) InnerKind {
    if (!std.mem.eql(u8, source.kind, "user")) return .string_like;
    const name = source.name orelse return .string_like;
    for (m.user_parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, name)) return classifyTypeRef(parameter.param_type);
    }
    return .string_like;
}

const InnerKind = enum { string_like, enum_or_union, numeric, boolean };

fn innerOptionKind(m: cm.Method, qp: cm.WireParameter) InnerKind {
    // Look up the user parameter and inspect the inner Option type.
    const name = qp.source.name orelse return .string_like;
    for (m.user_parameters) |p| {
        if (!std.mem.eql(u8, p.name, name)) continue;
        const t = p.param_type;
        if (!t.isOption()) {
            return classifyTypeRef(t);
        }
        // Unwrap Option to peek at the inner kind.
        switch (t.value) {
            .object => |o| {
                const kind_v = o.get("kind") orelse return .string_like;
                const inner_kind_str = switch (kind_v) {
                    .string => |s| s,
                    else => return .string_like,
                };
                const value_v = o.get("value") orelse std.json.Value{ .null = {} };
                const inner = cm.TypeRef{ .kind = inner_kind_str, .value = value_v };
                return classifyTypeRef(inner);
            },
            else => return .string_like,
        }
    }
    return .string_like;
}

fn classifyTypeRef(t: cm.TypeRef) InnerKind {
    if (t.isEnum() or std.mem.eql(u8, t.kind, "Union")) return .enum_or_union;
    if (t.isScalar()) {
        const name = t.scalarName() orelse return .string_like;
        if (std.mem.eql(u8, name, "bool")) return .boolean;
        if (std.mem.startsWith(u8, name, "int") or
            std.mem.startsWith(u8, name, "uint") or
            std.mem.startsWith(u8, name, "float") or
            std.mem.eql(u8, name, "safeint") or
            std.mem.eql(u8, name, "integer") or
            std.mem.eql(u8, name, "numeric"))
        {
            return .numeric;
        }
        return .string_like;
    }
    return .string_like;
}

fn renderOptionalAppendNoRequired(
    w: *std.Io.Writer,
    user_id: []const u8,
    wire_name: []const u8,
    kind: InnerKind,
) !void {
    switch (kind) {
        .string_like => try w.print(
            \\        if ({s}) |query_value| {{
            \\            const sep: []const u8 = if (has_query) "&" else "?";
            \\            const enc = try core.url.percentEncode(alloc, query_value);
            \\            defer alloc.free(enc);
            \\            try url_buf.print(alloc, "{{s}}{s}={{s}}", .{{ sep, enc }});
            \\            has_query = true;
            \\        }}
            \\
        , .{ user_id, wire_name }),
        .enum_or_union => try w.print(
            \\        if ({s}) |query_value| {{
            \\            const sep: []const u8 = if (has_query) "&" else "?";
            \\            const enc = try core.url.percentEncode(alloc, query_value.toWire());
            \\            defer alloc.free(enc);
            \\            try url_buf.print(alloc, "{{s}}{s}={{s}}", .{{ sep, enc }});
            \\            has_query = true;
            \\        }}
            \\
        , .{ user_id, wire_name }),
        .numeric => try w.print(
            \\        if ({s}) |query_value| {{
            \\            const sep: []const u8 = if (has_query) "&" else "?";
            \\            try url_buf.print(alloc, "{{s}}{s}={{d}}", .{{ sep, query_value }});
            \\            has_query = true;
            \\        }}
            \\
        , .{ user_id, wire_name }),
        .boolean => try w.print(
            \\        if ({s}) |query_value| {{
            \\            const sep: []const u8 = if (has_query) "&" else "?";
            \\            try url_buf.print(alloc, "{{s}}{s}={{}}", .{{ sep, query_value }});
            \\            has_query = true;
            \\        }}
            \\
        , .{ user_id, wire_name }),
    }
}

/// If `qp` maps to a user parameter whose (optionally-unwrapped) type is an
/// array, return the array element TypeRef; otherwise null. Array-valued query
/// parameters (e.g. blob `include`) are serialized as a comma-joined list.
fn queryParamArrayElement(m: cm.Method, qp: cm.WireParameter) ?cm.TypeRef {
    if (!std.mem.eql(u8, qp.source.kind, "user")) return null;
    const name = qp.source.name orelse return null;
    for (m.user_parameters) |p| {
        if (!std.mem.eql(u8, p.name, name)) continue;
        var t = p.param_type;
        if (t.isOption()) t = nestedTypeRef(t);
        if (!t.isArray()) return null;
        return nestedTypeRef(t);
    }
    return null;
}

/// Render a comma-joined, percent-encoded query parameter for an array-valued
/// user parameter. Enum elements use `.toWire()`; scalar strings pass through;
/// numeric/boolean elements are formatted inline.
fn renderArrayQueryAppend(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    qp: cm.WireParameter,
    elem: cm.TypeRef,
) !void {
    const user_id = try paramName(allocator, qp.source.name orelse "<missing>");
    defer allocator.free(user_id);
    const kind = classifyTypeRef(elem);
    const item_expr: []const u8 = switch (kind) {
        .enum_or_union => "item.toWire()",
        .boolean => "if (item) \"true\" else \"false\"",
        else => "item",
    };

    // Optional arrays are guarded with `if (list) |items|`; required arrays
    // iterate the slice directly.
    if (qp.optional) {
        try w.print("        if ({s}) |items| {{\n", .{user_id});
    } else {
        try w.print("        {{\n            const items = {s};\n", .{user_id});
    }

    switch (kind) {
        .numeric => try w.print(
            \\            var list_buf: std.ArrayList(u8) = .empty;
            \\            defer list_buf.deinit(alloc);
            \\            for (items, 0..) |item, i| {{
            \\                if (i != 0) try list_buf.append(alloc, ',');
            \\                try list_buf.print(alloc, "{{d}}", .{{item}});
            \\            }}
            \\
        , .{}),
        else => try w.print(
            \\            var list_buf: std.ArrayList(u8) = .empty;
            \\            defer list_buf.deinit(alloc);
            \\            for (items, 0..) |item, i| {{
            \\                if (i != 0) try list_buf.append(alloc, ',');
            \\                try list_buf.appendSlice(alloc, {s});
            \\            }}
            \\
        , .{item_expr}),
    }

    try w.print(
        \\            if (items.len != 0) {{
        \\                const sep: []const u8 = if (has_query) "&" else "?";
        \\                const enc = try core.url.percentEncode(alloc, list_buf.items);
        \\                defer alloc.free(enc);
        \\                try url_buf.print(alloc, "{{s}}{s}={{s}}", .{{ sep, enc }});
        \\                has_query = true;
        \\            }}
        \\        }}
        \\
    , .{qp.wire_name});
}

/// Unwrap a single-nested TypeRef (`Option`/`Array`/`Map`) whose element type
/// is stored as an object `{ kind, value }` in `.value`.
fn nestedTypeRef(t: cm.TypeRef) cm.TypeRef {
    switch (t.value) {
        .object => |o| {
            const kind_v = o.get("kind") orelse return t;
            const kind = switch (kind_v) {
                .string => |s| s,
                else => return t,
            };
            const value_v = o.get("value") orelse std.json.Value{ .null = {} };
            return .{ .kind = kind, .value = value_v };
        },
        else => return t,
    }
}

fn sourceExpression(allocator: std.mem.Allocator, src: cm.WireSource) ![]u8 {
    if (std.mem.eql(u8, src.kind, "constant")) {
        return try std.fmt.allocPrint(allocator, "\"{s}\"", .{src.value orelse ""});
    }
    if (std.mem.eql(u8, src.kind, "client")) {
        return try std.fmt.allocPrint(allocator, "self.{s}", .{src.name orelse "<missing>"});
    }
    // user
    return try paramName(allocator, src.name orelse "<missing>");
}

fn renderListBody(allocator: std.mem.Allocator, w: *std.Io.Writer, m: cm.Method) !void {
    // Determine the item type T.
    const item_type_ref: ?cm.TypeRef = if (m.paging) |p| p.item_type else null;
    var item_ty: []u8 = undefined;
    if (item_type_ref) |t| {
        item_ty = try types.renderType(allocator, t, .clients);
    } else if (m.response.response_type) |t| {
        const ty = try types.renderType(allocator, t, .clients);
        defer allocator.free(ty);
        const prefix = "[]const ";
        if (std.mem.startsWith(u8, ty, prefix)) {
            item_ty = try allocator.dupe(u8, ty[prefix.len..]);
        } else {
            item_ty = try allocator.dupe(u8, ty);
        }
    } else {
        item_ty = try allocator.dupe(u8, "std.json.Value");
    }
    defer allocator.free(item_ty);

    try w.print(
        \\        return core.pager.PipelinePager({s}).init(
        \\            self.pipeline,
        \\            url,
        \\            alloc,
        \\            core.pager.listPageParser({s}),
        \\            "application/json",
        \\        );
        \\
    , .{ item_ty, item_ty });
}

/// Body for an XML data-plane list operation. Returns a `core.pager.XmlPager`
/// over the whole envelope model; the pager owns the `marker` query pair and
/// the `x-ms-version` request header. The initial `marker` user parameter (if
/// present) seeds the first page.
fn renderXmlListBody(allocator: std.mem.Allocator, w: *std.Io.Writer, m: cm.Method) !void {
    const env_ty = if (xmlEnvelopeTypeRef(m)) |t|
        try types.renderType(allocator, t, .clients)
    else
        try allocator.dupe(u8, "std.json.Value");
    defer allocator.free(env_ty);

    var has_marker = false;
    var has_crid = false;
    for (m.user_parameters) |p| {
        if (std.mem.eql(u8, p.name, "marker")) has_marker = true;
        if (std.mem.eql(u8, p.name, "client_request_id")) has_crid = true;
    }
    const marker_arg: []const u8 = if (has_marker) "marker" else "null";
    const crid_arg: []const u8 = if (has_crid) "client_request_id" else "null";

    try w.print(
        \\        return core.pager.XmlPager({s}).init(
        \\            self.pipeline,
        \\            url,
        \\            self.api_version,
        \\            {s},
        \\            {s},
        \\            alloc,
        \\        );
        \\
    , .{ env_ty, marker_arg, crid_arg });
}

fn renderRequestSetup(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    m: cm.Method,
) !void {
    const verb = try httpVerbZig(allocator, m.http_method);
    defer allocator.free(verb);
    try w.print(
        \\        var req = core.http.Request.init(alloc, .{s}, url);
        \\        defer req.deinit();
        \\
    , .{verb});
    if (hasModeledRedirect(m)) {
        try w.writeAll("        req.redirect_policy = .not_allowed;\n");
    }

    for (m.header_parameters) |hp| {
        if (m.body_parameter) |bp| {
            if (std.mem.eql(u8, bp.serialization_kind, "multipart") and
                std.ascii.eqlIgnoreCase(hp.wire_name, "content-type"))
            {
                continue;
            }
        }
        if (std.mem.eql(u8, hp.source.kind, "constant")) {
            if (hp.optional and m.body_parameter != null and bodyParameterIsOptional(m)) {
                const body_id = try paramName(allocator, m.body_parameter.?.user_param_name);
                defer allocator.free(body_id);
                try w.print(
                    \\        if ({s} != null) try req.setHeader("{s}", "{s}");
                    \\
                , .{ body_id, hp.wire_name, hp.source.value orelse "" });
            } else {
                try w.print("        try req.setHeader(\"{s}\", \"{s}\");\n", .{ hp.wire_name, hp.source.value orelse "" });
            }
        } else {
            if (hp.source.name == null) continue;
            const value_expr = try sourceExpression(allocator, hp.source);
            defer allocator.free(value_expr);
            const kind = sourceKind(m, hp.source);
            if (hp.optional) {
                switch (kind) {
                    .enum_or_union => try w.print(
                        \\        if ({s}) |value| try req.setHeader("{s}", value.toWire());
                        \\
                    , .{ value_expr, hp.wire_name }),
                    .numeric => try w.print(
                        \\        if ({s}) |value| {{
                        \\            const header_val = try std.fmt.allocPrint(alloc, "{{d}}", .{{value}});
                        \\            defer alloc.free(header_val);
                        \\            try req.setHeader("{s}", header_val);
                        \\        }}
                        \\
                    , .{ value_expr, hp.wire_name }),
                    .boolean => try w.print(
                        \\        if ({s}) |value| try req.setHeader("{s}", if (value) "true" else "false");
                        \\
                    , .{ value_expr, hp.wire_name }),
                    .string_like => try w.print(
                        \\        if ({s}) |value| try req.setHeader("{s}", value);
                        \\
                    , .{ value_expr, hp.wire_name }),
                }
            } else {
                switch (kind) {
                    .enum_or_union => try w.print("        try req.setHeader(\"{s}\", {s}.toWire());\n", .{ hp.wire_name, value_expr }),
                    .numeric => try w.print(
                        \\        {{
                        \\            const header_val = try std.fmt.allocPrint(alloc, "{{d}}", .{{{s}}});
                        \\            defer alloc.free(header_val);
                        \\            try req.setHeader("{s}", header_val);
                        \\        }}
                        \\
                    , .{ value_expr, hp.wire_name }),
                    .boolean => try w.print("        try req.setHeader(\"{s}\", if ({s}) \"true\" else \"false\");\n", .{ hp.wire_name, value_expr }),
                    .string_like => try w.print("        try req.setHeader(\"{s}\", {s});\n", .{ hp.wire_name, value_expr }),
                }
            }
        }
    }

    if (m.body_parameter) |bp| {
        const id = try paramName(allocator, bp.user_param_name);
        defer allocator.free(id);
        if (std.mem.eql(u8, bp.serialization_kind, "raw")) {
            if (bodyParameterIsOptional(m)) {
                try w.print("        if ({s}) |body| req.body = body;\n", .{id});
            } else {
                try w.print("        req.body = {s};\n", .{id});
            }
        } else if (std.mem.eql(u8, bp.serialization_kind, "multipart")) {
            try renderMultipartBody(allocator, w, model, bp, id);
        } else if (std.mem.eql(u8, bp.serialization_kind, "xml")) {
            if (bodyParameterIsOptional(m)) {
                try w.print(
                    \\        var body_xml: ?[]u8 = null;
                    \\        defer if (body_xml) |bytes| alloc.free(bytes);
                    \\        if ({s}) |body| {{
                    \\            const bytes = try serde.xml.toSlice(alloc, body);
                    \\            body_xml = bytes;
                    \\            req.body = bytes;
                    \\        }}
                    \\
                , .{id});
            } else {
                try w.print(
                    \\        const body_xml = try serde.xml.toSlice(alloc, {s});
                    \\        defer alloc.free(body_xml);
                    \\        req.body = body_xml;
                    \\
                , .{id});
            }
        } else {
            if (bodyParameterIsOptional(m)) {
                try w.print(
                    \\        var body_json: ?[]u8 = null;
                    \\        defer if (body_json) |bytes| alloc.free(bytes);
                    \\        if ({s}) |body| {{
                    \\            const bytes = try serde.json.toSlice(alloc, body);
                    \\            body_json = bytes;
                    \\            req.body = bytes;
                    \\        }}
                    \\
                , .{id});
            } else {
                try w.print(
                    \\        const body_json = try serde.json.toSlice(alloc, {s});
                    \\        defer alloc.free(body_json);
                    \\        req.body = body_json;
                    \\
                , .{id});
            }
        }
    }
}

fn hasModeledRedirect(m: cm.Method) bool {
    if (statusesContainRedirect(m.response.status_codes)) return true;
    for (m.responses) |response| {
        if (statusesContainRedirect(response.status_codes)) return true;
    }
    return false;
}

fn statusesContainRedirect(statuses: []const std.json.Value) bool {
    for (statuses) |status| {
        switch (status) {
            .integer => |value| if (value >= 300 and value < 400) return true,
            else => {},
        }
    }
    return false;
}

fn bodyParameterIsOptional(m: cm.Method) bool {
    const body = m.body_parameter orelse return false;
    for (m.user_parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, body.user_param_name)) return parameter.optional;
    }
    return false;
}

fn renderMultipartBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    body_parameter: cm.BodyParameter,
    body_id: []const u8,
) !void {
    const type_name = if (body_parameter.body_type) |body_type|
        body_type.namedTypeName()
    else
        null;
    const multipart_model = if (type_name) |name| findModel(model, name) else null;
    const body_model = multipart_model orelse return error.MultipartBodyModelMissing;

    try w.writeAll(
        \\        const multipart_boundary = "azure-sdk-for-zig-acr-boundary";
        \\        var multipart_body: std.ArrayList(u8) = .empty;
        \\        defer multipart_body.deinit(alloc);
        \\
    );
    for (body_model.fields) |field| {
        const multipart = field.multipart orelse continue;
        const field_id = try ids.quoteIfNeeded(allocator, field.name);
        defer allocator.free(field_id);
        const value_expr = try multipartValueExpression(allocator, field, body_id, field_id);
        defer allocator.free(value_expr);
        const content_type = if (multipart.content_types.len > 0)
            multipart.content_types[0]
        else
            "text/plain";
        if (field.optional) {
            try w.print(
                \\        if ({s}.{s}) |value| {{
                \\            try multipart_body.print(
                \\                alloc,
                \\                "--{{s}}\r\nContent-Disposition: form-data; name=\"{s}\"\r\nContent-Type: {s}\r\n\r\n{{s}}\r\n",
                \\                .{{ multipart_boundary, {s} }},
                \\            );
                \\        }}
                \\
            , .{ body_id, field_id, multipart.name, content_type, value_expr });
        } else {
            try w.print(
                \\        try multipart_body.print(
                \\            alloc,
                \\            "--{{s}}\r\nContent-Disposition: form-data; name=\"{s}\"\r\nContent-Type: {s}\r\n\r\n{{s}}\r\n",
                \\            .{{ multipart_boundary, {s} }},
                \\        );
                \\
            , .{ multipart.name, content_type, value_expr });
        }
    }
    try w.writeAll(
        \\        try multipart_body.print(alloc, "--{s}--\r\n", .{multipart_boundary});
        \\        const multipart_bytes = try multipart_body.toOwnedSlice(alloc);
        \\        defer alloc.free(multipart_bytes);
        \\        req.body = multipart_bytes;
        \\        try req.setHeader("Content-Type", "multipart/form-data; boundary=azure-sdk-for-zig-acr-boundary");
        \\
    );
}

fn multipartValueExpression(
    allocator: std.mem.Allocator,
    field: cm.Field,
    body_id: []const u8,
    field_id: []const u8,
) ![]u8 {
    if (field.field_type.isEnum() or std.mem.eql(u8, field.field_type.kind, "Union")) {
        if (field.optional) return try allocator.dupe(u8, "value.toWire()");
        return try std.fmt.allocPrint(allocator, "{s}.{s}.toWire()", .{ body_id, field_id });
    }
    if (field.optional) return try allocator.dupe(u8, "value");
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ body_id, field_id });
}

fn findModel(model: cm.CodeModel, name: []const u8) ?cm.Model {
    for (model.models) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn httpVerbZig(allocator: std.mem.Allocator, http_method: []const u8) ![]u8 {
    var upper = try allocator.alloc(u8, http_method.len);
    for (http_method, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    return upper;
}

fn renderVoidBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    c: cm.Client,
    m: cm.Method,
) !void {
    try renderRequestSetup(allocator, w, model, m);
    const statuses = try renderExpectedStatuses(allocator, m.response.status_codes);
    defer allocator.free(statuses);
    try w.print(
        \\
        \\        var resp = try self.pipeline.send(&req);
        \\        defer resp.deinit();
        \\
        \\        if (!responseStatusExpected(resp.status_code, &.{{{[statuses]s}}})) {{
        \\            core.pager.logHttpError("{[client]s}.{[method]s}", resp.status_code, resp.body);
        \\            return error.AzureRequestFailed;
        \\        }}
        \\        return;
        \\
    , .{
        .client = c.name,
        .method = m.name_camel,
        .statuses = statuses,
    });
}

fn renderValueBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    c: cm.Client,
    m: cm.Method,
) !void {
    try renderRequestSetup(allocator, w, model, m);
    const ty = try types.renderType(allocator, m.response.response_type.?, .clients);
    defer allocator.free(ty);
    const statuses = try renderExpectedStatuses(allocator, m.response.status_codes);
    defer allocator.free(statuses);
    try w.print(
        \\
        \\        var resp = try self.pipeline.send(&req);
        \\        defer resp.deinit();
        \\
        \\        if (!responseStatusExpected(resp.status_code, &.{{{[statuses]s}}})) {{
        \\            core.pager.logHttpError("{[client]s}.{[method]s}", resp.status_code, resp.body);
        \\            return error.AzureRequestFailed;
        \\        }}
        \\        return try serde.json.fromSlice({[ty]s}, alloc, resp.body);
        \\
    , .{
        .client = c.name,
        .method = m.name_camel,
        .ty = ty,
        .statuses = statuses,
    });
}

fn renderLroBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    c: cm.Client,
    m: cm.Method,
) !void {
    try renderRequestSetup(allocator, w, model, m);
    const final_ty = if (m.long_running) |l| l.final_response_type else null;
    var ty_owned: []u8 = undefined;
    if (final_ty) |t| {
        ty_owned = try types.renderType(allocator, t, .clients);
    } else {
        ty_owned = try allocator.dupe(u8, "void");
    }
    defer allocator.free(ty_owned);
    const statuses = try renderExpectedStatuses(allocator, m.response.status_codes);
    defer allocator.free(statuses);
    try w.print(
        \\
        \\        var resp = try self.pipeline.send(&req);
        \\        defer resp.deinit();
        \\
        \\        if (!responseStatusExpected(resp.status_code, &.{{{[statuses]s}}})) {{
        \\            core.pager.logHttpError("{[client]s}.{[method]s}", resp.status_code, resp.body);
        \\            return error.AzureRequestFailed;
        \\        }}
        \\        return try core.lro.TypedPoller({[ty]s}).init(alloc, self.pipeline, resp, url, .{{}});
        \\
    , .{
        .client = c.name,
        .method = m.name_camel,
        .ty = ty_owned,
        .statuses = statuses,
    });
}

fn renderProtocolBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    c: cm.Client,
    m: cm.Method,
) !void {
    try renderRequestSetup(allocator, w, model, m);
    try w.writeAll(
        \\
        \\        var resp = try self.pipeline.send(&req);
        \\        defer resp.deinit();
        \\
        \\        switch (resp.status_code) {
        \\
    );
    for (m.responses) |response| {
        for (response.status_codes) |status| {
            const code = statusInteger(status) orelse continue;
            try w.print("            {d} => {{\n", .{code});
            try renderProtocolVariantReturn(allocator, w, model, response, code);
            try w.writeAll("            },\n");
        }
    }
    try w.print(
        \\            else => {{
        \\                core.pager.logHttpError("{s}.{s}", resp.status_code, resp.body);
        \\                return error.AzureRequestFailed;
        \\            }},
        \\        }}
        \\
    , .{ c.name, m.name_camel });
}

fn renderProtocolVariantReturn(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    response: cm.ResponseVariant,
    status: u16,
) !void {
    const headers = try uniqueResponseHeaders(allocator, response.headers);
    defer allocator.free(headers);
    for (headers, 0..) |header, index| {
        try renderResponseHeaderExtract(allocator, w, model, header, index);
    }

    const emits_body = response.response_type != null and
        !std.mem.eql(u8, response.body_kind, "none");
    if (emits_body) {
        if (std.mem.eql(u8, response.body_kind, "json")) {
            const ty = try types.renderType(allocator, response.response_type.?, .clients);
            defer allocator.free(ty);
            try w.print(
                \\                const response_body = try serde.json.fromSlice({s}, alloc, resp.body);
                \\
            , .{ty});
        } else if (std.mem.eql(u8, response.body_kind, "xml")) {
            const ty = try types.renderType(allocator, response.response_type.?, .clients);
            defer allocator.free(ty);
            try w.print(
                \\                const response_body = try serde.xml.fromSlice({s}, alloc, resp.body);
                \\
            , .{ty});
        } else {
            // raw / multipart / other binary bodies are surfaced as bytes.
            try w.writeAll(
                \\                const response_body = try bufferRawResponseBody(alloc, resp.body);
                \\                errdefer alloc.free(response_body);
                \\
            );
        }
    }

    try w.print(
        \\                return .{{ .status_{d} = .{{
        \\                    .status = resp.status_code,
        \\                    .headers = .{{
        \\
    , .{status});
    for (headers, 0..) |header, index| {
        const id = try ids.quoteIfNeeded(allocator, header.name);
        defer allocator.free(id);
        try w.print("                        .{s} = response_header_{d},\n", .{ id, index });
    }
    try w.writeAll(
        \\                    },
        \\
    );
    if (std.mem.eql(u8, response.body_kind, "none") or response.response_type == null) {
        try w.writeAll("                    .body = {},\n");
    } else {
        try w.writeAll("                    .body = response_body,\n");
    }
    try w.writeAll(
        \\                } };
        \\
    );
}

/// Extract a single response header into a `response_header_{index}` local
/// typed to match the generated struct field. Strings duplicate the raw
/// value; integers/floats/booleans parse; enums use `fromWire` (open enums
/// take the allocator to own an `unrecognized` value).
fn renderResponseHeaderExtract(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.CodeModel,
    header: cm.ResponseHeader,
    index: usize,
) !void {
    var inner = header.header_type;
    if (inner.isOption()) inner = unwrapOptionTypeRef(inner);
    const optional = header.optional or header.header_type.isOption();
    const zt = try types.renderType(allocator, inner, .clients);
    defer allocator.free(zt);
    const wire = header.wire_name;

    // Enum header: parse the wire value into the enum via `fromWire`.
    if (std.mem.startsWith(u8, zt, "enums.")) {
        const extensible = enumIsExtensible(model, inner);
        if (optional and extensible) {
            try w.print(
                \\                const response_header_{d}: ?{s} = if (resp.getHeader("{s}")) |value|
                \\                    try {s}.fromWire(alloc, value)
                \\                else
                \\                    null;
                \\
            , .{ index, zt, wire, zt });
        } else if (optional) {
            try w.print(
                \\                const response_header_{d}: ?{s} = if (resp.getHeader("{s}")) |value|
                \\                    {s}.fromWire(value)
                \\                else
                \\                    null;
                \\
            , .{ index, zt, wire, zt });
        } else if (extensible) {
            try w.print(
                \\                const response_header_{d} = try {s}.fromWire(
                \\                    alloc,
                \\                    resp.getHeader("{s}") orelse return error.MissingResponseHeader,
                \\                );
                \\
            , .{ index, zt, wire });
        } else {
            try w.print(
                \\                const response_header_{d} = {s}.fromWire(
                \\                    resp.getHeader("{s}") orelse return error.MissingResponseHeader,
                \\                ) orelse return error.UnexpectedResponseHeaderValue;
                \\
            , .{ index, zt, wire });
        }
        return;
    }

    // Boolean header.
    if (std.mem.eql(u8, zt, "bool")) {
        if (optional) {
            try w.print(
                \\                const response_header_{d}: ?bool = if (resp.getHeader("{s}")) |value|
                \\                    std.mem.eql(u8, value, "true")
                \\                else
                \\                    null;
                \\
            , .{ index, wire });
        } else {
            try w.print(
                \\                const response_header_{d} = std.mem.eql(u8, resp.getHeader("{s}") orelse return error.MissingResponseHeader, "true");
                \\
            , .{ index, wire });
        }
        return;
    }

    // Integer header.
    if (isZigIntType(zt)) {
        if (optional) {
            try w.print(
                \\                const response_header_{d}: ?{s} = if (resp.getHeader("{s}")) |value|
                \\                    try std.fmt.parseInt({s}, value, 10)
                \\                else
                \\                    null;
                \\
            , .{ index, zt, wire, zt });
        } else {
            try w.print(
                \\                const response_header_{d} = try std.fmt.parseInt(
                \\                    {s},
                \\                    resp.getHeader("{s}") orelse return error.MissingResponseHeader,
                \\                    10,
                \\                );
                \\
            , .{ index, zt, wire });
        }
        return;
    }

    // Float header.
    if (std.mem.eql(u8, zt, "f32") or std.mem.eql(u8, zt, "f64")) {
        if (optional) {
            try w.print(
                \\                const response_header_{d}: ?{s} = if (resp.getHeader("{s}")) |value|
                \\                    try std.fmt.parseFloat({s}, value)
                \\                else
                \\                    null;
                \\
            , .{ index, zt, wire, zt });
        } else {
            try w.print(
                \\                const response_header_{d} = try std.fmt.parseFloat(
                \\                    {s},
                \\                    resp.getHeader("{s}") orelse return error.MissingResponseHeader,
                \\                );
                \\
            , .{ index, zt, wire });
        }
        return;
    }

    // String (and any other) header: duplicate the raw value.
    if (optional) {
        try w.print(
            \\                const response_header_{d} = if (resp.getHeader("{s}")) |value|
            \\                    try alloc.dupe(u8, value)
            \\                else
            \\                    null;
            \\                errdefer if (response_header_{d}) |value| alloc.free(value);
            \\
        , .{ index, wire, index });
    } else {
        try w.print(
            \\                const response_header_{d} = try alloc.dupe(
            \\                    u8,
            \\                    resp.getHeader("{s}") orelse return error.MissingResponseHeader,
            \\                );
            \\                errdefer alloc.free(response_header_{d});
            \\
        , .{ index, wire, index });
    }
}

fn isZigIntType(s: []const u8) bool {
    const ints = [_][]const u8{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64" };
    for (ints) |i| {
        if (std.mem.eql(u8, s, i)) return true;
    }
    return false;
}

fn enumIsExtensible(model: cm.CodeModel, t: cm.TypeRef) bool {
    const name = t.namedTypeName() orelse return true;
    for (model.enums) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.extensible;
    }
    return true;
}

/// Unwrap an `Option` TypeRef to its inner type.
fn unwrapOptionTypeRef(t: cm.TypeRef) cm.TypeRef {
    if (!t.isOption()) return t;
    return nestedTypeRef(t);
}

fn renderExpectedStatuses(
    allocator: std.mem.Allocator,
    statuses: []const std.json.Value,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var first = true;
    for (statuses) |status| {
        const code = statusInteger(status) orelse continue;
        if (!first) try output.writer.writeAll(", ");
        try output.writer.print("{d}", .{code});
        first = false;
    }
    return try output.toOwnedSlice();
}

// ─── models.zig ───────────────────────────────────────────────────────

pub fn renderModels(allocator: std.mem.Allocator, model: cm.CodeModel) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    // Whether any generated struct will reference `core.arm.ResourceKind`.
    // If so, models.zig needs `const core = @import("azure_sdk_core");`.
    var needs_core = false;
    for (model.models) |m| {
        if (m.arm_resource_kind != null) {
            needs_core = true;
            break;
        }
    }

    try w.writeAll(
        \\//! Generated data-transfer-object models.
        \\
        \\const std = @import("std");
        \\const enums = @import("enums.zig");
        \\
    );
    if (needs_core) {
        try w.writeAll(
            \\const core = @import("azure_sdk_core");
            \\
        );
    }
    try w.writeAll("\n");
    if (needsJsonValue(model)) {
        try renderJsonValue(w);
    }

    var cycles = try CycleBreaker.init(allocator, model.models);
    defer cycles.deinit();

    for (model.models) |m| {
        if (m.doc) |d| try renderDocComment(w, d);
        try w.print("pub const {s} = struct {{\n", .{m.name}); // Azure services routinely omit nominally-required fields from
        // response bodies (e.g. a blob listing omits `<Deleted>`/`<Snapshot>`
        // for a normal blob). Match azure-sdk-for-rust, whose generated
        // response models make every field optional, by treating fields of
        // output-usage models as optional so deserialization tolerates the
        // absence. Wrapped arrays already default to an empty collection.
        // Restrict this to PURELY-output models: a model also used as a
        // request body (`is_input`) keeps its declared optionality so
        // request-side code (multipart bodies, header sources, serialization)
        // can access required fields without unwrapping.
        const force_optional = m.is_output and !m.is_input;
        for (m.fields) |f| {
            if (f.doc) |d| {
                try w.writeAll("    ");
                try renderDocComment(w, d);
            }
            const id = try ids.quoteIfNeeded(allocator, f.name);
            defer allocator.free(id);
            if (xmlWrappedArray(f) != null) {
                // Wrapped XML array (e.g. `<Containers><Container>…`): the
                // property becomes a nested wrapper struct declared below.
                const wt = try xmlWrapperTypeName(allocator, f);
                defer allocator.free(wt);
                if (f.optional) {
                    try w.print("    {s}: ?{s} = null,\n", .{ id, wt });
                } else {
                    try w.print("    {s}: {s} = .{{}},\n", .{ id, wt });
                }
                continue;
            }
            const opt = f.optional or force_optional;
            const rendered = try renderFieldType(allocator, f.field_type, opt, .models);
            defer allocator.free(rendered);
            // Boxed back edge of a recursive schema: `?Build` → `?*const Build`.
            const boxed = if (cycles.contains(m.name, f.name)) blk: {
                const bare = if (std.mem.startsWith(u8, rendered, "?"))
                    rendered[1..]
                else
                    rendered;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s}*const {s}",
                    .{ if (opt) "?" else "", bare },
                );
            } else null;
            defer if (boxed) |b| allocator.free(b);
            const ty = boxed orelse rendered;
            if (opt) {
                try w.print("    {s}: {s} = null,\n", .{ id, ty });
            } else {
                try w.print("    {s}: {s},\n", .{ id, ty });
            }
        }
        if (m.additional_properties != null) {
            try w.writeAll("    additional_properties: std.StringArrayHashMapUnmanaged(JsonValue) = .empty,\n");
        }

        // Nested wrapper structs for wrapped XML arrays.
        for (m.fields) |f| {
            const x = xmlWrappedArray(f) orelse continue;
            const wt = try xmlWrapperTypeName(allocator, f);
            defer allocator.free(wt);
            const elem_ty = try renderFieldType(allocator, f.field_type, false, .models);
            defer allocator.free(elem_ty);
            try w.print(
                \\    pub const {s} = struct {{
                \\        items: {s} = &.{{}},
                \\        pub const serde = .{{ .rename = .{{ .items = "{s}" }} }};
                \\    }};
                \\
            , .{ wt, elem_ty, x.items_name.? });
        }

        try renderModelSerdeOptions(allocator, w, m);
        if (m.additional_properties != null) {
            try renderOpenModelMethods(allocator, w, m);
        }

        // ARM resource marker. Lets `core.arm` helpers like
        // `core.arm.id(&res)` / `core.arm.setTags(&res, ...)` dispatch
        // on the resource's base type at comptime, with zero runtime
        // cost. See `sdk/core/arm/resource.zig`.
        if (m.arm_resource_kind) |kind| {
            try w.print(
                "    pub const arm_resource_kind: core.arm.ResourceKind = .{s};\n",
                .{kind},
            );
        }

        try w.writeAll("};\n\n");
    }
    return try aw.toOwnedSlice();
}

fn needsJsonValue(model: cm.CodeModel) bool {
    for (model.models) |item| {
        if (item.additional_properties) |additional| {
            if (typeRefContainsUnknown(additional)) return true;
        }
        for (item.fields) |field| {
            if (typeRefContainsUnknown(field.field_type)) return true;
        }
    }
    return false;
}

fn typeRefContainsUnknown(type_ref: cm.TypeRef) bool {
    if (type_ref.isScalar() and
        std.mem.eql(u8, type_ref.scalarName() orelse "", "unknown"))
    {
        return true;
    }
    return jsonValueContainsUnknown(type_ref.value);
}

fn jsonValueContainsUnknown(value: std.json.Value) bool {
    return switch (value) {
        .string => |text| std.mem.eql(u8, text, "unknown"),
        .array => |items| blk: {
            for (items.items) |item| {
                if (jsonValueContainsUnknown(item)) break :blk true;
            }
            break :blk false;
        },
        .object => |object| blk: {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (jsonValueContainsUnknown(entry.value_ptr.*)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn renderJsonValue(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\pub const JsonValue = union(enum) {
        \\    null_value: void,
        \\    boolean: bool,
        \\    integer: i64,
        \\    float: f64,
        \\    string: []const u8,
        \\    array: []JsonValue,
        \\    object: std.StringArrayHashMapUnmanaged(JsonValue),
        \\
        \\    pub fn zerdeDeserialize(
        \\        comptime T: type,
        \\        allocator: std.mem.Allocator,
        \\        deserializer: anytype,
        \\    ) @TypeOf(deserializer.*).Error!T {
        \\        const saved = deserializer.*;
        \\        if (deserializer.deserializeVoid()) |_| {
        \\            return .{ .null_value = {} };
        \\        } else |_| deserializer.* = saved;
        \\        if (deserializer.deserializeBool()) |value| {
        \\            return .{ .boolean = value };
        \\        } else |_| deserializer.* = saved;
        \\        if (deserializer.deserializeInt(i64)) |value| {
        \\            return .{ .integer = value };
        \\        } else |_| deserializer.* = saved;
        \\        if (deserializer.deserializeFloat(f64)) |value| {
        \\            return .{ .float = value };
        \\        } else |_| deserializer.* = saved;
        \\        if (deserializer.deserializeString(allocator)) |value| {
        \\            return .{ .string = value };
        \\        } else |_| deserializer.* = saved;
        \\
        \\        if (deserializer.deserializeSeqAccess()) |sequence_value| {
        \\            var sequence = sequence_value;
        \\            var values: std.ArrayList(JsonValue) = .empty;
        \\            errdefer values.deinit(allocator);
        \\            while (try sequence.nextElement(JsonValue, allocator)) |value| {
        \\                values.append(allocator, value) catch
        \\                    return deserializer.raiseError(error.OutOfMemory);
        \\            }
        \\            return .{ .array = values.toOwnedSlice(allocator) catch
        \\                return deserializer.raiseError(error.OutOfMemory) };
        \\        } else |_| deserializer.* = saved;
        \\
        \\        var map = deserializer.deserializeStruct(T) catch
        \\            return deserializer.raiseError(error.UnexpectedToken);
        \\        var values: std.StringArrayHashMapUnmanaged(JsonValue) = .empty;
        \\        errdefer values.deinit(allocator);
        \\        while (try map.nextKey(allocator)) |key| {
        \\            const owned_key = allocator.dupe(u8, key) catch
        \\                return deserializer.raiseError(error.OutOfMemory);
        \\            const value = map.nextValue(JsonValue, allocator) catch |err| {
        \\                allocator.free(owned_key);
        \\                return err;
        \\            };
        \\            values.put(allocator, owned_key, value) catch {
        \\                allocator.free(owned_key);
        \\                return deserializer.raiseError(error.OutOfMemory);
        \\            };
        \\        }
        \\        return .{ .object = values };
        \\    }
        \\
        \\    pub fn zerdeSerialize(self: JsonValue, serializer: anytype) @TypeOf(serializer.*).Error!void {
        \\        switch (self) {
        \\            .null_value => return serializer.serializeNull(),
        \\            .boolean => |value| return serializer.serializeBool(value),
        \\            .integer => |value| return serializer.serializeInt(value),
        \\            .float => |value| return serializer.serializeFloat(value),
        \\            .string => |value| return serializer.serializeString(value),
        \\            .array => |values| {
        \\                var array = try serializer.beginArray();
        \\                for (values) |value| try value.zerdeSerialize(&array);
        \\                return array.end();
        \\            },
        \\            .object => |values| {
        \\                var object = try serializer.beginStruct();
        \\                var iterator = values.iterator();
        \\                while (iterator.next()) |entry| {
        \\                    try object.serializeEntry(entry.key_ptr.*, entry.value_ptr.*);
        \\                }
        \\                return object.end();
        \\            },
        \\        }
        \\    }
        \\};
        \\
        \\
    );
}

fn renderModelSerdeOptions(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.Model,
) !void {
    if (model.is_xml) {
        try renderXmlModelSerdeOptions(allocator, w, model);
        return;
    }
    try w.writeAll("\n    pub const serde = .{\n        .rename_all = .camel_case,\n");
    var has_renames = false;
    for (model.fields) |field| {
        const camel = try naming.toCamelCase(allocator, field.name);
        defer allocator.free(camel);
        if (!std.mem.eql(u8, camel, field.serialized_name)) {
            if (!has_renames) {
                try w.writeAll("        .rename = .{\n");
                has_renames = true;
            }
            const id = try ids.quoteIfNeeded(allocator, field.name);
            defer allocator.free(id);
            try w.print("            .{s} = \"{s}\",\n", .{ id, field.serialized_name });
        }
    }
    if (has_renames) try w.writeAll("        },\n");
    if (model.additional_properties != null) {
        try w.writeAll("        .skip = .{ .additional_properties = .always },\n");
    }
    try w.writeAll("    };\n");
}

/// True when `f` is a wrapped XML array — an array property whose items
/// are nested under a wrapper element (`<Containers><Container>…`), i.e.
/// `xml.unwrapped == false`. Such properties are emitted as a nested
/// wrapper struct. Unwrapped arrays (repeated sibling elements) keep
/// their slice type and are handled by serde.xml directly.
fn xmlWrappedArray(f: cm.Field) ?cm.XmlField {
    const x = f.xml orelse return null;
    if (x.unwrapped) return null;
    if (!f.field_type.isArray()) return null;
    if (x.items_name == null) return null;
    return x;
}

/// Nested wrapper-struct type name for a wrapped XML array property, e.g.
/// `container_items` → `ContainerItemsXml`. Caller owns the returned slice.
fn xmlWrapperTypeName(allocator: std.mem.Allocator, f: cm.Field) ![]u8 {
    const pascal = try naming.toPascalCase(allocator, f.name);
    defer allocator.free(pascal);
    return std.fmt.allocPrint(allocator, "{s}Xml", .{pascal});
}

/// XML flavor of `renderModelSerdeOptions`. Emits `xml_root` (the element
/// name for the model when it is a body root), `xml_attribute` for
/// attribute properties, and an exact per-field `.rename` derived from the
/// TCGC XML name (blob XML uses PascalCase with hyphens/acronyms that a
/// `rename_all` convention cannot reproduce, e.g. `Last-Modified`, `Etag`).
fn renderXmlModelSerdeOptions(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.Model,
) !void {
    try w.writeAll("\n    pub const serde = .{\n");
    if (model.xml_name) |root| {
        try w.print("        .xml_root = \"{s}\",\n", .{root});
    }

    // Attribute properties → `.xml_attribute = .{ .a, .b }`.
    var has_attr = false;
    for (model.fields) |f| {
        const x = f.xml orelse continue;
        if (!x.attribute) continue;
        const id = try ids.quoteIfNeeded(allocator, f.name);
        defer allocator.free(id);
        if (!has_attr) {
            try w.writeAll("        .xml_attribute = .{ ");
            has_attr = true;
        } else {
            try w.writeAll(", ");
        }
        try w.print(".{s}", .{id});
    }
    if (has_attr) try w.writeAll(" },\n");

    // Text-content property → `.xml_text = .field`. An `unwrapped` scalar
    // (non-array, non-attribute) XML property carries the element's text
    // content (e.g. `<Name Encoded=..>blob</Name>`), not a child element.
    for (model.fields) |f| {
        if (!xmlIsTextContent(f)) continue;
        const id = try ids.quoteIfNeeded(allocator, f.name);
        defer allocator.free(id);
        try w.print("        .xml_text = .{s},\n", .{id});
        break;
    }

    // Exact per-field element/attribute names. Wrapped-array properties
    // carry the wrapper element name (`xml.name`); the item name lives on
    // the nested wrapper struct's own `serde.rename`. Text-content fields
    // are matched by field name via `xml_text`, so they are not renamed.
    try w.writeAll("        .rename = .{\n");
    for (model.fields) |f| {
        if (xmlIsTextContent(f)) continue;
        const id = try ids.quoteIfNeeded(allocator, f.name);
        defer allocator.free(id);
        const wire = if (f.xml) |x| x.name else f.serialized_name;
        try w.print("            .{s} = \"{s}\",\n", .{ id, wire });
    }
    try w.writeAll("        },\n");
    try w.writeAll("    };\n");
}

/// Returns true when the field is an `unwrapped` scalar XML property, i.e.
/// it maps to the enclosing element's text content rather than a child
/// element. Unwrapped *arrays* (sibling lists) are excluded.
fn xmlIsTextContent(f: cm.Field) bool {
    const x = f.xml orelse return false;
    if (!x.unwrapped or x.attribute) return false;
    return !xmlEffectiveIsArrayOrMap(f.field_type);
}

fn xmlEffectiveIsArrayOrMap(t: cm.TypeRef) bool {
    if (t.isArray() or t.isMap()) return true;
    if (t.isOption()) {
        switch (t.value) {
            .object => |o| {
                if (o.get("kind")) |k| switch (k) {
                    .string => |s| return std.mem.eql(u8, s, "Array") or std.mem.eql(u8, s, "Map"),
                    else => {},
                };
            },
            else => {},
        }
    }
    return false;
}

fn renderOpenModelMethods(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    model: cm.Model,
) !void {
    try w.writeAll(
        \\
        \\    pub fn zerdeDeserialize(
        \\        comptime T: type,
        \\        allocator: std.mem.Allocator,
        \\        deserializer: anytype,
        \\    ) @TypeOf(deserializer.*).Error!T {
        \\        var result: T = .{};
        \\        var map = try deserializer.deserializeStruct(T);
        \\        while (try map.nextKey(allocator)) |key| {
        \\
    );
    for (model.fields) |field| {
        const id = try ids.quoteIfNeeded(allocator, field.name);
        defer allocator.free(id);
        const ty = try renderFieldType(allocator, field.field_type, field.optional, .models);
        defer allocator.free(ty);
        try w.print(
            \\            if (std.mem.eql(u8, key, "{s}")) {{
            \\                result.{s} = try map.nextValue({s}, allocator);
            \\                continue;
            \\            }}
            \\
        , .{ field.serialized_name, id, ty });
    }
    try w.writeAll(
        \\            const owned_key = allocator.dupe(u8, key) catch
        \\                return deserializer.raiseError(error.OutOfMemory);
        \\            const value = map.nextValue(JsonValue, allocator) catch |err| {
        \\                allocator.free(owned_key);
        \\                return err;
        \\            };
        \\            result.additional_properties.put(allocator, owned_key, value) catch {
        \\                allocator.free(owned_key);
        \\                return deserializer.raiseError(error.OutOfMemory);
        \\            };
        \\        }
        \\        return result;
        \\    }
        \\
        \\    pub fn zerdeSerialize(self: @This(), serializer: anytype) @TypeOf(serializer.*).Error!void {
        \\        var object = try serializer.beginStruct();
        \\
    );
    for (model.fields) |field| {
        const id = try ids.quoteIfNeeded(allocator, field.name);
        defer allocator.free(id);
        if (field.optional) {
            try w.print(
                \\        if (self.{s}) |value| try object.serializeField("{s}", value);
                \\
            , .{ id, field.serialized_name });
        } else {
            try w.print(
                \\        try object.serializeField("{s}", self.{s});
                \\
            , .{ field.serialized_name, id });
        }
    }
    try w.writeAll(
        \\        var iterator = self.additional_properties.iterator();
        \\        while (iterator.next()) |entry| {
        \\            try object.serializeEntry(entry.key_ptr.*, entry.value_ptr.*);
        \\        }
        \\        return object.end();
        \\    }
        \\
    );
}

// ─── enums.zig ────────────────────────────────────────────────────────

fn renderEnums(allocator: std.mem.Allocator, model: cm.CodeModel) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    var any_needs_core = false;
    for (model.enums) |e| {
        if (e.extensible) {
            any_needs_core = true;
            break;
        }
        // Fixed enums with values now emit serde hooks that call
        // `core.fixed_enum`, so they need the core import too.
        if (e.values.len > 0) any_needs_core = true;
    }

    try w.writeAll(
        \\//! Generated enums.
        \\//!
        \\//! Azure data-plane enums are typically *extensible* — the wire
        \\//! contract may grow with new values that older clients still
        \\//! need to round-trip. Represented as a tagged union with a
        \\//! catch-all `unrecognized` variant.
        \\
        \\const std = @import("std");
        \\
    );
    if (any_needs_core) {
        try w.writeAll(
            \\const core = @import("azure_sdk_core");
            \\
        );
    }
    try w.writeAll("\n");
    for (model.enums) |e| {
        if (e.doc) |d| try renderDocComment(w, d);
        if (e.extensible) {
            try w.print("pub const {s} = union(enum) {{\n", .{e.name});
            for (e.values) |v| {
                const snake = try naming.toSnakeCase(allocator, v.name);
                defer allocator.free(snake);
                const tag = try ids.quoteIfNeeded(allocator, snake);
                defer allocator.free(tag);
                try w.print("    {s},\n", .{tag});
            }
            try w.writeAll("    unrecognized: []const u8,\n\n");

            try w.writeAll("    const wire_names = .{\n");
            for (e.values) |v| {
                const snake = try naming.toSnakeCase(allocator, v.name);
                defer allocator.free(snake);
                const tag = try ids.quoteIfNeeded(allocator, snake);
                defer allocator.free(tag);
                const wire = wireNameForEnumValue(v);
                try w.print("        .{s} = \"{s}\",\n", .{ tag, wire });
            }
            try w.writeAll("    };\n\n");

            try w.writeAll(
                \\    pub fn zerdeDeserialize(
                \\        comptime T: type,
                \\        allocator: std.mem.Allocator,
                \\        deserializer: anytype,
                \\    ) @TypeOf(deserializer.*).Error!T {
                \\        return core.open_enum.deserialize(T, wire_names, allocator, deserializer);
                \\    }
                \\
                \\    pub fn zerdeSerialize(self: @This(), serializer: anytype) !void {
                \\        return core.open_enum.serialize(self, wire_names, serializer);
                \\    }
                \\
                \\    pub fn toWire(self: @This()) []const u8 {
                \\        return core.open_enum.toWire(self, wire_names);
                \\    }
                \\
                \\    pub fn fromWire(allocator: std.mem.Allocator, s: []const u8) !@This() {
                \\        return core.open_enum.fromWire(@This(), wire_names, allocator, s);
                \\    }
                \\};
                \\
                \\
            );
        } else {
            try w.print("pub const {s} = enum {{\n", .{e.name});
            for (e.values) |v| {
                const snake = try naming.toSnakeCase(allocator, v.name);
                defer allocator.free(snake);
                const tag = try ids.quoteIfNeeded(allocator, snake);
                defer allocator.free(tag);
                try w.print("    {s},\n", .{tag});
            }
            if (e.values.len > 0) {
                // toWire: map each variant to its fixed wire string.
                try w.writeAll("\n    pub fn toWire(self: @This()) []const u8 {\n        return switch (self) {\n");
                for (e.values) |v| {
                    const snake = try naming.toSnakeCase(allocator, v.name);
                    defer allocator.free(snake);
                    const tag = try ids.quoteIfNeeded(allocator, snake);
                    defer allocator.free(tag);
                    const wire = wireNameForEnumValue(v);
                    try w.print("            .{s} => \"{s}\",\n", .{ tag, wire });
                }
                try w.writeAll("        };\n    }\n\n");
                // fromWire: parse a wire string into a variant, or null if unknown.
                try w.writeAll("    pub fn fromWire(s: []const u8) ?@This() {\n");
                for (e.values) |v| {
                    const snake = try naming.toSnakeCase(allocator, v.name);
                    defer allocator.free(snake);
                    const tag = try ids.quoteIfNeeded(allocator, snake);
                    defer allocator.free(tag);
                    const wire = wireNameForEnumValue(v);
                    try w.print("        if (std.mem.eql(u8, s, \"{s}\")) return .{s};\n", .{ wire, tag });
                }
                try w.writeAll("        return null;\n    }\n");
                // serde hooks: route (de)serialization through the wire mapping
                // (toWire/fromWire) instead of serde's default enum handling,
                // which matches by the Zig variant identifier (snake_case) and
                // would never match the PascalCase wire form.
                try w.writeAll(
                    \\
                    \\    pub fn zerdeDeserialize(
                    \\        comptime T: type,
                    \\        allocator: std.mem.Allocator,
                    \\        deserializer: anytype,
                    \\    ) @TypeOf(deserializer.*).Error!T {
                    \\        return core.fixed_enum.deserialize(T, allocator, deserializer);
                    \\    }
                    \\
                    \\    pub fn zerdeSerialize(self: @This(), serializer: anytype) !void {
                    \\        return core.fixed_enum.serialize(self, serializer);
                    \\    }
                    \\
                );
            }
            try w.writeAll("};\n\n");
        }
    }
    return try aw.toOwnedSlice();
}

/// Choose the JSON-wire string for an enum value. Prefers the explicit
/// `value` if it parsed as a string (TypeSpec allows `Foo: "wire-form"`);
/// falls back to the variant `name` otherwise.
fn wireNameForEnumValue(v: cm.EnumValue) []const u8 {
    return switch (v.value) {
        .string => |s| s,
        else => v.name,
    };
}

// ─── build.zig / build.zig.zon ───────────────────────────────────────

fn renderBuildZig(allocator: std.mem.Allocator, pkg_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const azure_sdk_core_dep = b.dependency("azure_sdk_core", .{{
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    const azure_sdk_core_mod = azure_sdk_core_dep.module("azure_sdk_core");
        \\
        \\    const serde_dep = b.dependency("serde", .{{
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    const serde_mod = serde_dep.module("serde");
        \\
        \\    _ = b.addModule("{[name]s}", .{{
        \\        .root_source_file = b.path("src/root.zig"),
        \\        .target = target,
        \\        .imports = &.{{
        \\            .{{ .name = "azure_sdk_core", .module = azure_sdk_core_mod }},
        \\            .{{ .name = "serde", .module = serde_mod }},
        \\        }},
        \\    }});
        \\
        \\    const t = b.addTest(.{{
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("src/root.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\            .imports = &.{{
        \\                .{{ .name = "azure_sdk_core", .module = azure_sdk_core_mod }},
        \\                .{{ .name = "serde", .module = serde_mod }},
        \\            }},
        \\        }}),
        \\    }});
        \\    const test_step = b.step("test", "Run unit tests");
        \\    test_step.dependOn(&b.addRunArtifact(t).step);
        \\}}
        \\
    , .{ .name = pkg_name });
}

fn renderBuildZigZon(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    pkg_version: []const u8,
    azure_sdk_core_commit: ?[]const u8,
    azure_sdk_core_hash: ?[]const u8,
    azure_sdk_core_path: []const u8,
) ![]u8 {
    const azure_sdk_core_entry = if (azure_sdk_core_commit) |sha| blk: {
        const hash = azure_sdk_core_hash orelse return error.MissingAzureSdkCoreHash;
        break :blk try std.fmt.allocPrint(allocator,
            \\        .azure_sdk_core = .{{
            \\            .url = "git+https://github.com/cataggar/azure-sdk-for-zig.git#{s}",
            \\            .hash = "{s}",
            \\        }},
            \\
        , .{ sha, hash });
    } else try std.fmt.allocPrint(allocator,
        \\        .azure_sdk_core = .{{
        \\            .path = "{s}",
        \\        }},
        \\
    , .{azure_sdk_core_path});
    defer allocator.free(azure_sdk_core_entry);

    const serde_entry =
        \\        .serde = .{
        \\            .url = "git+https://github.com/cataggar/serde.zig#73d872776b0361b6fc92f6cecd7ccf2f05e77cdd",
        \\            .hash = "serde-1.0.1-1DszT1XhDACnteUU3yWahMMjLjkJqB34hwROPIfhZc7l",
        \\        },
        \\
    ;

    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{[name_id]s},
        \\    .version = "{[version]s}",
        \\    .fingerprint = 0x{[fp]x},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\{[sdk]s}{[serde]s}    }},
        \\    .paths = .{{
        \\        ".gitignore",
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\        "README.md",
        \\    }},
        \\}}
        \\
    , .{
        .name_id = pkg_name,
        .version = pkg_version,
        .fp = computeFingerprint(pkg_name),
        .sdk = azure_sdk_core_entry,
        .serde = serde_entry,
    });
}

/// Build a build.zig.zon fingerprint that Zig will accept.
///
/// Zig requires the high 32 bits of the `.fingerprint` value to equal
/// CRC32-IEEE of the bare package name. The low 32 bits are a random /
/// project-specific value; we derive it deterministically from the
/// package name with Wyhash so successive regenerations don't churn the
/// file.
fn computeFingerprint(pkg_name: []const u8) u64 {
    const crc: u32 = std.hash.Crc32.hash(pkg_name);
    const wy: u64 = std.hash.Wyhash.hash(0xa11302, pkg_name);
    return (@as(u64, crc) << 32) | @as(u32, @truncate(wy));
}

fn renderReadme(allocator: std.mem.Allocator, display_name: []const u8, model: cm.CodeModel) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print(
        \\# {[name]s}
        \\
        \\Generated Azure SDK client for Zig.
        \\
        \\This package is produced by `codegen` from the TypeSpec
        \\specification in [`Azure/azure-rest-api-specs`](https://github.com/Azure/azure-rest-api-specs).
        \\Do not edit generated package files by hand — they will be
        \\overwritten on the next regeneration.
        \\
        \\## Clients
        \\
    , .{ .name = display_name });
    for (model.clients) |c| {
        try w.print("- `{s}`\n", .{c.name});
    }
    return try aw.toOwnedSlice();
}

// ─── helpers ──────────────────────────────────────────────────────────

fn renderDocComment(w: *std.Io.Writer, doc: []const u8) !void {
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| try w.print("/// {s}\n", .{line});
}

/// Pick the right Zig type for a model field / method parameter:
///  * If the TypeRef is `Option<X>` we render `?X` regardless of the
///    `optional` flag.
///  * If `optional` is set but the TypeRef is not `Option<...>`, prefix
///    with `?` so the field can be omitted at serialization time.
///  * Otherwise render the TypeRef as-is.
fn renderFieldType(
    allocator: std.mem.Allocator,
    t: cm.TypeRef,
    optional: bool,
    scope: types.Scope,
) ![]u8 {
    if (t.isOption()) {
        return try types.renderType(allocator, t, scope);
    }
    if (optional) {
        const inner = try types.renderType(allocator, t, scope);
        defer allocator.free(inner);
        return try std.fmt.allocPrint(allocator, "?{s}", .{inner});
    }
    return try types.renderType(allocator, t, scope);
}

/// The model a field points at *by value*, if any.
///
/// A `[]const T` or a map already stores `T` behind a pointer, so only a
/// bare (or optional) model reference contributes to a struct's size and
/// can therefore make a type depend on itself.
fn directModelName(t: cm.TypeRef) ?[]const u8 {
    const inner = if (t.isOption()) nestedTypeRef(t) else t;
    if (inner.isArray() or inner.isMap()) return null;
    if (!inner.isModel()) return null;
    return inner.namedTypeName();
}

/// The `Model.field` pairs that have to be boxed to keep every generated
/// struct finitely sized.
///
/// Azure DevOps has genuinely recursive schemas — a `Build` carries the
/// `Build` that triggered it, a `WikiPage` carries its sub-pages — which
/// map to `field: ?Build`, a type that contains itself. Zig rejects that,
/// so one field on each cycle is emitted as `?*const Build` instead. The
/// back edge of a depth-first traversal is chosen, which is stable for a
/// given model order and breaks every cycle it belongs to.
///
/// Keys are `"Model.field"`; the caller owns the map and its keys.
const CycleBreaker = struct {
    boxed: std.StringHashMapUnmanaged(void) = .empty,
    allocator: std.mem.Allocator,

    const State = enum { unvisited, in_progress, done };

    fn init(allocator: std.mem.Allocator, models: []const cm.Model) !CycleBreaker {
        var self: CycleBreaker = .{ .allocator = allocator };
        errdefer self.deinit();

        var index: std.StringHashMapUnmanaged(usize) = .empty;
        defer index.deinit(allocator);
        for (models, 0..) |m, i| try index.put(allocator, m.name, i);

        const state = try allocator.alloc(State, models.len);
        defer allocator.free(state);
        @memset(state, .unvisited);

        for (0..models.len) |i| {
            if (state[i] == .unvisited) try self.visit(models, index, state, i);
        }
        return self;
    }

    fn visit(
        self: *CycleBreaker,
        models: []const cm.Model,
        index: std.StringHashMapUnmanaged(usize),
        state: []State,
        i: usize,
    ) !void {
        state[i] = .in_progress;
        for (models[i].fields) |f| {
            const target_name = directModelName(f.field_type) orelse continue;
            const j = index.get(target_name) orelse continue;
            switch (state[j]) {
                // Back edge: this field closes a cycle, so box it.
                .in_progress => {
                    const key = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}.{s}",
                        .{ models[i].name, f.name },
                    );
                    errdefer self.allocator.free(key);
                    const entry = try self.boxed.getOrPut(self.allocator, key);
                    if (entry.found_existing) self.allocator.free(key);
                },
                .unvisited => try self.visit(models, index, state, j),
                .done => {},
            }
        }
        state[i] = .done;
    }

    fn contains(self: CycleBreaker, model_name: []const u8, field_name: []const u8) bool {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(
            &buf,
            "{s}.{s}",
            .{ model_name, field_name },
        ) catch return false;
        return self.boxed.contains(key);
    }

    fn deinit(self: *CycleBreaker) void {
        var it = self.boxed.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.boxed.deinit(self.allocator);
    }
};

// ─── tests ────────────────────────────────────────────────────────────

test "recursive models box the back edge so the struct stays finitely sized" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // `Build.triggered_by_build: ?Build` and the two-hop
    // `Dashboard → Widget → Dashboard` are both real Azure DevOps schemas.
    var array_of_build: std.json.ObjectMap = try .init(
        alloc,
        &.{ "kind", "value" },
        &.{ .{ .string = "Model" }, .{ .string = "Build" } },
    );
    defer array_of_build.deinit(alloc);

    var build_fields = [_]cm.Field{
        .{
            .name = "triggered_by_build",
            .serialized_name = "triggeredByBuild",
            .field_type = .{ .kind = "Model", .value = .{ .string = "Build" } },
            .optional = true,
        },
        .{
            .name = "children",
            .serialized_name = "children",
            .field_type = .{
                .kind = "Array",
                .value = .{ .object = array_of_build },
            },
            .optional = true,
        },
    };
    var dashboard_fields = [_]cm.Field{.{
        .name = "widget",
        .serialized_name = "widget",
        .field_type = .{ .kind = "Model", .value = .{ .string = "Widget" } },
        .optional = true,
    }};
    var widget_fields = [_]cm.Field{.{
        .name = "dashboard",
        .serialized_name = "dashboard",
        .field_type = .{ .kind = "Model", .value = .{ .string = "Dashboard" } },
        .optional = true,
    }};
    var models = [_]cm.Model{
        .{ .name = "Build", .fields = &build_fields, .is_output = true },
        .{ .name = "Dashboard", .fields = &dashboard_fields, .is_output = true },
        .{ .name = "Widget", .fields = &widget_fields, .is_output = true },
    };
    const model: cm.CodeModel = .{
        .package_name = "azure_rest_devops",
        .package_version = "0.1.0",
        .target_kind = "dataplane",
        .service_kind = "default",
        .models = &models,
    };

    const rendered = try renderModels(alloc, model);
    defer alloc.free(rendered);

    // Direct self-reference is boxed.
    try testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "triggered_by_build: ?*const Build = null,",
    ) != null);
    // A slice already provides the indirection, so it is left alone.
    try testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "children: ?[]const Build = null,",
    ) != null);
    // Exactly one edge of the two-hop cycle is boxed.
    const widget_boxed = std.mem.indexOf(u8, rendered, "widget: ?*const Widget") != null;
    const dashboard_boxed = std.mem.indexOf(u8, rendered, "dashboard: ?*const Dashboard") != null;
    try testing.expect(widget_boxed != dashboard_boxed);
}

test "display_name surfaces in root.zig + README, not build.zig" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const model: cm.CodeModel = .{
        .package_name = "azure_rest_arm_avs",
        .package_version = "0.1.0",
        .target_kind = "arm",
        .service_kind = "default",
    };

    const root = try renderRoot(alloc, model, "arm-avs");
    defer alloc.free(root);
    try testing.expect(std.mem.indexOf(u8, root, "//! arm-avs — generated") != null);
    try testing.expect(std.mem.indexOf(u8, root, "azure_rest_arm_avs") == null);

    const readme = try renderReadme(alloc, "arm-avs", model);
    defer alloc.free(readme);
    try testing.expect(std.mem.indexOf(u8, readme, "# arm-avs\n") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "azure_rest_arm_avs") == null);

    // build.zig and build.zig.zon stay on the snake-cased package name —
    // Zig module identifiers (and `addModule` keys) must be snake_case.
    const build_zig = try renderBuildZig(alloc, "azure_rest_arm_avs");
    defer alloc.free(build_zig);
    try testing.expect(std.mem.indexOf(u8, build_zig, "\"azure_rest_arm_avs\"") != null);
    try testing.expect(std.mem.indexOf(u8, build_zig, "arm-avs") == null);

    const zon = try renderBuildZigZon(
        alloc,
        "azure_rest_arm_avs",
        "0.1.0",
        null,
        null,
        "../azure-sdk-core",
    );
    defer alloc.free(zon);
    try testing.expect(std.mem.indexOf(u8, zon, ".name = .azure_rest_arm_avs") != null);
    try testing.expect(std.mem.indexOf(u8, zon, "arm-avs") == null);
}

test "REST package metadata supports local and pinned azure_sdk_core dependencies" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const build_zig = try renderBuildZig(alloc, "azure_rest_container_registry");
    defer alloc.free(build_zig);
    try testing.expect(std.mem.indexOf(
        u8,
        build_zig,
        "b.addModule(\"azure_rest_container_registry\"",
    ) != null);

    const local_zon = try renderBuildZigZon(
        alloc,
        "azure_rest_container_registry",
        "0.1.0",
        null,
        null,
        "../../sdk/core",
    );
    defer alloc.free(local_zon);
    try testing.expect(std.mem.indexOf(
        u8,
        local_zon,
        ".name = .azure_rest_container_registry",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, local_zon, ".path = \"../../sdk/core\"") != null);
    try testing.expect(std.mem.indexOf(u8, local_zon, ".azure_sdk_core = .{") != null);

    const pinned_zon = try renderBuildZigZon(
        alloc,
        "azure_rest_container_registry",
        "0.1.0",
        "0123456789abcdef",
        "azure_sdk_core-0.1.0-example",
        "../../sdk/core",
    );
    defer alloc.free(pinned_zon);
    try testing.expect(std.mem.indexOf(
        u8,
        pinned_zon,
        "#0123456789abcdef",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        pinned_zon,
        ".hash = \"azure_sdk_core-0.1.0-example\"",
    ) != null);

    try testing.expectError(
        error.MissingAzureSdkCoreHash,
        renderBuildZigZon(
            alloc,
            "azure_rest_container_registry",
            "0.1.0",
            "0123456789abcdef",
            null,
            "../../sdk/core",
        ),
    );
}

test "sub-client accessors forward only the child's declared state and preserve the pipeline" {
    const allocator = std.testing.allocator;
    var parameters = [_]cm.InitParameter{
        .{ .name = "subscription_id", .serialized_name = "subscriptionId", .param_type = .{ .kind = "Scalar", .value = .{ .string = "string" } } },
        .{ .name = "error", .serialized_name = "error", .param_type = .{ .kind = "Scalar", .value = .{ .string = "string" } } },
    };
    var accessors = [_]cm.SubClient{
        .{ .accessor_camel = "operations", .accessor_snake = "operations", .client_name = "Operations" },
        .{ .accessor_camel = "resources", .accessor_snake = "resources", .client_name = "Resources" },
        .{ .accessor_camel = "errors", .accessor_snake = "errors", .client_name = "Errors" },
    };
    var nested = [_]cm.SubClient{
        .{ .accessor_camel = "nested", .accessor_snake = "nested", .client_name = "Nested" },
    };
    const endpoint: cm.Endpoint = .{ .name = "endpoint" };
    var clients = [_]cm.Client{
        .{ .name = "RootClient", .endpoint = endpoint, .init_parameters = &parameters, .sub_clients = &accessors },
        .{ .name = "Operations", .endpoint = endpoint, .is_root = false },
        .{ .name = "Resources", .endpoint = endpoint, .is_root = false, .init_parameters = parameters[0..1], .sub_clients = &nested },
        .{ .name = "Errors", .endpoint = endpoint, .is_root = false, .init_parameters = parameters[1..2] },
        .{ .name = "Nested", .endpoint = endpoint, .is_root = false, .init_parameters = parameters[0..1] },
    };
    const model: cm.CodeModel = .{
        .package_name = "azure_rest_fixture",
        .package_version = "0.1.0",
        .target_kind = "arm",
        .service_kind = "default",
        .clients = &clients,
    };
    const rendered = try renderClients(allocator, model);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered,
        \\    pub fn operations(self: *@This()) Operations {
        \\        return .{
        \\            .endpoint = self.endpoint,
        \\            .api_version = self.api_version,
        \\            .pipeline = self.pipeline,
        \\        };
        \\    }
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered,
        \\    pub fn resources(self: *@This()) Resources {
        \\        return .{
        \\            .endpoint = self.endpoint,
        \\            .api_version = self.api_version,
        \\            .pipeline = self.pipeline,
        \\            .subscription_id = self.subscription_id,
        \\        };
        \\    }
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered,
        \\    pub fn errors(self: *@This()) Errors {
        \\        return .{
        \\            .endpoint = self.endpoint,
        \\            .api_version = self.api_version,
        \\            .pipeline = self.pipeline,
        \\            .@"error" = self.@"error",
        \\        };
        \\    }
    ) != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, rendered, ".pipeline = self.pipeline,"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, ".subscription_id = self.subscription_id,"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, ".@\"error\" = self.@\"error\","));

    clients[2].init_parameters = &.{};
    try std.testing.expectError(error.MissingSubClientParameter, renderClients(allocator, model));
    clients[2].init_parameters = parameters[0..1];
    accessors[0].client_name = "Missing";
    try std.testing.expectError(error.UnknownSubClient, renderClients(allocator, model));
}

test "bodyless success status alternatives preserve the void API" {
    var statuses = [_]std.json.Value{ .{ .integer = 200 }, .{ .integer = 204 } };
    var statuses_200 = [_]std.json.Value{.{ .integer = 200 }};
    var statuses_204 = [_]std.json.Value{.{ .integer = 204 }};
    var responses = [_]cm.ResponseVariant{
        .{ .status_codes = &statuses_200, .body_kind = "none" },
        .{ .status_codes = &statuses_204, .body_kind = "none" },
    };
    const method: cm.Method = .{
        .name = "delete_item",
        .name_camel = "deleteItem",
        .http_method = "delete",
        .path = "/items/{name}",
        .response = .{ .status_codes = &statuses },
        .responses = &responses,
    };
    try std.testing.expect(!usesProtocolResult(method));
}

test "optional JSON request bodies are omitted when null" {
    const allocator = std.testing.allocator;
    const optional_payload = cm.TypeRef{
        .kind = "Model",
        .value = .{ .string = "Payload" },
    };
    var user_parameters = [_]cm.UserParameter{
        .{
            .name = "payload",
            .method_name = "payload",
            .param_type = optional_payload,
            .optional = true,
        },
    };
    var methods = [_]cm.Method{
        .{
            .name = "update",
            .name_camel = "update",
            .http_method = "patch",
            .path = "/item",
            .user_parameters = &user_parameters,
            .body_parameter = .{
                .user_param_name = "payload",
                .content_type = "application/json",
                .body_type = optional_payload,
                .serialization_kind = "json",
            },
            .response = .{},
        },
    };
    var clients_model = [_]cm.Client{
        .{
            .name = "OptionalBodyClient",
            .endpoint = .{ .name = "endpoint" },
            .methods = &methods,
        },
    };
    const model: cm.CodeModel = .{
        .package_name = "optional_body",
        .package_version = "0.1.0",
        .target_kind = "client",
        .service_kind = "azure-dataplane",
        .clients = &clients_model,
    };

    const clients = try renderClients(allocator, model);
    defer allocator.free(clients);
    try std.testing.expect(std.mem.indexOf(u8, clients, "if (payload) |body| {") != null);
    try std.testing.expect(std.mem.indexOf(u8, clients, "req.body = bytes;") != null);
    try std.testing.expect(std.mem.indexOf(u8, clients, "toSlice(alloc, payload)") == null);
}
