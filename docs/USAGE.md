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
then invokes the `handler` shell function with the event JSON as the first argument.

For compatibility, if `_HANDLER` does not contain a dot, the runtime treats it as a handler file. If the file is
executable, it is run directly. If not, the runtime invokes it with `/bin/sh`.

The runtime:

1. Retrieves the next event from the Runtime API.
2. Passes the event payload to the handler (argument for `function.handler`, STDIN for file handlers).
3. Reads the handler's STDOUT as the invocation response.

The handler:

- Reads the event JSON from the first argument (or STDIN for file handlers)
- Writes the response JSON to STDOUT
- Writes logs to STDERR

The runtime does not transform or reinterpret the event or response payload.

## Environment variables used

Only AWS-defined environment variables are used:

- `AWS_LAMBDA_RUNTIME_API`: host:port for the Runtime API
- `_HANDLER`: handler identifier (`function.handler` or a handler filename)
- `LAMBDA_TASK_ROOT`: function code directory (defaults to `/var/task`)

The runtime does not modify `PATH` or `LD_LIBRARY_PATH`. Lambda already includes `/opt/bin` and `/opt/lib` in the default environment for layers.
