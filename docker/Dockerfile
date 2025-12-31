FROM public.ecr.aws/amazonlinux/amazonlinux:2023

RUN dnf -y update \
  && dnf -y install curl-minimal unzip jq \
  && dnf clean all

RUN curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip" \
  && cd /tmp \
  && unzip -q awscliv2.zip \
  && ./aws/install -i /opt/aws-cli -b /opt/bin \
  && rm -rf /tmp/aws /tmp/awscliv2.zip
