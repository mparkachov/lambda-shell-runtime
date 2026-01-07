FROM public.ecr.aws/amazonlinux/amazonlinux:2023

ARG AWSCLI_VERSION=""

RUN dnf -y update \
  && dnf -y install curl-minimal unzip jq \
  && dnf clean all

RUN arch=$(uname -m) \
  && case "$arch" in \
    aarch64) awscli_arch="aarch64" ;; \
    x86_64) awscli_arch="x86_64" ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac \
  && if [ -n "$AWSCLI_VERSION" ]; then \
    awscli_pkg="awscli-exe-linux-${awscli_arch}-${AWSCLI_VERSION}.zip"; \
  else \
    awscli_pkg="awscli-exe-linux-${awscli_arch}.zip"; \
  fi \
  && curl -sS "https://awscli.amazonaws.com/${awscli_pkg}" -o "/tmp/awscliv2.zip" \
  && cd /tmp \
  && unzip -q awscliv2.zip \
  && ./aws/install -i /opt/aws-cli -b /opt/bin \
  && rm -rf /tmp/aws /tmp/awscliv2.zip
