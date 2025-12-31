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
mkdir -p "$root/layer/opt/bin" "$root/layer/opt/lib"

docker cp "$container_id:/opt/aws-cli" "$root/layer/opt/aws-cli"
rm -f "$root/layer/opt/bin/aws"
aws_version_dir=$(ls "$root/layer/opt/aws-cli/v2" | grep -E '^[0-9]' | head -n1)
if [ -z "$aws_version_dir" ]; then
  printf '%s\n' "Unable to find AWS CLI v2 version directory under $root/layer/opt/aws-cli/v2" >&2
  exit 1
fi
ln -s "../aws-cli/v2/$aws_version_dir/bin/aws" "$root/layer/opt/bin/aws"
docker cp "$container_id:/usr/bin/jq" "$root/layer/opt/bin/jq"
docker cp "$container_id:/usr/lib64/libjq.so.1" "$root/layer/opt/lib/libjq.so.1"
docker cp "$container_id:/usr/lib64/libonig.so.5" "$root/layer/opt/lib/libonig.so.5"

libjq_target=$(readlink "$root/layer/opt/lib/libjq.so.1" || true)
if [ -z "$libjq_target" ]; then
  printf '%s\n' "Unable to resolve libjq.so.1 target" >&2
  exit 1
fi
docker cp "$container_id:/usr/lib64/$libjq_target" "$root/layer/opt/lib/$libjq_target"

libonig_target=$(readlink "$root/layer/opt/lib/libonig.so.5" || true)
if [ -z "$libonig_target" ]; then
  printf '%s\n' "Unable to resolve libonig.so.5 target" >&2
  exit 1
fi
docker cp "$container_id:/usr/lib64/$libonig_target" "$root/layer/opt/lib/$libonig_target"

cp "$root/runtime/bootstrap" "$root/layer/opt/bootstrap"

chmod +x \
  "$root/layer/opt/bootstrap" \
  "$root/layer/opt/bin/jq"
