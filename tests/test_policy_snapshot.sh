#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-policy-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

target_user=$(id -un)
work=$test_root
grant_mode=dedicated
fresh_wheel_migration=false
fail() { echo "policy-test: $*" >&2; exit 1; }
# shellcheck source=bin/omarchy-escalock-maint-policy
source "$project_root/bin/omarchy-escalock-maint-policy"

write_policy() {
  local first_command=$1 first_negated=$2 second_command=$3 second_negated=$4
  /usr/bin/jq -n --arg user "$target_user" \
    --arg first "$first_command" --arg second "$second_command" \
    --argjson first_negated "$first_negated" --argjson second_negated "$second_negated" '
    def command($value; $negative):
      {"command":$value} + if $negative then {"negated":true} else {} end;
    {"User_Specs":[
      {"User_List":[{"username":$user}],"Host_List":[{"hostname":"ALL"}],
       "Cmnd_Specs":[{"runasusers":[{"username":"ALL"}],
       "Commands":[{"command":"ALL"}]}]},
      {"User_List":[{"username":$user}],"Host_List":[{"hostname":"ALL"}],
       "Cmnd_Specs":[{"runasusers":[{"username":"root"}],
       "Commands":[command($first;$first_negated),command($second;$second_negated)]}]}
    ]}
  ' > "$work/sudo-policy.enabled.json"
}

# The exact Omarchy conflict: a restriction is canceled by a later unrestricted
# grant for the same executable.
write_policy "/usr/bin/asdcontrol ^/dev/hiddev[0-9]+$" true "/usr/bin/asdcontrol" false
validate_managed_policy
if (reject_overridden_restrictions) >/dev/null 2>&1; then
  echo "overridden sudo restriction was accepted" >&2
  exit 1
fi

# When the restriction is last, both records are reported accurately and the
# restriction is not screened as a positive shell-escapable grant.
write_policy "/usr/bin/asdcontrol" false "/bin/bash" true
reject_overridden_restrictions
output=$(screen_retained_delegations)
/usr/bin/grep -Fq 'Retained sudo delegation (any arguments): /usr/bin/asdcontrol' <<< "$output"
/usr/bin/grep -Fq 'Retained sudo restriction (any arguments): /bin/bash' <<< "$output"

derive_disabled_policy
[[ $(/usr/bin/jq '[.User_Specs[]?.Cmnd_Specs[]?.Commands[]? | select(.command == "ALL")] | length' \
  "$work/sudo-policy.disabled.json") == 0 ]]
[[ $(/usr/bin/jq '[.User_Specs[]?.Cmnd_Specs[]?.Commands[]?] | length' \
  "$work/sudo-policy.disabled.json") == 2 ]]

write_policy "/bin/bash" false "/usr/bin/asdcontrol ^/dev/hiddev[0-9]+$" true
if (screen_retained_delegations) >/dev/null 2>&1; then
  echo "positive shell delegation was accepted" >&2
  exit 1
fi

echo "sudo policy snapshot tests passed"
