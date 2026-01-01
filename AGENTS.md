# lambda-shell-runtime

## Purpose
`lambda-shell-runtime` provides a minimal AWS Lambda **custom runtime** implemented using the execution environment’s standard POSIX shell, following the official AWS Lambda custom runtime specification as closely as possible.

The runtime is packaged as a Lambda Layer and is intended to be consumed directly or via the AWS Serverless Application Repository (SAR).

## Scope
- Architecture: arm64, amd64
- Runtime type: AWS Lambda custom runtime (`provided.al2023`)
- Shell: system-provided `/bin/sh`
- Distribution: Lambda Layer
- Tools included:
  - AWS CLI v2 (Linux aarch64, x86_64)
  - jq

## Design Principles
- Adhere strictly to AWS Lambda custom runtime documentation
- Use only AWS-defined environment variables and contracts
- Avoid abstractions, frameworks, or opinionated conventions
- Prefer predictable, explicit, and minimal behavior
- Make the runtime transparent and easy to audit

## Repository Structure

- runtime/bootstrap
- layer/opt
- scripts/
  - build_layer.sh
  - package_layer.sh
  - smoke_test.sh
- docker/Dockerfile
- examples/hello/
  - handler
  - README.md
- docs/
  - USAGE.md
  - DEVELOPMENT.md
- dist/
- Makefile
- README.md
- LICENSE
- .gitignore

....

## Lambda Layer Contents
The layer zip must contain a top-level `opt/` directory, mounted by Lambda at `/opt`.

Expected contents:
- `/opt/bootstrap`
- `/opt/bin/aws`
- `/opt/bin/jq`
- `/opt/aws-cli/`

`/opt/bin` is added to `PATH` by the runtime.

## Runtime Behavior
- `bootstrap` is the runtime entrypoint.
- The runtime implements the standard AWS Lambda Runtime API loop:
  1. Initialize the runtime.
  2. Poll the Runtime API for the next invocation.
  3. Pass the event payload to the handler via STDIN.
  4. Read handler STDOUT as the invocation response.
  5. Send the response back to the Runtime API.

The runtime does not transform or reinterpret event or response payloads.

## Handler Contract
- The handler is an executable file included in the Lambda function package.
- The handler name is provided via the `_HANDLER` environment variable.
- Example: `_HANDLER=handler`
- The handler:
- Reads the event JSON from STDIN
- Writes the response JSON to STDOUT
- Writes logs to STDERR

No additional response validation is performed.

## Build Strategy
- All binaries are built in a Docker environment based on Amazon Linux 2023 (arm64, x86_64).
- AWS CLI v2:
    - Installed using the official Linux installer for the target architecture
    - Installed under `/opt/aws-cli`
    - Exposed via `/opt/bin/aws`
- jq:
    - Installed via `dnf`
    - Copied into `/opt/bin/jq`

## Quality Checks
- All shell scripts should pass `shellcheck`
- Smoke tests verify:
- `aws --version`
- `jq --version`
- End-to-end runtime invocation with a sample handler

## Versioning
- Git tags correspond to releases
- Each release produces versioned layer artifacts:
    - `lambda-shell-runtime-arm64-<version>.zip`
    - `lambda-shell-runtime-amd64-<version>.zip`

## Licensing
- Apache License 2.0
- All bundled third-party software must be compatible with Apache-2.0

## Non-Goals
- Automatic dependency updates
- Opinionated handler frameworks
- Nonstandard configuration or environment variables

This document defines the authoritative design constraints for the project.
