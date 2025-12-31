# Development

## Build the layer

```sh
./scripts/build_layer.sh
```

This builds an Amazon Linux 2023 (arm64) container, installs AWS CLI v2 and jq, and stages the layer contents under `layer/opt`.

## Package the layer

```sh
./scripts/package_layer.sh
```

This produces `dist/lambda-shell-runtime-arm64.zip` with a top-level `opt/` directory and a versioned artifact named `dist/lambda-shell-runtime-arm64-<aws-cli-version>.zip`. The script also updates `template.yaml` `SemanticVersion` to match the bundled AWS CLI v2 version.

## Smoke test

```sh
./scripts/smoke_test.sh
```

The smoke test:
- checks `aws --version` and `jq --version`
- runs the `bootstrap` against a local mock Runtime API and the example handler

## Shellcheck

All shell scripts are written for POSIX `sh` and should pass `shellcheck`.

```sh
shellcheck runtime/bootstrap scripts/*.sh examples/hello/handler
```

## Release

1. Ensure `./scripts/package_layer.sh` has been run so the versioned artifact is created.
2. Tag the release in Git. Use the AWS CLI version as the tag to match `template.yaml` `SemanticVersion`.

## Publish to SAR

1. Update `SemanticVersion` in `template.yaml`.
2. Build and package the layer:

```sh
./scripts/build_layer.sh
./scripts/package_layer.sh
```

3. Set `S3_BUCKET` to an S3 bucket in your account and package the template:

```sh
sam package \
  --template-file template.yaml \
  --s3-bucket "$S3_BUCKET" \
  --output-template-file packaged.yaml
```

4. Publish to SAR:

```sh
sam publish --template packaged.yaml
```
