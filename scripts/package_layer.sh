#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
self="$root/scripts/package_layer.sh"
layer_base="$root/layer"
dist_dir="$root/dist"

. "$root/scripts/aws_env.sh"
. "$root/scripts/template_utils.sh"

host_arch() {
  arch=$(uname -m 2>/dev/null || true)
  case "$arch" in
    aarch64|arm64) printf '%s\n' "arm64" ;;
    x86_64|amd64) printf '%s\n' "amd64" ;;
    *) return 1 ;;
  esac
}

arch=${ARCH:-${1:-}}
if [ -z "$arch" ]; then
  arch=$(host_arch) || {
    printf '%s\n' "Unable to detect host architecture" >&2
    exit 1
  }
fi

if [ "$arch" = "all" ]; then
  ARCH=arm64 "$self"
  ARCH=amd64 "$self"
  exit 0
fi

case "$arch" in
  arm64|amd64) ;;
  *)
    printf '%s\n' "Unsupported architecture: $arch" >&2
    exit 1
    ;;
 esac

host=$(host_arch)
layer_root="$layer_base/opt"
if [ "$arch" != "$host" ] || [ ! -d "$layer_root" ]; then
  layer_root="$layer_base/$arch/opt"
fi

if [ ! -d "$layer_root" ]; then
  printf '%s\n' "Layer contents not found at $layer_root. Run scripts/build_layer.sh first." >&2
  exit 1
fi

if [ ! -x "$layer_root/bin/aws" ]; then
  printf '%s\n' "AWS CLI not found at $layer_root/bin/aws. Run scripts/build_layer.sh first." >&2
  exit 1
fi

aws_version=""
for version_dir in "$layer_root/aws-cli/v2/"[0-9]*; do
  if [ ! -d "$version_dir" ]; then
    continue
  fi
  version_base=$(basename "$version_dir")
  case "$version_base" in
    [0-9]*.[0-9]*.[0-9]*)
      aws_version="$version_base"
      break
      ;;
  esac
done
case "$aws_version" in
  ''|*[!0-9.]*|*.*.*.*)
    printf '%s\n' "Unable to determine AWS CLI version from $layer_root/aws-cli" >&2
    exit 1
    ;;
  *.*.*)
    ;;
  *)
    printf '%s\n' "Unable to parse AWS CLI version from: $aws_version" >&2
    exit 1
    ;;
esac

template_version=${TEMPLATE_VERSION:-$aws_version}
case "$template_version" in
  ''|*[!0-9.]*|*.*.*.*)
    printf '%s\n' "Unable to parse template version: $template_version" >&2
    exit 1
    ;;
  *.*.*)
    ;;
  *)
    printf '%s\n' "Unable to parse template version: $template_version" >&2
    exit 1
    ;;
esac

template_paths=${TEMPLATE_PATHS:-"$(template_source_path wrapper) $(template_source_path arm64) $(template_source_path amd64)"}
template_out_dir=$(template_output_dir)
template_suffix_value=$(template_suffix)

mkdir -p "$template_out_dir"

for template_path in $template_paths; do
  if [ ! -f "$template_path" ]; then
    printf '%s\n' "Template not found at $template_path" >&2
    exit 1
  fi

  if ! grep -q '^    SemanticVersion:' "$template_path"; then
    printf '%s\n' "SemanticVersion not found in $template_path" >&2
    exit 1
  fi

  app_name=""
  layer_name=""
  content_uri=""
  content_uri_base=""
  arch=""
  case "$(basename "$template_path")" in
    template.yaml)
      app_name=${SAR_APP_NAME_BASE:-$LSR_SAR_APP_BASE}
      arch="wrapper"
      ;;
    template-arm64.yaml)
      app_name=${SAR_APP_NAME_ARM64:-$LSR_SAR_APP_NAME_ARM64}
      layer_name=${LSR_LAYER_NAME_ARM64:-$app_name}
      content_uri_base="lambda-shell-runtime-arm64.zip"
      arch="arm64"
      ;;
    template-amd64.yaml)
      app_name=${SAR_APP_NAME_AMD64:-$LSR_SAR_APP_NAME_AMD64}
      layer_name=${LSR_LAYER_NAME_AMD64:-$app_name}
      content_uri_base="lambda-shell-runtime-amd64.zip"
      arch="amd64"
      ;;
  esac

  base_name=$(basename "$template_path" .yaml)
  if [ -n "$arch" ]; then
    output_path=$(template_output_path "$arch")
  else
    output_path="$template_out_dir/${base_name}${template_suffix_value}.yaml"
  fi

  if [ -n "$content_uri_base" ]; then
    if [ "$template_out_dir" = "$dist_dir" ]; then
      content_uri="$content_uri_base"
    else
      content_uri="$dist_dir/$content_uri_base"
    fi
  fi

  render_template \
    "$template_path" \
    "$output_path" \
    "$template_version" \
    "$app_name" \
    "$layer_name" \
    "$content_uri"
done

mkdir -p "$dist_dir"

zip_path="$dist_dir/lambda-shell-runtime-$arch.zip"
rm -f "$zip_path"

( cd "$layer_root" && zip -9 -ryq "$zip_path" bootstrap bin aws-cli lib )

cp "$zip_path" "$dist_dir/lambda-shell-runtime-$arch-$aws_version.zip"
