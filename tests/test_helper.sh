#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

target_user=$(id -un)
target_uid=$(id -u)
target_gid=$(id -g)
test_helper="$project_root/build/omarchy-escalock-helper-test"

/usr/bin/gcc -DTESTING -O1 -g -std=c17 -Wall -Wextra -Werror -Wformat=2 \
  -Wconversion -Wshadow -Wstrict-prototypes -fstack-protector-strong -fPIE \
  "$project_root/src/omarchy-escalock-helper.c" -o "$test_helper" \
  -pie -Wl,-z,relro,-z,now

mkdir -p \
  "$test_root/etc/omarchy-escalock" \
  "$test_root/etc/sudoers.d" \
  "$test_root/etc/polkit-1/rules.d" \
  "$test_root/usr/share/polkit-1/actions" \
  "$test_root/usr/local/libexec"
chmod 0700 "$test_root/etc/omarchy-escalock"

config_dir="$test_root/etc/omarchy-escalock"
grant="$test_root/etc/sudoers.d/00_$target_user"
disabled="$config_dir/sudoers.disabled"
off_rule="$test_root/etc/polkit-1/rules.d/10-omarchy-escalock-off.rules"

printf 'TARGET_USER=%s\nTARGET_UID=%s\n' "$target_user" "$target_uid" > "$config_dir/config"
chmod 0600 "$config_dir/config"
printf '%s ALL=(ALL) ALL\n' "$target_user" > "$config_dir/sudoers.template"
chmod 0440 "$config_dir/sudoers.template"
cp "$config_dir/sudoers.template" "$grant"
chmod 0440 "$grant"

sed "s/@@TARGET_USER@@/$target_user/g" \
  "$project_root/polkit/05-omarchy-escalock-recovery.rules.in" > "$config_dir/05-omarchy-escalock-recovery.rules.template"
sed "s/@@TARGET_USER@@/$target_user/g" \
  "$project_root/polkit/10-omarchy-escalock-off.rules.in" > "$config_dir/10-omarchy-escalock-off.rules.template"
sed "s/@@TARGET_USER@@/$target_user/g" \
  "$project_root/polkit/20-omarchy-escalock-manage.rules.in" > "$config_dir/20-omarchy-escalock-manage.rules.template"
cp "$project_root/polkit/com.github.andrewbacon.omarchy-escalock.policy" \
  "$config_dir/com.github.andrewbacon.omarchy-escalock.policy.template"
chmod 0644 "$config_dir"/*.rules.template "$config_dir"/*.policy.template

cp "$config_dir/05-omarchy-escalock-recovery.rules.template" \
  "$test_root/etc/polkit-1/rules.d/05-omarchy-escalock-recovery.rules"
cp "$config_dir/20-omarchy-escalock-manage.rules.template" \
  "$test_root/etc/polkit-1/rules.d/20-omarchy-escalock-manage.rules"
cp "$config_dir/com.github.andrewbacon.omarchy-escalock.policy.template" \
  "$test_root/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-escalock.policy"
chmod 0644 \
  "$test_root/etc/polkit-1/rules.d/05-omarchy-escalock-recovery.rules" \
  "$test_root/etc/polkit-1/rules.d/20-omarchy-escalock-manage.rules" \
  "$test_root/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-escalock.policy"

cp "$test_helper" "$test_root/usr/local/libexec/omarchy-escalock-helper"
chmod 0755 "$test_root/usr/local/libexec/omarchy-escalock-helper"

printf 'root ALL=(ALL:ALL) ALL\n@includedir %s/etc/sudoers.d\n' "$test_root" > "$test_root/etc/sudoers"
chmod 0440 "$test_root/etc/sudoers"

run_helper() {
  OMARCHY_ESCALOCK_TEST_ROOT="$test_root" "$test_helper" "$@"
}

run_mutation() {
  OMARCHY_ESCALOCK_TEST_ROOT="$test_root" \
    OMARCHY_ESCALOCK_TEST_PKEXEC=1 "$test_helper" "$@"
}

[[ $(run_helper status) == enabled ]]

if run_helper unexpected >/dev/null 2>&1; then
  echo "helper accepted an unexpected operation" >&2
  exit 1
fi
if run_helper enable >/dev/null 2>&1; then
  echo "direct non-root helper execution changed state" >&2
  exit 1
fi

[[ $(run_mutation disable) == disabled ]]
[[ ! -e $grant && -f $disabled && -f $off_rule ]]
[[ $(run_helper status) == disabled ]]
[[ $(run_mutation disable) == disabled ]]

[[ $(run_mutation enable) == enabled ]]
[[ -f $grant && ! -e $disabled && ! -e $off_rule ]]
[[ $(run_helper status) == enabled ]]
[[ $(run_mutation enable) == enabled ]]

mv "$grant" "$grant.missing"
[[ $(run_helper status) == inconsistent ]]
if run_mutation disable >/dev/null 2>&1; then
  echo "helper disabled from an inconsistent state" >&2
  exit 1
fi
mv "$grant.missing" "$grant"
[[ $(run_helper status) == enabled ]]

chmod 0640 "$config_dir/sudoers.template"
[[ $(run_helper status) == inconsistent ]]
chmod 0440 "$config_dir/sudoers.template"

run_mutation disable >/dev/null
printf '// tampered\n' >> "$off_rule"
[[ $(run_helper status) == inconsistent ]]
cp "$config_dir/10-omarchy-escalock-off.rules.template" "$off_rule"
chmod 0644 "$off_rule"
[[ $(run_helper status) == disabled ]]
run_mutation enable >/dev/null

echo "helper transition tests passed"

