#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ ! -x "$root/layer/opt/bootstrap" ] || \
   [ ! -x "$root/layer/opt/bin/aws" ] || \
   [ ! -x "$root/layer/opt/bin/jq" ]; then
  "$root/scripts/build_layer.sh"
fi

"$root/layer/opt/bin/aws" --version
"$root/layer/opt/bin/jq" --version

event_file=$(mktemp)
response_file=$(mktemp)
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
  rm -f "$event_file" "$response_file" "$port_file" "$log_file"
}
trap cleanup EXIT

printf '{"message":"hello","value":1}' > "$event_file"

python3 - "$event_file" "$response_file" "$port_file" <<'PY' &
import http.server
import socketserver
import threading
import sys

event_path, response_path, port_path = sys.argv[1:4]
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

waits=100
while [ ! -s "$port_file" ] && [ $waits -gt 0 ]; do
  sleep 0.1
  waits=$((waits - 1))
done

if [ ! -s "$port_file" ]; then
  printf '%s\n' "Mock runtime API failed to start" >&2
  exit 1
fi

port=$(cat "$port_file")

PATH="$root/layer/opt/bin:$PATH" \
AWS_LAMBDA_RUNTIME_API="127.0.0.1:${port}" \
LAMBDA_TASK_ROOT="$root/examples/hello" \
_HANDLER="handler" \
"$root/layer/opt/bootstrap" >"$log_file" 2>&1 &
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

"$root/layer/opt/bin/jq" -e '.message == "hello"' "$response_file" >/dev/null
