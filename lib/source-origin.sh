#!/bin/bash

readonly OMARCHY_ESCALOCK_CANONICAL_ORIGIN=https://github.com/RamenPacket84/omarchy-escalock

omarchy_escalock_origin_is_canonical() {
  (( $# == 1 )) || return 2

  local normalized=${1,,}
  normalized=${normalized%.git}
  [[ $normalized == "${OMARCHY_ESCALOCK_CANONICAL_ORIGIN,,}" ]]
}
