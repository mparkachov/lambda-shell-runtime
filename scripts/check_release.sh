#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "Required command not found: $1" >&2
    exit 1
  fi
}

require_cmd git
require_cmd curl

strict=${CHECK_RELEASE_STRICT:-1}
release_version=${RELEASE_VERSION:-${AWSCLI_VERSION:-}}

if [ -z "$release_version" ]; then
  release_version=$(curl -fsSL "https://api.github.com/repos/aws/aws-cli/tags?per_page=1" \
    | awk -F'"' '/"name":/ {print $4; exit}')
fi

case "$release_version" in
  ''|*[!0-9.]*|*.*.*.*)
    printf '%s\n' "Unable to resolve AWS CLI version for release." >&2
    exit 1
    ;;
  *.*.*)
    ;;
  *)
    printf '%s\n' "Unable to parse AWS CLI version: $release_version" >&2
    exit 1
    ;;
esac

if git remote get-url origin >/dev/null 2>&1; then
  git fetch --tags --quiet || true
fi

write_outputs() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    printf '%s\n' "$2" >> "$GITHUB_OUTPUT"
  fi
}

if git rev-parse "refs/tags/$release_version" >/dev/null 2>&1; then
  printf '%s\n' "Tag $release_version already exists; skipping release."
  write_outputs "release_needed=false" "release_version=$release_version"
  if [ "$strict" = "1" ]; then
    exit 2
  fi
  exit 0
fi

printf '%s\n' "Release version $release_version does not exist; proceeding."
write_outputs "release_needed=true" "release_version=$release_version"
