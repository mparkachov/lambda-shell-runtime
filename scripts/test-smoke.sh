#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

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

host=$(host_arch)
if [ "$arch" != "$host" ]; then
  printf '%s\n' "ARCH=$arch does not match host $host. Run tests on the matching architecture." >&2
  exit 2
fi

layer_root="$root/layer/opt"

needs_build=0
if [ ! -x "$layer_root/bootstrap" ] || \
   [ ! -x "$layer_root/bin/aws" ] || \
   [ ! -x "$layer_root/bin/jq" ]; then
  needs_build=1
elif ! cmp -s "$root/runtime/bootstrap" "$layer_root/bootstrap" 2>/dev/null; then
  needs_build=1
fi

if [ "$needs_build" -eq 1 ]; then
  build_log=$(mktemp)
  if ! ARCH="$arch" "$root/scripts/build_layer.sh" >"$build_log" 2>&1; then
    cat "$build_log" >&2 || true
    rm -f "$build_log"
    exit 1
  fi
  rm -f "$build_log"
fi

"$layer_root/bin/aws" --version
LD_LIBRARY_PATH="$layer_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$layer_root/bin/jq" --version

event_file=$(mktemp)
response_file=$(mktemp)
log_file=$(mktemp)
mock_bin=$(mktemp -d)

bootstrap_pid=""

cleanup() {
  if [ -n "$bootstrap_pid" ]; then
    kill "$bootstrap_pid" >/dev/null 2>&1 || true
    wait "$bootstrap_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$event_file" "$response_file" "$log_file"
  rm -rf "$mock_bin"
}
trap cleanup EXIT

ln -s "$root/scripts/mock_curl.sh" "$mock_bin/curl"

printf '{"message":"hello","value":1}' > "$event_file"

PATH="$mock_bin:$layer_root/bin:$PATH" \
LD_LIBRARY_PATH="$layer_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
AWS_LAMBDA_RUNTIME_API="mock" \
LAMBDA_TASK_ROOT="$root/examples" \
_HANDLER="function.handler" \
MOCK_EVENT_FILE="$event_file" \
MOCK_RESPONSE_FILE="$response_file" \
MOCK_REQUEST_ID="test-invocation-id" \
"$layer_root/bootstrap" >"$log_file" 2>&1 &
bootstrap_pid=$!

waits=200
while [ ! -s "$response_file" ] && [ $waits -gt 0 ]; do
  sleep 0.1
  waits=$((waits - 1))
done

if [ ! -s "$response_file" ]; then
  printf '%s\n' "No response captured from handler" >&2
  printf '%s\n' "Bootstrap output:" >&2
  cat "$log_file" >&2 || true
  exit 1
fi

LD_LIBRARY_PATH="$layer_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$layer_root/bin/jq" -e '.input.message == "hello"' "$response_file" >/dev/null
