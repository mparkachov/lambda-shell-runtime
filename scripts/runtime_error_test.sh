#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bootstrap="$root/runtime/bootstrap"

case_name=${1:-}
if [ -z "$case_name" ]; then
  printf '%s\n' "Usage: $0 <missing-handler-file|missing-handler-function|unreadable-handler|handler-exit>" >&2
  exit 2
fi

workdir=$(mktemp -d)
event_file=$(mktemp)
response_file=$(mktemp)
endpoint_file=$(mktemp)
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
  rm -f "$event_file" "$response_file" "$endpoint_file" "$port_file" "$log_file"
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

start_init_server() {
  python3 - "$response_file" "$endpoint_file" "$port_file" <<'PY' &
import http.server
import socketserver
import threading
import sys

response_path, endpoint_path, port_path = sys.argv[1:4]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/2018-06-01/runtime/init/error":
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else b""
            with open(response_path, "wb") as fh:
                fh.write(body)
            with open(endpoint_path, "w", encoding="utf-8") as fh:
                fh.write(self.path)
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
  python3 - "$event_file" "$response_file" "$endpoint_file" "$port_file" <<'PY' &
import http.server
import socketserver
import threading
import sys

event_path, response_path, endpoint_path, port_path = sys.argv[1:5]
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
        if self.path in (
            f"/2018-06-01/runtime/invocation/{invocation_id}/response",
            f"/2018-06-01/runtime/invocation/{invocation_id}/error",
        ):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else b""
            with open(response_path, "wb") as fh:
                fh.write(body)
            with open(endpoint_path, "w", encoding="utf-8") as fh:
                fh.write(self.path)
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
    if [ "$(cat "$endpoint_file")" != "/2018-06-01/runtime/init/error" ]; then
      printf '%s\n' "Unexpected init error endpoint: $(cat "$endpoint_file")" >&2
      exit 1
    fi
    assert_json_field_equals "$response_file" "errorType" "Runtime.InvalidHandler"
    assert_json_field_contains "$response_file" "errorMessage" "Handler script not found"
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
    if [ "$(cat "$endpoint_file")" != "/2018-06-01/runtime/init/error" ]; then
      printf '%s\n' "Unexpected init error endpoint: $(cat "$endpoint_file")" >&2
      exit 1
    fi
    assert_json_field_equals "$response_file" "errorType" "Runtime.InvalidHandler"
    assert_json_field_contains "$response_file" "errorMessage" "Handler function not found"
    ;;
  unreadable-handler)
    printf '%s\n' "#!/bin/sh" > "$workdir/script"
    chmod 000 "$workdir/script"
    start_init_server
    wait_for_file "$port_file"
    run_bootstrap "script" || true
    wait_for_file "$response_file"
    wait_for_file "$endpoint_file"
    if [ "$(cat "$endpoint_file")" != "/2018-06-01/runtime/init/error" ]; then
      printf '%s\n' "Unexpected init error endpoint: $(cat "$endpoint_file")" >&2
      exit 1
    fi
    assert_json_field_equals "$response_file" "errorType" "Runtime.InvalidHandler"
    assert_json_field_contains "$response_file" "errorMessage" "Handler not readable"
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
    case "$(cat "$endpoint_file")" in
      */error) ;;
      *)
        printf '%s\n' "Unexpected invoke error endpoint: $(cat "$endpoint_file")" >&2
        exit 1
        ;;
    esac
    assert_json_field_equals "$response_file" "errorType" "Runtime.HandlerError"
    assert_json_field_contains "$response_file" "errorMessage" "Handler exited with status 3"
    ;;
  *)
    printf '%s\n' "Unknown test case: $case_name" >&2
    exit 2
    ;;
esac
