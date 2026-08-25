#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-cli-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

fake_helper="$test_root/helper"
fake_pkexec="$test_root/pkexec"
test_cli="$test_root/omarchy-escalock"
state_file="$test_root/state"

printf '%s\n' enabled > "$state_file"
printf '#!/bin/bash\n[[ ${1:-} == status ]] || exit 2\n/bin/cat %q\n' \
  "$state_file" > "$fake_helper"
printf '#!/bin/bash\noperation=${2:-}\ncase "$operation" in\n  enable) /usr/bin/printf "enabled\\n" > %q; /usr/bin/printf "enabled\\n" ;;\n  disable) /usr/bin/printf "disabled\\n" > %q; /usr/bin/printf "disabled\\n" ;;\n  *) exit 2 ;;\nesac\n' \
  "$state_file" "$state_file" > "$fake_pkexec"
chmod 0755 "$fake_helper" "$fake_pkexec"

sed \
  -e "s|readonly helper=/usr/local/libexec/omarchy-escalock-helper|readonly helper=$fake_helper|" \
  -e "s|readonly pkexec=/usr/bin/pkexec|readonly pkexec=$fake_pkexec|" \
  "$project_root/bin/omarchy-escalock" > "$test_cli"
chmod 0755 "$test_cli"

[[ $($test_cli status) == off ]]
[[ $($test_cli on) == on ]]
[[ $($test_cli status) == on ]]
[[ $($test_cli toggle) == off ]]
[[ $($test_cli status) == off ]]

if "$test_cli" enable >/dev/null 2>&1; then
  echo "public CLI accepted the ambiguous legacy enable verb" >&2
  exit 1
fi
if "$test_cli" disable >/dev/null 2>&1; then
  echo "public CLI accepted the ambiguous legacy disable verb" >&2
  exit 1
fi

echo "public CLI mapping tests passed"
