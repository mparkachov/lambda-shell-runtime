#!/bin/sh

handler() {
  printf '%s\n' "handler received event" >&2

  aws_version=$(aws --version 2>&1 | awk '{print $1}')

  jq -c --arg aws "$aws_version" '{aws_cli:$aws, input:.}'
}
