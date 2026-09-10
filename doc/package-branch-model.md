# Package Branch Model

The repository separates package catalog ownership from package source
ownership. `eng/packages.zig` remains the catalog for all supported packages;
every package's source lives on its package branch, while `main` carries only
shared tooling (`eng/`, `codegen/`, `doc/`, `scripts/`, and the workspace
`build.zig`).

## Ownership classes

### Branch-owned packages

Every registered package uses `.ownership = .branch_owned`. Their
registry entries retain package identity, branch, dependencies, release
commands, and `historical_source_path`, but have no `workspace_path`. `main`
owns no package source, so root builds run only workspace tooling and the
fixture consumer that pins `azure_sdk_core` by immutable commit and hash.

The package branch is the development branch and contains the package at its
repository root. Changes are made on feature branches and merged through pull
requests whose base is the package branch, not `main`.

Examples:

```text
feature/storage-retry -> sdk/storage_blobs
feature/kusto-status  -> sdk/kusto
generated/acr-1234    -> rest/container_registry
```

One branch-owned package can expose multiple public namespaces. The
`azure_sdk_kusto` package and module on `sdk/kusto` expose `common`, `data`,
and `ingest`; those namespaces are not separate packages or compatibility
aliases. Likewise, `azure_sdk_core` on `sdk/core` exposes `tracing` and `perf`
as namespaces (`core.tracing`, `core.perf`) rather than separate packages.

## Required package-branch checks

Every package branch uses the same protected check contexts:

```text
package-test (ubuntu-latest)
package-test (windows-latest)
package-test (macos-latest)
```

Render the canonical workflow into a package worktree with:

```bash
scripts/package-branch-release.sh render-ci \
  azure_sdk_storage_blobs \
  .github/workflows/package-ci.yml
```

The workflow checks formatting, runs package tests, builds examples when
declared, and compiles live tests without credentials when declared.

## Dependency rules

Released packages never use local `.path` dependencies. Package branches pin
every internal dependency with:

- the dependency package's release commit in `.url`;
- the matching Zig package `.hash`; and
- a package-scoped release tag that resolves to the same commit.

Branch-owned packages must never depend on untagged commits or workspace-local
paths.

## History preservation

`eng/package_history_map.zig` records reviewed current and historical path
mappings for every branch-owned package. Boilerplate files such as copied
licenses and manifests are explicitly excluded as ancestry evidence.

Packages created directly on their package branch are marked `branch_native`
and have no historical path mappings. History reconstruction skips them
instead of inventing a Main-owned source path.

`scripts/package-history-reset.sh` uses pinned `git-filter-repo` behavior to
produce candidate repositories, path maps, and commit maps. The completed
cutover and retained recovery refs are documented in the
[package reset record](package-reset-2026-07-24.md).

## Generated packages

`codegen/scripts/sync.sh --output-root` writes TypeSpec output into an external
package worktree and requires either an explicit Core worktree path or an
immutable Core commit/hash pin. Container Registry regeneration also accepts
external REST and SDK worktree roots.

Generated pull requests record the generator commit in
`.azure-sdk-generator`. The manual `Update generated package` workflow creates
Container Registry pull requests directly against its package branch.

## Tags and releases

Package tags are lightweight refs named:

```text
<package-name>/v<semver>
```

For branch-owned packages, releasing creates only the new tag at the already
reviewed branch tip. Release tooling does not synthesize or advance the package
branch. This includes Core-family packages; no package currently uses the
staged Main-owned release process. See [Releasing Packages](releasing-packages.md).
