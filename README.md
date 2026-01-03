# lambda-shell-runtime

![CI](https://github.com/mparkachov/lambda-shell-runtime/actions/workflows/ci.yml/badge.svg)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

`lambda-shell-runtime` is a minimal AWS Lambda custom runtime implemented in POSIX shell for `provided.al2023` (arm64, x86_64). It is packaged as a Lambda Layer and includes AWS CLI v2 and jq. The primary distribution target is the AWS Serverless Application Repository (SAR), which publishes a thin wrapper app (`lambda-shell-runtime`) that references the per-architecture apps and exposes both layer ARNs.

## Design goals

- Follow the AWS Lambda Custom Runtime API
- Use only AWS-defined environment variables and contracts
- Keep the runtime explicit, minimal, and easy to audit

## Repository layout

- `runtime/bootstrap`: runtime entrypoint
- `layer/opt`: staged layer contents for the host architecture
- `scripts/`: build, package, and smoke test scripts
- `docker/Dockerfile`: build image for Amazon Linux 2023 (arm64, x86_64)
- `template.yaml`: SAR wrapper application (arm64 + amd64)
- `template-arm64.yaml`, `template-amd64.yaml`: SAR application templates (SAM)
- `SAR_README.md`: SAR application README shown to end users
- `runtime-tutorial/`: minimal handler example
- `docs/`: usage and development notes

## Build the layer

```sh
./scripts/build_layer.sh
```

The build image uses `curl-minimal` to keep dependencies small. If the AWS CLI download ever needs full curl features, switch the Dockerfile to `curl`.

## Package the layer

```sh
./scripts/package_layer.sh
```

The outputs are `dist/lambda-shell-runtime-arm64.zip` and `dist/lambda-shell-runtime-amd64.zip`, each with a top-level `opt/` directory.
`./scripts/package_layer.sh` also writes versioned artifacts named `dist/lambda-shell-runtime-<arch>-<aws-cli-version>.zip` and updates the `SemanticVersion` in both templates to match the bundled AWS CLI v2 version.

## Smoke test

```sh
./scripts/smoke_test.sh
```

## Usage

- Runtime: `provided.al2023`
- Architecture: `arm64` or `x86_64`
- Handler: `function.handler` (script stored as `function.sh` in your function package)

See [SAR_README.md](SAR_README.md) for end-user SAR installation and quick start, [docs/USAGE.md](docs/USAGE.md) for manual publishing and the runtime contract, [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for build and release workflow, and [runtime-tutorial/README.md](runtime-tutorial/README.md) for a deployable example.

## Publish to SAR

```sh
make build-all
make package-all
```

Set `S3_BUCKET` to an S3 bucket in your account and run:

```sh
sam package \
  --template-file template-arm64.yaml \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "sar" \
  --output-template-file packaged-arm64.yaml

sam publish --template packaged-arm64.yaml

sam package \
  --template-file template-amd64.yaml \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "sar" \
  --output-template-file packaged-amd64.yaml

sam publish --template packaged-amd64.yaml
```

Each SAR application publishes a single layer output (`LayerVersionArn`) for its architecture.
`./scripts/package_layer.sh` updates the templates' `SemanticVersion` to match the bundled AWS CLI v2 version; review and commit the change for each release.
The wrapper application in `template.yaml` references both architecture-specific apps; `make release` and `make aws-setup` publish it after the per-arch apps.
