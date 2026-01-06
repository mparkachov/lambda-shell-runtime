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
  waits=${2:-200}
  while [ ! -s "$file" ] && [ "$waits" -gt 0 ]; do
    sleep 0.1
    waits=$((waits - 1))
  done
  [ -s "$file" ]
}

wait_for_payload() {
  payload=$1
  request_file=$2
  next_file=$3
  waits=${4:-200}
  while [ "$waits" -gt 0 ]; do
    if [ -f "$request_file" ] && grep -F "$payload" "$request_file" >/dev/null 2>&1; then
      return 0
    fi
    if [ -f "$next_file" ] && grep -F "$payload" "$next_file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    waits=$((waits - 1))
  done
  return 1
}

ensure_image() {
  image=$1
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    if ! docker pull "$image" >/dev/null 2>&1; then
      printf '%s\n' "Failed to pull image: $image" >&2
      return 1
    fi
  fi
  return 0
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

wait_for_container_port() {
  container=$1
  port=$2
  waits=${3:-200}
  while [ "$waits" -gt 0 ]; do
    if docker exec "$container" sh -c "if command -v ncat >/dev/null 2>&1; then ncat -z 127.0.0.1 $port; elif command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 $port; else exit 1; fi" >/dev/null 2>&1; then
      return 0
    fi
    if ! container_running "$container"; then
      return 1
    fi
    sleep 0.2
    waits=$((waits - 1))
  done
  return 1
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
streaming_next_request=""
streaming_request_clean=""
streaming_api_log=""
streaming_runtime_log=""
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
  if [ -n "$streaming_api_log" ]; then
    rm -f "$streaming_api_log"
  fi
  if [ -n "$streaming_runtime_log" ]; then
    rm -f "$streaming_runtime_log"
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
  api_image="public.ecr.aws/amazonlinux/amazonlinux:2023"
  runtime_image="public.ecr.aws/lambda/provided:al2023"
  streaming_dir=$(mktemp -d)
  streaming_code_dir=$(mktemp -d)
  streaming_request="$streaming_dir/response_request.txt"
  streaming_next_request="$streaming_dir/next_request.txt"
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
handler=${HANDLER_FILE:-/data/handle_request.sh}
log_file=${LOG_FILE:-/data/api.log}

event=$(cat "$event_file")
length=$(printf '%s' "$event" | wc -c | tr -d ' ')

cat <<'HANDLER' > "$handler"
#!/bin/sh
set -eu

request_line=""
if IFS= read -r request_line; then
  :
fi
clean_request_line=$(printf '%s' "$request_line" | tr -d '\r')
if [ -z "$clean_request_line" ]; then
  exit 0
fi

printf '%s\n' "$clean_request_line" >> "$LOG_FILE"

path=$(printf '%s' "$clean_request_line" | awk '{print $2}')
target=""
case "$path" in
  /2018-06-01/runtime/invocation/next)
    target="$NEXT_FILE"
    ;;
  /2018-06-01/runtime/invocation/*/response)
    target="$RESPONSE_FILE"
    ;;
  *)
    target="$RESPONSE_FILE"
    ;;
esac

printf '%s\n' "$clean_request_line" > "$target"
while IFS= read -r line; do
  clean_line=$(printf '%s' "$line" | tr -d '\r')
  printf '%s\n' "$clean_line" >> "$target"
  [ -z "$clean_line" ] && break
done

case "$path" in
  /2018-06-01/runtime/invocation/next)
    {
      printf 'HTTP/1.1 200 OK\r\n'
      printf 'Lambda-Runtime-Aws-Request-Id: %s\r\n' "$REQUEST_ID"
      printf 'Lambda-Runtime-Deadline-Ms: 0\r\n'
      printf 'Lambda-Runtime-Function-Response-Mode: streaming\r\n'
      printf 'Content-Type: application/json\r\n'
      printf 'Content-Length: %s\r\n' "$EVENT_LENGTH"
      printf 'Connection: close\r\n'
      printf '\r\n'
      printf '%s' "$EVENT_PAYLOAD"
    }
    ;;
  *)
    {
      printf 'HTTP/1.1 202 Accepted\r\n'
      printf 'Content-Length: 0\r\n'
      printf 'Connection: close\r\n'
      printf '\r\n'
    }
    ;;
esac

case "$path" in
  /2018-06-01/runtime/invocation/next)
    exit 0
    ;;
esac

while IFS= read -r line || [ -n "$line" ]; do
  clean_line=$(printf '%s' "$line" | tr -d '\r')
  printf '%s\n' "$clean_line" >> "$target"
done
HANDLER
chmod +x "$handler"

if command -v ncat >/dev/null 2>&1; then
  NCHANDLER=$(command -v ncat)
elif command -v nc >/dev/null 2>&1; then
  NCHANDLER=$(command -v nc)
else
  printf '%s\n' "ncat/nc not available" >&2
  exit 1
fi

export NEXT_FILE="$next_file"
export RESPONSE_FILE="$response_file"
export REQUEST_ID="$request_id"
export EVENT_PAYLOAD="$event"
export EVENT_LENGTH="$length"
export LOG_FILE="$log_file"

while :; do
  "$NCHANDLER" -l -p "$port" -c "$handler"
done
API
  chmod +x "$streaming_script"

  streaming_network="lambda-shell-runtime-streaming-$arch-$$"
  streaming_api_container="lambda-shell-runtime-streaming-api-$$"
  streaming_runtime_container="lambda-shell-runtime-streaming-runtime-$$"
  streaming_api_log=$(mktemp)
  streaming_runtime_log=$(mktemp)

  ensure_image "$api_image"
  ensure_image "$runtime_image"

  docker network create "$streaming_network" >/dev/null
  if ! docker run -d --name "$streaming_api_container" \
    --network "$streaming_network" \
    --platform "$platform" \
    -v "$streaming_dir:/data" \
    "$api_image" sh -c \
    'dnf -y install nmap-ncat >/dev/null 2>&1 || { echo "Failed to install nmap-ncat" >&2; exit 1; }; sh /data/runtime_api.sh' \
    >"$streaming_api_log" 2>&1; then
    cat "$streaming_api_log" >&2
    exit 1
  fi

  if ! wait_for_container_port "$streaming_api_container" 9001 600; then
    docker logs "$streaming_api_container" >&2 || true
    printf '%s\n' "Streaming API container did not become ready" >&2
    exit 1
  fi

  if ! docker run -d --name "$streaming_runtime_container" \
    --network "$streaming_network" \
    --platform "$platform" \
    -v "$layer_root:/opt:ro" \
    -v "$streaming_code_dir:/var/task:ro" \
    -e AWS_LAMBDA_RUNTIME_API="$streaming_api_container:9001" \
    -e _HANDLER="function.handler" \
    -e LAMBDA_TASK_ROOT="/var/task" \
    --entrypoint /bin/sh \
    "$runtime_image" \
    -c 'if ! rpm -q curl-minimal >/dev/null 2>&1; then echo "curl-minimal not installed" >&2; exit 1; fi; exec /opt/bootstrap' \
    >"$streaming_runtime_log" 2>&1; then
    cat "$streaming_runtime_log" >&2
    exit 1
  fi

  if ! wait_for_file "$streaming_request" 600; then
    docker logs "$streaming_runtime_container" >&2 || true
    docker logs "$streaming_api_container" >&2 || true
    docker inspect -f 'runtime status: {{.State.Status}} exit={{.State.ExitCode}}' "$streaming_runtime_container" >&2 2>/dev/null || true
    docker inspect -f 'api status: {{.State.Status}} exit={{.State.ExitCode}}' "$streaming_api_container" >&2 2>/dev/null || true
    if [ -f "$streaming_next_request" ]; then
      printf '%s\n' "Captured next request:" >&2
      tr -d '\r' < "$streaming_next_request" >&2 || true
    fi
    if [ -f "$streaming_dir/api.log" ]; then
      printf '%s\n' "API request log:" >&2
      cat "$streaming_dir/api.log" >&2 || true
    fi
    printf '%s\n' "Streaming response request was not captured" >&2
    exit 1
  fi
  wait_for_payload "$streaming_payload" "$streaming_request" "$streaming_next_request" 600 || true

  streaming_request_clean=$(mktemp)
  {
    if [ -f "$streaming_request" ]; then
      cat "$streaming_request"
    fi
    if [ -f "$streaming_next_request" ]; then
      cat "$streaming_next_request"
    fi
  } | tr -d '\r' > "$streaming_request_clean"

  if ! grep -F "/2018-06-01/runtime/invocation/${streaming_request_id}/response" "$streaming_request_clean" >/dev/null 2>&1; then
    request_line=$(head -n 1 "$streaming_request_clean" || true)
    printf '%s\n' "Streaming response used unexpected endpoint: $request_line" >&2
    printf '%s\n' "Captured requests:" >&2
    cat "$streaming_request_clean" >&2 || true
    docker logs "$streaming_runtime_container" >&2 || true
    docker logs "$streaming_api_container" >&2 || true
    exit 1
  fi
  if ! grep -i -F "Lambda-Runtime-Function-Response-Mode: streaming" "$streaming_request_clean" >/dev/null 2>&1; then
    printf '%s\n' "Streaming response header missing response mode" >&2
    printf '%s\n' "Captured requests:" >&2
    cat "$streaming_request_clean" >&2 || true
    exit 1
  fi
  if ! grep -i -F "Trailer: Lambda-Runtime-Function-Error-Type, Lambda-Runtime-Function-Error-Body" "$streaming_request_clean" >/dev/null 2>&1; then
    printf '%s\n' "Streaming response header missing error trailers" >&2
    printf '%s\n' "Captured requests:" >&2
    cat "$streaming_request_clean" >&2 || true
    exit 1
  fi
  if ! grep -F "$streaming_payload" "$streaming_request_clean" >/dev/null 2>&1; then
    printf '%s\n' "Streaming response payload not captured" >&2
    printf '%s\n' "Captured requests:" >&2
    cat "$streaming_request_clean" >&2 || true
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
