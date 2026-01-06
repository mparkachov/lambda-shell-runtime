#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

event="$root/tests/integration/event.json"

host_arch() {
  arch=$(uname -m 2>/dev/null || true)
  case "$arch" in
    aarch64|arm64) printf '%s\n' "arm64" ;;
    x86_64|amd64) printf '%s\n' "amd64" ;;
    *) return 1 ;;
  esac
}

arch=${ARCH:-}
if [ -z "$arch" ]; then
  arch=$(host_arch) || {
    printf '%s\n' "Unable to detect host architecture" >&2
    exit 1
  }
fi

case "$arch" in
  arm64|amd64) ;;
  *)
    printf '%s\n' "Unsupported architecture: $arch" >&2
    exit 1
    ;;
 esac

if ! command -v sam >/dev/null 2>&1; then
  printf '%s\n' "sam is not installed" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' "docker is not installed" >&2
  exit 2
fi

if ! docker info >/dev/null 2>&1; then
  printf '%s\n' "docker is not running" >&2
  exit 2
fi

build_log=$(mktemp)
if ! ARCH="$arch" "$root/scripts/build_layer.sh" >"$build_log" 2>&1; then
  cat "$build_log" >&2
  exit 1
fi
rm -f "$build_log"

package_log=$(mktemp)
if ! TEMPLATE_PATHS="" ARCH="$arch" "$root/scripts/package_layer.sh" >"$package_log" 2>&1; then
  cat "$package_log" >&2
  exit 1
fi
rm -f "$package_log"

layer_zip="$root/dist/lambda-shell-runtime-$arch.zip"
if [ ! -f "$layer_zip" ]; then
  printf '%s\n' "Packaged layer zip not found at $layer_zip" >&2
  exit 1
fi

entries_file=$(mktemp)
list_file=$(mktemp)
if ! zip -sf "$layer_zip" > "$list_file"; then
  rm -f "$entries_file" "$list_file"
  printf '%s\n' "Unable to read packaged layer zip: $layer_zip" >&2
  exit 1
fi
sed '1d' "$list_file" | sed 's/^[[:space:]]*//' | sed '/^$/d' > "$entries_file"
rm -f "$list_file"

missing=""
if ! grep -qx "bootstrap" "$entries_file"; then
  missing="bootstrap"
fi
for prefix in bin/ aws-cli/ lib/; do
  if ! grep -q "^$prefix" "$entries_file"; then
    if [ -n "$missing" ]; then
      missing="$missing, $prefix"
    else
      missing="$prefix"
    fi
  fi
done
if grep -q '^opt/' "$entries_file"; then
  printf '%s\n' "unexpected opt/ prefix in packaged layer zip" >&2
  exit 1
fi
if [ -n "$missing" ]; then
  printf '%s\n' "missing expected entries in packaged layer zip: $missing" >&2
  exit 1
fi

code_dir=$(mktemp -d)
response=$(mktemp)
log=$(mktemp)
template=$(mktemp)
cleanup() {
  rm -rf "$code_dir" "$response" "$log" "$template" "$entries_file" "$list_file"
}
trap cleanup EXIT

cp "$root/examples/function.sh" "$code_dir/function.sh"
cat <<'BOOT' > "$code_dir/bootstrap"
#!/bin/sh
exec /opt/bootstrap
BOOT
chmod +x "$code_dir/function.sh" "$code_dir/bootstrap"

aws_arch="$arch"
if [ "$arch" = "amd64" ]; then
  aws_arch="x86_64"
fi

cat <<TEMPLATE > "$template"
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: Local integration test template for lambda-shell-runtime.

Resources:
  LambdaShellRuntimeLayer:
    Type: AWS::Serverless::LayerVersion
    Properties:
      LayerName: lambda-shell-runtime
      ContentUri: $layer_zip
      CompatibleRuntimes:
        - provided.al2023
      CompatibleArchitectures:
        - $aws_arch

  HelloFunction:
    Type: AWS::Serverless::Function
    Properties:
      FunctionName: lambda-shell-runtime-hello
      Runtime: provided.al2023
      Handler: function.handler
      CodeUri: $code_dir
      Architectures:
        - $aws_arch
      Layers:
        - !Ref LambdaShellRuntimeLayer
      Timeout: 10
TEMPLATE

export DOCKER_DEFAULT_PLATFORM="linux/$arch"
export SAM_CLI_TELEMETRY=0

if ! sam local invoke HelloFunction \
  --template "$template" \
  --event "$event" \
  >"$response" 2>"$log"; then
  cat "$log" >&2
  exit 1
fi

grep -Eq '"input"[[:space:]]*:' "$response"
grep -Eq '"aws_cli"[[:space:]]*:[[:space:]]*"aws-cli/' "$response"
