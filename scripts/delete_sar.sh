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

require_cmd aws

arch=${ARCH:-${1:-}}
case "$arch" in
  arm64|amd64) ;;
  *)
    printf '%s\n' "ARCH must be arm64 or amd64." >&2
    exit 1
    ;;
esac

if [ "$LSR_ENV" = "prod" ] && [ "${ALLOW_PROD_DELETE:-}" != "1" ]; then
  printf '%s\n' "Refusing to delete SAR applications in ENV=prod without ALLOW_PROD_DELETE=1." >&2
  exit 1
fi

case "$arch" in
  arm64) app_name=$LSR_SAR_APP_NAME_ARM64 ;;
  amd64) app_name=$LSR_SAR_APP_NAME_AMD64 ;;
esac

bucket_name=${S3_BUCKET:-$LSR_BUCKET_NAME}
s3_prefix_base=${S3_PREFIX:-$LSR_S3_PREFIX}

if [ -z "$bucket_name" ]; then
  printf '%s\n' "LSR_BUCKET_NAME is not set." >&2
  exit 1
fi

version=$LSR_SAR_VERSION
if [ -z "$version" ]; then
  template_path="$root/template-$arch.yaml"
  if [ ! -f "$template_path" ]; then
    printf '%s\n' "Template not found at $template_path" >&2
    exit 1
  fi
  version=$(awk -F': *' '/^[[:space:]]*SemanticVersion:/ {print $2; exit}' "$template_path")
fi
if [ -z "$version" ]; then
  printf '%s\n' "Unable to resolve SemanticVersion for $arch." >&2
  exit 1
fi
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  printf '%s\n' "SemanticVersion must be a semver like 0.0.0 (got: $version)" >&2
  exit 1
fi

app_id=$(aws serverlessrepo list-applications \
  --query "Applications[?Name=='$app_name'].ApplicationId | [0]" \
  --output text 2>/dev/null || true)

if [ -z "$app_id" ] || [ "$app_id" = "None" ] || [ "$app_id" = "null" ]; then
  printf '%s\n' "SAR application not found: $app_name"
  exit 0
fi

aws serverlessrepo delete-application --application-id "$app_id"

aws s3 rm "s3://${bucket_name}/${s3_prefix_base}/${version}/${arch}/" --recursive
