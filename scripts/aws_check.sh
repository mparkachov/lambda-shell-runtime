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
require_cmd curl
require_cmd python3

if [ -z "${S3_BUCKET:-}" ]; then
  printf '%s\n' "S3_BUCKET is not set." >&2
  exit 1
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  green=$(printf '\033[32m')
  red=$(printf '\033[31m')
  reset=$(printf '\033[0m')
else
  green=""
  red=""
  reset=""
fi

ok="${green}[ok]${reset}"
fail="${red}[fail]${reset}"
RUN_CHECK_OUTPUT=""

run_check() {
  description=$1
  shift

  printf '%s' "Checking $description... "
  output=$(mktemp)
  if "$@" >"$output" 2>&1; then
    RUN_CHECK_OUTPUT=$(cat "$output")
    printf '%s\n' "$ok"
    rm -f "$output"
    return 0
  fi

  printf '%s\n' "$fail" >&2
  sed 's/^/  /' "$output" >&2
  rm -f "$output"
  exit 1
}

check_stack_access() {
  stack_name=$1
  output=$(mktemp)
  if aws cloudformation describe-stacks --stack-name "$stack_name" >"$output" 2>&1; then
    rm -f "$output"
    return 0
  fi
  if grep -q "ValidationError" "$output"; then
    rm -f "$output"
    return 0
  fi
  printf '%s\n' "$fail" >&2
  sed 's/^/  /' "$output" >&2
  rm -f "$output"
  exit 1
}

extract_s3_uris() {
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()
uris = sorted(set(re.findall(r"s3://[^\\s\"']+", text)))
for uri in uris:
    print(uri)
PY
}

resolve_app_id() {
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

resolve_version() {
  arch=$1
  if [ "$LSR_ENV" = "dev" ]; then
    printf '%s\n' "$LSR_SAR_VERSION"
    return 0
  fi

  template_path="$root/template-$arch.yaml"
  if [ ! -f "$template_path" ]; then
    printf '%s\n' "Template not found at $template_path" >&2
    exit 1
  fi
  version=$(awk -F': *' '/^[[:space:]]*SemanticVersion:/ {print $2; exit}' "$template_path")
  case "$version" in
    ''|*[!0-9.]*|*.*.*.*)
      printf '%s\n' "Unable to parse SemanticVersion from $template_path: $version" >&2
      exit 1
      ;;
    *.*.*)
      ;;
    *)
      printf '%s\n' "Unable to parse SemanticVersion from $template_path: $version" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$version"
}

check_s3_rw() {
  s3_prefix=${S3_PREFIX:-$LSR_S3_PREFIX}
  key="${s3_prefix}/aws-check/${LSR_ENV}/$(date +%s)-$$.txt"
  body=$(mktemp)
  printf '%s\n' "ok" >"$body"
  run_check "S3 put-object ($S3_BUCKET)" aws s3api put-object --bucket "$S3_BUCKET" --key "$key" --body "$body"
  run_check "S3 head-object ($S3_BUCKET)" aws s3api head-object --bucket "$S3_BUCKET" --key "$key"
  run_check "S3 delete-object ($S3_BUCKET)" aws s3api delete-object --bucket "$S3_BUCKET" --key "$key"
  rm -f "$body"
}

check_sar_deploy_access() {
  arch=$1
  case "$arch" in
    arm64)
      app_name=$LSR_SAR_APP_NAME_ARM64
      stack_name=$LSR_SAR_STACK_NAME_ARM64
      ;;
    amd64)
      app_name=$LSR_SAR_APP_NAME_AMD64
      stack_name=$LSR_SAR_STACK_NAME_AMD64
      ;;
    *)
      printf '%s\n' "Unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac

  version=$(resolve_version "$arch")
  if [ -z "$version" ]; then
    printf '%s\n' "Unable to resolve SemanticVersion for $arch." >&2
    exit 1
  fi

  run_check "SAR list-applications ($app_name)" \
    aws serverlessrepo list-applications --max-items 5 --output text
  app_id=$(resolve_app_id "$app_name" || true)
  if [ -z "$app_id" ] || [ "$app_id" = "None" ] || [ "$app_id" = "null" ]; then
    printf '%s\n' "SAR application not found: $app_name" >&2
    exit 1
  fi

  run_check "SAR create template ($app_name $version)" \
    aws serverlessrepo create-cloud-formation-template \
      --application-id "$app_id" \
      --semantic-version "$version" \
      --query "TemplateId" \
      --output text
  template_id=$RUN_CHECK_OUTPUT
  if [ -z "$template_id" ] || [ "$template_id" = "None" ] || [ "$template_id" = "null" ]; then
    printf '%s\n' "Unable to resolve template ID for $app_name" >&2
    exit 1
  fi

  run_check "SAR get template ($app_name $version)" \
    aws serverlessrepo get-cloud-formation-template \
      --application-id "$app_id" \
      --template-id "$template_id" \
      --query "TemplateUrl" \
      --output text
  template_url=$RUN_CHECK_OUTPUT
  if [ -z "$template_url" ] || [ "$template_url" = "None" ] || [ "$template_url" = "null" ]; then
    printf '%s\n' "Unable to resolve template URL for $app_name" >&2
    exit 1
  fi

  template_file=$(mktemp)
  run_check "Download SAR template ($app_name $version)" curl -fsSL "$template_url" -o "$template_file"
  run_check "CloudFormation validate-template ($app_name $version)" \
    aws cloudformation validate-template --template-body "file://$template_file"

  uris=$(extract_s3_uris "$template_file")
  if [ -z "$uris" ]; then
    printf '%s\n' "No S3 URIs found in SAR template for $app_name" >&2
    exit 1
  fi

  for uri in $uris; do
    bucket=${uri#s3://}
    bucket=${bucket%%/*}
    key=${uri#s3://$bucket/}
    if [ -z "$key" ] || [ "$bucket" = "$key" ]; then
      printf '%s\n' "Invalid S3 URI in SAR template: $uri" >&2
      exit 1
    fi
    run_check "S3 head-object ($bucket)" aws s3api head-object --bucket "$bucket" --key "$key"
  done

  printf '%s' "Checking CloudFormation describe-stacks ($stack_name)... "
  check_stack_access "$stack_name"
  printf '%s\n' "$ok"

  rm -f "$template_file"
}

run_check "AWS identity" aws sts get-caller-identity --query 'Arn' --output text
run_check "Lambda list-layers" aws lambda list-layers --max-items 5 --output text
run_check "S3 bucket access ($S3_BUCKET)" aws s3api head-bucket --bucket "$S3_BUCKET"
check_s3_rw

check_arches=${AWS_CHECK_ARCHES:-}
if [ -z "$check_arches" ]; then
  if [ "$LSR_ENV" = "dev" ]; then
    check_arches="amd64"
  else
    check_arches="arm64 amd64"
  fi
fi

for arch in $check_arches; do
  check_sar_deploy_access "$arch"
done
