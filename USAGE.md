# Usage (manual publish)

This document covers manual publishing (without SAR) and the runtime contract.
If you are installing from SAR, use `SAR_README.md` for the end-user instructions.

AWS documentation:
- https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html
- https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html

## Manual publish (without SAR)

1. Build and package the layer:

```sh
./scripts/build_layer.sh
./scripts/package_layer.sh
```

2. Publish the layer and attach it to your function:

```sh
aws lambda publish-layer-version \
  --layer-name lambda-shell-runtime \
  --zip-file fileb://dist/lambda-shell-runtime-arm64.zip \
  --compatible-runtimes provided.al2023 \
  --compatible-architectures arm64
```

For x86_64, publish the amd64 artifact:

```sh
aws lambda publish-layer-version \
  --layer-name lambda-shell-runtime \
  --zip-file fileb://dist/lambda-shell-runtime-amd64.zip \
  --compatible-runtimes provided.al2023 \
  --compatible-architectures x86_64
```

## Handler contract

The handler is a shell script in the function package. `_HANDLER` follows the `function.handler` pattern from the
AWS custom runtime tutorial. For example, `_HANDLER=function.handler` loads `function.sh` from `LAMBDA_TASK_ROOT`,
then invokes the `handler` shell function with the event JSON on STDIN.

Execution modes:

- `function.handler`: the runtime sources `function.sh` with `/bin/sh` and invokes the `handler` function. The file
  does not need to be executable and must use POSIX `sh` syntax.
- `handler` (no dot): the runtime treats `_HANDLER` as a handler file path. If the file is executable, it is run
  directly (shebang honored). If not, the runtime invokes it with `/bin/sh`. Use this mode for bash by making the
  handler executable and starting it with `#!/bin/bash`.

The runtime:

1. Retrieves the next event from the Runtime API.
2. Passes the event payload to the handler via STDIN.
3. Reads the handler's STDOUT as the invocation response.

The handler:

- Reads the event JSON from STDIN
- Writes the response JSON to STDOUT
- Writes logs to STDERR

The runtime does not transform or reinterpret the event or response payload.

## Invocation metadata

For each invocation, the runtime maps Runtime API headers to environment variables for the handler:

- `LAMBDA_RUNTIME_AWS_REQUEST_ID` (`Lambda-Runtime-Aws-Request-Id`)
- `LAMBDA_RUNTIME_DEADLINE_MS` (`Lambda-Runtime-Deadline-Ms`)
- `LAMBDA_RUNTIME_INVOKED_FUNCTION_ARN` (`Lambda-Runtime-Invoked-Function-Arn`)
- `LAMBDA_RUNTIME_TRACE_ID` (`Lambda-Runtime-Trace-Id`)
- `LAMBDA_RUNTIME_CLIENT_CONTEXT` (`Lambda-Runtime-Client-Context`)
- `LAMBDA_RUNTIME_COGNITO_IDENTITY` (`Lambda-Runtime-Cognito-Identity`)

The runtime also sets `_X_AMZN_TRACE_ID` to the trace header value when present. Client context and Cognito identity
are passed through as received (base64-encoded JSON per the Runtime API). Values are unset between invocations.

## Remaining time helper

`LAMBDA_RUNTIME_DEADLINE_MS` is an epoch time in milliseconds. The helper below returns the remaining time in
milliseconds for POSIX `sh` handlers.

```sh
remaining_time_ms() {
  if [ -z "${LAMBDA_RUNTIME_DEADLINE_MS:-}" ]; then
    return 1
  fi
  now_ms=$(date +%s%3N 2>/dev/null || true)
  case "$now_ms" in
    ''|*[!0-9]*)
      now_ms=$(( $(date +%s) * 1000 ))
      ;;
  esac
  printf '%s\n' "$((LAMBDA_RUNTIME_DEADLINE_MS - now_ms))"
}
```

On AL2023, `date` supports `%s` and `%3N`. If `%3N` is unavailable, the helper falls back to second precision.

## Environment variables used

The runtime depends only on AWS-defined environment variables:

- `AWS_LAMBDA_RUNTIME_API`: host:port for the Runtime API
- `_HANDLER`: handler identifier (`function.handler` or a handler filename)
- `LAMBDA_TASK_ROOT`: function code directory (defaults to `/var/task`)
- `_X_AMZN_TRACE_ID`: X-Ray trace header for the current invocation (set by the runtime when provided)

The runtime does not modify `PATH` or `LD_LIBRARY_PATH`. Lambda already includes `/opt/bin` and `/opt/lib` in the default environment for layers.

## Performance note

The AWS CLI layer adds size, which can make cold starts slow at low memory settings. For quicker testing, increase
the function memory (for example, 512 MB) and invoke it twice to observe warm performance.
