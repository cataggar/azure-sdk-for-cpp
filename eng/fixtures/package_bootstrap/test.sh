#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
[[ ! -L "$ROOT/.release" ]] || exit 1
mkdir -p "$ROOT/.release"
WORK="$ROOT/.release/bootstrap-self-test-$$-$RANDOM"
mkdir "$WORK"
cleanup() {
  [[ -d "$WORK" && ! -L "$WORK" && "$(cd "$WORK" && pwd -P)" == "$WORK" &&
    "$WORK" == "$ROOT/.release/bootstrap-self-test-"* ]] || return
  rm -rf -- "$WORK"
}
trap cleanup EXIT
mkdir "$WORK/home"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
export GIT_AUTHOR_NAME='Bootstrap fixture' GIT_AUTHOR_EMAIL='fixture@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_TERMINAL_PROMPT=0

TOOLING="$WORK/tooling"
REMOTE="$WORK/remote.git"
OTHER="$WORK/other.git"
SOURCE="$WORK/source"
mkdir "$TOOLING" "$SOURCE"
cp -R "$ROOT/eng" "$ROOT/scripts" "$TOOLING/"
cp "$ROOT/build.zig" "$ROOT/.gitignore" "$TOOLING/"
git init --quiet "$TOOLING"
git -C "$TOOLING" add -f eng scripts build.zig .gitignore
git -C "$TOOLING" commit --quiet -m "Offline tooling snapshot"
git init --quiet --bare "$REMOTE"
git init --quiet --bare "$OTHER"
git -C "$TOOLING" remote add origin "$REMOTE"
git init --quiet "$SOURCE"
for file in .gitignore build.zig root.zig conformance_test.zig README.md LICENSE.txt; do
  printf 'offline bootstrap fixture\n' >"$SOURCE/$file"
done
cat >"$SOURCE/build.zig.zon" <<'EOF'
.{
    .name = .azure_sdk_testing,
    .version = "0.1.0",
    .fingerprint = 0x12345678,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .azure_sdk_core = .{
            .url = "git+https://example.invalid/core#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .hash = "fixture-core-hash",
        },
    },
    .paths = .{
        ".gitignore", "build.zig", "build.zig.zon", "conformance_test.zig",
        "root.zig", "README.md", "LICENSE.txt",
    },
}
EOF
git -C "$SOURCE" add -f .
git -C "$SOURCE" commit --quiet -m "Offline reviewed template"
COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
TAG=azure_sdk_testing/v0.1.0
DESTINATION=refs/heads/sdk/core_symcrypt
git -C "$SOURCE" tag "$TAG"
git -C "$SOURCE" push --quiet "$REMOTE" \
  "HEAD:refs/heads/sdk/testing" "HEAD:refs/heads/main" "refs/tags/$TAG"
TRUSTED="file/${REMOTE#/}"
cat >"$WORK/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
trusted="$2"
shift 2
source "$ROOT/scripts/lib/package-remote.sh"
source "$ROOT/scripts/lib/package-bootstrap.sh"
bootstrap_main "$trusted" "$@"
EOF

run() { bash "$WORK/run.sh" "$TOOLING" "$TRUSTED" "$@"; }
seal() {
  run seal azure_sdk_core_symcrypt --id "$1" \
    --template-package azure_sdk_testing --template-tag "$TAG" --template-commit "$COMMIT"
}
expect_failure() {
  local label="$1" pattern="$2"
  shift 2
  if "$@" >"$WORK/failure.log" 2>&1; then
    echo "FAIL (unexpected success): $label" >&2
    exit 1
  fi
  if ! grep -Eq "$pattern" "$WORK/failure.log"; then
    echo "FAIL (wrong failure): $label" >&2
    cat "$WORK/failure.log" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}
refs() { git --git-dir="$REMOTE" for-each-ref --format='%(objectname) %(refname)' | sort; }
refs >"$WORK/before"

expect_failure "unregistered package" UnknownPackage run seal unknown --id wrong \
  --template-package azure_sdk_testing --template-tag "$TAG" --template-commit "$COMMIT"
expect_failure "reconstructed package" PackageIsNotBranchNative run seal azure_sdk_core --id wrong \
  --template-package azure_sdk_testing --template-tag "$TAG" --template-commit "$COMMIT"
expect_failure "wrong source package" UnknownSourcePackage run seal azure_sdk_core_symcrypt --id wrong \
  --template-package unknown --template-tag unknown/v0.1.0 --template-commit "$COMMIT"
expect_failure "wrong source tag" SourceTagMismatch run seal azure_sdk_core_symcrypt --id wrong \
  --template-package azure_sdk_testing --template-tag azure_sdk_core/v0.1.0 --template-commit "$COMMIT"
expect_failure "mutable source" InvalidDigest run seal azure_sdk_core_symcrypt --id wrong \
  --template-package azure_sdk_testing --template-tag "$TAG" --template-commit main
expect_failure "production refuses fixture override" 'canonical HTTPS/SSH' \
  bash "$TOOLING/scripts/package-bootstrap.sh" seal azure_sdk_core_symcrypt --id wrong \
  --template-package azure_sdk_testing --template-tag "$TAG" --template-commit "$COMMIT"
expect_failure "unexpected repository" 'unexpected repository' \
  run seal azure_sdk_core_symcrypt --id wrong --remote "$OTHER" \
  --template-package azure_sdk_testing --template-tag "$TAG" --template-commit "$COMMIT"

git -C "$TOOLING" config remote.origin.pushurl "$OTHER"
expect_failure "split fetch and push" 'repository mismatch' seal wrong
git -C "$TOOLING" config --unset remote.origin.pushurl
git -C "$TOOLING" config --add remote.origin.url "$OTHER"
expect_failure "multiple fetch URLs" 'exactly one fetch URL' seal wrong
git -C "$TOOLING" config --unset-all remote.origin.url
git -C "$TOOLING" config remote.origin.url "$REMOTE"
git -C "$TOOLING" config --add remote.origin.pushurl "$REMOTE"
git -C "$TOOLING" config --add remote.origin.pushurl "$OTHER"
expect_failure "multiple push URLs" 'exactly one fetch URL' seal wrong
git -C "$TOOLING" config --unset-all remote.origin.pushurl
git -C "$TOOLING" config url."$OTHER".insteadOf "$REMOTE"
expect_failure "URL rewrite" 'URL rewrites' seal wrong
git -C "$TOOLING" config --unset-all url."$OTHER".insteadOf
git -C "$TOOLING" config url."$OTHER".pushInsteadOf "$REMOTE"
expect_failure "push URL rewrite" 'URL rewrites' seal wrong
git -C "$TOOLING" config --unset-all url."$OTHER".pushInsteadOf

# Exercise the extracted helper and production URL allowlist without networking.
cat >"$WORK/identity.sh" <<'EOF'
set -euo pipefail
ROOT="$1"
source "$ROOT/scripts/lib/package-remote.sh"
source "$ROOT/scripts/lib/package-bootstrap.sh"
case "$2" in
  canonical) canonical_repository "$3" ;;
  url) bootstrap_url "$3" github.com/cataggar/azure-sdk-for-zig ;;
esac
EOF
for url in https://github.com/cataggar/azure-sdk-for-zig.git \
  git@github.com:cataggar/azure-sdk-for-zig.git \
  ssh://git@github.com/cataggar/azure-sdk-for-zig.git; do
  [[ "$(bash "$WORK/identity.sh" "$TOOLING" canonical "$url")" == github.com/cataggar/azure-sdk-for-zig ]]
  bash "$WORK/identity.sh" "$TOOLING" url "$url"
done
expect_failure "embedded password" 'embedded password' bash "$WORK/identity.sh" "$TOOLING" \
  canonical https://user:password@github.com/cataggar/azure-sdk-for-zig.git
for url in http://github.com/cataggar/azure-sdk-for-zig.git \
  https://user@github.com/cataggar/azure-sdk-for-zig.git \
  https://github.com/cataggar/azure-sdk-for-zig.git/ \
  ssh://git@github.com:22/cataggar/azure-sdk-for-zig.git \
  'https://github.com/cataggar/azure-sdk-for-zig.git?x=1'; do
  expect_failure "ambiguous/noncanonical URL" 'canonical HTTPS/SSH' \
    bash "$WORK/identity.sh" "$TOOLING" url "$url"
done

git -C "$SOURCE" tag -a -f "$TAG" -m annotated >/dev/null
git --git-dir="$REMOTE" fetch --quiet "$SOURCE" "+refs/tags/$TAG:refs/tags/$TAG"
expect_failure "annotated source release" 'absent, annotated, or moved' seal annotated
git --git-dir="$REMOTE" update-ref "refs/tags/$TAG" "$COMMIT"
git -C "$SOURCE" commit --quiet --allow-empty -m "Other immutable commit"
OTHER_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
git --git-dir="$REMOTE" fetch --quiet "$SOURCE" HEAD
expect_failure "unexpected source commit" 'absent, annotated, or moved' \
  run seal azure_sdk_core_symcrypt --id wrong-commit --template-package azure_sdk_testing \
  --template-tag "$TAG" --template-commit "$OTHER_COMMIT"
expect_failure "missing release tag" 'absent, annotated, or moved' \
  run seal azure_sdk_core_symcrypt --id missing-tag --template-package azure_sdk_testing \
  --template-tag azure_sdk_testing/v0.2.0 --template-commit "$COMMIT"
git --git-dir="$REMOTE" update-ref refs/tags/azure_sdk_testing/v0.2.0 "$COMMIT"
expect_failure "tag disagrees with source manifest" 'manifest does not match its release tag' \
  run seal azure_sdk_core_symcrypt --id wrong-version --template-package azure_sdk_testing \
  --template-tag azure_sdk_testing/v0.2.0 --template-commit "$COMMIT"
git --git-dir="$REMOTE" update-ref -d refs/tags/azure_sdk_testing/v0.2.0 "$COMMIT"

seal valid >"$WORK/seal.log"
ARTIFACTS="$TOOLING/.release/package-bootstrap/valid"
DIGEST="$(cat "$ARTIFACTS/sealed.complete")"
run preview --id valid --seal-sha256 "$DIGEST"
refs >"$WORK/after"
cmp "$WORK/before" "$WORK/after"
printf 'PASS: valid seal and read-only preview preserve all refs\n'
expect_failure "missing independent digest" 'independently reviewed seal digest' run execute --id valid
expect_failure "seal ID cannot overwrite artifacts" 'seal ID already exists' seal valid
expect_failure "arbitrary destination option" usage run execute --id valid --seal-sha256 "$DIGEST" --destination refs/heads/main

cp "$ARTIFACTS/manifest.tsv" "$WORK/manifest.tsv"
sed 's#refs/heads/sdk/core_symcrypt#refs/heads/main#' "$WORK/manifest.tsv" >"$ARTIFACTS/manifest.tsv"
expect_failure "tampered seal" SealDigestMismatch run preview --id valid --seal-sha256 "$DIGEST"
# Even a newly approved digest cannot authorize an arbitrary destination.
BAD_DIGEST="$(cd "$TOOLING" && zig run eng/package_bootstrap_tool.zig -- digest-file "$ARTIFACTS/manifest.tsv")"
printf '%s\n' "$BAD_DIGEST" >"$ARTIFACTS/sealed.complete"
expect_failure "noncanonical sealed destination" DestinationMismatch run execute --id valid --seal-sha256 "$BAD_DIGEST"
cp "$WORK/manifest.tsv" "$ARTIFACTS/manifest.tsv"
printf '%s\n' "$DIGEST" >"$ARTIFACTS/sealed.complete"
for field in metadata_sha256 repository fetch_url; do
  case "$field" in
    metadata_sha256) replacement="$(printf '%064d' 0)"; pattern=MetadataDigestMismatch ;;
    repository) replacement=github.com/other/repo; pattern=RepositoryMismatch ;;
    fetch_url) replacement=https://github.com/other/repo.git; pattern=RemoteUrlMismatch ;;
  esac
  awk -F '\t' -v OFS='\t' -v field="$field" -v replacement="$replacement" \
    '$1 == field {$2 = replacement} {print}' "$WORK/manifest.tsv" >"$ARTIFACTS/manifest.tsv"
  BAD_DIGEST="$(cd "$TOOLING" && zig run eng/package_bootstrap_tool.zig -- digest-file "$ARTIFACTS/manifest.tsv")"
  printf '%s\n' "$BAD_DIGEST" >"$ARTIFACTS/sealed.complete"
  expect_failure "sealed $field mismatch" "$pattern" run execute --id valid --seal-sha256 "$BAD_DIGEST"
done
cp "$WORK/manifest.tsv" "$ARTIFACTS/manifest.tsv"
printf '%s\n' "$DIGEST" >"$ARTIFACTS/sealed.complete"
cp "$ARTIFACTS/source.tar" "$WORK/source.tar"
printf 'tamper' >>"$ARTIFACTS/source.tar"
expect_failure "tampered source artifact" 'archive digest mismatch' run execute --id valid --seal-sha256 "$DIGEST"
cp "$WORK/source.tar" "$ARTIFACTS/source.tar"
printf '%064d\n' 0 >"$ARTIFACTS/sealed.complete"
expect_failure "tampered completion" 'completion digest' run execute --id valid --seal-sha256 "$DIGEST"
printf '%s\n' "$DIGEST" >"$ARTIFACTS/sealed.complete"

git --git-dir="$REMOTE" update-ref "refs/tags/$TAG" "$OTHER_COMMIT"
expect_failure "moved tag after sealing" 'absent, annotated, or moved' run execute --id valid --seal-sha256 "$DIGEST"
git --git-dir="$REMOTE" update-ref "refs/tags/$TAG" "$COMMIT"
git --git-dir="$REMOTE" update-ref "$DESTINATION" "$OTHER_COMMIT"
expect_failure "existing destination at seal" 'destination already exists' seal occupied
expect_failure "existing destination at execute" 'destination already exists' run execute --id valid --seal-sha256 "$DIGEST"
[[ "$(git --git-dir="$REMOTE" rev-parse "$DESTINATION")" == "$OTHER_COMMIT" ]]
git --git-dir="$REMOTE" update-ref -d "$DESTINATION" "$OTHER_COMMIT"

printf '\n' >>"$TOOLING/eng/packages.zig"
expect_failure "dirty metadata" 'checkout must be clean' run execute --id valid --seal-sha256 "$DIGEST"
git -C "$TOOLING" checkout -- eng/packages.zig
TOOLING_COMMIT="$(git -C "$TOOLING" rev-parse HEAD)"
git -C "$TOOLING" commit --quiet --allow-empty -m "Changed tooling revision"
expect_failure "changed tooling revision" ToolingRevisionMismatch run execute --id valid --seal-sha256 "$DIGEST"
git -C "$TOOLING" reset --quiet --hard "$TOOLING_COMMIT"

# Git reports "up to date", not lease failure, if an identical ref appears before
# push negotiation. That must not be reported as a successful branch creation.
mkdir "$WORK/bin"
REAL_GIT="$(command -v git)"
cat >"$WORK/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then
    '$REAL_GIT' --git-dir='$REMOTE' update-ref '$DESTINATION' '$COMMIT' ""
    break
  fi
done
exec '$REAL_GIT' "\$@"
EOF
chmod +x "$WORK/bin/git"
expect_failure "identical concurrent creation is not success" 'did not create a new branch' \
  env PATH="$WORK/bin:$PATH" bash "$WORK/run.sh" "$TOOLING" "$TRUSTED" \
  execute --id valid --seal-sha256 "$DIGEST"
[[ "$(git --git-dir="$REMOTE" rev-parse "$DESTINATION")" == "$COMMIT" ]]
git --git-dir="$REMOTE" update-ref -d "$DESTINATION" "$COMMIT"

# A local receive hook creates the destination after every client absence check.
cat >"$REMOTE/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
set -euo pipefail
unset GIT_QUARANTINE_PATH
git --git-dir='$REMOTE' update-ref '$DESTINATION' '$OTHER_COMMIT' ""
cat >/dev/null
EOF
chmod +x "$REMOTE/hooks/pre-receive"
expect_failure "concurrent creation loses expected-absent lease" 'cannot lock ref|reference already exists|failed to update ref|stale info' \
  run execute --id valid --seal-sha256 "$DIGEST"
[[ "$(git --git-dir="$REMOTE" rev-parse "$DESTINATION")" == "$OTHER_COMMIT" ]]
rm "$REMOTE/hooks/pre-receive"
git --git-dir="$REMOTE" update-ref -d "$DESTINATION" "$OTHER_COMMIT"
refs >"$WORK/after"
cmp "$WORK/before" "$WORK/after"

run execute --id valid --seal-sha256 "$DIGEST"
[[ "$(git --git-dir="$REMOTE" rev-parse "$DESTINATION")" == "$COMMIT" ]]
refs | grep -v " $DESTINATION$" >"$WORK/after"
cmp "$WORK/before" "$WORK/after"
[[ "$(refs | wc -l)" -eq "$(($(wc -l <"$WORK/before") + 1))" ]]
expect_failure "completed seal is not replayable" 'destination already exists' run execute --id valid --seal-sha256 "$DIGEST"
printf 'PASS: exactly one branch created; every unrelated ref and all tags unchanged\n'
printf 'package bootstrap offline fixtures passed\n'
