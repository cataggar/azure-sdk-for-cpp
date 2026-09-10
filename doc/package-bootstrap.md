# Sealed branch-native package bootstrap

This narrowly scoped workflow creates **one absent registered package branch**.
It cannot replace branches, create tags, change Main, alter rulesets, or bypass
branch protection. It is separate from the completed global history reset.

## Review boundaries and prerequisites

1. Merge the shared bootstrap tooling through normal Main review and checks.
2. Separately review and merge the new package's canonical registry/catalog
   metadata. Its entry in `eng/package_history_map.zig` must explicitly use
   `.branch_native` with no reconstruction mappings. Main must contain no
   package source. This workflow does not register packages.
3. Select a **reviewed existing package release** in
   `cataggar/azure-sdk-for-zig`: a registered branch-owned template package,
   its exact stable release tag, and the full 40-character commit ID. The
   tag must be lightweight and still point directly to that commit.
   Review the release's source and embedded workflows, including behavior on
   branch creation. A tag alone is not proof of human approval: record the
   reviewed release/PR and approval to use it as a bootstrap template.
4. Use a clean checkout of the reviewed shared-tooling/metadata commit.
   The checkout's exact HEAD and a digest of its `eng/`, `scripts/`, and
   `build.zig` tree entries are sealed. Do not change checkout revisions
   between sealing and execution. No mutable branch name is evidence.

The template commit is used **unchanged**, not copied into a fabricated history
or republished under the new package name. Its identity remains that of the
template. The Git parentage records the explicit seed choice; it is not evidence
of reconstructed package ancestry. Only an ordinary reviewed PR against the
newly created branch replaces the template with the real implementation,
canonical package identity, immutable dependencies, documentation, and CI.
Until then, the new branch is not an implemented or released package.

## Seal, review, preview, execute

Commands below use placeholders; select actual registered metadata and a
reviewed template before running them:

```bash
scripts/package-bootstrap.sh seal PACKAGE \
  --id BOOTSTRAP_ID \
  --template-package TEMPLATE_PACKAGE \
  --template-tag TEMPLATE_PACKAGE/vVERSION \
  --template-commit FULL_RELEASE_COMMIT \
  --remote origin
```

The ID must use 1–64 lowercase letters, digits, or hyphens, start with a letter
or digit, and not start with `work-`. It must not already exist. Paths are fixed
under `.release/package-bootstrap/BOOTSTRAP_ID/`:

| Artifact | Meaning |
| --- | --- |
| `manifest.tsv` | Versioned, strict ordered data: canonical package/destination; template package/tag/commit; trusted repository and exact fetch/push URLs; tooling commit; metadata/tooling and source-archive SHA256 digests. |
| `source.tar` | Exact Git archive of the immutable template commit; retained for review, never trusted as an executable input. Maximum supported archive size is 256 MiB. |
| `sealed.complete` | SHA256 of the completed manifest, written only after all sealing checks succeed. |

Review the manifest and template artifacts, record the full manifest SHA256 in
the approval record **outside the seal directory**, then pass that independently
reviewed value explicitly:

```bash
scripts/package-bootstrap.sh preview \
  --id BOOTSTRAP_ID --seal-sha256 REVIEWED_MANIFEST_SHA256 --remote origin

scripts/package-bootstrap.sh execute \
  --id BOOTSTRAP_ID --seal-sha256 REVIEWED_MANIFEST_SHA256 --remote origin
```

Do not substitute `$(cat .../sealed.complete)` for the reviewed digest during
execution: a checksum stored beside editable artifacts does not authenticate
approval. The seal is an integrity/review boundary, not a digital signature.

Both operations verify seal integrity and exact current metadata/repository
identity, re-fetch the original release tag into an isolated bare repository,
require a lightweight commit matching the seal, recreate and compare the archive,
and validate the template using the existing branch and immutable-manifest
validators. Source symlinks/gitlinks are rejected before extraction. Bootstrap
does not run template code or rebuild its dependencies: successful release CI
and source review are prerequisites, not assertions made by this workflow.
The template manifest must still match current registry publish/dependency
metadata and the selected release tag.

Preview performs no remote ref writes. Execute repeats tag and absence checks
on both fetch/push endpoints, then submits precisely:

```text
git push --no-follow-tags --recurse-submodules=no \
  --force-with-lease=refs/heads/CANONICAL_BRANCH: \
  PUSH_URL SEALED_COMMIT:refs/heads/CANONICAL_BRANCH
```

There is exactly one refspec and one explicit expected-absent lease. A concurrent
creator wins without being overwritten; the bootstrap fails. Server protection
is authoritative. Never relax it or add generic force to make bootstrap pass.
Execution requires an explicit new-branch push result, not an "up to date"
response from a concurrent identical ref, and verifies the destination OID.
If the server accepted the
push but the response/verification was interrupted, inspect that exact ref:
do not retry blindly, delete it, or treat an existing branch as successful
bootstrap. Retrying a completed seal fails because the destination exists.

Only canonical HTTPS and `git` SSH URLs for the trusted repository are accepted.
Fetch/push identities must agree, with exactly one URL each. Password-bearing,
ambiguous, alternate-repository, HTTP, and rewritten URLs are rejected, as are
ambient Git repository/config overrides. There is no production local-remote,
arbitrary destination, candidate-commit, or protection-bypass option.

All work is local under the fixed `.release/package-bootstrap/` directory.
Cleanup removes only the operation's owned resolved `work-*` subdirectory.
Artifacts remain for review; failed seals remain incomplete and require a fresh
ID. Changing tooling, metadata, URLs, or template releases requires a new seal
and fresh review. A source release tag moved before a later check causes failure;
even if a tag moves after the final check, the only push source is the sealed
commit, never the moving tag.

## Offline validation

```bash
zig build package-bootstrap-test --summary all
```

The existing Zig/Bash runners exercise strict seal/metadata unit tests and
isolated local fixture repositories. The production entry point never accepts
the fixture trust context. Tests cover canonical/native identities, template
provenance, coherent remotes, annotated/moved tags, tampering, pre-existing and
concurrently created destinations, and preservation of every unrelated ref and
tag. No test publishes to GitHub.
