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

resolve_app_id() {
  name=$1
  attempts=${APP_LOOKUP_ATTEMPTS:-4}
  delay=${APP_LOOKUP_DELAY:-2}
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

arch=${ARCH:-${1:-}}
if [ -z "$arch" ] && [ "$LSR_ENV" = "dev" ]; then
  arch=amd64
fi
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

version=${LSR_SAR_VERSION:-${RELEASE_VERSION:-${AWSCLI_VERSION:-}}}
if [ -z "$version" ]; then
  template_path=$(template_output_path "$arch")
  if [ -f "$template_path" ]; then
    version=$(template_semantic_version "$template_path")
  else
    template_path=$(template_source_path "$arch")
    if [ -f "$template_path" ]; then
      version=$(template_semantic_version "$template_path")
      printf '%s\n' "Using version from source template: $template_path" >&2
    else
      printf '%s\n' "Template not found for $arch." >&2
      exit 1
    fi
  fi
fi
if [ -z "$version" ]; then
  printf '%s\n' "Unable to resolve SemanticVersion for $arch." >&2
  exit 1
fi
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  printf '%s\n' "SemanticVersion must be a semver like 0.0.0 (got: $version)" >&2
  exit 1
fi

app_id=$(resolve_app_id "$app_name" || true)

if [ -z "$app_id" ] || [ "$app_id" = "None" ] || [ "$app_id" = "null" ]; then
  printf '%s\n' "SAR application not found: $app_name"
  exit 0
fi

aws serverlessrepo delete-application --application-id "$app_id"

aws s3 rm "s3://${bucket_name}/${s3_prefix_base}/${version}/${arch}/" --recursive
