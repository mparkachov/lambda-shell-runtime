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

This produces `dist/lambda-shell-runtime-<arch>.zip` with `bootstrap`, `bin/`, `aws-cli/`, and `lib/` at the zip
root, plus a versioned artifact named `dist/lambda-shell-runtime-<arch>-<aws-cli-version>.zip`. The script also
updates the `SemanticVersion` in `template.yaml`, `template-arm64.yaml`, and `template-amd64.yaml` to match the
bundled AWS CLI v2 version.

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
shellcheck runtime/bootstrap scripts/*.sh runtime-tutorial/function.sh
```

## AWS configuration

Project defaults live in `scripts/aws_env.sh`. It pins the AWS region to `us-east-1` and sets default names
for the S3 bucket, setup stack, SAR applications, and the S3 prefix used for SAR artifacts. These defaults
are used by `make aws-check`, `make aws-setup`, and `make release`.
`./scripts/package_layer.sh` keeps the SAR application names in the templates aligned with these defaults; rerun it after changing the app name settings.
Set `ENV=dev` to switch to the dev defaults (the `*_DEV` values).

Override any of the defaults by exporting:
- `ENV` (`prod` or `dev`, default: `prod`)
- `LSR_AWS_REGION`
- `LSR_BUCKET_NAME` (prod bucket)
- `LSR_BUCKET_NAME_DEV` (dev bucket)
- `LSR_STACK_NAME` (prod setup stack)
- `LSR_STACK_NAME_DEV` (dev setup stack)
- `LSR_SAR_APP_BASE` (prod SAR app base)
- `LSR_SAR_APP_BASE_DEV` (dev SAR app base)
- `LSR_SAR_VERSION_DEV` (dev SAR version, default `0.0.0`)
- `LSR_SAR_APP_NAME_ARM64` / `LSR_SAR_APP_NAME_AMD64` (override derived names)
- `LSR_LAYER_NAME_ARM64` / `LSR_LAYER_NAME_AMD64` (override layer names)
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
- uploads SAR artifacts under `S3_PREFIX/<version>/<arch>`

To check whether a release is needed without building anything, run:

```sh
make check-release
```

This checks the latest AWS CLI v2 version (via the AWS CLI GitHub tags) against existing Git tags.

To delete the current GitHub release and tag (so you can re-run `make release`), run:

```sh
make delete-release
```

Note: SAR application versions are immutable. Deleting a GitHub release/tag does not remove the SAR
version that was already published.

## Dev SAR publishing (arm64/amd64)

For fast iteration without touching the stable SAR apps, use the dev-only apps:

```sh
ENV=dev make publish-sar ARCH=arm64
```

```sh
ENV=dev make publish-sar ARCH=amd64
```

Aliases:
- `make publish-dev-arm64`
- `make publish-dev-amd64`

Defaults:
- SAR app base: `lambda-shell-runtime-dev` (override with `LSR_SAR_APP_BASE_DEV`)
- SAR app name: `<base>-arm64` / `<base>-amd64` (override with `LSR_SAR_APP_NAME_ARM64` / `LSR_SAR_APP_NAME_AMD64`)
- Layer name: defaults to the SAR app name (override with `LSR_LAYER_NAME_ARM64` / `LSR_LAYER_NAME_AMD64`)
- S3 bucket: `lambda-shell-runtime-dev` (override with `LSR_BUCKET_NAME_DEV`)
- Dev version: `0.0.0` (override with `LSR_SAR_VERSION_DEV` or `LSR_SAR_VERSION`)
- S3 prefix: `LSR_S3_PREFIX` / `S3_PREFIX` (dev publishes under `S3_PREFIX/0.0.0/<arch>` by default)

This publishes only the selected dev SAR application and skips the wrapper/stable apps.

To delete the dev SAR apps (so you can republish the same version), run:

```sh
ENV=dev make delete-sar ARCH=arm64
ENV=dev make delete-sar ARCH=amd64
```

Aliases:
- `make delete-release-arm64`
- `make delete-release-amd64`
- `make delete-dev-arm64`
- `make delete-dev-amd64`

To deploy the dev SAR apps into your account (CloudFormation stacks), run:

```sh
ENV=dev make deploy-sar ARCH=arm64
ENV=dev make deploy-sar ARCH=amd64
```

Aliases:
- `make deploy-dev-arm64`
- `make deploy-dev-amd64`

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

If you use `make release` (locally or via the workflow), SAR publishing is handled there. For manual publishing, prefer the make targets (they call `sam package`/`sam publish` and use `S3_PREFIX/<version>/<arch>`):

```sh
make publish-arm64
make publish-amd64
```

These expect `dist/lambda-shell-runtime-<arch>.zip` to exist (run `make package-<arch>` first).

To publish all three SAR applications (arm64, amd64, wrapper) in order:

```sh
make publish-all
```

`publish-all` requires the wrapper ApplicationIds to be populated in `template.yaml`.

To publish the wrapper application after updating the ApplicationIds, run:

```sh
make publish-wrapper
```

If you want the raw SAM commands instead:

1. Build and package the layer (this updates the templates' `SemanticVersion` to match the bundled AWS CLI version):

```sh
./scripts/build_layer.sh
./scripts/package_layer.sh
```

2. Set `S3_BUCKET` to an S3 bucket in your account and package each template (use a versioned prefix like `sar/<version>/<arch>` to group artifacts):

```sh
sam package \
  --template-file template-arm64.yaml \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "sar/<version>/arm64" \
  --output-template-file packaged-arm64.yaml

sam package \
  --template-file template-amd64.yaml \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix "sar/<version>/amd64" \
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
  --s3-prefix "sar/<version>/wrapper" \
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

To create only the dev bucket and policy (no SAR publishing), use:

```sh
ENV=dev SKIP_SAR_PUBLISH=1 make aws-setup
```

Alias:
- `make aws-setup-dev`

Options:
- `BUCKET_NAME` (default: `lambda-shell-runtime`)
- `STACK_NAME` (default: `lambda-shell-runtime-setup`)
- `SAR_APP_NAME_BASE` (default: `lambda-shell-runtime`)
- `SAR_APP_NAME_ARM64` (default: `lambda-shell-runtime-arm64`)
- `SAR_APP_NAME_AMD64` (default: `lambda-shell-runtime-amd64`)
- `S3_BUCKET` (optional; defaults to `BUCKET_NAME` for packaging)
- `S3_PREFIX` (optional; defaults to `sar`)

Dev options:
- `LSR_BUCKET_NAME_DEV` (default: `lambda-shell-runtime-dev`)
- `LSR_STACK_NAME_DEV` (default: `lambda-shell-runtime-dev-setup`)
- `LSR_SAR_APP_BASE_DEV` (default: `lambda-shell-runtime-dev`)
- `LSR_SAR_VERSION_DEV` (default: `0.0.0`)

Behavior:
- If the bucket already exists and is accessible, the stack skips bucket creation to avoid failure.
- If the stack created the bucket, deleting the stack will fail when the bucket is not empty.
- If any SAR application is missing, `make aws-setup` runs `make package-all` and publishes the first version (arm64, amd64, and the wrapper).
- The bucket policy grants SAR read access only to the configured `S3_PREFIX`.
- The lifecycle rule transitions objects under `S3_PREFIX/` to STANDARD_IA after 30 days and GLACIER_IR after 90 days.

## GitHub Actions AWS check

The manual workflow `.github/workflows/aws-check.yml` validates GitHub Actions access to AWS for both dev and prod. It runs `make aws-check`, which you can also execute locally. Set `ENV` and `S3_BUCKET` (or `S3_BUCKET_DEV`) to target a specific environment, and use `AWS_CHECK_ARCHES` to limit checks to specific architectures.

## CI IAM policy (restricted)

To remove `AdministratorAccess` from the GitHub Actions role, attach a least-privilege policy that covers:
- `make publish-sar` and `make deploy-sar` (dev CI)
- `make release` (prod release)
- `make aws-check` (permission validation)

Create an IAM policy in the AWS console (IAM → Policies → Create policy → JSON) using the template below.
Replace `<ACCOUNT_ID>`, `<REGION>`, `<S3_BUCKET_PROD>`, `<S3_BUCKET_DEV>`, and `<S3_PREFIX>` to match your setup.
`serverlessrepo:CreateApplication` does not support resource-level scoping, so it is limited by region instead.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StsIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Sid": "CloudFormationDeploy",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateChangeSet",
        "cloudformation:ExecuteChangeSet",
        "cloudformation:DeleteChangeSet",
        "cloudformation:DescribeChangeSet",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResources",
        "cloudformation:GetTemplate",
        "cloudformation:GetTemplateSummary",
        "cloudformation:ListStacks",
        "cloudformation:ValidateTemplate",
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LambdaLayers",
      "Effect": "Allow",
      "Action": [
        "lambda:PublishLayerVersion",
        "lambda:DeleteLayerVersion",
        "lambda:GetLayerVersion"
      ],
      "Resource": "arn:aws:lambda:<REGION>:<ACCOUNT_ID>:layer:lambda-shell-runtime*"
    },
    {
      "Sid": "LambdaLayerRead",
      "Effect": "Allow",
      "Action": "lambda:ListLayers",
      "Resource": "*"
    },
    {
      "Sid": "ServerlessRepoList",
      "Effect": "Allow",
      "Action": "serverlessrepo:ListApplications",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "<REGION>"
        }
      }
    },
    {
      "Sid": "ServerlessRepoCreateApplication",
      "Effect": "Allow",
      "Action": "serverlessrepo:CreateApplication",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "<REGION>"
        }
      }
    },
    {
      "Sid": "ServerlessRepoManageApps",
      "Effect": "Allow",
      "Action": [
        "serverlessrepo:CreateApplicationVersion",
        "serverlessrepo:CreateCloudFormationTemplate",
        "serverlessrepo:GetCloudFormationTemplate",
        "serverlessrepo:DeleteApplication"
      ],
      "Resource": "arn:aws:serverlessrepo:<REGION>:<ACCOUNT_ID>:applications/lambda-shell-runtime*"
    },
    {
      "Sid": "S3PackagingBucketsList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [
        "arn:aws:s3:::<S3_BUCKET_PROD>",
        "arn:aws:s3:::<S3_BUCKET_DEV>"
      ]
    },
    {
      "Sid": "S3PackagingBucketsObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::<S3_BUCKET_PROD>/<S3_PREFIX>/*",
        "arn:aws:s3:::<S3_BUCKET_DEV>/<S3_PREFIX>/*"
      ]
    },
    {
      "Sid": "SarChangesetRead",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::awsserverlessrepo-changesets-*/*"
    }
  ]
}
```

After creating the policy:
1. IAM → Roles → `GitHubActionsLambdaShellRuntime` → Attach policies → attach the new policy.
2. Remove `AdministratorAccess` from the role.
3. If you use permission boundaries or SCPs, ensure they do not deny `s3:GetObject` for `awsserverlessrepo-changesets-*`.
4. In GitHub repo variables, set `AWS_REGION`, `S3_BUCKET`, and (optionally) `S3_BUCKET_DEV`.

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
