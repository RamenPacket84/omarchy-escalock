#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-rebaseline-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

target_user=$(id -un)
target_uid=$(id -u)
target_gid=$(id -g)
stage=$test_root/stage
script_dir=$stage/bin
work=$stage/generated
config_dir=$test_root/etc/omarchy-escalock
sudoers_dir=$test_root/etc/sudoers.d
sudoers_main=$test_root/etc/sudoers
sudo_conf=$test_root/etc/sudo.conf
backup_root=$test_root/backups
grant_basename="04_$target_user"
grant=$sudoers_dir/$grant_basename
wheel_grant=$sudoers_dir/00-omarchy-wheel
installed_helper=$test_root/installed-helper
staged_helper=$stage/build/omarchy-escalock-helper
fake_cvtsudoers=$test_root/cvtsudoers
live_policy=$test_root/live-policy.json
entry=$script_dir/omarchy-escalock-maint-rebaseline

mkdir -p "$script_dir" "$stage/build" "$work" "$config_dir" "$sudoers_dir"
chmod 0700 "$script_dir" "$config_dir" "$work"

sed \
  -e "s|readonly helper=/usr/local/libexec/omarchy-escalock-helper|readonly helper=$installed_helper|" \
  -e "s|readonly config_dir=/etc/omarchy-escalock|readonly config_dir=$config_dir|" \
  -e "s|readonly sudoers_dir=/etc/sudoers.d|readonly sudoers_dir=$sudoers_dir|" \
  -e "s|readonly sudoers_main=/etc/sudoers|readonly sudoers_main=$sudoers_main|" \
  -e "s|readonly sudo_conf=/etc/sudo.conf|readonly sudo_conf=$sudo_conf|" \
  -e "s|readonly wheel_grant=/etc/sudoers.d/00-omarchy-wheel|readonly wheel_grant=$wheel_grant|" \
  -e "s|readonly backup_root=/var/backups/omarchy-escalock|readonly backup_root=$backup_root|" \
  -e "s/0:0:600/$target_uid:$target_gid:600/g" \
  -e "s/0:0:440/$target_uid:$target_gid:440/g" \
  "$project_root/bin/omarchy-escalock-maint-common" \
  > "$script_dir/omarchy-escalock-maint-common"

sed \
  -e "s/== 0:\*:\*/== $target_uid:*:*/g" \
  -e "s/0:0:700/$target_uid:$target_gid:700/g" \
  "$project_root/bin/omarchy-escalock-maint-grant" \
  > "$script_dir/omarchy-escalock-maint-grant"

sed \
  -e "s/0:0:\*/$target_uid:$target_gid:*/g" \
  -e "s/0:0:700/$target_uid:$target_gid:700/g" \
  -e "s/0:0:600/$target_uid:$target_gid:600/g" \
  -e "s/\[\[ \$EUID == 0 \]\]/[[ \$EUID == $target_uid ]]/" \
  -e "s/-o root -g root/-o $target_uid -g $target_gid/g" \
  -e "s|/usr/bin/cvtsudoers|$fake_cvtsudoers|g" \
  -e 's/^\[\[ -t 0 \]\] || fail "policy rebaseline confirmation requires a terminal"$/: # TTY is exercised by the production entry point; this copy uses piped test input./' \
  "$project_root/bin/omarchy-escalock-maint-rebaseline" > "$entry"

chmod 0644 "$script_dir/omarchy-escalock-maint-common" \
  "$script_dir/omarchy-escalock-maint-grant"
chmod 0755 "$entry"

printf '%s\n' \
  "TARGET_USER=$target_user" \
  "TARGET_UID=$target_uid" \
  'GRANT_MODE=dedicated' \
  "GRANT_BASENAME=$grant_basename" > "$config_dir/config"
printf '%s ALL=(ALL) ALL\n' "$target_user" > "$grant"
printf '# test sudoers root\n' > "$sudoers_main"
chmod 0600 "$config_dir/config"
chmod 0440 "$grant"

/usr/bin/jq -S -n --arg user "$target_user" \
  '{User_Specs:[{User_List:[{username:$user}],Policy:"new-enabled"}]}' \
  > "$work/sudo-policy.enabled.json"
/usr/bin/jq -S -n --arg user "$target_user" \
  '{User_Specs:[{User_List:[{username:$user}],Policy:"new-disabled"}]}' \
  > "$work/sudo-policy.disabled.json"
/usr/bin/jq -S -n '{Policy:"old-enabled"}' > "$test_root/old-enabled.json"
/usr/bin/jq -S -n '{Policy:"old-disabled"}' > "$test_root/old-disabled.json"
chmod 0600 "$work"/sudo-policy.*.json

enabled_hash=$(/usr/bin/sha256sum "$work/sudo-policy.enabled.json")
enabled_hash=${enabled_hash%% *}
disabled_hash=$(/usr/bin/sha256sum "$work/sudo-policy.disabled.json")
disabled_hash=${disabled_hash%% *}
printf '%s\n' \
  "TARGET_USER=$target_user" \
  "TARGET_UID=$target_uid" \
  'GRANT_MODE=dedicated' \
  "GRANT_BASENAME=$grant_basename" \
  'FRESH_WHEEL_MIGRATION=false' \
  "ENABLED_POLICY_SHA256=$enabled_hash" \
  "DISABLED_POLICY_SHA256=$disabled_hash" > "$work/plan"
chmod 0600 "$work/plan"

printf '#!/bin/bash\n[[ ${1:-} == rebaseline-ready ]] || exit 2\n[[ ${OMARCHY_ESCALOCK_TEST_STRUCTURAL_FAILURE:-0} == 0 ]] || exit 1\nprintf "enabled\\n"\n' \
  > "$staged_helper"
printf '#!/bin/bash\n[[ ${1:-} == status ]] || exit 2\nif /usr/bin/cmp -s %q %q && /usr/bin/cmp -s %q %q; then\n  [[ ${OMARCHY_ESCALOCK_TEST_POSTCOMMIT_FAILURE:-0} == 0 ]] || exit 1\n  printf "enabled\\n"\nelse\n  printf "inconsistent\\n"\nfi\n' \
  "$config_dir/sudo-policy.enabled.json" "$work/sudo-policy.enabled.json" \
  "$config_dir/sudo-policy.disabled.json" "$work/sudo-policy.disabled.json" \
  > "$installed_helper"
printf '#!/bin/bash\n/usr/bin/cat %q\n' "$live_policy" > "$fake_cvtsudoers"
chmod 0755 "$staged_helper" "$installed_helper" "$fake_cvtsudoers"

write_old_snapshots() {
  cp "$test_root/old-enabled.json" "$config_dir/sudo-policy.enabled.json"
  cp "$test_root/old-disabled.json" "$config_dir/sudo-policy.disabled.json"
  chmod 0600 "$config_dir"/sudo-policy.*.json
}

snapshots_are_old() {
  cmp -s "$test_root/old-enabled.json" "$config_dir/sudo-policy.enabled.json" &&
    cmp -s "$test_root/old-disabled.json" "$config_dir/sudo-policy.disabled.json"
}

run_rebaseline() {
  local answer=$1
  printf '%s\n' "$answer" | "$entry" --stage "$stage" --user "$target_user" \
    --commit "$(printf 'a%.0s' {1..40})" --digest "$(printf 'b%.0s' {1..64})"
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "unsafe policy rebaseline unexpectedly succeeded" >&2
    exit 1
  fi
}

write_old_snapshots
mv "$config_dir" "$test_root/config.absent"
expect_failure run_rebaseline rebaseline
mv "$test_root/config.absent" "$config_dir"
snapshots_are_old

cp "$work/sudo-policy.enabled.json" "$config_dir/sudo-policy.enabled.json"
cp "$work/sudo-policy.disabled.json" "$config_dir/sudo-policy.disabled.json"
chmod 0600 "$config_dir"/sudo-policy.*.json
expect_failure run_rebaseline rebaseline
write_old_snapshots

expect_failure run_rebaseline cancel
snapshots_are_old
[[ ! -e $backup_root ]]

expect_failure env OMARCHY_ESCALOCK_TEST_STRUCTURAL_FAILURE=1 \
  bash -c 'printf "rebaseline\n" | "$@"' _ "$entry" --stage "$stage" \
  --user "$target_user" --commit "$(printf 'a%.0s' {1..40})" \
  --digest "$(printf 'b%.0s' {1..64})"
snapshots_are_old

/usr/bin/jq -S -n '{Policy:"changed-after-review"}' > "$live_policy"
expect_failure run_rebaseline rebaseline
snapshots_are_old

cp "$work/sudo-policy.enabled.json" "$live_policy"
run_rebaseline rebaseline >/dev/null
cmp -s "$work/sudo-policy.enabled.json" "$config_dir/sudo-policy.enabled.json"
cmp -s "$work/sudo-policy.disabled.json" "$config_dir/sudo-policy.disabled.json"
find "$backup_root" -mindepth 2 -maxdepth 2 -name live-policy.commit.json -print -quit |
  /usr/bin/grep -q .

write_old_snapshots
expect_failure env OMARCHY_ESCALOCK_TEST_POSTCOMMIT_FAILURE=1 \
  bash -c 'printf "rebaseline\n" | "$@"' _ "$entry" --stage "$stage" \
  --user "$target_user" --commit "$(printf 'a%.0s' {1..40})" \
  --digest "$(printf 'b%.0s' {1..64})"
snapshots_are_old

echo "policy rebaseline transaction tests passed"
