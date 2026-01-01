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

This produces `dist/lambda-shell-runtime-<arch>.zip` with a top-level `opt/` directory and a versioned artifact named `dist/lambda-shell-runtime-<arch>-<aws-cli-version>.zip`. The script also updates `template.yaml` `SemanticVersion` to match the bundled AWS CLI v2 version.

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

## Release

1. Ensure `ARCH=all ./scripts/package_layer.sh` has been run so the versioned artifacts are created.
2. Tag the release in Git. Use the AWS CLI version as the tag to match `template.yaml` `SemanticVersion`.

## Publish to SAR

1. Build and package the layer (this updates `template.yaml` `SemanticVersion` to match the bundled AWS CLI version):

```sh
./scripts/build_layer.sh
./scripts/package_layer.sh
```

2. Set `S3_BUCKET` to an S3 bucket in your account and package the template:

```sh
sam package \
  --template-file template.yaml \
  --s3-bucket "$S3_BUCKET" \
  --output-template-file packaged.yaml
```

3. Publish to SAR:

```sh
sam publish --template packaged.yaml
```

## GitHub Actions AWS connectivity

The manual workflow `.github/workflows/aws-connectivity.yml` validates GitHub Actions access to AWS. It uses OIDC and requires a role with appropriate permissions.

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
