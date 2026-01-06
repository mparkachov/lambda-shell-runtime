#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/scripts/aws_env.sh"
. "$root/scripts/template_utils.sh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "Required command not found: $1" >&2
    exit 1
  fi
}

require_cmd git
require_cmd gh

template_arm64=$(template_output_path arm64)
template_amd64=$(template_output_path amd64)

version=${RELEASE_VERSION:-}
if [ -z "$version" ]; then
  if [ ! -f "$template_arm64" ]; then
    printf '%s\n' "RELEASE_VERSION not set and generated templates not found. Run make package-all or set RELEASE_VERSION." >&2
    exit 1
  fi
  version_arm64=$(template_semantic_version "$template_arm64")
  version=$version_arm64
  if [ -f "$template_amd64" ]; then
    version_amd64=$(template_semantic_version "$template_amd64")
    if [ "$version_arm64" != "$version_amd64" ]; then
      printf '%s\n' "Template SemanticVersion mismatch; set RELEASE_VERSION to override." >&2
      exit 1
    fi
  fi
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
