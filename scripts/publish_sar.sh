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

require_cmd sam
require_cmd make

arch=${ARCH:-${1:-}}
if [ "$arch" = "all" ]; then
  ARCH=arm64 "$0"
  ARCH=amd64 "$0"
  if [ "$LSR_ENV" != "dev" ]; then
    ARCH=wrapper "$0"
  fi
  exit 0
fi

case "$arch" in
  arm64|amd64|wrapper) ;;
  *)
    printf '%s\n' "ARCH must be arm64, amd64, wrapper, or all." >&2
    exit 1
    ;;
esac

if [ "$LSR_ENV" = "dev" ] && [ "$arch" = "wrapper" ]; then
  printf '%s\n' "Wrapper publishing is not supported for ENV=dev." >&2
  exit 1
fi

template_src="$root/template-$arch.yaml"
if [ "$arch" = "wrapper" ]; then
  template_src="$root/template.yaml"
  if grep -q "__APP_ID" "$template_src"; then
    printf '%s\n' "Wrapper template is missing ApplicationIds. Run make aws-setup first." >&2
    exit 1
  fi
fi

if [ ! -f "$template_src" ]; then
  printf '%s\n' "Template not found at $template_src" >&2
  exit 1
fi

if [ -z "${S3_BUCKET:-}" ]; then
  printf '%s\n' "S3_BUCKET is not set." >&2
  exit 1
fi

content_uri=""
content_path=""
if [ "$arch" != "wrapper" ]; then
  content_uri=$(awk -F': *' '/^[[:space:]]*ContentUri:/ {print $2; exit}' "$template_src")
  if [ -z "$content_uri" ]; then
    printf '%s\n' "ContentUri not found in $template_src" >&2
    exit 1
  fi
  content_path="$root/$content_uri"
fi

template_path="$template_src"
packaged_path="$root/packaged-$arch.yaml"
version=""

if [ "$LSR_ENV" = "dev" ]; then
  version=$LSR_SAR_VERSION
  if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s\n' "LSR_SAR_VERSION must be a semver like 0.0.0 (got: $version)" >&2
    exit 1
  fi

  case "$arch" in
    arm64)
      app_name=$LSR_SAR_APP_NAME_ARM64
      layer_name=$LSR_LAYER_NAME_ARM64
      package_target="package-arm64"
      ;;
    amd64)
      app_name=$LSR_SAR_APP_NAME_AMD64
      layer_name=$LSR_LAYER_NAME_AMD64
      package_target="package-amd64"
      ;;
  esac

  template_tmp=$(mktemp "$root/.tmp-template-${arch}.XXXXXX.yaml")
  trap 'rm -f "$template_tmp"' EXIT
  cp "$template_src" "$template_tmp"

  TEMPLATE_PATHS="$template_tmp" make "$package_target"

  tmp_updated=$(mktemp "$root/.tmp-template-${arch}.XXXXXX.yaml")
  awk -v app_name="$app_name" -v version="$version" -v layer_name="$layer_name" '
    $1 == "Name:" { sub(/Name:.*/, "Name: " app_name); print; next }
    $1 == "SemanticVersion:" { sub(/SemanticVersion:.*/, "SemanticVersion: " version); print; next }
    $1 == "LayerName:" { sub(/LayerName:.*/, "LayerName: " layer_name); print; next }
    { print }
  ' "$template_tmp" > "$tmp_updated"
  mv "$tmp_updated" "$template_tmp"

  template_path="$template_tmp"
  packaged_path="$root/packaged-dev-$arch.yaml"
else
  version=$(awk -F': *' '/^[[:space:]]*SemanticVersion:/ {print $2; exit}' "$template_src")
  case "$version" in
    ''|*[!0-9.]*|*.*.*.*)
      printf '%s\n' "Unable to parse SemanticVersion from $template_src: $version" >&2
      exit 1
      ;;
    *.*.*)
      ;;
    *)
      printf '%s\n' "Unable to parse SemanticVersion from $template_src: $version" >&2
      exit 1
      ;;
  esac
fi

if [ "$arch" != "wrapper" ]; then
  if [ ! -f "$content_path" ]; then
    printf '%s\n' "Expected layer artifact not found: $content_path" >&2
    printf '%s\n' "Run make package-$arch first." >&2
    exit 1
  fi
fi

s3_prefix_base=${S3_PREFIX:-$LSR_S3_PREFIX}
s3_prefix_publish="${s3_prefix_base}/${version}/${arch}"

SAM_CLI_TELEMETRY=0 \
sam package \
  --template-file "$template_path" \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "$s3_prefix_publish" \
  --output-template-file "$packaged_path"

sam publish --template "$packaged_path"
