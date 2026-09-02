#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-plan-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

target_user=$(id -un)
target_uid=$(id -u)
target_gid=$(id -g)
probe=$test_root/plan-probe
plan=$test_root/plan
marker=$test_root/injection-ran
printf '{}\n' > "$test_root/sudo-policy.enabled.json"
printf '{"disabled":true}\n' > "$test_root/sudo-policy.disabled.json"
chmod 0600 "$test_root"/sudo-policy.*.json
enabled_hash=$(/usr/bin/sha256sum "$test_root/sudo-policy.enabled.json")
enabled_hash=${enabled_hash%% *}
disabled_hash=$(/usr/bin/sha256sum "$test_root/sudo-policy.disabled.json")
disabled_hash=${disabled_hash%% *}

{
  printf '#!/bin/bash\nset -euo pipefail\nreadonly escalock_program=plan-probe\n'
  sed \
    -e "s/== 0:0:600/== $target_uid:$target_gid:600/g" \
    "$project_root/bin/omarchy-escalock-maint-common"
  printf '%s\n' \
    'select_grant_mode() { :; }' \
    'verify_preflight_plan "$1" "$2"'
} > "$probe"
chmod 0755 "$probe"

write_plan() {
  printf '%s\n' "$@" > "$plan"
  chmod 0600 "$plan"
}

expect_rejected() {
  if "$probe" "$plan" "$target_user" >/dev/null 2>&1; then
    echo "unsafe privileged preflight plan was accepted" >&2
    exit 1
  fi
}

write_plan \
  "TARGET_USER=$target_user" \
  "TARGET_UID=$target_uid" \
  "GRANT_MODE=dedicated" \
  "GRANT_BASENAME=00_$target_user" \
  "FRESH_WHEEL_MIGRATION=false" \
  "ENABLED_POLICY_SHA256=$enabled_hash" \
  "DISABLED_POLICY_SHA256=$disabled_hash"
"$probe" "$plan" "$target_user"

write_plan \
  "TARGET_USER=$target_user" \
  "TARGET_UID=$target_uid" \
  "GRANT_MODE=\$(touch $marker)" \
  "GRANT_BASENAME=00_$target_user" \
  "FRESH_WHEEL_MIGRATION=false" \
  "ENABLED_POLICY_SHA256=$enabled_hash" \
  "DISABLED_POLICY_SHA256=$disabled_hash"
expect_rejected
[[ ! -e $marker ]]

write_plan \
  "TARGET_USER=$target_user" \
  "TARGET_UID=$target_uid" \
  "GRANT_MODE=dedicated" \
  "GRANT_BASENAME=../00_$target_user" \
  "FRESH_WHEEL_MIGRATION=false" \
  "ENABLED_POLICY_SHA256=$enabled_hash" \
  "DISABLED_POLICY_SHA256=$disabled_hash"
expect_rejected

write_plan \
  "TARGET_USER=$target_user" \
  "TARGET_UID=$target_uid" \
  "GRANT_MODE=dedicated" \
  "GRANT_BASENAME=00_$target_user" \
  "FRESH_WHEEL_MIGRATION=false" \
  "ENABLED_POLICY_SHA256=$enabled_hash" \
  "DISABLED_POLICY_SHA256=$disabled_hash" \
  "EXTRA_FIELD=$marker"
expect_rejected

write_plan \
  "TARGET_USER=$target_user" \
  "TARGET_UID=$target_uid" \
  "GRANT_MODE=dedicated" \
  "GRANT_BASENAME=00_$target_user" \
  "FRESH_WHEEL_MIGRATION=false" \
  "ENABLED_POLICY_SHA256=$enabled_hash" \
  "DISABLED_POLICY_SHA256=$disabled_hash"
printf 'tampered\n' >> "$test_root/sudo-policy.enabled.json"
expect_rejected

echo "privileged preflight plan tests passed"
