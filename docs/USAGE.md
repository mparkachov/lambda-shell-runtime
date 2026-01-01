# Usage

This runtime implements the AWS Lambda Custom Runtime API for `provided.al2023` and is distributed as a Lambda Layer for arm64 and x86_64. It uses the system-provided `/bin/sh` and follows the documented runtime contract.

AWS documentation:
- https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html
- https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html

## Install from SAR (recommended)

Deploy the Serverless Application Repository (SAR) application that fits your needs:

- `lambda-shell-runtime` (wrapper): exposes both architectures and outputs `LayerVersionArnArm64` and `LayerVersionArnAmd64`
- `lambda-shell-runtime-arm64` or `lambda-shell-runtime-amd64`: single-architecture apps that output `LayerVersionArn`

The SAR application semantic version tracks the bundled AWS CLI v2 version.

If you deployed with the console, open the CloudFormation stack outputs and copy the appropriate output key (`LayerVersionArn` for arch apps, or `LayerVersionArnArm64`/`LayerVersionArnAmd64` for the wrapper).

If you prefer the CLI, set `STACK_NAME` to the deployed stack name and run:

```sh
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs'
```

Attach the matching output to your Lambda function.

## Quick start (create a Lambda function)

1. Deploy the SAR application (wrapper or per-arch) and export the layer ARN.

Wrapper (arm64 output example):

```sh
STACK_NAME=lambda-shell-runtime
LAYER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerVersionArnArm64'].OutputValue" \
  --output text)
```

Per-arch application:

```sh
STACK_NAME=lambda-shell-runtime-arm64
LAYER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerVersionArn'].OutputValue" \
  --output text)
```

For x86_64, use `LayerVersionArnAmd64` (wrapper) or deploy the amd64 application.

2. Create a simple handler and package it:

```sh
cat > handler <<'SH'
#!/bin/sh
set -eu

payload=$(cat)
printf '%s' "$payload" | jq -c '{ok:true, input:.}'
SH

chmod +x handler
zip -r function.zip handler
```

3. Create an execution role (if you do not already have one):

```sh
aws iam create-role \
  --role-name lambda-shell-runtime-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

aws iam attach-role-policy \
  --role-name lambda-shell-runtime-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

ROLE_ARN=$(aws iam get-role \
  --role-name lambda-shell-runtime-role \
  --query "Role.Arn" \
  --output text)
```

4. Create the function with the layer:

```sh
aws lambda create-function \
  --function-name hello-shell-runtime \
  --runtime provided.al2023 \
  --handler handler \
  --architectures arm64 \
  --role "$ROLE_ARN" \
  --zip-file fileb://function.zip \
  --layers "$LAYER_ARN"
```

For x86_64, set `--architectures x86_64` and use the amd64 layer ARN.

5. Invoke it:

```sh
aws lambda invoke \
  --function-name hello-shell-runtime \
  --payload '{"message":"hello"}' \
  response.json

cat response.json
```

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
