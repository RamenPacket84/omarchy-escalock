#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# shellcheck source=../lib/source-origin.sh
source "$project_root/lib/source-origin.sh"

accepted=(
  "https://github.com/RamenPacket84/omarchy-escalock"
  "https://github.com/RamenPacket84/omarchy-escalock.git"
  "HTTPS://GITHUB.COM/ramenpacket84/OMARCHY-ESCALOCK.GIT"
)
rejected=(
  "https://github.com/andrewbacon/omarchy-escalock"
  "https://github.com/someoneelse/omarchy-escalock"
  "http://github.com/RamenPacket84/omarchy-escalock"
  "git://github.com/RamenPacket84/omarchy-escalock.git"
  "git@github.com:RamenPacket84/omarchy-escalock.git"
  "ssh://git@github.com/RamenPacket84/omarchy-escalock.git"
  "https://github.com/RamenPacket84/omarchy-escalock/"
  "https://github.com/RamenPacket84/omarchy-escalock/tree/main"
  "https://github.com/RamenPacket84/omarchy-escalock.git?ref=main"
  "https://github.com/RamenPacket84/omarchy-escalock.evil"
)

for origin in "${accepted[@]}"; do
  omarchy_escalock_origin_is_canonical "$origin" || {
    echo "canonical origin was rejected: $origin" >&2
    exit 1
  }
done

for origin in "${rejected[@]}"; do
  if omarchy_escalock_origin_is_canonical "$origin"; then
    echo "noncanonical origin was accepted: $origin" >&2
    exit 1
  fi
done

expected_install="omarchy plugin add ${OMARCHY_ESCALOCK_CANONICAL_ORIGIN}.git --enable"
/usr/bin/grep -Fqx "$expected_install" "$project_root/README.md" || {
  echo "README install command does not match the canonical source origin" >&2
  exit 1
}

echo "canonical source-origin tests passed"
