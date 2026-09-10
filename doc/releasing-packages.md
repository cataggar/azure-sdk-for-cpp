# Releasing Packages

Release commands depend on source ownership in `eng/packages.zig`.

## Core-family releases

`azure_sdk_core`, `azure_sdk_core_symcrypt`, `azure_sdk_amqp`, and
`azure_sdk_testing` are branch-owned and release through the branch-owned flow
below, like every other package.

The staged release workflow in `scripts/package-release.sh` applies only to
Main-owned packages. No package is currently Main-owned, so the staged engine
governs no packages today; it is retained for any future Main-owned package
and exercised by the offline regression suite:

```bash
scripts/package-release.sh self-test
```

## Branch-owned releases

Branch-owned packages are tested and tagged from their package branch:

```bash
scripts/package-branch-release.sh verify azure_sdk_storage_blobs
scripts/package-branch-release.sh publish azure_sdk_storage_blobs
scripts/package-branch-release.sh publish azure_sdk_storage_blobs --execute
```

`verify` fetches the remote package branch into an isolated tree and checks:

- package identity, version, declared paths, and required files;
- immutable internal and external dependency pins;
- internal dependency commits protected by package release tags;
- Zig package hashes by fetching each internal dependency;
- the package-specific test, example, and live-test commands registered in
  `eng/packages.zig`.

The `Package release verification` workflow runs the same read-only verification
after validating the shared registry and history mappings:

```bash
gh workflow run package-release-verify.yml \
  --repo cataggar/azure-sdk-for-zig \
  --ref main \
  -f package=azure_sdk_storage_blobs
```

It accepts any registered branch-owned package. It does not prepare a Main-owned
release stage, publish tags, or advance package branches.

`azure_sdk_core_symcrypt` uses source-only checks during sealed verification
because release tooling has no ambient native SymCrypt binaries. Its package
pull-request CI validates the native dynamic/static tests and examples on
Linux and Windows, plus the supported Arm64 build matrix. Release review must
confirm those checks completed successfully before merge.

`publish` additionally requires a release version greater than every existing
package tag. Without `--execute` it prints the proposed lightweight tag.
Execution creates the tag with an expected-absent lease and does not move the
package branch.

Cross-package changes move in dependency order. Merge and release the
dependency package first, then update each dependent package in a separate
package-branch pull request with the new immutable commit/hash pin.

For Kusto, finalize Core, Storage Common, Storage Blobs, and Storage Queues
pins before finalizing `azure_sdk_kusto`; its manifest also pins the external
`serde` dependency.

## Completed one-time reset

The 2026-07-24 package reset established 18 non-Core package branches and
their `v0.1.0` tags from history-preserving candidate commits. Seventeen
package identities replaced existing branch and tag refs. Kusto consolidated into the
single `azure_sdk_kusto` package and module on `sdk/kusto`, version `0.1.0`,
with public `common`, `data`, and `ingest` namespaces.

The cutover archived and deleted `sdk/kusto_common`, `sdk/kusto_data`, and
`sdk/kusto_ingest` and their corresponding
`azure_sdk_kusto_common/v0.1.0`, `azure_sdk_kusto_data/v0.1.0`, and
`azure_sdk_kusto_ingest/v0.1.0` tags. It created `sdk/kusto` and
`azure_sdk_kusto/v0.1.0` with expected-absent leases in the same global atomic
transaction. No compatibility branches, packages, or aliases are retained.

The cutover:

1. Record every old branch and tag object ID.
2. Push immutable archive refs.
3. Create a checksummed Git bundle containing all old refs.
4. Seal 18 package candidates, dependency pins, generated provenance, and
   three example candidates.
5. Use one exact-lease atomic push during the approved ruleset maintenance
   window.

The recreated tags produced new Zig package hashes. Consumers must replace old
`v0.1.0` hashes with the hashes from the recreated tags. The old `arm_avs` and
`keyvault_secrets` identities remain provenance notes only; they are not
accepted release identities after the reset.

The aggregate `sdk/aggregate` branch and `azure_sdk/v0.1.0` tag were retired
during that cutover. They are not valid dependencies for new packages.

The existing `example/arm_avs` and `example/arm_avs_wasi` branches received
fast-forward compatibility commits. The standalone Kusto project was created
as the expected-absent `example/kusto` branch in the same transaction; example
branches do not receive package release tags.

See the [package reset record](package-reset-2026-07-24.md) for exact commits,
archive refs, artifact digests, and recovery details.
