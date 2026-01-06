#!/bin/sh

if [ -z "${root:-}" ]; then
  root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fi

template_suffix() {
  env=${LSR_ENV:-prod}
  if [ "$env" = "dev" ]; then
    printf '%s' "-dev"
  else
    printf '%s' ""
  fi
}

template_output_dir() {
  printf '%s' "${TEMPLATE_OUTPUT_DIR:-$root/dist}"
}

template_source_path() {
  arch=$1
  case "$arch" in
    wrapper) printf '%s\n' "$root/template/template.yaml" ;;
    arm64) printf '%s\n' "$root/template/template-arm64.yaml" ;;
    amd64) printf '%s\n' "$root/template/template-amd64.yaml" ;;
    *) return 1 ;;
  esac
}

template_output_path() {
  arch=$1
  base=$(basename "$(template_source_path "$arch")" .yaml)
  printf '%s/%s%s.yaml\n' "$(template_output_dir)" "$base" "$(template_suffix)"
}

template_semantic_version() {
  path=$1
  version=$(awk -F': *' '/^[[:space:]]*SemanticVersion:/ {print $2; exit}' "$path")
  case "$version" in
    ''|*[!0-9.]*|*.*.*.*)
      printf '%s\n' "Unable to parse SemanticVersion from $path: $version" >&2
      return 1
      ;;
    *.*.*)
      ;;
    *)
      printf '%s\n' "Unable to parse SemanticVersion from $path: $version" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$version"
}

render_template() {
  src=$1
  dest=$2
  version=$3
  app_name=$4
  layer_name=$5
  content_uri=$6
  arm64_id=${7:-}
  amd64_id=${8:-}

  tmp_template=$(mktemp)
  awk -v version="$version" \
    -v app_name="$app_name" \
    -v layer_name="$layer_name" \
    -v content_uri="$content_uri" \
    -v arm64_id="$arm64_id" \
    -v amd64_id="$amd64_id" '
    $1 == "Name:" && app_name != "" { sub(/Name:.*/, "Name: " app_name); print; next }
    $1 == "SemanticVersion:" && version != "" { sub(/SemanticVersion:.*/, "SemanticVersion: " version); print; next }
    $1 == "LayerName:" && layer_name != "" { sub(/LayerName:.*/, "LayerName: " layer_name); print; next }
    $1 == "ContentUri:" && content_uri != "" { sub(/ContentUri:.*/, "ContentUri: " content_uri); print; next }
    /^[[:space:]]*RuntimeArm64Application:/ { in_arm64=1; in_amd64=0 }
    /^[[:space:]]*RuntimeAmd64Application:/ { in_arm64=0; in_amd64=1 }
    /^[[:space:]]*Outputs:/ { in_arm64=0; in_amd64=0 }
    $1 == "ApplicationId:" && in_arm64 && arm64_id != "" { sub(/ApplicationId:.*/, "ApplicationId: " arm64_id); print; next }
    $1 == "ApplicationId:" && in_amd64 && amd64_id != "" { sub(/ApplicationId:.*/, "ApplicationId: " amd64_id); print; next }
    { print }
  ' "$src" > "$tmp_template"
  mv "$tmp_template" "$dest"
}
