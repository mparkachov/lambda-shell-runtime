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

require_cmd aws

stack_name=${STACK_NAME:-$LSR_STACK_NAME}
bucket_name=${BUCKET_NAME:-$LSR_BUCKET_NAME}
wrapper_app_name=$LSR_SAR_APP_NAME_WRAPPER
arm64_app_name=$LSR_SAR_APP_NAME_ARM64
amd64_app_name=$LSR_SAR_APP_NAME_AMD64
template_path="$root/template/aws-setup.yaml"
s3_prefix_base=${S3_PREFIX:-$LSR_S3_PREFIX}
template_wrapper_src=$(template_source_path wrapper)
template_wrapper_out=$(template_output_path wrapper)
template_arm64=$(template_output_path arm64)
template_amd64=$(template_output_path amd64)

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

sar_app_exists() {
  app_id=$(sar_app_id "$1" || true)
  if [ -n "$app_id" ] && [ "$app_id" != "None" ] && [ "$app_id" != "null" ]; then
    return 0
  fi
  return 1
}

create_bucket="true"
if aws s3api head-bucket --bucket "$bucket_name" >/dev/null 2>&1; then
  create_bucket="false"
fi

aws cloudformation deploy \
  --stack-name "$stack_name" \
  --template-file "$template_path" \
  --parameter-overrides \
    "BucketName=$bucket_name" \
    "CreateBucket=$create_bucket" \
    "S3Prefix=$s3_prefix_base" \
  --no-fail-on-empty-changeset

lifecycle_file=$(mktemp)
trap 'rm -f "$lifecycle_file"' EXIT
cat >"$lifecycle_file" <<JSON
{
  "Rules": [
    {
      "ID": "SarArtifactsLifecycle",
      "Status": "Enabled",
      "Filter": {
        "Prefix": "${s3_prefix_base}/"
      },
      "Transitions": [
        {
          "Days": 30,
          "StorageClass": "STANDARD_IA"
        },
        {
          "Days": 90,
          "StorageClass": "GLACIER_IR"
        }
      ]
    }
  ]
}
JSON

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$bucket_name" \
  --lifecycle-configuration "file://$lifecycle_file"

if [ "${SKIP_SAR_PUBLISH:-}" = "1" ]; then
  exit 0
fi

use_wrapper=true
if [ "$LSR_ENV" = "dev" ]; then
  use_wrapper=false
fi

arm64_exists=false
amd64_exists=false
wrapper_exists=false
if sar_app_exists "$arm64_app_name"; then
  arm64_exists=true
fi
if sar_app_exists "$amd64_app_name"; then
  amd64_exists=true
fi
if [ "$use_wrapper" = "true" ] && sar_app_exists "$wrapper_app_name"; then
  wrapper_exists=true
fi

require_cmd sam
require_cmd make

make package-all

S3_BUCKET=${S3_BUCKET:-$bucket_name}
export S3_BUCKET

if [ ! -f "$template_arm64" ] || [ ! -f "$template_amd64" ]; then
  printf '%s\n' "Generated templates not found. Run make package-all first." >&2
  exit 1
fi

version=$(template_semantic_version "$template_arm64")

s3_prefix_publish_base="${s3_prefix_base}/${version}"

publish_app() {
  arch=$1
  template_path=$2
  if [ "$3" = "true" ]; then
    return 0
  fi
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

publish_app "arm64" "$template_arm64" "$arm64_exists"
publish_app "amd64" "$template_amd64" "$amd64_exists"

arm64_id=$(sar_app_id "$arm64_app_name")
amd64_id=$(sar_app_id "$amd64_app_name")
if [ -z "$arm64_id" ] || [ "$arm64_id" = "None" ] || [ "$arm64_id" = "null" ]; then
  printf '%s\n' "Unable to resolve SAR application ID for $arm64_app_name" >&2
  exit 1
fi
if [ -z "$amd64_id" ] || [ "$amd64_id" = "None" ] || [ "$amd64_id" = "null" ]; then
  printf '%s\n' "Unable to resolve SAR application ID for $amd64_app_name" >&2
  exit 1
fi

if [ "$use_wrapper" = "true" ]; then
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
  publish_app "wrapper" "$template_wrapper_out" "$wrapper_exists"
fi
