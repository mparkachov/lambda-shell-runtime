#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

event="$root/spec/data/event.json"
mode=${1:-all}

host_arch() {
  arch=$(uname -m 2>/dev/null || true)
  case "$arch" in
    aarch64|arm64) printf '%s\n' "arm64" ;;
    x86_64|amd64) printf '%s\n' "amd64" ;;
    *) return 1 ;;
  esac
}

wait_for_file() {
  file=$1
  waits=200
  while [ ! -s "$file" ] && [ "$waits" -gt 0 ]; do
    sleep 0.1
    waits=$((waits - 1))
  done
  [ -s "$file" ]
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

case "$mode" in
  standard|streaming|all) ;;
  *)
    printf '%s\n' "Usage: $0 [standard|streaming|all]" >&2
    exit 2
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

host=$(host_arch 2>/dev/null || true)
if [ -z "$host" ]; then
  host="$arch"
fi
if [ "$arch" = "$host" ]; then
  layer_root="$root/layer/opt"
else
  layer_root="$root/layer/$arch/opt"
fi
if [ ! -x "$layer_root/bootstrap" ]; then
  printf '%s\n' "Runtime bootstrap not found at $layer_root/bootstrap" >&2
  exit 1
fi

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
streaming_dir=""
streaming_code_dir=""
streaming_request=""
streaming_request_clean=""
streaming_network=""
streaming_api_container=""
streaming_runtime_container=""
cleanup() {
  if [ -n "$streaming_runtime_container" ]; then
    docker rm -f "$streaming_runtime_container" >/dev/null 2>&1 || true
  fi
  if [ -n "$streaming_api_container" ]; then
    docker rm -f "$streaming_api_container" >/dev/null 2>&1 || true
  fi
  if [ -n "$streaming_network" ]; then
    docker network rm "$streaming_network" >/dev/null 2>&1 || true
  fi
  rm -rf "$code_dir" "$response" "$log" "$template" "$entries_file" "$list_file"
  if [ -n "$streaming_dir" ]; then
    rm -rf "$streaming_dir"
  fi
  if [ -n "$streaming_code_dir" ]; then
    rm -rf "$streaming_code_dir"
  fi
  if [ -n "$streaming_request_clean" ]; then
    rm -f "$streaming_request_clean"
  fi
}
trap cleanup EXIT

run_standard() {
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
}

run_streaming() {
  platform="linux/$arch"
  streaming_dir=$(mktemp -d)
  streaming_code_dir=$(mktemp -d)
  streaming_request="$streaming_dir/response_request.txt"
  streaming_event="$streaming_dir/event.json"
  streaming_script="$streaming_dir/runtime_api.sh"
  streaming_request_id="streaming-test-id"
  streaming_payload='{"ok":true,"stream":"yes"}'

  printf '%s' '{"message":"stream"}' > "$streaming_event"

  cat <<'HANDLER' > "$streaming_code_dir/function.sh"
handler() {
  printf '%s' '{"ok":true,"stream":"yes"}'
}
HANDLER
  cat <<'BOOT' > "$streaming_code_dir/bootstrap"
#!/bin/sh
exec /opt/bootstrap
BOOT
  chmod +x "$streaming_code_dir/function.sh" "$streaming_code_dir/bootstrap"

  cat <<'API' > "$streaming_script"
#!/bin/sh
set -eu

port=${PORT:-9001}
event_file=${EVENT_FILE:-/data/event.json}
next_file=${NEXT_FILE:-/data/next_request.txt}
response_file=${RESPONSE_FILE:-/data/response_request.txt}
request_id=${REQUEST_ID:-streaming-test-id}

event=$(cat "$event_file")
length=$(printf '%s' "$event" | wc -c | tr -d ' ')

{
  printf 'HTTP/1.1 200 OK\r\n'
  printf 'Lambda-Runtime-Aws-Request-Id: %s\r\n' "$request_id"
  printf 'Lambda-Runtime-Deadline-Ms: 0\r\n'
  printf 'Lambda-Runtime-Function-Response-Mode: streaming\r\n'
  printf 'Content-Type: application/json\r\n'
  printf 'Content-Length: %s\r\n' "$length"
  printf 'Connection: close\r\n'
  printf '\r\n'
  printf '%s' "$event"
} | nc -l -p "$port" > "$next_file"

{
  printf 'HTTP/1.1 202 Accepted\r\n'
  printf 'Content-Length: 0\r\n'
  printf 'Connection: close\r\n'
  printf '\r\n'
} | nc -l -p "$port" > "$response_file"
API
  chmod +x "$streaming_script"

  streaming_network="lambda-shell-runtime-streaming-$arch-$$"
  streaming_api_container="lambda-shell-runtime-streaming-api-$$"
  streaming_runtime_container="lambda-shell-runtime-streaming-runtime-$$"

  docker network create "$streaming_network" >/dev/null
  docker run -d --name "$streaming_api_container" \
    --network "$streaming_network" \
    --platform "$platform" \
    -v "$streaming_dir:/data" \
    busybox sh /data/runtime_api.sh >/dev/null

  sleep 0.2

  docker run -d --name "$streaming_runtime_container" \
    --network "$streaming_network" \
    --platform "$platform" \
    -v "$layer_root:/opt:ro" \
    -v "$streaming_code_dir:/var/task:ro" \
    -e AWS_LAMBDA_RUNTIME_API="$streaming_api_container:9001" \
    -e _HANDLER="function.handler" \
    -e LAMBDA_TASK_ROOT="/var/task" \
    --entrypoint /bin/sh \
    public.ecr.aws/lambda/provided:al2023 \
    -c 'if ! rpm -q curl-minimal >/dev/null 2>&1; then echo "curl-minimal not installed" >&2; exit 1; fi; curl --version >&2; exec /opt/bootstrap' >/dev/null

  if ! wait_for_file "$streaming_request"; then
    docker logs "$streaming_runtime_container" >&2 || true
    printf '%s\n' "Streaming response request was not captured" >&2
    exit 1
  fi

  streaming_request_clean=$(mktemp)
  tr -d '\r' < "$streaming_request" > "$streaming_request_clean"

  if ! grep -F "POST /2018-06-01/runtime/invocation/${streaming_request_id}/response" "$streaming_request_clean" >/dev/null 2>&1; then
    printf '%s\n' "Streaming response used unexpected endpoint" >&2
    exit 1
  fi
  if ! grep -i -F "Lambda-Runtime-Function-Response-Mode: streaming" "$streaming_request_clean" >/dev/null 2>&1; then
    printf '%s\n' "Streaming response header missing response mode" >&2
    exit 1
  fi
  if ! grep -i -F "Trailer: Lambda-Runtime-Function-Error-Type, Lambda-Runtime-Function-Error-Body" "$streaming_request_clean" >/dev/null 2>&1; then
    printf '%s\n' "Streaming response header missing error trailers" >&2
    exit 1
  fi
  if ! grep -F "$streaming_payload" "$streaming_request_clean" >/dev/null 2>&1; then
    printf '%s\n' "Streaming response payload not captured" >&2
    exit 1
  fi
}

case "$mode" in
  standard) run_standard ;;
  streaming) run_streaming ;;
  all)
    run_standard
    run_streaming
    ;;
esac
