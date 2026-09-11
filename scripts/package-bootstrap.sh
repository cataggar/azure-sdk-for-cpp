#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/scripts/lib/package-remote.sh"
source "$ROOT/scripts/lib/package-bootstrap.sh"

# Production has no destination-repository override or fixture mode.
bootstrap_main "github.com/cataggar/azure-sdk-for-zig" "$@"
