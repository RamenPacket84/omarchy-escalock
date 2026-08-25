#!/bin/bash

set -euo pipefail

test_root=$(mktemp -d /tmp/omarchy-escalock-layout-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

source_json="$test_root/shell.json"
migrated_json="$test_root/shell.migrated.json"

printf '%s\n' \
  '{"version":1,"bar":{"layout":{"right":[{"id":"omarchy.tray"},{"id":"andrewbacon.admin-toggle","custom":true},{"id":"omarchy.power"}]}}}' \
  > "$source_json"

legacy_count=$(/usr/bin/jq \
  '[.. | objects | select(.id? == "andrewbacon.admin-toggle")] | length' \
  "$source_json")
[[ $legacy_count == 1 ]]

/usr/bin/sed 's/andrewbacon\.admin-toggle/andrewbacon.escalock/g' \
  "$source_json" > "$migrated_json"
/usr/bin/jq -e . "$migrated_json" >/dev/null

[[ $(/usr/bin/jq -r '.bar.layout.right[1].id' "$migrated_json") == andrewbacon.escalock ]]
[[ $(/usr/bin/jq -r '.bar.layout.right[1].custom' "$migrated_json") == true ]]
[[ $(/usr/bin/jq \
  '[.. | objects | select(.id? == "andrewbacon.admin-toggle")] | length' \
  "$migrated_json") == 0 ]]

echo "bar-layout migration tests passed"
