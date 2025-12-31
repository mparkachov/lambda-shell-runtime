# lambda-shell-runtime

`lambda-shell-runtime` is a minimal AWS Lambda custom runtime implemented in POSIX shell for `provided.al2023` (arm64). It is packaged as a Lambda Layer and includes AWS CLI v2 (Linux aarch64) and jq. The primary distribution target is the AWS Serverless Application Repository (SAR), so teams can install the application and receive a layer version.

## Design goals

- Follow the AWS Lambda Custom Runtime API
- Use only AWS-defined environment variables and contracts
- Keep the runtime explicit, minimal, and easy to audit

## Repository layout

- `runtime/bootstrap`: runtime entrypoint
- `layer/opt`: staged layer contents
- `scripts/`: build, package, and smoke test scripts
- `docker/Dockerfile`: build image for Amazon Linux 2023 arm64
- `template.yaml`: SAR application template (SAM)
- `examples/hello/`: minimal handler example
- `docs/`: usage and development notes

## Build the layer

```sh
./scripts/build_layer.sh
```

## Package the layer

```sh
./scripts/package_layer.sh
```

The output is `dist/lambda-shell-runtime-arm64.zip` with a top-level `opt/` directory.
`./scripts/package_layer.sh` also writes a versioned artifact named `dist/lambda-shell-runtime-arm64-<aws-cli-version>.zip` and updates `template.yaml` `SemanticVersion` to match the bundled AWS CLI v2 version.

## Smoke test

```sh
./scripts/smoke_test.sh
```

## Usage

- Runtime: `provided.al2023`
- Architecture: `arm64`
- Handler: executable name of your handler file

See `docs/USAGE.md` for full details and `examples/hello/README.md` for a deployable example.

## Publish to SAR

```sh
./scripts/build_layer.sh
./scripts/package_layer.sh
```

Set `S3_BUCKET` to an S3 bucket in your account and run:

```sh
sam package \
  --template-file template.yaml \
  --s3-bucket "$S3_BUCKET" \
  --output-template-file packaged.yaml

sam publish --template packaged.yaml
```

Update the `SemanticVersion` in `template.yaml` for each release.
