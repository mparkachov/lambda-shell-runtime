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

case "$arch" in
  arm64) app_name=${DEV_SAR_APP_NAME_ARM64:-${LSR_SAR_APP_BASE}-dev-arm64} ;;
  amd64) app_name=${DEV_SAR_APP_NAME_AMD64:-${LSR_SAR_APP_BASE}-dev-amd64} ;;
esac

bucket_name=${DEV_BUCKET_NAME:-$LSR_BUCKET_NAME_DEV}
s3_prefix_base=${S3_PREFIX:-$LSR_S3_PREFIX}
latest_prefix="${s3_prefix_base}/latest/${arch}"

if [ -z "$bucket_name" ]; then
  printf '%s\n' "DEV_BUCKET_NAME is not set." >&2
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

aws s3 rm "s3://${bucket_name}/${latest_prefix}/" --recursive
