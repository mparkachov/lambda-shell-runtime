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

missing_arch=""
for arch in aarch64 x86_64; do
  url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${release_version}.zip"
  if ! curl -fsI "$url" >/dev/null 2>&1; then
    if [ -z "$missing_arch" ]; then
      missing_arch=$arch
    else
      missing_arch="$missing_arch $arch"
    fi
  fi
done
if [ -n "$missing_arch" ]; then
  printf '%s\n' "AWS CLI $release_version is not available for: $missing_arch" >&2
  printf '%s\n' "Skipping release until downloads are available." >&2
  write_outputs "release_needed=false" "release_version=$release_version"
  exit 0
fi

printf '%s\n' "Release version $release_version does not exist; proceeding."
write_outputs "release_needed=true" "release_version=$release_version"
