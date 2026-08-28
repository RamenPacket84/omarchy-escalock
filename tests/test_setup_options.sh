#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
setup="$project_root/setup.sh"

help_output=$("$setup" --help)
/usr/bin/grep -Fqx \
  'Usage: ./setup.sh [--enable] [--check] [--development]' \
  <<< "$help_output"

for deprecated in --upgrade --dry-run --user; do
  if "$setup" "$deprecated" >/dev/null 2>&1; then
    echo "setup accepted removed option: $deprecated" >&2
    exit 1
  fi
done

echo "setup option tests passed"
