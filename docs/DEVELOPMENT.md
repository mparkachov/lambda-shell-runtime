# Development

## Build the layer

```sh
./scripts/build_layer.sh
```

This builds an Amazon Linux 2023 container for the host architecture, installs AWS CLI v2 and jq, and stages the layer contents under `layer/opt`. Non-host builds are staged under `layer/<arch>/opt`.

To build a specific architecture or both:

```sh
ARCH=arm64 ./scripts/build_layer.sh
ARCH=amd64 ./scripts/build_layer.sh
ARCH=all ./scripts/build_layer.sh
```

Cross-architecture builds require Docker buildx with QEMU/binfmt configured so the non-native image can be built locally.
The Docker build uses `curl-minimal` to keep dependencies small. If you need full curl features, switch the Dockerfile to `curl`.

## Package the layer

```sh
./scripts/package_layer.sh
```

This produces `dist/lambda-shell-runtime-<arch>.zip` with a top-level `opt/` directory and a versioned artifact named `dist/lambda-shell-runtime-<arch>-<aws-cli-version>.zip`. The script also updates the `SemanticVersion` in `template.yaml`, `template-arm64.yaml`, and `template-amd64.yaml` to match the bundled AWS CLI v2 version.

To package both architectures:

```sh
ARCH=all ./scripts/package_layer.sh
```

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

## AWS configuration

Project defaults live in `scripts/aws_env.sh`. It pins the AWS region to `us-east-1` and sets default names
for the S3 bucket, setup stack, SAR applications, and the S3 prefix used for SAR artifacts. These defaults
are used by `make aws-check`, `make aws-setup`, and `make release`.
`./scripts/package_layer.sh` keeps the SAR application names in the templates aligned with these defaults; rerun it after changing the app name settings.

Override any of the defaults by exporting:
- `LSR_AWS_REGION`
- `LSR_BUCKET_NAME`
- `LSR_STACK_NAME`
- `LSR_SAR_APP_BASE`
- `LSR_SAR_APP_NAME_ARM64`
- `LSR_SAR_APP_NAME_AMD64`
- `LSR_S3_PREFIX`
- `S3_BUCKET` (optional; overrides the bucket used for packaging)

## Release

Use the `make release` target locally or the GitHub Actions workflow `.github/workflows/release.yml` (it calls the same target).

```sh
S3_BUCKET=your-bucket make release
```

It:
- builds and packages both architectures
- updates the templates' `SemanticVersion` to the bundled AWS CLI v2 version
- checks for an existing Git tag
- if missing, commits the templates, tags the repo, and creates a GitHub release with versioned artifacts
- publishes the SAR applications with `sam package`/`sam publish`
- updates `template.yaml` with the arm64/amd64 ApplicationIds and publishes the wrapper application
- uploads SAR artifacts under `S3_PREFIX/<version>`

To check whether a release is needed without building anything, run:

```sh
make check-release
```

This checks the latest AWS CLI v2 version (via the AWS CLI GitHub tags) against existing Git tags.

Local requirements:
- Docker with buildx/QEMU (for cross-arch)
- `sam`, `gh`, and `aws` CLIs installed (`gh auth login` or `GH_TOKEN` required)
- `S3_BUCKET` set in the environment (or via `make release S3_BUCKET=...`)
- `S3_PREFIX` (optional; defaults to `sar`, used as the base prefix for SAR artifacts)

Repo setup required for the workflow:
- `AWS_ROLE_ARN` secret for OIDC
- `AWS_REGION` and `S3_BUCKET` repository variables
- allow GitHub Actions to push to `main` if branch protection is enabled

To run in GitHub: Actions -> Release -> Run workflow.

Manual fallback:
1. Ensure `ARCH=all ./scripts/package_layer.sh` has been run so the versioned artifacts are created.
2. Tag the release in Git. Use the AWS CLI version as the tag to match the templates' `SemanticVersion`.

## Publish to SAR

If you use `make release` (locally or via the workflow), SAR publishing is handled there. For manual publishing:

1. Build and package the layer (this updates the templates' `SemanticVersion` to match the bundled AWS CLI version):

```sh
./scripts/build_layer.sh
./scripts/package_layer.sh
```

2. Set `S3_BUCKET` to an S3 bucket in your account and package each template (use a versioned prefix like `sar/<version>` to group artifacts):

```sh
sam package \
  --template-file template-arm64.yaml \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "sar/<version>" \
  --output-template-file packaged-arm64.yaml

sam package \
  --template-file template-amd64.yaml \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "sar/<version>" \
  --output-template-file packaged-amd64.yaml
```

3. Publish to SAR:

```sh
sam publish --template packaged-arm64.yaml
sam publish --template packaged-amd64.yaml
```

4. Update the wrapper template with the architecture application IDs and publish it:

```sh
ARM64_APP_ID=$(aws serverlessrepo list-applications \
  --query "Applications[?Name=='lambda-shell-runtime-arm64'].ApplicationId | [0]" \
  --output text)
AMD64_APP_ID=$(aws serverlessrepo list-applications \
  --query "Applications[?Name=='lambda-shell-runtime-amd64'].ApplicationId | [0]" \
  --output text)

sed -i.bak \
  -e "s|__APP_ID_ARM64__|$ARM64_APP_ID|g" \
  -e "s|__APP_ID_AMD64__|$AMD64_APP_ID|g" \
  template.yaml

sam package \
  --template-file template.yaml \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "sar" \
  --output-template-file packaged.yaml

sam publish --template packaged.yaml
```

## AWS setup

Use `make aws-setup` to bootstrap the S3 bucket and create the SAR applications if they do not exist.
CloudFormation cannot create SAR applications directly, so the target creates the bucket via `aws-setup.yaml`
and then runs `sam publish` to create the first SAR version if needed.

```sh
make aws-setup
```

Options:
- `BUCKET_NAME` (default: `lambda-shell-runtime`)
- `STACK_NAME` (default: `lambda-shell-runtime-setup`)
- `SAR_APP_NAME_BASE` (default: `lambda-shell-runtime`)
- `SAR_APP_NAME_ARM64` (default: `lambda-shell-runtime-arm64`)
- `SAR_APP_NAME_AMD64` (default: `lambda-shell-runtime-amd64`)
- `S3_BUCKET` (optional; defaults to `BUCKET_NAME` for packaging)
- `S3_PREFIX` (optional; defaults to `sar`)

Behavior:
- If the bucket already exists and is accessible, the stack skips bucket creation to avoid failure.
- If the stack created the bucket, deleting the stack will fail when the bucket is not empty.
- If any SAR application is missing, `make aws-setup` runs `make package-all` and publishes the first version (arm64, amd64, and the wrapper).
- The bucket policy grants SAR read access only to the configured `S3_PREFIX`.
- The lifecycle rule transitions objects under `S3_PREFIX/` to STANDARD_IA after 30 days and GLACIER_IR after 90 days.

## GitHub Actions AWS check

The manual workflow `.github/workflows/aws-check.yml` validates GitHub Actions access to AWS. It runs `make aws-check`, which you can also execute locally. Set `S3_BUCKET` so the check can validate bucket access.

### One-time AWS setup (admin)

1. Create the GitHub OIDC provider in AWS (if not already present):
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
2. Create an IAM role for GitHub Actions with:
   - Trust policy allowing `sts:AssumeRoleWithWebIdentity` from your repo and branch.
   - For initial setup, attach `AdministratorAccess`. You can reduce permissions later.

Example trust policy (replace account ID, org, repo, and branch):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:ORG/REPO:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

### GitHub repo setup

1. Add a repository secret `AWS_ROLE_ARN` with the IAM role ARN.
2. Add a repository variable `AWS_REGION` (for example, `us-east-1`).

### Run the workflow

In GitHub, open the Actions tab, select **AWS Connectivity**, and click **Run workflow**. The job runs `aws sts get-caller-identity` and lists a few Lambda layers to confirm connectivity.
