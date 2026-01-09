#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bootstrap="$root/runtime/bootstrap"

case_name=${1:-}
if [ -z "$case_name" ]; then
  printf '%s\n' "Usage: $0 <missing-handler-file|missing-handler-function|unreadable-handler|handler-exit|handler-exit-stderr|handler-exit-escape|response-post-failure|error-post-failure|large-payload|env-var-cleanup|xray-segment-log|xray-segment-log-disabled|streaming-response>" >&2
  exit 2
fi

workdir=$(mktemp -d)
event_file=$(mktemp)
response_file=$(mktemp)
endpoint_file=$(mktemp)
header_file=$(mktemp)
mode_file=$(mktemp)
log_file=$(mktemp)
mock_bin=$(mktemp -d)

bootstrap_pid=""

cleanup() {
  if [ -n "$bootstrap_pid" ]; then
    kill "$bootstrap_pid" >/dev/null 2>&1 || true
    wait "$bootstrap_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$event_file" "$response_file" "$endpoint_file" "$header_file" "$mode_file" "$log_file"
  rm -rf "$workdir" "$mock_bin"
}
trap cleanup EXIT

ln -s "$root/scripts/mock_curl.sh" "$mock_bin/curl"

wait_for_file() {
  file=$1
  waits=100
  while [ ! -s "$file" ] && [ "$waits" -gt 0 ]; do
    sleep 0.1
    waits=$((waits - 1))
  done
  [ -s "$file" ]
}

wait_for_lines() {
  file=$1
  expected=$2
  waits=100
  while [ "$waits" -gt 0 ]; do
    if [ -f "$file" ]; then
      count=$(wc -l < "$file" | tr -d ' ')
      if [ "$count" -ge "$expected" ]; then
        return 0
      fi
    fi
    sleep 0.1
    waits=$((waits - 1))
  done
  return 1
}

json_get_string() {
  file=$1
  key=$2
  sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p" "$file" | head -n1
}

json_array_items() {
  file=$1
  key=$2
  raw=$(sed -n "s/.*\"$key\":\[\(.*\)\].*/\1/p" "$file" | head -n1)
  raw=$(printf '%s' "$raw" | tr -d '\r')
  if [ -z "$raw" ]; then
    return 0
  fi
  printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//' | sed 's/","/\n/g'
}

assert_json_field_equals() {
  file=$1
  key=$2
  expected=$3
  value=$(json_get_string "$file" "$key")
  if [ "$value" != "$expected" ]; then
    printf '%s\n' "$key expected $expected, got $value" >&2
    exit 1
  fi
}

assert_json_field_contains() {
  file=$1
  key=$2
  expected=$3
  value=$(json_get_string "$file" "$key")
  case "$value" in
    *"$expected"*) return 0 ;;
  esac
  printf '%s\n' "$key expected to contain $expected, got $value" >&2
  exit 1
}

assert_json_array_length() {
  file=$1
  key=$2
  expected=$3
  items=$(json_array_items "$file" "$key" || true)
  count=0
  if [ -n "$items" ]; then
    count=$(printf '%s\n' "$items" | sed '/^$/d' | wc -l | tr -d ' ')
  fi
  if [ "$count" -ne "$expected" ]; then
    printf '%s\n' "$key expected length $expected, got $count" >&2
    exit 1
  fi
}

assert_json_array_contains() {
  file=$1
  key=$2
  expected=$3
  items=$(json_array_items "$file" "$key" || true)
  if ! printf '%s\n' "$items" | grep -F "$expected" >/dev/null 2>&1; then
    printf '%s\n' "$key expected to contain $expected" >&2
    exit 1
  fi
}

assert_file_equals() {
  file=$1
  expected=$2
  actual=$(tr -d '\r\n' < "$file")
  if [ "$actual" != "$expected" ]; then
    printf '%s\n' "Expected $file to be ${expected}, got ${actual}" >&2
    exit 1
  fi
}

assert_file_contains() {
  file=$1
  expected=$2
  waits=50
  while [ "$waits" -gt 0 ]; do
    if grep -F "$expected" "$file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
    waits=$((waits - 1))
  done
  printf '%s\n' "Expected $file to contain: $expected" >&2
  exit 1
}

assert_log_contains() {
  expected=$1
  if ! grep -F "$expected" "$log_file" >/dev/null 2>&1; then
    printf '%s\n' "Expected log to contain: $expected" >&2
    exit 1
  fi
}

get_exit_status() {
  pid=$1
  waits=100
  while kill -0 "$pid" >/dev/null 2>&1 && [ "$waits" -gt 0 ]; do
    sleep 0.1
    waits=$((waits - 1))
  done
  if kill -0 "$pid" >/dev/null 2>&1; then
    printf '%s\n' "timeout"
    return 0
  fi
  if wait "$pid"; then
    printf '%s\n' "0"
  else
    printf '%s\n' "$?"
  fi
  return 0
}

run_bootstrap() {
  AWS_LAMBDA_RUNTIME_API="mock" \
  LAMBDA_TASK_ROOT="$workdir" \
  _HANDLER="$1" \
  AWS_XRAY_DAEMON_ADDRESS="${MOCK_XRAY_DAEMON_ADDRESS:-}" \
  PATH="$mock_bin:$PATH" \
  MOCK_EVENT_FILE="$event_file" \
  MOCK_RESPONSE_FILE="$response_file" \
  MOCK_ENDPOINT_FILE="$endpoint_file" \
  MOCK_ERROR_TYPE_FILE="$header_file" \
  MOCK_RESPONSE_MODE="${MOCK_RESPONSE_MODE:-}" \
  MOCK_RESPONSE_MODE_FILE="${MOCK_RESPONSE_MODE_FILE:-}" \
  MOCK_REQUEST_ID="test-invocation-id" \
  MOCK_RESPONSE_CODE="${MOCK_RESPONSE_CODE:-}" \
  MOCK_ERROR_CODE="${MOCK_ERROR_CODE:-}" \
  MOCK_INIT_ERROR_CODE="${MOCK_INIT_ERROR_CODE:-}" \
  MOCK_NEXT_CODE="${MOCK_NEXT_CODE:-}" \
  MOCK_NEXT_BODY="${MOCK_NEXT_BODY:-}" \
  MOCK_NEXT_BODY_FILE="${MOCK_NEXT_BODY_FILE:-}" \
  MOCK_NEXT_COUNT_FILE="${MOCK_NEXT_COUNT_FILE:-}" \
  MOCK_NEXT_TRACE_ID="${MOCK_NEXT_TRACE_ID:-}" \
  MOCK_NEXT_TRACE_ID_ONCE="${MOCK_NEXT_TRACE_ID_ONCE:-}" \
  "$bootstrap" >"$log_file" 2>&1 &
  bootstrap_pid=$!
}

case "$case_name" in
  missing-handler-file)
    run_bootstrap "missing.handler" || true
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    wait_for_file "$header_file"
    if [ "$(cat "$endpoint_file")" != "/2018-06-01/runtime/init/error" ]; then
      printf '%s\n' "Unexpected init error endpoint: $(cat "$endpoint_file")" >&2
      exit 1
    fi
    assert_file_equals "$header_file" "Unhandled"
    assert_json_field_equals "$response_file" "errorType" "Runtime.InvalidHandler"
    assert_json_field_contains "$response_file" "errorMessage" "Handler script not found"
    assert_json_array_length "$response_file" "stackTrace" "0"
    ;;
  missing-handler-function)
    cat <<'HANDLER' > "$workdir/function.sh"
not_handler() { :; }
HANDLER
    run_bootstrap "function.handler" || true
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    wait_for_file "$header_file"
    if [ "$(cat "$endpoint_file")" != "/2018-06-01/runtime/init/error" ]; then
      printf '%s\n' "Unexpected init error endpoint: $(cat "$endpoint_file")" >&2
      exit 1
    fi
    assert_file_equals "$header_file" "Unhandled"
    assert_json_field_equals "$response_file" "errorType" "Runtime.InvalidHandler"
    assert_json_field_contains "$response_file" "errorMessage" "Handler function not found"
    assert_json_array_length "$response_file" "stackTrace" "0"
    ;;
  unreadable-handler)
    printf '%s\n' "#!/bin/sh" > "$workdir/script"
    chmod 000 "$workdir/script"
    run_bootstrap "script" || true
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    wait_for_file "$header_file"
    if [ "$(cat "$endpoint_file")" != "/2018-06-01/runtime/init/error" ]; then
      printf '%s\n' "Unexpected init error endpoint: $(cat "$endpoint_file")" >&2
      exit 1
    fi
    assert_file_equals "$header_file" "Unhandled"
    assert_json_field_equals "$response_file" "errorType" "Runtime.InvalidHandler"
    assert_json_field_contains "$response_file" "errorMessage" "Handler not readable"
    assert_json_array_length "$response_file" "stackTrace" "0"
    ;;
  handler-exit)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  return 3
}
HANDLER
    printf '{"message":"fail"}' > "$event_file"
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    wait_for_file "$header_file"
    case "$(cat "$endpoint_file")" in
      */error) ;;
      *)
        printf '%s\n' "Unexpected invoke error endpoint: $(cat "$endpoint_file")" >&2
        exit 1
        ;;
    esac
    assert_file_equals "$header_file" "Unhandled"
    assert_json_field_equals "$response_file" "errorType" "Error"
    assert_json_field_contains "$response_file" "errorMessage" "Handler exited with status 3"
    assert_json_array_length "$response_file" "stackTrace" "0"
    ;;
  handler-exit-stderr)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  printf '%s\n' "TypeError: bad input" >&2
  printf '%s\n' "line 2" >&2
  return 3
}
HANDLER
    printf '{"message":"fail"}' > "$event_file"
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    wait_for_file "$header_file"
    case "$(cat "$endpoint_file")" in
      */error) ;;
      *)
        printf '%s\n' "Unexpected invoke error endpoint: $(cat "$endpoint_file")" >&2
        exit 1
        ;;
    esac
    assert_file_equals "$header_file" "Unhandled"
    assert_json_field_equals "$response_file" "errorType" "TypeError"
    assert_json_field_equals "$response_file" "errorMessage" "bad input"
    assert_json_array_contains "$response_file" "stackTrace" "line 2"
    ;;
  handler-exit-escape)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  printf 'Error: bad\t"quote" \\ slash\n' >&2
  printf 'trace\tline\001\n' >&2
  return 3
}
HANDLER
    printf '{"message":"fail"}' > "$event_file"
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    wait_for_file "$header_file"
    case "$(cat "$endpoint_file")" in
      */error) ;;
      *)
        printf '%s\n' "Unexpected invoke error endpoint: $(cat "$endpoint_file")" >&2
        exit 1
        ;;
    esac
    assert_file_equals "$header_file" "Unhandled"
    assert_json_field_equals "$response_file" "errorType" "Error"
    assert_file_contains "$response_file" '"errorMessage":"bad\t\"quote\" \\ slash"'
    assert_file_contains "$response_file" '"stackTrace":["trace\tline\u0001"]'
    ;;
  response-post-failure)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  printf '%s\n' "{\"ok\":true}"
}
HANDLER
    printf '{"message":"ok"}' > "$event_file"
    MOCK_RESPONSE_CODE=500
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    exit_status=$(get_exit_status "$bootstrap_pid")
    if [ "$exit_status" = "timeout" ]; then
      printf '%s\n' "Bootstrap did not exit after failed response POST" >&2
      exit 1
    fi
    if [ "$exit_status" -eq 0 ]; then
      printf '%s\n' "Expected non-zero exit for failed response POST" >&2
      exit 1
    fi
    case "$(cat "$endpoint_file")" in
      */response) ;;
      *)
        printf '%s\n' "Unexpected invoke response endpoint: $(cat "$endpoint_file")" >&2
        exit 1
        ;;
    esac
    assert_log_contains "Failed to post runtime response"
    ;;
  error-post-failure)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  printf '%s\n' "Error: fail" >&2
  return 2
}
HANDLER
    printf '{"message":"fail"}' > "$event_file"
    MOCK_ERROR_CODE=500
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    wait_for_file "$header_file"
    exit_status=$(get_exit_status "$bootstrap_pid")
    if [ "$exit_status" = "timeout" ]; then
      printf '%s\n' "Bootstrap did not exit after failed error POST" >&2
      exit 1
    fi
    if [ "$exit_status" -eq 0 ]; then
      printf '%s\n' "Expected non-zero exit for failed error POST" >&2
      exit 1
    fi
    case "$(cat "$endpoint_file")" in
      */error) ;;
      *)
        printf '%s\n' "Unexpected invoke error endpoint: $(cat "$endpoint_file")" >&2
        exit 1
        ;;
    esac
    assert_file_equals "$header_file" "Unhandled"
    assert_log_contains "Failed to post runtime error"
    ;;
  large-payload)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  bytes=$(wc -c | tr -d ' ')
  printf '{"bytes":"%s"}' "$bytes"
}
HANDLER
    payload_size=1048576
    printf '{"data":"' > "$event_file"
    awk -v size="$payload_size" 'BEGIN { for (i = 0; i < size; i++) printf "a" }' >> "$event_file"
    printf '"}' >> "$event_file"
    expected_bytes=$(wc -c < "$event_file" | tr -d ' ')
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    assert_json_field_equals "$response_file" "bytes" "$expected_bytes"
    ;;
  env-var-cleanup)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  log_file="${LAMBDA_TASK_ROOT}/env-log"
  if [ "${LAMBDA_RUNTIME_TRACE_ID+x}" = "x" ]; then
    printf '%s\n' "$LAMBDA_RUNTIME_TRACE_ID" >> "$log_file"
  else
    printf '%s\n' "UNSET" >> "$log_file"
  fi
  printf '%s\n' '{"ok":true}'
}
HANDLER
    printf '{"message":"ok"}' > "$event_file"
    trace_id="Root=1-abcdef01-234567890abcdef01234567;Parent=1234;Sampled=1"
    MOCK_NEXT_TRACE_ID="$trace_id"
    MOCK_NEXT_TRACE_ID_ONCE=1
    MOCK_NEXT_COUNT_FILE="$workdir/next-count"
    run_bootstrap "function.handler"
    env_log="$workdir/env-log"
    if ! wait_for_lines "$env_log" 2; then
      printf '%s\n' "Expected env log to contain two invocations" >&2
      exit 1
    fi
    line1=$(sed -n '1p' "$env_log")
    line2=$(sed -n '2p' "$env_log")
    if [ "$line1" != "$trace_id" ]; then
      printf '%s\n' "Expected first invocation trace id to be set" >&2
      exit 1
    fi
    if [ "$line2" != "UNSET" ]; then
      printf '%s\n' "Expected trace id to be unset on second invocation" >&2
      exit 1
    fi
    ;;
  xray-segment-log)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  printf '%s\n' '{"ok":true}'
}
HANDLER
    printf '{"message":"ok"}' > "$event_file"
    trace_id="Root=1-abcdef01-234567890abcdef01234567;Parent=1234;Sampled=1"
    MOCK_NEXT_TRACE_ID="$trace_id"
    MOCK_XRAY_DAEMON_ADDRESS="127.0.0.1:2000"
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    assert_log_contains "X-Ray segment:"
    assert_log_contains "1-abcdef01-234567890abcdef01234567"
    ;;
  xray-segment-log-disabled)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  printf '%s\n' '{"ok":true}'
}
HANDLER
    printf '{"message":"ok"}' > "$event_file"
    trace_id="Root=1-abcdef01-234567890abcdef01234567;Parent=1234;Sampled=1"
    MOCK_NEXT_TRACE_ID="$trace_id"
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    if grep -F "X-Ray segment:" "$log_file" >/dev/null 2>&1; then
      printf '%s\n' "Expected X-Ray segment log to be disabled" >&2
      exit 1
    fi
    ;;
  streaming-response)
    cat <<'HANDLER' > "$workdir/function.sh"
handler() {
  printf '%s' '{"ok":true,"stream":"yes"}'
}
HANDLER
    printf '{"message":"ok"}' > "$event_file"
    MOCK_RESPONSE_MODE="streaming"
    MOCK_RESPONSE_MODE_FILE="$mode_file"
    run_bootstrap "function.handler"
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    wait_for_file "$mode_file"
    case "$(cat "$endpoint_file")" in
      */response) ;;
      *)
        printf '%s\n' "Unexpected invoke response endpoint: $(cat "$endpoint_file")" >&2
        exit 1
        ;;
    esac
    assert_file_equals "$mode_file" "streaming"
    assert_file_equals "$response_file" '{"ok":true,"stream":"yes"}'
    ;;
  *)
    printf '%s\n' "Unknown test case: $case_name" >&2
    exit 2
    ;;
esac
