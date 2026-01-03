#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/scripts/aws_env.sh"

bucket_name=${DEV_BUCKET_NAME:-$LSR_BUCKET_NAME_DEV}
stack_name=${DEV_STACK_NAME:-$LSR_STACK_NAME_DEV}
s3_prefix=${S3_PREFIX:-$LSR_S3_PREFIX}

SKIP_SAR_PUBLISH=1 \
BUCKET_NAME="$bucket_name" \
STACK_NAME="$stack_name" \
S3_PREFIX="$s3_prefix" \
"$root/scripts/aws_setup.sh"
