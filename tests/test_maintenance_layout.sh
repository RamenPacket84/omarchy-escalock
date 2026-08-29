#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
setup=$project_root/setup.sh

expected_members=(
  build/omarchy-escalock-helper
  bin/omarchy-escalock
  bin/omarchy-escalock-maint-common
  bin/omarchy-escalock-maint-grant
  bin/omarchy-escalock-maint-transaction
  bin/omarchy-escalock-maint-preflight
  bin/omarchy-escalock-maint-install
  bin/omarchy-escalock-maint-uninstall
  manifest.json
  polkit/00-00-omarchy-escalock-on.rules.in
  polkit/00-00-omarchy-escalock-off.rules.in
  polkit/com.github.andrewbacon.omarchy-escalock.policy
)

read_array() {
  local name=$1

  /usr/bin/awk -v name="$name" '
    $0 == name "=(" { inside = 1; next }
    inside && $0 == ")" { exit }
    inside {
      value = $0
      sub(/^[[:space:]]+/, "", value)
      if (value != "") print value
    }
  ' "$setup"
}

mapfile -t source_members < <(read_array payload_files)
mapfile -t root_members < <(read_array expected_members)
[[ ${source_members[*]} == "${expected_members[*]}" ]] || {
  echo "unprivileged payload member list changed unexpectedly" >&2
  exit 1
}
[[ ${root_members[*]} == "${expected_members[*]}" ]] || {
  echo "root payload member list differs from the source list" >&2
  exit 1
}

[[ ! -e $project_root/bin/omarchy-escalock-maintain ]] || {
  echo "the removed multi-operation maintenance entry point returned" >&2
  exit 1
}

libraries=(common grant transaction)
entries=(preflight install uninstall)
for component in "${libraries[@]}" "${entries[@]}"; do
  file=$project_root/bin/omarchy-escalock-maint-$component
  [[ -f $file && ! -L $file ]] || {
    echo "maintenance component is missing or linked: $component" >&2
    exit 1
  }
  lines=$(/usr/bin/wc -l < "$file")
  bytes=$(/usr/bin/wc -c < "$file")
  (( lines <= 320 && bytes <= 14000 )) || {
    echo "maintenance component exceeds the static-analysis budget: $component" >&2
    exit 1
  }
done

for component in "${libraries[@]}"; do
  [[ $(/usr/bin/stat -c '%a' "$project_root/bin/omarchy-escalock-maint-$component") == 644 ]]
done
for component in "${entries[@]}"; do
  [[ $(/usr/bin/stat -c '%a' "$project_root/bin/omarchy-escalock-maint-$component") == 755 ]]
done

/usr/bin/grep -Fq \
  'readonly uninstaller=/usr/local/libexec/omarchy-escalock-maint-uninstall' \
  "$project_root/bin/omarchy-escalock"
if /usr/bin/grep -Eq 'omarchy-escalock-maint-(preflight|install).*\$operation' "$setup"; then
  echo "setup dynamically selects a privileged maintenance executable" >&2
  exit 1
fi

echo "privileged maintenance layout tests passed"
