#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/scripts/aws_env.sh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "Required command not found: $1" >&2
    exit 1
  fi
}

require_cmd aws

if [ -z "${S3_BUCKET:-}" ]; then
  printf '%s\n' "S3_BUCKET is not set." >&2
  exit 1
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  green=$(printf '\033[32m')
  red=$(printf '\033[31m')
  reset=$(printf '\033[0m')
else
  green=""
  red=""
  reset=""
fi

ok="${green}[ok]${reset}"
fail="${red}[fail]${reset}"

run_check() {
  description=$1
  shift

  printf '%s' "Checking $description... "
  output=$(mktemp)
  if "$@" >"$output" 2>&1; then
    printf '%s\n' "$ok"
    rm -f "$output"
    return 0
  fi

  printf '%s\n' "$fail" >&2
  sed 's/^/  /' "$output" >&2
  rm -f "$output"
  exit 1
}

run_check "AWS identity" aws sts get-caller-identity --query 'Arn' --output text
run_check "Lambda list-layers" aws lambda list-layers --max-items 5 --output text
run_check "S3 bucket access ($S3_BUCKET)" aws s3api head-bucket --bucket "$S3_BUCKET"
