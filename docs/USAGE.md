# Usage

This runtime implements the AWS Lambda Custom Runtime API for `provided.al2023` and is distributed as a Lambda Layer for arm64 and x86_64. It uses the system-provided `/bin/sh` and follows the documented runtime contract.

AWS documentation:
- https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html
- https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html

## Install from SAR (recommended)

Deploy the Serverless Application Repository (SAR) application in your account. The deployment creates two Lambda Layer versions (arm64 and x86_64) and returns their ARNs as stack outputs.
The SAR application semantic version tracks the bundled AWS CLI v2 version.

If you deployed with the console, open the CloudFormation stack outputs and copy `LayerVersionArnArm64` or `LayerVersionArnAmd64` depending on your function architecture.

If you prefer the CLI, set `STACK_NAME` to the deployed stack name and run:

```sh
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs'
```

Attach the matching output to your Lambda function.

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

## Create a function

- Runtime: `provided.al2023`
- Architecture: `arm64` or `x86_64`
- Handler: the executable name of your handler file

The Handler value is provided to the runtime via `_HANDLER`.

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

## Example handler

```sh
#!/bin/sh
set -eu

payload=$(cat)

printf '%s' "$payload" | jq -c '{ok:true, input:.}'
```

Package the handler into a zip and set the function Handler to `handler`.
