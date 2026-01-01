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

stack_name=${STACK_NAME:-$LSR_STACK_NAME}
bucket_name=${BUCKET_NAME:-$LSR_BUCKET_NAME}
wrapper_app_name=${SAR_APP_NAME_BASE:-$LSR_SAR_APP_BASE}
arm64_app_name=${SAR_APP_NAME_ARM64:-$LSR_SAR_APP_NAME_ARM64}
amd64_app_name=${SAR_APP_NAME_AMD64:-$LSR_SAR_APP_NAME_AMD64}
template_path="$root/aws-setup.yaml"
s3_prefix=${S3_PREFIX:-$LSR_S3_PREFIX}
template_wrapper="$root/template.yaml"
template_arm64="$root/template-arm64.yaml"
template_amd64="$root/template-amd64.yaml"

sar_app_id() {
  name=$1
  aws serverlessrepo list-applications \
    --query "Applications[?Name=='$name'].ApplicationId | [0]" \
    --output text 2>/dev/null || true
}

sar_app_exists() {
  app_id=$(sar_app_id "$1")
  if [ -n "$app_id" ] && [ "$app_id" != "None" ] && [ "$app_id" != "null" ]; then
    return 0
  fi
  return 1
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
    "S3Prefix=$s3_prefix" \
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
        "Prefix": "${s3_prefix}/"
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

arm64_exists=false
amd64_exists=false
wrapper_exists=false
if sar_app_exists "$arm64_app_name"; then
  arm64_exists=true
fi
if sar_app_exists "$amd64_app_name"; then
  amd64_exists=true
fi
if sar_app_exists "$wrapper_app_name"; then
  wrapper_exists=true
fi

require_cmd sam
require_cmd make

make package-all

S3_BUCKET=${S3_BUCKET:-$bucket_name}
export S3_BUCKET

publish_app() {
  arch=$1
  template_path=$2
  if [ "$3" = "true" ]; then
    return 0
  fi
  packaged_path="$root/packaged-$arch.yaml"
  SAM_CLI_TELEMETRY=0 \
  sam package \
    --template-file "$template_path" \
    --s3-bucket "$S3_BUCKET" \
    --s3-prefix "$s3_prefix" \
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

version=$(awk -F': *' '/^[[:space:]]*SemanticVersion:/ {print $2; exit}' "$template_arm64")
if [ -z "$version" ]; then
  printf '%s\n' "Unable to resolve SemanticVersion from $template_arm64" >&2
  exit 1
fi

update_wrapper_template "$template_wrapper" "$version" "$arm64_id" "$amd64_id" "$wrapper_app_name"

publish_app "wrapper" "$template_wrapper" "$wrapper_exists"
