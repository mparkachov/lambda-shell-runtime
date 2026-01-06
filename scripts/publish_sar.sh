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

require_cmd sam
require_cmd make

arch=${ARCH:-${1:-}}
if [ -z "$arch" ] && [ "$LSR_ENV" = "dev" ]; then
  arch=amd64
fi
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

template_src="$root/template/template-$arch.yaml"
if [ "$arch" = "wrapper" ]; then
  template_src="$root/template/template.yaml"
fi

if [ ! -f "$template_src" ]; then
  printf '%s\n' "Template not found at $template_src" >&2
  exit 1
fi

if [ -z "${S3_BUCKET:-}" ]; then
  printf '%s\n' "S3_BUCKET is not set." >&2
  exit 1
fi

content_path=""
if [ "$arch" != "wrapper" ]; then
  content_path="$root/dist/lambda-shell-runtime-$arch.zip"
fi

template_path=""
packaged_path="$root/dist/packaged-$arch.yaml"
version=""

if [ "$LSR_ENV" = "dev" ]; then
  version=$LSR_SAR_VERSION
  if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s\n' "LSR_SAR_VERSION must be a semver like 0.0.0 (got: $version)" >&2
    exit 1
  fi

  case "$arch" in
    arm64)
      package_target="package-arm64"
      ;;
    amd64)
      package_target="package-amd64"
      ;;
  esac

  TEMPLATE_VERSION="$version" make "$package_target"

  template_path=$(template_output_path "$arch")
  packaged_path="$root/dist/packaged-dev-$arch.yaml"
else
  if [ "$arch" = "wrapper" ]; then
    template_arm64=$(template_output_path arm64)
    if [ ! -f "$template_arm64" ]; then
      printf '%s\n' "Generated template not found at $template_arm64. Run make package-all first." >&2
      exit 1
    fi
    version=$(template_semantic_version "$template_arm64")
  else
    template_path=$(template_output_path "$arch")
    if [ ! -f "$template_path" ]; then
      printf '%s\n' "Generated template not found at $template_path. Run make package-$arch first." >&2
      exit 1
    fi
    version=$(template_semantic_version "$template_path")
  fi
fi

if [ "$arch" != "wrapper" ]; then
  if [ ! -f "$content_path" ]; then
    printf '%s\n' "Expected layer artifact not found: $content_path" >&2
    printf '%s\n' "Run make package-$arch first." >&2
    exit 1
  fi
else
  require_cmd aws
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

  template_path=$(template_output_path wrapper)
  mkdir -p "$(template_output_dir)"
  render_template \
    "$template_src" \
    "$template_path" \
    "$version" \
    "$LSR_SAR_APP_NAME_WRAPPER" \
    "" \
    "" \
    "$arm64_id" \
    "$amd64_id"
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
