#!/bin/sh
set -eu

output_file=""
header_file=""
write_out=""
method=""
data_file=""
data_tmp=""
data_from_stdin=0
error_type=""
response_mode=""
url=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      output_file=${1:-}
      ;;
    -D)
      shift
      header_file=${1:-}
      ;;
    -w)
      shift
      write_out=${1:-}
      ;;
    -X)
      shift
      method=${1:-}
      ;;
    -H)
      shift
      header=${1:-}
      case "$header" in
        Lambda-Runtime-Function-Error-Type:*)
          error_type=$(printf '%s' "$header" | sed 's/^[^:]*: *//')
          ;;
        Lambda-Runtime-Function-Response-Mode:*)
          response_mode=$(printf '%s' "$header" | sed 's/^[^:]*: *//')
          ;;
      esac
      ;;
    --data-binary)
      shift
      data_spec=${1:-}
      case "$data_spec" in
        @-)
          data_from_stdin=1
          ;;
        @*) data_file=${data_spec#@} ;;
        *)
          data_tmp=$(mktemp)
          printf '%s' "$data_spec" > "$data_tmp"
          data_file=$data_tmp
          ;;
      esac
      ;;
    http://*|https://*)
      url=$1
      ;;
    *)
      ;;
  esac
  shift
done

cleanup() {
  if [ -n "$data_tmp" ]; then
    rm -f "$data_tmp"
  fi
}
trap cleanup EXIT

if [ "$data_from_stdin" -eq 1 ]; then
  data_tmp=$(mktemp)
  cat > "$data_tmp"
  data_file=$data_tmp
fi

path=""
if [ -n "$url" ]; then
  path=${url#*://}
  path="/${path#*/}"
fi

request_id=${MOCK_REQUEST_ID:-test-invocation-id}

case "$path" in
  /2018-06-01/runtime/invocation/next)
    event_file=${MOCK_EVENT_FILE:-}
    next_index=1
    if [ -n "${MOCK_NEXT_COUNT_FILE:-}" ]; then
      current=0
      if [ -f "$MOCK_NEXT_COUNT_FILE" ]; then
        current=$(cat "$MOCK_NEXT_COUNT_FILE")
      fi
      case "$current" in
        ''|*[!0-9]*) current=0 ;;
      esac
      next_index=$((current + 1))
      printf '%s' "$next_index" > "$MOCK_NEXT_COUNT_FILE"
    fi
    code=${MOCK_NEXT_CODE:-200}
    trace_id_header=""
    if [ -n "${MOCK_NEXT_TRACE_ID:-}" ]; then
      if [ -n "${MOCK_NEXT_TRACE_ID_ONCE:-}" ]; then
        if [ "$next_index" -eq 1 ]; then
          trace_id_header=$MOCK_NEXT_TRACE_ID
        fi
      else
        trace_id_header=$MOCK_NEXT_TRACE_ID
      fi
    fi
    if [ "$code" = "200" ]; then
      if [ -z "$event_file" ] || [ ! -f "$event_file" ]; then
        exit 1
      fi
      if [ -n "$output_file" ]; then
        cat "$event_file" > "$output_file"
      fi
      if [ -n "$header_file" ]; then
        {
          printf '%s\n' "Lambda-Runtime-Aws-Request-Id: $request_id"
          printf '%s\n' "Lambda-Runtime-Deadline-Ms: 0"
          if [ -n "$trace_id_header" ]; then
            printf '%s\n' "Lambda-Runtime-Trace-Id: $trace_id_header"
          fi
          if [ -n "${MOCK_RESPONSE_MODE:-}" ]; then
            printf '%s\n' "Lambda-Runtime-Function-Response-Mode: ${MOCK_RESPONSE_MODE}"
          fi
        } > "$header_file"
      fi
    else
      if [ -n "$output_file" ]; then
        if [ -n "${MOCK_NEXT_BODY_FILE:-}" ] && [ -f "$MOCK_NEXT_BODY_FILE" ]; then
          cat "$MOCK_NEXT_BODY_FILE" > "$output_file"
        elif [ -n "${MOCK_NEXT_BODY:-}" ]; then
          printf '%s' "$MOCK_NEXT_BODY" > "$output_file"
        else
          : > "$output_file"
        fi
      fi
      if [ -n "$header_file" ]; then
        : > "$header_file"
      fi
    fi
    if [ -n "$write_out" ]; then
      printf '%s' "$code"
    fi
    exit 0
    ;;
  /2018-06-01/runtime/init/error)
    code=${MOCK_INIT_ERROR_CODE:-202}
    target_file=${MOCK_INIT_ERROR_FILE:-${MOCK_RESPONSE_FILE:-}}
    ;;
  /2018-06-01/runtime/invocation/*/response)
    code=${MOCK_RESPONSE_CODE:-202}
    target_file=${MOCK_RESPONSE_FILE:-}
    ;;
  /2018-06-01/runtime/invocation/*/error)
    code=${MOCK_ERROR_CODE:-202}
    target_file=${MOCK_ERROR_FILE:-${MOCK_RESPONSE_FILE:-}}
    ;;
  *)
    code=404
    target_file=""
    ;;
esac

if [ -n "${MOCK_ENDPOINT_FILE:-}" ]; then
  printf '%s' "$path" > "$MOCK_ENDPOINT_FILE"
fi

if [ -n "${MOCK_ERROR_TYPE_FILE:-}" ] && [ -n "$error_type" ]; then
  printf '%s' "$error_type" > "$MOCK_ERROR_TYPE_FILE"
fi

if [ -n "${MOCK_RESPONSE_MODE_FILE:-}" ] && [ -n "$response_mode" ]; then
  printf '%s' "$response_mode" > "$MOCK_RESPONSE_MODE_FILE"
fi

if [ -n "$target_file" ] && [ -n "$data_file" ]; then
  cat "$data_file" > "$target_file"
fi

if [ -n "$write_out" ]; then
  printf '%s' "$code"
fi

exit 0
