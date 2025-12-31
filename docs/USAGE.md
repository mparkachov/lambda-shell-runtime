# Usage

This runtime implements the AWS Lambda Custom Runtime API for `provided.al2023` and is distributed as a Lambda Layer. It uses the system-provided `/bin/sh` and follows the documented runtime contract.

AWS documentation:
- https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html
- https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html

## Install from SAR (recommended)

Deploy the Serverless Application Repository (SAR) application in your account. The deployment creates a Lambda Layer version and returns its ARN as a stack output.
The SAR application semantic version tracks the bundled AWS CLI v2 version.

If you deployed with the console, open the CloudFormation stack outputs and copy `LayerVersionArn`.

If you prefer the CLI, set `STACK_NAME` to the deployed stack name and run:

```sh
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs'
```

Attach the `LayerVersionArn` output to your Lambda function.

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

## Create a function

- Runtime: `provided.al2023`
- Architecture: `arm64`
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

## Example handler

```sh
#!/bin/sh
set -eu

payload=$(cat)

printf '%s' "$payload" | jq -c '{ok:true, input:.}'
```

Package the handler into a zip and set the function Handler to `handler`.
