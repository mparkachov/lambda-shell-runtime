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
- Handler: file name of your handler script in the function package (for example, `handler` or `handler.sh`)

Lambda automatically includes `/opt/bin` and `/opt/lib` from layers in `PATH` and `LD_LIBRARY_PATH`.

## Quick start (create a Lambda function)

If you prefer to work entirely in the AWS Lambda console, skip to **Lambda console notes** below.

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

## Lambda console notes (important)

If you create a function in the AWS Lambda console, it may show sample files like `bootstrap.sh` and `hello.sh`. Those are for a different custom-runtime tutorial and are not used with this layer.
This runtime already provides the `bootstrap` in the layer. Your function package should only include a handler script that reads STDIN and writes STDOUT.

Console checklist:
- Runtime: `provided.al2023`
- Architecture: `arm64` or `x86_64` (must match the layer you attached)
- Handler: the filename you created in the editor (for example, `handler`)
- Layers: add the layer ARN from the SAR stack output

Example handler file (save as `handler`, no extension, in the console editor):

```sh
#!/bin/sh
set -eu

payload=$(cat)
printf '%s' "$payload" | jq -c '{ok:true, input:.}'
```

The runtime will execute this file with `/bin/sh` even if the console does not mark it as executable.

## Handler contract

Your handler is an executable file that:

- reads the event JSON from STDIN
- writes the response JSON to STDOUT
- writes logs to STDERR

The runtime does not transform the event or response payload.

## Versioning

The SAR `SemanticVersion` matches the bundled AWS CLI v2 version.
