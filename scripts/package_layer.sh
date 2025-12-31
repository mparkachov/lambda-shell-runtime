#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
layer_dir="$root/layer"
dist_dir="$root/dist"
zip_path="$dist_dir/lambda-shell-runtime-arm64.zip"
template_path="$root/template.yaml"

if [ ! -d "$layer_dir/opt" ]; then
  printf '%s\n' "Layer contents not found at $layer_dir/opt. Run scripts/build_layer.sh first." >&2
  exit 1
fi

if [ ! -x "$layer_dir/opt/bin/aws" ]; then
  printf '%s\n' "AWS CLI not found at $layer_dir/opt/bin/aws. Run scripts/build_layer.sh first." >&2
  exit 1
fi

aws_version=""
version_file="$layer_dir/opt/aws-cli/v2/current/dist/awscli/__init__.py"
if [ -f "$version_file" ]; then
  aws_version=$(sed -n "s/^__version__ = ['\"]\\([0-9][0-9.]*\\)['\"].*/\\1/p" "$version_file")
fi
if [ -z "$aws_version" ]; then
  version_file=$(find "$layer_dir/opt/aws-cli" -type f -path "*/awscli/__init__.py" 2>/dev/null | head -n1)
  if [ -n "$version_file" ]; then
    aws_version=$(sed -n "s/^__version__ = ['\"]\\([0-9][0-9.]*\\)['\"].*/\\1/p" "$version_file")
  fi
fi
case "$aws_version" in
  ''|*[!0-9.]*|*.*.*.*)
    printf '%s\n' "Unable to determine AWS CLI version from $layer_dir/opt/aws-cli" >&2
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
rm -f "$zip_path"

( cd "$layer_dir" && zip -r "$zip_path" opt )

cp "$zip_path" "$dist_dir/lambda-shell-runtime-arm64-$aws_version.zip"
