#!/bin/bash

set -euo pipefail

readonly cli=/usr/local/bin/omarchy-escalock

if (( $# == 2 )) && [[ $1 == --user && $2 == $(/usr/bin/id -un) ]]; then
  shift 2
fi
if (( $# != 0 )); then
  echo "Usage: ./uninstall.sh [--user CURRENT_USER]" >&2
  exit 2
fi
if (( EUID == 0 )); then
  echo "Run uninstall as the configured desktop user, not with sudo." >&2
  exit 1
fi
[[ -x $cli ]] || {
  echo "The installed EscaLock CLI is missing; no system files were changed." >&2
  exit 1
}

exec "$cli" uninstall
