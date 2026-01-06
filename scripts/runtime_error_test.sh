#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bootstrap="$root/runtime/bootstrap"

case_name=${1:-}
if [ -z "$case_name" ]; then
  printf '%s\n' "Usage: $0 <missing-handler-file|missing-handler-function|unreadable-handler|handler-exit|handler-exit-stderr|response-post-failure|error-post-failure>" >&2
  exit 2
fi

workdir=$(mktemp -d)
event_file=$(mktemp)
response_file=$(mktemp)
endpoint_file=$(mktemp)
header_file=$(mktemp)
port_file=$(mktemp)
log_file=$(mktemp)

server_pid=""
bootstrap_pid=""

cleanup() {
  if [ -n "$bootstrap_pid" ]; then
    kill "$bootstrap_pid" >/dev/null 2>&1 || true
    wait "$bootstrap_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$event_file" "$response_file" "$endpoint_file" "$header_file" "$port_file" "$log_file"
  rm -rf "$workdir"
}
trap cleanup EXIT

wait_for_file() {
  file=$1
  waits=100
  while [ ! -s "$file" ] && [ "$waits" -gt 0 ]; do
    sleep 0.1
    waits=$((waits - 1))
  done
  [ -s "$file" ]
}

assert_json_field_equals() {
  file=$1
  key=$2
  expected=$3
  python3 - "$file" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(key, "")
if value != expected:
    sys.exit(f"{key} expected {expected!r}, got {value!r}")
PY
}

assert_json_field_contains() {
  file=$1
  key=$2
  expected=$3
  python3 - "$file" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = str(data.get(key, ""))
if expected not in value:
    sys.exit(f"{key} expected to contain {expected!r}, got {value!r}")
PY
}

assert_json_array_length() {
  file=$1
  key=$2
  expected=$3
  python3 - "$file" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:4]
expected = int(expected)
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(key)
if not isinstance(value, list) or len(value) != expected:
    sys.exit(f"{key} expected length {expected!r}, got {value!r}")
PY
}

assert_json_array_contains() {
  file=$1
  key=$2
  expected=$3
  python3 - "$file" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(key)
if not isinstance(value, list) or expected not in value:
    sys.exit(f"{key} expected to contain {expected!r}, got {value!r}")
PY
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

start_init_server() {
  python3 - "$response_file" "$endpoint_file" "$header_file" "$port_file" <<'PY' &
import http.server
import socketserver
import threading
import sys

response_path, endpoint_path, header_path, port_path = sys.argv[1:5]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/2018-06-01/runtime/init/error":
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else b""
            with open(response_path, "wb") as fh:
                fh.write(body)
            with open(endpoint_path, "w", encoding="utf-8") as fh:
                fh.write(self.path)
            with open(header_path, "w", encoding="utf-8") as fh:
                fh.write(self.headers.get("Lambda-Runtime-Function-Error-Type", ""))
            self.send_response(202)
            self.end_headers()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    port = httpd.server_address[1]
    with open(port_path, "w", encoding="utf-8") as fh:
        fh.write(str(port))
    httpd.serve_forever()
PY
  server_pid=$!
}

start_invoke_server() {
  response_code=${1:-202}
  error_code=${2:-202}
  python3 - "$event_file" "$response_file" "$endpoint_file" "$header_file" "$port_file" "$response_code" "$error_code" <<'PY' &
import http.server
import socketserver
import threading
import sys

event_path, response_path, endpoint_path, header_path, port_path, response_code, error_code = sys.argv[1:8]
response_code = int(response_code)
error_code = int(error_code)
with open(event_path, "rb") as fh:
    event_body = fh.read()

invocation_id = "test-invocation-id"

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/2018-06-01/runtime/invocation/next":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Lambda-Runtime-Aws-Request-Id", invocation_id)
            self.end_headers()
            self.wfile.write(event_body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == f"/2018-06-01/runtime/invocation/{invocation_id}/response":
            status = response_code
        elif self.path == f"/2018-06-01/runtime/invocation/{invocation_id}/error":
            status = error_code
        else:
            status = None
        if status is not None:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else b""
            with open(response_path, "wb") as fh:
                fh.write(body)
            with open(endpoint_path, "w", encoding="utf-8") as fh:
                fh.write(self.path)
            if self.path.endswith("/error"):
                with open(header_path, "w", encoding="utf-8") as fh:
                    fh.write(self.headers.get("Lambda-Runtime-Function-Error-Type", ""))
            self.send_response(status)
            self.end_headers()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    port = httpd.server_address[1]
    with open(port_path, "w", encoding="utf-8") as fh:
        fh.write(str(port))
    httpd.serve_forever()
PY
  server_pid=$!
}

run_bootstrap() {
  port=$(cat "$port_file")
  AWS_LAMBDA_RUNTIME_API="127.0.0.1:${port}" \
  LAMBDA_TASK_ROOT="$workdir" \
  _HANDLER="$1" \
  "$bootstrap" >"$log_file" 2>&1 &
  bootstrap_pid=$!
}

case "$case_name" in
  missing-handler-file)
    start_init_server
    wait_for_file "$port_file"
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
    cat <<'SH' > "$workdir/function.sh"
not_handler() { :; }
SH
    start_init_server
    wait_for_file "$port_file"
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
    start_init_server
    wait_for_file "$port_file"
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
    cat <<'SH' > "$workdir/function.sh"
handler() {
  return 3
}
SH
    printf '{"message":"fail"}' > "$event_file"
    start_invoke_server
    wait_for_file "$port_file"
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
    cat <<'SH' > "$workdir/function.sh"
handler() {
  printf '%s\n' "TypeError: bad input" >&2
  printf '%s\n' "line 2" >&2
  return 3
}
SH
    printf '{"message":"fail"}' > "$event_file"
    start_invoke_server
    wait_for_file "$port_file"
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
  response-post-failure)
    cat <<'SH' > "$workdir/function.sh"
handler() {
  printf '%s\n' "{\"ok\":true}"
}
SH
    printf '{"message":"ok"}' > "$event_file"
    start_invoke_server 500 202
    wait_for_file "$port_file"
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
    cat <<'SH' > "$workdir/function.sh"
handler() {
  printf '%s\n' "Error: fail" >&2
  return 2
}
SH
    printf '{"message":"fail"}' > "$event_file"
    start_invoke_server 202 500
    wait_for_file "$port_file"
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
  *)
    printf '%s\n' "Unknown test case: $case_name" >&2
    exit 2
    ;;
esac
