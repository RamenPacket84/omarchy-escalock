#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-transaction-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

target_uid=$(id -u)
target_gid=$(id -g)
config_dir=$test_root/etc/omarchy-escalock
first_path=$test_root/system/first
second_path=$test_root/system/second
backup=$test_root/backup
patched_module=$test_root/transaction
transaction_paths=("$first_path" "$second_path")
readonly escalock_program=transaction-test

fail() {
  echo "$escalock_program: $*" >&2
  exit 1
}

sed \
  -e "s/-o root -g root/-o $target_uid -g $target_gid/g" \
  "$project_root/bin/omarchy-escalock-maint-transaction" > "$patched_module"
# shellcheck disable=SC1090
source "$patched_module"

mkdir -p "$(dirname -- "$first_path")"
printf 'original\n' > "$first_path"
chmod 0640 "$first_path"
backup_system_files "$backup/system"

printf 'changed\n' > "$first_path"
printf 'new\n' > "$second_path"
restore_system_files "$backup/system"
[[ $(<"$first_path") == original ]]
[[ $(stat -c '%a' "$first_path") == 640 ]]
[[ ! -e $second_path ]]

mkdir -p "$config_dir"
printf 'trusted\n' > "$config_dir/config"
cp -a -- "$config_dir" "$backup/config.before"
printf 'partial\n' > "$config_dir/config"
restore_config_directory "$backup/config.before"
[[ $(<"$config_dir/config") == trusted ]]

printf 'partial\n' > "$config_dir/config"
restore_config_directory "$backup/missing"
[[ ! -e $config_dir ]]

echo "privileged transaction primitive tests passed"
