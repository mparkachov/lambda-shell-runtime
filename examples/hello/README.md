# Hello Example

This example shows a minimal handler that reads JSON from STDIN and writes JSON to STDOUT. It also calls `aws --version` and `jq` to prove the layer tools are on `PATH`.

## Build the layer

```sh
./scripts/build_layer.sh
./scripts/package_layer.sh
```

The layer zips will be created at `dist/lambda-shell-runtime-arm64.zip` and `dist/lambda-shell-runtime-amd64.zip`.

## Package the function

```sh
cd examples/hello
zip -r ../../dist/hello-function.zip handler
```

## Install the layer from SAR

Deploy the SAR application for your architecture (or the wrapper application) in your account. After deployment, read the relevant output and export it:

```sh
STACK_NAME=lambda-shell-runtime-arm64
LAYER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerVersionArn'].OutputValue" \
  --output text)
```

For x86_64, use the amd64 application stack:

```sh
STACK_NAME=lambda-shell-runtime-amd64
LAYER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerVersionArn'].OutputValue" \
  --output text)
```

If you deployed the wrapper application (`lambda-shell-runtime`), use the architecture-specific outputs:

```sh
STACK_NAME=lambda-shell-runtime
LAYER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerVersionArnArm64'].OutputValue" \
  --output text)
```

## Manual publish (without SAR)

```sh
aws lambda publish-layer-version \
  --layer-name lambda-shell-runtime \
  --zip-file fileb://dist/lambda-shell-runtime-arm64.zip \
  --compatible-runtimes provided.al2023 \
  --compatible-architectures arm64
```

Record the returned LayerVersionArn for the next step.

Set `LAYER_ARN` to the returned LayerVersionArn if you used the manual publish path.

For x86_64, publish the amd64 artifact instead:

```sh
aws lambda publish-layer-version \
  --layer-name lambda-shell-runtime \
  --zip-file fileb://dist/lambda-shell-runtime-amd64.zip \
  --compatible-runtimes provided.al2023 \
  --compatible-architectures x86_64
```

## Create the function

Set `ROLE_ARN` to an existing Lambda execution role ARN.

```sh
aws lambda create-function \
  --function-name hello-shell-runtime \
  --runtime provided.al2023 \
  --handler handler \
  --architectures arm64 \
  --role "$ROLE_ARN" \
  --zip-file fileb://dist/hello-function.zip \
  --layers "$LAYER_ARN"
```

`--handler handler` maps to the `_HANDLER` environment variable used by the runtime.
For x86_64, set `--architectures x86_64` and use the amd64 layer ARN.

## Invoke

```sh
aws lambda invoke \
  --function-name hello-shell-runtime \
  --payload '{"message":"hello"}' \
  dist/response.json

cat dist/response.json
```

If the function role is permitted, the handler can also call AWS APIs using the bundled CLI.
