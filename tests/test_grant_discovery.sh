#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-grant-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

target_user=$(id -un)
target_uid=$(id -u)
target_gid=$(id -g)
sudoers_dir="$test_root/etc/sudoers.d"
config_dir="$test_root/etc/omarchy-escalock"
wheel_grant="$sudoers_dir/00-omarchy-wheel"
probe="$test_root/omarchy-escalock-grant-probe"

mkdir -p "$sudoers_dir"
chmod 0750 "$sudoers_dir"

# Exercise the maintainer's real discovery and configuration functions against
# an unprivileged temporary tree. Only fixed path and trusted-owner constants
# are changed; the probe exits before any maintenance operation can run.
sed \
  -e "s|^readonly config_dir=.*|readonly config_dir=$config_dir|" \
  -e "s|^readonly sudoers_dir=.*|readonly sudoers_dir=$sudoers_dir|" \
  -e "s|^readonly wheel_grant=.*|readonly wheel_grant=$wheel_grant|" \
  -e 's/^\[\[ \$EUID == 0 \]\].*/true/' \
  -e "s/== 0:0:600/== $target_uid:$target_gid:600/g" \
  -e "s/== 0:0:440/== $target_uid:$target_gid:440/g" \
  -e "s/== 0:0:700/== $target_uid:$target_gid:700/g" \
  -e "s/== 0:\*:\*/== $target_uid:\*:\*/g" \
  -e '/^check_sudo_policy_backend() {/i\
select_grant_mode\
/usr/bin/printf '\''RESULT %s %s %s\\n'\'' "$grant_mode" "$grant_basename" "$grant"\
exit 0\
' \
  "$project_root/bin/omarchy-escalock-maintain" > "$probe"
chmod 0755 "$probe"

reset_layout() {
  rm -rf -- "$sudoers_dir" "$config_dir"
  mkdir -p "$sudoers_dir"
  chmod 0750 "$sudoers_dir"
}

write_dedicated() {
  local basename=$1

  printf '%s ALL=(ALL) ALL\n' "$target_user" > "$sudoers_dir/$basename"
  chmod 0440 "$sudoers_dir/$basename"
}

write_wheel() {
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$wheel_grant"
  chmod 0440 "$wheel_grant"
}

expect_probe() {
  local mode=$1 basename=$2 output

  output=$("$probe" probe --user "$target_user" 2>&1)
  /usr/bin/grep -Fxq \
    "RESULT $mode $basename $sudoers_dir/$basename" <<< "$output"
}

expect_failure() {
  local expected=$1 output

  if output=$("$probe" probe --user "$target_user" 2>&1); then
    echo "grant probe unexpectedly succeeded: $output" >&2
    exit 1
  fi
  /usr/bin/grep -Fq -- "$expected" <<< "$output"
}

write_dedicated "00_$target_user"
expect_probe dedicated "00_$target_user"

reset_layout
write_dedicated "04_$target_user"
expect_probe dedicated "04_$target_user"

reset_layout
write_dedicated "137_$target_user"
expect_probe dedicated "137_$target_user"

reset_layout
write_dedicated "4_$target_user"
expect_failure "found 0"

reset_layout
printf '%s ALL=(ALL) ALL\n' "$target_user" > "$sudoers_dir/04_$target_user"
chmod 0644 "$sudoers_dir/04_$target_user"
expect_failure "unsafe or modified"

reset_layout
printf '%s ALL=(ALL:ALL) ALL\n' "$target_user" > "$sudoers_dir/04_$target_user"
chmod 0440 "$sudoers_dir/04_$target_user"
expect_failure "unsafe or modified"

reset_layout
ln -s /etc/passwd "$sudoers_dir/04_$target_user"
expect_failure "unsafe or modified"

reset_layout
write_dedicated "04_$target_user"
write_dedicated "05_$target_user"
expect_failure "found 2"

reset_layout
write_dedicated "04_$target_user"
write_wheel
expect_failure "found 2"

reset_layout
write_wheel
expect_probe omarchy-wheel "00_$target_user"

reset_layout
write_dedicated "37_$target_user"
mkdir -p "$config_dir"
chmod 0700 "$config_dir"
printf 'TARGET_USER=%s\nTARGET_UID=%s\nGRANT_MODE=dedicated\nGRANT_BASENAME=37_%s\n' \
  "$target_user" "$target_uid" "$target_user" > "$config_dir/config"
chmod 0600 "$config_dir/config"
expect_probe dedicated "37_$target_user"

write_dedicated "38_$target_user"
expect_failure "ambiguous general sudo grant"
rm "$sudoers_dir/38_$target_user"

printf 'TARGET_USER=%s\nTARGET_UID=%s\nGRANT_MODE=dedicated\nGRANT_BASENAME=../37_%s\n' \
  "$target_user" "$target_uid" "$target_user" > "$config_dir/config"
expect_failure "configuration belongs to another account or is invalid"

reset_layout
write_dedicated "00_$target_user"
mkdir -p "$config_dir"
chmod 0700 "$config_dir"
printf 'TARGET_USER=%s\nTARGET_UID=%s\nGRANT_MODE=dedicated\n' \
  "$target_user" "$target_uid" > "$config_dir/config"
chmod 0600 "$config_dir/config"
expect_probe dedicated "00_$target_user"

reset_layout
printf '%s ALL=(ALL:ALL) ALL\n' "$target_user" > "$sudoers_dir/00_$target_user"
printf '%%wheel, !%s ALL=(ALL:ALL) ALL\n' "$target_user" > "$wheel_grant"
chmod 0440 "$sudoers_dir/00_$target_user" "$wheel_grant"
mkdir -p "$config_dir"
chmod 0700 "$config_dir"
printf 'TARGET_USER=%s\nTARGET_UID=%s\nGRANT_MODE=omarchy-wheel\n' \
  "$target_user" "$target_uid" > "$config_dir/config"
chmod 0600 "$config_dir/config"
expect_probe omarchy-wheel "00_$target_user"

echo "maintainer grant-discovery tests passed"
