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

The handler must be an executable file in the function package. The runtime:

1. Retrieves the next event from the Runtime API.
2. Writes the event payload to the handler's STDIN.
3. Reads the handler's STDOUT as the invocation response.

The handler:

- Reads JSON from STDIN
- Writes the response JSON to STDOUT
- Writes logs to STDERR

The runtime does not transform or reinterpret the event or response payload.

## Environment variables used

Only AWS-defined environment variables are used:

- `AWS_LAMBDA_RUNTIME_API`: host:port for the Runtime API
- `_HANDLER`: handler executable name
- `LAMBDA_TASK_ROOT`: function code directory (defaults to `/var/task`)

The runtime does not modify `PATH` or `LD_LIBRARY_PATH`. Lambda already includes `/opt/bin` and `/opt/lib` in the default environment for layers.
