#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/package-remote.sh"

usage() {
  cat >&2 <<'EOF'
usage: package-branch-release.sh verify PACKAGE [--remote REMOTE] [--skip-tests]
       package-branch-release.sh publish PACKAGE [--remote REMOTE] [--execute]
       package-branch-release.sh render-ci PACKAGE OUTPUT
EOF
}

branch_tool() {
  (cd "$ROOT" && zig run eng/package_branch_tool.zig -- "$@")
}

remote_tag_commit() {
  local remote_url="$1"
  local tag="$2"
  local direct peeled
  direct="$(git -C "$ROOT" ls-remote "$remote_url" "refs/tags/$tag" | awk 'NR == 1 { print $1 }')"
  peeled="$(git -C "$ROOT" ls-remote "$remote_url" "refs/tags/$tag^{}" | awk 'NR == 1 { print $1 }')"
  if [[ -n "$peeled" ]]; then
    echo "$tag is annotated; package release tags must be lightweight" >&2
    exit 1
  fi
  printf '%s\n' "$direct"
}

verify_dependency() {
  local remote_url="$1"
  local work="$2"
  local name="$3"
  local url="$4"
  local expected_hash="$5"
  local commit="${url##*#}"
  [[ "$url" == *"#"* && "$commit" =~ ^[0-9a-f]{40}$ ]] || {
    echo "$name: dependency URL does not end in a full commit ID" >&2
    exit 1
  }
  if ! git -C "$ROOT" ls-remote --tags "$remote_url" "refs/tags/$name/v*" |
    awk -v commit="$commit" '$1 == commit { found = 1 } END { exit !found }'
  then
    echo "$name: dependency commit is not protected by a package release tag" >&2
    exit 1
  fi
  local actual_hash
  mkdir -p "$work/home" "$work/tmp" "$work/zig-global-cache"
  actual_hash="$(
    env -i \
      PATH="$PATH" \
      HOME="$work/home" \
      TMPDIR="$work/tmp" \
      GIT_CONFIG_GLOBAL=/dev/null \
      zig fetch --global-cache-dir "$work/zig-global-cache" "$url"
  )"
  [[ "$actual_hash" == "$expected_hash" ]] || {
    echo "$name: dependency hash mismatch" >&2
    exit 1
  }
}

verify_package() {
  local package="$1"
  local remote="$2"
  local run_tests="$3"
  local require_unreleased="$4"
  local work repository tree published branch tip tag tag_commit
  work="$(mktemp -d "${TMPDIR:-/tmp}/package-branch-release.XXXXXX")"
  trap 'rm -rf "$work"' RETURN
  repository="$work/repository.git"
  tree="$work/tree"
  published="$work/published"
  branch="$(branch_tool metadata "$package" | awk -F '\t' '$1 == "branch" { print $2 }')"
  [[ -n "$branch" ]] || {
    echo "$package: branch metadata is missing" >&2
    exit 1
  }

  git init --quiet --bare "$repository"
  git --git-dir="$repository" fetch --quiet --no-tags "$FETCH_URL" "refs/heads/$branch"
  tip="$(git --git-dir="$repository" rev-parse FETCH_HEAD)"
  mkdir -p "$tree"
  git --git-dir="$repository" archive "$tip" | tar -x -C "$tree"
  branch_tool validate-tree "$package" "$tree"
  mkdir -p "$published"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    mkdir -p "$published/$(dirname "$path")"
    cp -a "$tree/$path" "$published/$path"
  done < <(branch_tool publish-paths "$package")
  branch_tool validate-tree "$package" "$published"
  tag="$(branch_tool tag "$package" "$published")"
  tag_commit="$(remote_tag_commit "$FETCH_URL" "$tag")"
  if [[ -n "$tag_commit" && "$tag_commit" != "$tip" ]]; then
    echo "$package: $tag does not match the package branch tip" >&2
    exit 1
  fi
  if [[ "$require_unreleased" == true && -n "$tag_commit" ]]; then
    echo "$package: release tag already exists: $tag" >&2
    exit 1
  fi

  while IFS=$'\t' read -r dependency url package_hash; do
    [[ -n "$dependency" ]] || continue
    verify_dependency "$FETCH_URL" "$work" "$dependency" "$url" "$package_hash"
  done < <(branch_tool dependencies "$package" "$published")

  if [[ "$run_tests" == true ]]; then
    local test_command examples_command live_test_command
    test_command="$(branch_tool metadata "$package" | awk -F '\t' '$1 == "test" { print $2 }')"
    examples_command="$(branch_tool metadata "$package" | awk -F '\t' '$1 == "examples" { print $2 }')"
    live_test_command="$(branch_tool metadata "$package" | awk -F '\t' '$1 == "live-test" { print $2 }')"
    mkdir -p "$work/home" "$work/tmp" "$work/zig-global-cache" "$work/xdg-cache"
    isolated_env=(
      env -i
      PATH="$PATH"
      HOME="$work/home"
      TMPDIR="$work/tmp"
      XDG_CACHE_HOME="$work/xdg-cache"
      ZIG_GLOBAL_CACHE_DIR="$work/zig-global-cache"
      GIT_CONFIG_GLOBAL=/dev/null
      CI=1
    )
    [[ -z "${SYSTEMROOT:-}" ]] || isolated_env+=("SYSTEMROOT=$SYSTEMROOT")
    [[ -z "${WINDIR:-}" ]] || isolated_env+=("WINDIR=$WINDIR")
    [[ -z "${COMSPEC:-}" ]] || isolated_env+=("COMSPEC=$COMSPEC")
    [[ -z "${PATHEXT:-}" ]] || isolated_env+=("PATHEXT=$PATHEXT")
    (
      cd "$published"
      "${isolated_env[@]}" bash -euo pipefail -c "$test_command" >&2
      "${isolated_env[@]}" bash -euo pipefail -c "$examples_command" >&2
      "${isolated_env[@]}" bash -euo pipefail -c "$live_test_command" >&2
    )
  fi

  printf '%s\t%s\t%s\n' "$tip" "$tag" "$published"
  trap - RETURN
  rm -rf "$work"
}

command="${1:-}"
package="${2:-}"
[[ -n "$command" && -n "$package" ]] || {
  usage
  exit 2
}
shift 2

if [[ "$command" == render-ci ]]; then
  (($# == 1)) || {
    usage
    exit 2
  }
  branch_tool render-ci "$package" "$1"
  exit
fi

remote="origin"
run_tests=true
execute=false
while (($#)); do
  case "$1" in
    --remote)
      remote="$2"
      shift 2
      ;;
    --skip-tests)
      run_tests=false
      shift
      ;;
    --execute)
      execute=true
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
resolve_remote_identity "$remote"

case "$command" in
  verify)
    IFS=$'\t' read -r tip tag _ < <(
      verify_package "$package" "$remote" "$run_tests" false
    )
    echo "verified $package at $tip ($tag)"
    ;;
  publish)
    IFS=$'\t' read -r tip tag tree < <(
      verify_package "$package" "$remote" true true
    )
    previous_versions=()
    while IFS= read -r version; do
      [[ -n "$version" ]] && previous_versions+=("$version")
    done < <(
      git -C "$ROOT" ls-remote --tags "$FETCH_URL" "refs/tags/$package/v*" |
        sed -n "s#^[0-9a-f]*[[:space:]]refs/tags/$package/v##p"
    )
    target_version="${tag##*/v}"
    if ((${#previous_versions[@]})); then
      branch_tool check-version "$package" "$target_version" "${previous_versions[@]}"
    else
      branch_tool check-version "$package" "$target_version"
    fi
    if ! $execute; then
      echo "dry-run: would create lightweight tag $tag at $tip"
      exit
    fi
    branch="$(branch_tool metadata "$package" | awk -F '\t' '$1 == "branch" { print $2 }')"
    publish_work="$(mktemp -d "${TMPDIR:-/tmp}/package-branch-publish.XXXXXX")"
    trap 'rm -rf "$publish_work"' EXIT
    git init --quiet --bare "$publish_work/repository.git"
    mkdir -p "$publish_work/empty-hooks"
    git --git-dir="$publish_work/repository.git" fetch --quiet --no-tags \
      "$FETCH_URL" "refs/heads/$branch"
    [[ "$(git --git-dir="$publish_work/repository.git" rev-parse FETCH_HEAD)" == "$tip" ]] || {
      echo "$package: package branch moved after verification" >&2
      exit 1
    }
    git -c "core.hooksPath=$publish_work/empty-hooks" \
      --git-dir="$publish_work/repository.git" push --atomic \
      --force-with-lease="refs/heads/$branch:$tip" \
      --force-with-lease="refs/tags/$tag:" \
      "$PUSH_URL" \
      "$tip:refs/heads/$branch" \
      "$tip:refs/tags/$tag"
    [[ "$(git -C "$ROOT" ls-remote "$FETCH_URL" "refs/heads/$branch" | awk 'NR == 1 { print $1 }')" == "$tip" ]]
    [[ "$(remote_tag_commit "$FETCH_URL" "$tag")" == "$tip" ]]
    echo "published $tag at $tip"
    ;;
  *)
    usage
    exit 2
    ;;
esac
