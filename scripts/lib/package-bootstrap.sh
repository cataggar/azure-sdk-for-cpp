#!/usr/bin/env bash

bootstrap_usage() {
  cat >&2 <<'EOF'
usage: package-bootstrap.sh seal PACKAGE --id ID --template-package PACKAGE
         --template-tag TAG --template-commit COMMIT [--remote REMOTE]
       package-bootstrap.sh preview|execute --id ID --seal-sha256 SHA256 [--remote REMOTE]

Artifacts: .release/package-bootstrap/ID/{manifest.tsv,source.tar,sealed.complete}
Review the manifest and record its SHA256 independently before preview/execute.
EOF
}

bootstrap_fail() {
  echo "package bootstrap: $*" >&2
  exit 1
}

bootstrap_tool() {
  (cd "$ROOT" && zig run eng/package_bootstrap_tool.zig -- "$@")
}

bootstrap_sha256() {
  bootstrap_tool digest-file "$1"
}

bootstrap_url() {
  local url="$1" trusted="$2"
  if [[ "$trusted" == github.com/cataggar/azure-sdk-for-zig ]]; then
    case "$url" in
      https://github.com/cataggar/azure-sdk-for-zig|https://github.com/cataggar/azure-sdk-for-zig.git|\
      git@github.com:cataggar/azure-sdk-for-zig|git@github.com:cataggar/azure-sdk-for-zig.git|\
      ssh://git@github.com/cataggar/azure-sdk-for-zig|ssh://git@github.com/cataggar/azure-sdk-for-zig.git)
        ;;
      *) bootstrap_fail "only unambiguous canonical HTTPS/SSH repository URLs are accepted" ;;
    esac
  else
    # Only the offline test runner supplies a local trust context.
    [[ "$url" == /* && -d "$url" && ! -L "$url" &&
      "$url" == "$(cd "$url" && pwd -P)" ]] ||
      bootstrap_fail "fixture remote must be an exact resolved directory"
  fi
  [[ "$(canonical_repository "$url")" == "$trusted" ]] ||
    bootstrap_fail "unexpected repository"
}

bootstrap_remote() {
  local remote="$1" trusted="$2" config
  config="$(git -C "$ROOT" config --list)"
  [[ ! "$config" =~ url\..*\.(insteadof|pushinsteadof)= ]] ||
    bootstrap_fail "Git URL rewrites are not allowed"
  resolve_remote_identity "$remote"
  bootstrap_url "$FETCH_URL" "$trusted"
  bootstrap_url "$PUSH_URL" "$trusted"
}

bootstrap_absent() {
  local url="$1" destination="$2" refs
  refs="$(git -C "$ROOT" ls-remote --refs "$url" "$destination")"
  [[ -z "$refs" ]] || bootstrap_fail "destination already exists: $destination"
}

bootstrap_tag() {
  local url="$1" tag="$2" commit="$3" refs
  refs="$(git -C "$ROOT" ls-remote "$url" "refs/tags/$tag" "refs/tags/$tag^{}")"
  [[ "$refs" == "$commit"$'\t'"refs/tags/$tag" ]] ||
    bootstrap_fail "release tag is absent, annotated, or moved: $tag"
}

bootstrap_clean() {
  local status metadata
  status="$(git -C "$ROOT" status --porcelain --untracked-files=normal)"
  [[ -z "$status" ]] ||
    bootstrap_fail "reviewed tooling checkout must be clean"
  TOOLING_COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD)"
  metadata="$(git -C "$ROOT" ls-tree -r "$TOOLING_COMMIT" -- eng scripts build.zig)"
  METADATA_SHA256="$(bootstrap_tool digest-text "$metadata")"
}

bootstrap_directory() {
  local path="$1"
  [[ ! -L "$path" ]] || bootstrap_fail "symlink directory: $path"
  mkdir -p "$path"
  [[ "$(cd "$path" && pwd -P)" == "$path" ]] ||
    bootstrap_fail "directory is not resolved: $path"
}

bootstrap_cleanup() {
  if [[ -n "${BOOTSTRAP_WORK:-}" && -d "$BOOTSTRAP_WORK" &&
    ! -L "$BOOTSTRAP_WORK" &&
    "$(cd "$BOOTSTRAP_WORK" && pwd -P)" == "$BOOTSTRAP_WORK" &&
    "$BOOTSTRAP_WORK" == "$ROOT/.release/package-bootstrap/work-"* ]]; then
    rm -rf -- "$BOOTSTRAP_WORK"
  fi
}

bootstrap_git() {
  git -c core.hooksPath="$BOOTSTRAP_WORK/empty-hooks" \
    -c core.attributesFile=/dev/null -c push.followTags=false \
    --git-dir="$BOOTSTRAP_WORK/repository.git" "$@"
}

bootstrap_source() {
  local package="$1" tag="$2" commit="$3" config actual_tag
  bootstrap_tag "$FETCH_URL" "$tag" "$commit"
  bootstrap_tag "$PUSH_URL" "$tag" "$commit"
  mkdir "$BOOTSTRAP_WORK/empty-hooks"
  git init --quiet --bare --template="$BOOTSTRAP_WORK/empty-hooks" "$BOOTSTRAP_WORK/repository.git"
  config="$(bootstrap_git config --list)"
  [[ ! "$config" =~ url\..*\.(insteadof|pushinsteadof)= ]] ||
    bootstrap_fail "Git URL rewrites are not allowed in the isolated repository"
  bootstrap_git fetch --quiet --no-tags "$FETCH_URL" "refs/tags/$tag"
  [[ "$(bootstrap_git rev-parse FETCH_HEAD)" == "$commit" &&
    "$(bootstrap_git cat-file -t "$commit")" == commit ]] ||
    bootstrap_fail "fetched release is not the sealed lightweight commit"
  # Reject symlinks and gitlinks before archive extraction, not afterwards.
  bootstrap_git ls-tree -r "$commit" >"$BOOTSTRAP_WORK/tree.tsv"
  if grep -Ev '^(100644|100755) blob ' "$BOOTSTRAP_WORK/tree.tsv" >/dev/null; then
    bootstrap_fail "template contains a symlink, gitlink, or unsupported tree entry"
  fi
  bootstrap_git archive --format=tar "$commit" >"$BOOTSTRAP_WORK/source.tar"
  mkdir "$BOOTSTRAP_WORK/tree"
  tar -xf "$BOOTSTRAP_WORK/source.tar" -C "$BOOTSTRAP_WORK/tree"
  (cd "$ROOT" && zig run eng/package_branch_tool.zig -- validate-tree "$package" "$BOOTSTRAP_WORK/tree")
  (cd "$ROOT" && zig run eng/candidate_manifest_tool.zig -- validate "$BOOTSTRAP_WORK/tree")
  actual_tag="$(cd "$ROOT" && zig run eng/package_branch_tool.zig -- tag "$package" "$BOOTSTRAP_WORK/tree")"
  [[ "$actual_tag" == "$tag" ]] || bootstrap_fail "template manifest does not match its release tag"
}

bootstrap_main() (
  set -euo pipefail
  local trusted="$1"
  shift
  local mode="${1:-}" package="" id="" source_package="" tag="" commit=""
  local remote=origin remote_seen=false expected_digest="" destination="" archive_digest="" digest="" record=""
  [[ -n "$mode" ]] || { bootstrap_usage; exit 2; }
  shift
  case "$mode" in
    seal)
      package="${1:-}"
      [[ -n "$package" ]] || { bootstrap_usage; exit 2; }
      shift
      ;;
    preview|execute) ;;
    *) bootstrap_usage; exit 2 ;;
  esac
  while (($#)); do
    [[ $# -ge 2 && -n "$2" ]] || { bootstrap_usage; exit 2; }
    case "$1" in
      --id) [[ -z "$id" ]] || bootstrap_fail "duplicate --id"; id="$2" ;;
      --remote) [[ "$remote_seen" == false ]] || bootstrap_fail "duplicate --remote"; remote_seen=true; remote="$2" ;;
      --template-package) [[ -z "$source_package" ]] || bootstrap_fail "duplicate template"; source_package="$2" ;;
      --template-tag) [[ -z "$tag" ]] || bootstrap_fail "duplicate tag"; tag="$2" ;;
      --template-commit) [[ -z "$commit" ]] || bootstrap_fail "duplicate commit"; commit="$2" ;;
      --seal-sha256) [[ -z "$expected_digest" ]] || bootstrap_fail "duplicate digest"; expected_digest="$2" ;;
      *) bootstrap_usage; exit 2 ;;
    esac
    shift 2
  done
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]{0,63}$ && "$id" != work-* ]] ||
    bootstrap_fail "invalid seal ID"
  [[ "$remote" != -* && "$remote" != *$'\n'* && "$remote" != *$'\r'* ]] ||
    bootstrap_fail "invalid remote"
  if [[ "$mode" == seal ]]; then
    [[ -n "$source_package" && -n "$tag" && -n "$commit" && -z "$expected_digest" ]] ||
      bootstrap_fail "seal requires only template inputs"
    destination="$(bootstrap_tool target "$package" "$source_package" "$tag" "$commit")"
  else
    [[ -z "$source_package" && -z "$tag" && -z "$commit" &&
      "$expected_digest" =~ ^[0-9a-f]{64}$ ]] ||
      bootstrap_fail "preview/execute require only an independently reviewed seal digest"
  fi
  if env | grep -Eq '^GIT_(DIR|WORK_TREE|COMMON_DIR|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|NAMESPACE|CONFIG|CONFIG_PARAMETERS|CONFIG_COUNT|SHALLOW_FILE|REPLACE_REF_BASE)='; then
    bootstrap_fail "ambient Git repository/config overrides are not allowed"
  fi
  export GIT_NO_REPLACE_OBJECTS=1
  bootstrap_clean
  bootstrap_remote "$remote" "$trusted"
  local sealed_revision="$TOOLING_COMMIT" sealed_metadata="$METADATA_SHA256"
  local sealed_fetch="$FETCH_URL" sealed_push="$PUSH_URL"
  bootstrap_directory "$ROOT/.release"
  bootstrap_directory "$ROOT/.release/package-bootstrap"
  local output="$ROOT/.release/package-bootstrap/$id"
  if [[ "$mode" == seal ]]; then
    bootstrap_absent "$FETCH_URL" "$destination"
    bootstrap_absent "$PUSH_URL" "$destination"
    mkdir "$output" || bootstrap_fail "seal ID already exists"
  else
    [[ -d "$output" && ! -L "$output" ]] || bootstrap_fail "missing seal directory"
    local artifact
    for artifact in manifest.tsv source.tar sealed.complete; do
      [[ -f "$output/$artifact" && ! -L "$output/$artifact" ]] ||
        bootstrap_fail "missing or symlink seal artifact: $artifact"
    done
    [[ "$(cat "$output/sealed.complete")" == "$expected_digest" ]] ||
      bootstrap_fail "completion digest does not match reviewed seal"
    record="$(bootstrap_tool verify "$output/manifest.tsv" "$expected_digest" \
      "$TOOLING_COMMIT" "$METADATA_SHA256" "$trusted" "$FETCH_URL" "$PUSH_URL")"
    IFS=$'\t' read -r package destination source_package tag commit archive_digest <<<"$record"
    [[ "$(bootstrap_sha256 "$output/source.tar")" == "$archive_digest" ]] ||
      bootstrap_fail "sealed source archive digest mismatch"
    bootstrap_absent "$FETCH_URL" "$destination"
    bootstrap_absent "$PUSH_URL" "$destination"
  fi
  BOOTSTRAP_WORK="$ROOT/.release/package-bootstrap/work-$$-$RANDOM"
  mkdir "$BOOTSTRAP_WORK"
  trap bootstrap_cleanup EXIT
  bootstrap_source "$source_package" "$tag" "$commit"
  digest="$(bootstrap_sha256 "$BOOTSTRAP_WORK/source.tar")"
  if [[ "$mode" == seal ]]; then
    cp "$BOOTSTRAP_WORK/source.tar" "$output/source.tar"
    expected_digest="$(bootstrap_tool seal "$package" "$source_package" "$tag" "$commit" \
      "$trusted" "$FETCH_URL" "$PUSH_URL" "$TOOLING_COMMIT" "$METADATA_SHA256" "$digest" "$output/manifest.tsv")"
  else
    [[ "$digest" == "$archive_digest" ]] || bootstrap_fail "refetched source archive digest mismatch"
  fi
  # Repeat read-only checks after source validation, including the push endpoint.
  bootstrap_clean
  [[ "$TOOLING_COMMIT" == "$sealed_revision" && "$METADATA_SHA256" == "$sealed_metadata" ]] ||
    bootstrap_fail "tooling changed during verification"
  bootstrap_remote "$remote" "$trusted"
  [[ "$FETCH_URL" == "$sealed_fetch" && "$PUSH_URL" == "$sealed_push" ]] ||
    bootstrap_fail "remote URLs changed during verification"
  bootstrap_tag "$FETCH_URL" "$tag" "$commit"
  bootstrap_tag "$PUSH_URL" "$tag" "$commit"
  bootstrap_absent "$FETCH_URL" "$destination"
  bootstrap_absent "$PUSH_URL" "$destination"
  if [[ "$mode" == seal ]]; then
    printf '%s\n' "$expected_digest" >"$output/sealed.complete"
    printf 'sealed %s\nmanifest: %s/manifest.tsv\nSHA256: %s\n' "$id" "$output" "$expected_digest"
  elif [[ "$mode" == preview ]]; then
    printf 'preview: create %s at %s from %s (no release)\n' "$destination" "$commit" "$tag"
  else
    # One explicit refspec and one empty expected-old OID: never replace a branch.
    bootstrap_git push --porcelain --no-follow-tags --recurse-submodules=no \
      "--force-with-lease=$destination:" "$PUSH_URL" "$commit:$destination" >"$BOOTSTRAP_WORK/push-result.tsv"
    cat "$BOOTSTRAP_WORK/push-result.tsv"
    grep -Fx -- "*"$'\t'"$commit:$destination"$'\t'"[new branch]" "$BOOTSTRAP_WORK/push-result.tsv" >/dev/null ||
      bootstrap_fail "push did not create a new branch; a concurrent identical ref is not bootstrap success"
    record="$(git -C "$ROOT" ls-remote --refs "$PUSH_URL" "$destination")"
    [[ "$record" == "$commit"$'\t'"$destination" ]] ||
      bootstrap_fail "post-push verification failed; inspect the exact destination, do not retry blindly"
    printf 'created %s at %s; no release tag created\n' "$destination" "$commit"
  fi
)
