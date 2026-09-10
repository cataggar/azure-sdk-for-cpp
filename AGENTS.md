# AI Agent Guidelines

## Build and test commands

```bash
zig build
zig build test --summary all
zig build package-check --summary all
zig build package-history-check --summary all
zig fmt codegen/ eng/ build.zig
zig fmt --check codegen/ eng/ build.zig
```

## Source ownership

- `main` owns no package source. Every registered package is
  branch-owned and has no `workspace_path` in `eng/packages.zig`.
- `main` carries only shared tooling: `eng/`, `codegen/`, `doc/`,
  `scripts/`, and the workspace `build.zig`.
- Branch-owned changes target their package branch, not `main`.
- Do not restore branch-owned package source to `main`.

## Repository structure

- `eng/` — package registry, validation, history, and release tooling
- `codegen/` — TypeSpec and fixture-based package generation

Branch-owned source (including `azure_sdk_core` on `sdk/core`,
`azure_sdk_amqp` on `sdk/amqp`, and `azure_sdk_testing` on
`sdk/testing`) is available from the package branches documented in
`doc/package-catalog.md`.

## Naming conventions

- Types and structs: `PascalCase`
- Functions and methods: `camelCase`
- Constants: `snake_case`
- Files: `snake_case.zig`
- Build modules: `snake_case` with an `azure_` prefix

## Key patterns

- Runtime interfaces use function-pointer structs with `@fieldParentPtr`.
- Service clients store `core.pipeline.HttpPipeline` by value.
- List operations return `PipelinePager(T)`.
- Azure failures use `core.errors.errorFromResponse`.
- Prefer Zig over Python for repository tooling when practical.

## Package rules

- Main-owned manifests may use local paths only to Main-owned packages.
- Branch-owned manifests pin internal dependencies by full commit URL and Zig
  package hash.
- Package branch CI uses the three fixed `package-test (<os>)` contexts.
- Branch-owned releases create a lightweight tag at the reviewed branch tip;
  they do not rewrite the branch.
- History reconstruction must use `eng/package_history_map.zig`; do not infer
  ancestry from copied licenses, manifests, build files, or `.gitignore`.

## Do not

- Add C dependencies; the SDK must remain pure Zig.
- Hardcode credentials or secrets.
- Break public API signatures without justification.
- Skip `zig fmt`.
- Modify remote package refs outside the sealed reset/cutover or approved
  expected-absent branch-native bootstrap workflow.
