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

if [ ! -x "$layer_root/bootstrap" ] || \
   [ ! -x "$layer_root/bin/aws" ] || \
   [ ! -x "$layer_root/bin/jq" ]; then
  ARCH="$arch" "$root/scripts/build_layer.sh"
fi

"$layer_root/bin/aws" --version
LD_LIBRARY_PATH="$layer_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$layer_root/bin/jq" --version

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

PATH="$layer_root/bin:$PATH" \
LD_LIBRARY_PATH="$layer_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
AWS_LAMBDA_RUNTIME_API="127.0.0.1:${port}" \
LAMBDA_TASK_ROOT="$root/runtime-tutorial" \
_HANDLER="function.handler" \
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
  "$layer_root/bin/jq" -e '.message == "hello"' "$response_file" >/dev/null
