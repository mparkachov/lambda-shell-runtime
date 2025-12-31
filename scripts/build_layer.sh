#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image="lambda-shell-runtime-builder"

docker build --platform linux/arm64 -t "$image" -f "$root/docker/Dockerfile" "$root"

container_id=$(docker create --platform linux/arm64 "$image")
cleanup() {
  docker rm -f "$container_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$root/layer/opt"
mkdir -p "$root/layer/opt/bin"

docker cp "$container_id:/opt/aws-cli" "$root/layer/opt/aws-cli"
docker cp "$container_id:/opt/bin/aws" "$root/layer/opt/bin/aws"
docker cp "$container_id:/usr/bin/jq" "$root/layer/opt/bin/jq"

cp "$root/runtime/bootstrap" "$root/layer/opt/bootstrap"

chmod +x \
  "$root/layer/opt/bootstrap" \
  "$root/layer/opt/bin/aws" \
  "$root/layer/opt/bin/jq"
