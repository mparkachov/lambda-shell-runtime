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
require_cmd gh

template_arm64="$root/template-arm64.yaml"
template_amd64="$root/template-amd64.yaml"
template_wrapper="$root/template.yaml"

template_version() {
  path=$1
  version=$(awk -F': *' '/^[[:space:]]*SemanticVersion:/ {print $2; exit}' "$path")
  case "$version" in
    ''|*[!0-9.]*|*.*.*.*)
      printf '%s\n' "Unable to parse SemanticVersion from $path: $version" >&2
      exit 1
      ;;
    *.*.*)
      ;;
    *)
      printf '%s\n' "Unable to parse SemanticVersion from $path: $version" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$version"
}

version=${RELEASE_VERSION:-}
if [ -z "$version" ]; then
  version_wrapper=$(template_version "$template_wrapper")
  version_arm64=$(template_version "$template_arm64")
  version_amd64=$(template_version "$template_amd64")
  if [ "$version_wrapper" != "$version_arm64" ] || [ "$version_arm64" != "$version_amd64" ]; then
    printf '%s\n' "Template SemanticVersion mismatch; set RELEASE_VERSION to override." >&2
    exit 1
  fi
  version=$version_arm64
fi

if ! gh auth status >/dev/null 2>&1; then
  token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  if [ -z "$token" ]; then
    printf '%s\n' "gh is not authenticated. Run 'gh auth login' or set GH_TOKEN/GITHUB_TOKEN." >&2
    exit 1
  fi
  export GH_TOKEN="$token"
fi

if gh release view "$version" >/dev/null 2>&1; then
  gh release delete "$version" -y
else
  printf '%s\n' "GitHub release $version not found; skipping."
fi

if git rev-parse "refs/tags/$version" >/dev/null 2>&1; then
  git tag -d "$version"
else
  printf '%s\n' "Local tag $version not found; skipping."
fi

if git remote get-url origin >/dev/null 2>&1; then
  if git ls-remote --tags origin "refs/tags/$version" | grep -q "$version"; then
    git push origin ":refs/tags/$version"
  else
    printf '%s\n' "Remote tag $version not found; skipping."
  fi
else
  printf '%s\n' "No git remote named origin; skipping remote tag delete."
fi
