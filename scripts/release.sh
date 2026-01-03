#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/scripts/aws_env.sh"

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
template_wrapper="$root/template.yaml"
template_arm64="$root/template-arm64.yaml"
template_amd64="$root/template-amd64.yaml"

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
  other_changes=$(printf '%s\n' "$changes" | grep -vE '^(template.yaml|template-arm64.yaml|template-amd64.yaml)$' || true)
  if [ -n "$other_changes" ]; then
    printf '%s\n' "Working tree has uncommitted changes:" >&2
    printf '%s\n' "$other_changes" >&2
    exit 1
  fi
fi

template_version() {
  path=$1
  if [ ! -f "$path" ]; then
    printf '%s\n' "Template not found at $path" >&2
    exit 1
  fi

  version=$(awk -F': *' '/^[[:space:]]*SemanticVersion:/ {print $2; exit}' "$path")
  case "$version" in
    ''|*[!0-9.]*|*.*.*.*)
      printf '%s\n' "Unable to parse SemanticVersion from $path" >&2
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

version_wrapper=$(template_version "$template_wrapper")
version_arm64=$(template_version "$template_arm64")
version_amd64=$(template_version "$template_amd64")
if [ "$version_wrapper" != "$version_arm64" ]; then
  printf '%s\n' "SemanticVersion mismatch: $template_wrapper=$version_wrapper $template_arm64=$version_arm64" >&2
  exit 1
fi
if [ "$version_arm64" != "$version_amd64" ]; then
  printf '%s\n' "SemanticVersion mismatch: $template_arm64=$version_arm64 $template_amd64=$version_amd64" >&2
  exit 1
fi
version=$version_arm64
s3_prefix_publish_base="${s3_prefix_base}/${version}"

sar_app_id() {
  name=$1
  aws serverlessrepo list-applications \
    --query "Applications[?Name=='$name'].ApplicationId | [0]" \
    --output text 2>/dev/null || true
}

update_wrapper_template() {
  path=$1
  version=$2
  arm64_id=$3
  amd64_id=$4
  app_name=$5

  tmp_template=$(mktemp)
  awk -v version="$version" \
    -v arm64_id="$arm64_id" \
    -v amd64_id="$amd64_id" \
    -v app_name="$app_name" '
    $1 == "Name:" && app_name != "" { sub(/Name:.*/, "Name: " app_name); print; next }
    $1 == "SemanticVersion:" { sub(/SemanticVersion:.*/, "SemanticVersion: " version); print; next }
    /^[[:space:]]*RuntimeArm64Application:/ { in_arm64=1; in_amd64=0 }
    /^[[:space:]]*RuntimeAmd64Application:/ { in_arm64=0; in_amd64=1 }
    /^[[:space:]]*Outputs:/ { in_arm64=0; in_amd64=0 }
    $1 == "ApplicationId:" && in_arm64 { sub(/ApplicationId:.*/, "ApplicationId: " arm64_id); print; next }
    $1 == "ApplicationId:" && in_amd64 { sub(/ApplicationId:.*/, "ApplicationId: " amd64_id); print; next }
    { print }
  ' "$path" > "$tmp_template"
  mv "$tmp_template" "$path"
}

if git rev-parse "refs/tags/$version" >/dev/null 2>&1; then
  printf '%s\n' "Tag $version already exists; skipping release."
  exit 0
fi

for arch in arm64 amd64; do
  artifact="dist/lambda-shell-runtime-$arch-$version.zip"
  if [ ! -f "$artifact" ]; then
    printf '%s\n' "Expected artifact not found: $artifact" >&2
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

update_wrapper_template "$template_wrapper" "$version" "$arm64_id" "$amd64_id" "$wrapper_app_name"

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

if ! git diff --quiet HEAD -- "$template_wrapper" "$template_arm64" "$template_amd64"; then
  if ! git config user.name >/dev/null 2>&1; then
    git config user.name "github-actions[bot]"
  fi
  if ! git config user.email >/dev/null 2>&1; then
    git config user.email "github-actions[bot]@users.noreply.github.com"
  fi
  git add "$template_wrapper" "$template_arm64" "$template_amd64"
  git commit -m "Release $version"
  git push origin "$current_branch"
fi

git tag -a "$version" -m "Release $version"
git push origin "$version"

gh release create "$version" \
  "dist/lambda-shell-runtime-arm64-$version.zip" \
  "dist/lambda-shell-runtime-amd64-$version.zip" \
  --title "$version" \
  --generate-notes

publish_template() {
  arch=$1
  template_path=$2
  s3_prefix_publish="${s3_prefix_publish_base}/${arch}"
  packaged_path="$root/packaged-$arch.yaml"
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
publish_template "wrapper" "$template_wrapper"
