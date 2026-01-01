#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
self="$root/scripts/package_layer.sh"
layer_base="$root/layer"
dist_dir="$root/dist"
template_path="$root/template.yaml"

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

if [ ! -f "$template_path" ]; then
  printf '%s\n' "template.yaml not found at $template_path" >&2
  exit 1
fi

if ! grep -q '^    SemanticVersion:' "$template_path"; then
  printf '%s\n' "SemanticVersion not found in $template_path" >&2
  exit 1
fi

tmp_template=$(mktemp)
awk -v version="$aws_version" '
  $1 == "SemanticVersion:" { print "    SemanticVersion: " version; next }
  { print }
' "$template_path" > "$tmp_template"
mv "$tmp_template" "$template_path"

mkdir -p "$dist_dir"

zip_path="$dist_dir/lambda-shell-runtime-$arch.zip"
rm -f "$zip_path"

layer_parent=$(dirname "$layer_root")
( cd "$layer_parent" && zip -ry "$zip_path" opt )

cp "$zip_path" "$dist_dir/lambda-shell-runtime-$arch-$aws_version.zip"
