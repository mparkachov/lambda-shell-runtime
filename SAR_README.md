# Lambda Shell Runtime (SAR)

This Serverless Application Repository (SAR) application publishes a Lambda layer that provides a minimal
custom runtime for `provided.al2023` using `/bin/sh`, plus AWS CLI v2 and jq.

## Applications

Three SAR applications are published:

- `lambda-shell-runtime` (wrapper that references both architectures)
- `lambda-shell-runtime-arm64`
- `lambda-shell-runtime-amd64`

The wrapper application publishes no layer itself; it exposes both architecture layer ARNs as stack outputs.
Each architecture-specific application publishes a single Lambda layer version.

## Install

Deploy the SAR application that matches your needs. After deployment, read the
appropriate output and attach it to your function.

Example (wrapper application):

```sh
STACK_NAME=lambda-shell-runtime
LAYER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerVersionArnArm64'].OutputValue" \
  --output text)
```

For x86_64, use `LayerVersionArnAmd64` instead.

Example (single architecture):

```sh
STACK_NAME=lambda-shell-runtime-arm64
LAYER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerVersionArn'].OutputValue" \
  --output text)
```

## Use the layer

- Runtime: `provided.al2023`
- Architecture: `arm64` or `x86_64` (must match the layer)
- Handler: executable file name in your function package

Lambda automatically includes `/opt/bin` and `/opt/lib` from layers in `PATH` and `LD_LIBRARY_PATH`.

## Quick start

For a full end-to-end walkthrough (deploy the app, create a role, create the function, and invoke it),
see the usage guide:

https://github.com/mparkachov/lambda-shell-runtime/blob/main/docs/USAGE.md#quick-start-create-a-lambda-function

## Handler contract

Your handler is an executable file that:

- reads the event JSON from STDIN
- writes the response JSON to STDOUT
- writes logs to STDERR

The runtime does not transform the event or response payload.

## Versioning

The SAR `SemanticVersion` matches the bundled AWS CLI v2 version.
