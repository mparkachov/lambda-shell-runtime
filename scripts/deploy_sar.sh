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

resolve_app_id() {
  name=$1
  attempts=${APP_LOOKUP_ATTEMPTS:-8}
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

arch=${ARCH:-${1:-}}
case "$arch" in
  arm64|amd64) ;;
  *)
    printf '%s\n' "ARCH must be arm64 or amd64." >&2
    exit 1
    ;;
esac

case "$arch" in
  arm64)
    app_name=$LSR_SAR_APP_NAME_ARM64
    stack_name=$LSR_SAR_STACK_NAME_ARM64
    ;;
  amd64)
    app_name=$LSR_SAR_APP_NAME_AMD64
    stack_name=$LSR_SAR_STACK_NAME_AMD64
    ;;
esac

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

app_id=$(resolve_app_id "$app_name" || true)

if [ -z "$app_id" ] || [ "$app_id" = "None" ] || [ "$app_id" = "null" ]; then
  printf '%s\n' "SAR application not found: $app_name" >&2
  exit 1
fi

template_id=$(aws serverlessrepo create-cloud-formation-template \
  --application-id "$app_id" \
  --semantic-version "$version" \
  --query "TemplateId" \
  --output text)

if [ -z "$template_id" ] || [ "$template_id" = "None" ] || [ "$template_id" = "null" ]; then
  printf '%s\n' "Unable to resolve template ID for $app_name" >&2
  exit 1
fi

template_url=$(aws serverlessrepo get-cloud-formation-template \
  --application-id "$app_id" \
  --template-id "$template_id" \
  --query "TemplateUrl" \
  --output text)

if [ -z "$template_url" ] || [ "$template_url" = "None" ] || [ "$template_url" = "null" ]; then
  printf '%s\n' "Unable to resolve template URL for $app_name" >&2
  exit 1
fi

template_file=$(mktemp "$root/.tmp-sar-template-${arch}.XXXXXX.yaml")
trap 'rm -f "$template_file"' EXIT
curl -fsSL "$template_url" -o "$template_file"

aws cloudformation deploy \
  --stack-name "$stack_name" \
  --template-file "$template_file" \
  --no-fail-on-empty-changeset
