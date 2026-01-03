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
require_cmd sam
require_cmd make

bucket_name=${DEV_BUCKET_NAME:-$LSR_BUCKET_NAME_DEV}
dev_app_name=${DEV_SAR_APP_NAME_ARM64:-${LSR_SAR_APP_BASE}-dev-arm64}
s3_prefix_base=${S3_PREFIX:-$LSR_S3_PREFIX}

if [ -z "$bucket_name" ]; then
  printf '%s\n' "DEV_BUCKET_NAME is not set." >&2
  exit 1
fi

S3_BUCKET=${DEV_S3_BUCKET:-$bucket_name}
export S3_BUCKET

template_src="$root/template-arm64.yaml"
template_tmp=$(mktemp "$root/.tmp-template-arm64.XXXXXX.yaml")
trap 'rm -f "$template_tmp"' EXIT
cp "$template_src" "$template_tmp"

TEMPLATE_PATHS="$template_tmp" SAR_APP_NAME_ARM64="$dev_app_name" make package-arm64

s3_prefix_publish="${s3_prefix_base}/latest/arm64"
packaged_path="$root/packaged-dev-arm64.yaml"

SAM_CLI_TELEMETRY=0 \
sam package \
  --template-file "$template_tmp" \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "$s3_prefix_publish" \
  --output-template-file "$packaged_path"

sam publish --template "$packaged_path"
