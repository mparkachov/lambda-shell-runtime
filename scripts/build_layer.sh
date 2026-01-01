#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
self="$root/scripts/build_layer.sh"

host_arch() {
  arch=$(uname -m 2>/dev/null || true)
  case "$arch" in
    aarch64|arm64) printf '%s\n' "arm64" ;;
    x86_64|amd64) printf '%s\n' "amd64" ;;
    *) return 1 ;;
  esac
}

arch=${ARCH:-${1:-}}
if [ -z "$arch" ]; then
  arch=$(host_arch) || {
    printf '%s\n' "Unable to detect host architecture" >&2
    exit 1
  }
fi

if [ "$arch" = "all" ]; then
  ARCH=arm64 "$self"
  ARCH=amd64 "$self"
  exit 0
fi

case "$arch" in
  arm64|amd64) ;;
  *)
    printf '%s\n' "Unsupported architecture: $arch" >&2
    exit 1
    ;;
 esac

host=$(host_arch)
if [ "$arch" = "$host" ]; then
  layer_root="$root/layer/opt"
else
  layer_root="$root/layer/$arch/opt"
fi

platform="linux/$arch"
image="lambda-shell-runtime-builder:$arch"
container_id=""

if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load --platform "$platform" -t "$image" -f "$root/docker/Dockerfile" "$root"
  container_id=$(docker create --platform "$platform" "$image")
elif [ "$arch" = "$host" ]; then
  DOCKER_BUILDKIT=1 docker build --platform "$platform" -t "$image" -f "$root/docker/Dockerfile" "$root"
  container_id=$(docker create --platform "$platform" "$image")
else
  container_id=$(docker run -d --platform "$platform" public.ecr.aws/amazonlinux/amazonlinux:2023 sleep infinity)
  docker exec "$container_id" sh -c "dnf -y update \
    && dnf -y install curl-minimal unzip jq \
    && dnf clean all"
  docker exec "$container_id" sh -c "arch=\$(uname -m) \
    && case \"\$arch\" in \
      aarch64) awscli_arch=\"aarch64\" ;; \
      x86_64) awscli_arch=\"x86_64\" ;; \
      *) echo \"Unsupported architecture: \$arch\" >&2; exit 1 ;; \
    esac \
    && curl -sS \"https://awscli.amazonaws.com/awscli-exe-linux-\${awscli_arch}.zip\" -o \"/tmp/awscliv2.zip\" \
    && cd /tmp \
    && unzip -q awscliv2.zip \
    && ./aws/install -i /opt/aws-cli -b /opt/bin \
    && rm -rf /tmp/aws /tmp/awscliv2.zip"
fi

if [ -z "$container_id" ]; then
  printf '%s\n' "Failed to create build container" >&2
  exit 1
fi
cleanup() {
  docker rm -f "$container_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$layer_root"
mkdir -p "$layer_root/bin" "$layer_root/lib"

docker cp "$container_id:/opt/aws-cli" "$layer_root/aws-cli"
rm -f "$layer_root/bin/aws"
aws_version_dir=$(ls "$layer_root/aws-cli/v2" | grep -E '^[0-9]' | head -n1)
if [ -z "$aws_version_dir" ]; then
  printf '%s\n' "Unable to find AWS CLI v2 version directory under $layer_root/aws-cli/v2" >&2
  exit 1
fi
ln -s "../aws-cli/v2/$aws_version_dir/bin/aws" "$layer_root/bin/aws"

docker cp "$container_id:/usr/bin/jq" "$layer_root/bin/jq"
docker cp "$container_id:/usr/lib64/libjq.so.1" "$layer_root/lib/libjq.so.1"
docker cp "$container_id:/usr/lib64/libonig.so.5" "$layer_root/lib/libonig.so.5"

libjq_target=$(readlink "$layer_root/lib/libjq.so.1" || true)
if [ -z "$libjq_target" ]; then
  printf '%s\n' "Unable to resolve libjq.so.1 target" >&2
  exit 1
fi
docker cp "$container_id:/usr/lib64/$libjq_target" "$layer_root/lib/$libjq_target"

libonig_target=$(readlink "$layer_root/lib/libonig.so.5" || true)
if [ -z "$libonig_target" ]; then
  printf '%s\n' "Unable to resolve libonig.so.5 target" >&2
  exit 1
fi
docker cp "$container_id:/usr/lib64/$libonig_target" "$layer_root/lib/$libonig_target"

cp "$root/runtime/bootstrap" "$layer_root/bootstrap"

chmod +x \
  "$layer_root/bootstrap" \
  "$layer_root/bin/jq"
