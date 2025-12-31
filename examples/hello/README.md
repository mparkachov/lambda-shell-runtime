# Hello Example

This example shows a minimal handler that reads JSON from STDIN and writes JSON to STDOUT. It also calls `aws --version` and `jq` to prove the layer tools are on `PATH`.

## Build the layer

```sh
./scripts/build_layer.sh
./scripts/package_layer.sh
```

The layer zip will be created at `dist/lambda-shell-runtime-arm64.zip`.

## Package the function

```sh
cd examples/hello
zip -r ../../dist/hello-function.zip handler
```

## Install the layer from SAR

Deploy the SAR application in your account. After deployment, read the `LayerVersionArn` output from the CloudFormation stack and export it:

```sh
STACK_NAME=lambda-shell-runtime
LAYER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LayerVersionArn'].OutputValue" \
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

## Invoke

```sh
aws lambda invoke \
  --function-name hello-shell-runtime \
  --payload '{"message":"hello"}' \
  dist/response.json

cat dist/response.json
```

If the function role is permitted, the handler can also call AWS APIs using the bundled CLI.
