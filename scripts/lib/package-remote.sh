#!/usr/bin/env bash
# Shared identity checks; callers supply ROOT and receive FETCH_URL/PUSH_URL.

canonical_repository() {
  local url="$1"
  local value authority path userinfo host directory base
  if [[ "$url" == file://* ]]; then
    value="${url#file://}"
    directory="$(cd "$(dirname "$value")" && pwd -P)"
    printf 'file/%s/%s\n' "${directory#/}" "$(basename "$value")"
    return
  fi
  if [[ "$url" == *://* ]]; then
    value="${url#*://}"
    authority="${value%%/*}"
    path="${value#*/}"
    if [[ "$authority" == *@* ]]; then
      userinfo="${authority%@*}"
      [[ "$userinfo" != *:* ]] || {
        echo "remote URL must not contain an embedded password" >&2
        exit 1
      }
      authority="${authority##*@}"
    fi
    host="$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')"
    path="${path%/}"
    path="${path%.git}"
    printf '%s/%s\n' "$host" "$path"
    return
  fi
  if [[ "$url" =~ ^([^@/]+@)?([^:]+):(.+)$ ]]; then
    host="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"
    path="${BASH_REMATCH[3]%/}"
    path="${path%.git}"
    printf '%s/%s\n' "$host" "$path"
    return
  fi
  directory="$(cd "$(dirname "$url")" && pwd -P)"
  base="$(basename "$url")"
  printf 'file/%s/%s\n' "${directory#/}" "$base"
}

resolve_remote_identity() {
  local remote="$1"
  local fetch_urls push_urls fetch_count push_count fetch_identity push_identity
  if git -C "$ROOT" remote get-url "$remote" >/dev/null 2>&1; then
    fetch_urls="$(git -C "$ROOT" remote get-url --all "$remote")"
    push_urls="$(git -C "$ROOT" remote get-url --push --all "$remote")"
    fetch_count="$(printf '%s\n' "$fetch_urls" | sed '/^$/d' | wc -l | tr -d ' ')"
    push_count="$(printf '%s\n' "$push_urls" | sed '/^$/d' | wc -l | tr -d ' ')"
    [[ "$fetch_count" == 1 && "$push_count" == 1 ]] || {
      echo "publication remote must have exactly one fetch URL and one push URL" >&2
      exit 1
    }
    FETCH_URL="$fetch_urls"
    PUSH_URL="$push_urls"
  else
    FETCH_URL="$remote"
    PUSH_URL="$remote"
  fi
  if git -C "$ROOT" config --get-regexp '^url\..*\.' 2>/dev/null |
    grep -Eiq '\.(insteadof|pushinsteadof)[[:space:]]'
  then
    echo "Git URL rewrite configuration is not allowed for package release" >&2
    exit 1
  fi
  fetch_identity="$(canonical_repository "$FETCH_URL")"
  push_identity="$(canonical_repository "$PUSH_URL")"
  [[ "$fetch_identity" == "$push_identity" ]] || {
    echo "publication remote fetch/push repository mismatch" >&2
    exit 1
  }
}
