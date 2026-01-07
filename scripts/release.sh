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
require_cmd sam
require_cmd aws
require_cmd gh

release_branch=${RELEASE_BRANCH:-main}
s3_prefix_base=${S3_PREFIX:-$LSR_S3_PREFIX}
wrapper_app_name=$LSR_SAR_APP_NAME_WRAPPER
template_wrapper_src=$(template_source_path wrapper)
template_wrapper_out=$(template_output_path wrapper)
template_arm64=$(template_output_path arm64)
template_amd64=$(template_output_path amd64)

ensure_git_identity() {
  git_name=$(git config user.name 2>/dev/null || true)
  git_email=$(git config user.email 2>/dev/null || true)
  if [ -z "$git_name" ]; then
    git config user.name "github-actions[bot]"
  fi
  if [ -z "$git_email" ]; then
    git config user.email "github-actions[bot]@users.noreply.github.com"
  fi
}

cd "$root"

current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ -z "$current_branch" ]; then
  printf '%s\n' "Unable to determine current Git branch" >&2
  exit 1
fi
if [ "$current_branch" != "$release_branch" ]; then
  printf '%s\n' "Releases must run on branch '$release_branch' (current: $current_branch)" >&2
  printf '%s\n' "Override with RELEASE_BRANCH if needed." >&2
  exit 1
fi

changes=$(git diff --name-only HEAD)
if [ -n "$changes" ]; then
  printf '%s\n' "Working tree has uncommitted changes:" >&2
  printf '%s\n' "$changes" >&2
  exit 1
fi

if [ ! -f "$template_arm64" ] || [ ! -f "$template_amd64" ]; then
  printf '%s\n' "Generated templates not found. Run make package-all first." >&2
  exit 1
fi

version_arm64=$(template_semantic_version "$template_arm64")
version_amd64=$(template_semantic_version "$template_amd64")
if [ "$version_arm64" != "$version_amd64" ]; then
  printf '%s\n' "SemanticVersion mismatch: $template_arm64=$version_arm64 $template_amd64=$version_amd64" >&2
  exit 1
fi
version=$version_arm64
s3_prefix_publish_base="${s3_prefix_base}/${version}"

sar_app_id() {
  name=$1
  attempts=${APP_LOOKUP_ATTEMPTS:-6}
  delay=${APP_LOOKUP_DELAY:-3}
  max_items=${APP_LOOKUP_MAX_ITEMS:-1000}

  i=1
  while [ "$i" -le "$attempts" ]; do
    app_id=$(aws serverlessrepo list-applications \
      --max-items "$max_items" \
      --query "Applications[?Name=='$name'].ApplicationId | [0]" \
      --output text 2>/dev/null || true)
    if [ -n "$app_id" ] && [ "$app_id" != "None" ] && [ "$app_id" != "null" ]; then
      printf '%s\n' "$app_id"
      return 0
    fi
    if [ "$i" -lt "$attempts" ]; then
      sleep "$delay"
    fi
    i=$((i + 1))
  done
  return 1
}

tag_exists=false
if git rev-parse "refs/tags/$version" >/dev/null 2>&1; then
  tag_exists=true
fi

for arch in arm64 amd64; do
  artifact="dist/lambda-shell-runtime-$arch-$version.zip"
  fallback="dist/lambda-shell-runtime-$arch.zip"
  if [ ! -f "$artifact" ] && [ -f "$fallback" ]; then
    cp "$fallback" "$artifact"
  fi
  if [ ! -f "$artifact" ]; then
    printf '%s\n' "Expected artifact not found: $artifact" >&2
    if [ -f "$fallback" ]; then
      printf '%s\n' "Found unversioned artifact at $fallback but failed to create versioned copy." >&2
    fi
    printf '%s\n' "Run make package-all first." >&2
    exit 1
  fi
done

arm64_id=$(sar_app_id "$LSR_SAR_APP_NAME_ARM64")
amd64_id=$(sar_app_id "$LSR_SAR_APP_NAME_AMD64")
if [ -z "$arm64_id" ] || [ "$arm64_id" = "None" ] || [ "$arm64_id" = "null" ]; then
  printf '%s\n' "Unable to resolve SAR application ID for $LSR_SAR_APP_NAME_ARM64. Run make aws-setup first." >&2
  exit 1
fi
if [ -z "$amd64_id" ] || [ "$amd64_id" = "None" ] || [ "$amd64_id" = "null" ]; then
  printf '%s\n' "Unable to resolve SAR application ID for $LSR_SAR_APP_NAME_AMD64. Run make aws-setup first." >&2
  exit 1
fi

mkdir -p "$(template_output_dir)"
render_template \
  "$template_wrapper_src" \
  "$template_wrapper_out" \
  "$version" \
  "$wrapper_app_name" \
  "" \
  "" \
  "$arm64_id" \
  "$amd64_id"

if [ -z "${S3_BUCKET:-}" ]; then
  printf '%s\n' "S3_BUCKET is not set." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  if [ -z "$token" ]; then
    printf '%s\n' "gh is not authenticated. Run 'gh auth login' or set GH_TOKEN/GITHUB_TOKEN." >&2
    exit 1
  fi
  export GH_TOKEN="$token"
fi

publish_template() {
  arch=$1
  template_path=$2
  s3_prefix_publish="${s3_prefix_publish_base}/${arch}"
  packaged_path="$root/dist/packaged-$arch.yaml"
  SAM_CLI_TELEMETRY=0 \
  sam package \
    --template-file "$template_path" \
    --s3-bucket "$S3_BUCKET" \
    --s3-prefix "$s3_prefix_publish" \
    --output-template-file "$packaged_path"

  sam publish --template "$packaged_path"
}

publish_template "arm64" "$template_arm64"
publish_template "amd64" "$template_amd64"
publish_template "wrapper" "$template_wrapper_out"

if [ "$tag_exists" = "true" ]; then
  printf '%s\n' "Tag $version already exists; skipping tag and GitHub release."
  exit 0
fi

ensure_git_identity
git tag -a "$version" -m "Release $version"
git push origin "$version"

gh release create "$version" \
  "dist/lambda-shell-runtime-arm64-$version.zip" \
  "dist/lambda-shell-runtime-amd64-$version.zip" \
  --title "$version" \
  --generate-notes
