#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-cli-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

fake_helper="$test_root/helper"
fake_pkexec="$test_root/pkexec"
fake_maintainer="$test_root/maintainer"
fake_sudo="$test_root/sudo"
fake_omarchy="$test_root/omarchy"
test_cli="$test_root/omarchy-escalock"
state_file="$test_root/state"
call_log="$test_root/calls"

printf '%s\n' enabled > "$state_file"
printf '#!/bin/bash\nif [[ ${1:-} == version ]]; then echo 2.0.2; exit 0; fi\n[[ ${1:-} == status ]] || exit 2\n/bin/cat %q\n' \
  "$state_file" > "$fake_helper"
printf '#!/bin/bash\noperation=${2:-}\ncase "$operation" in\n  enable) /usr/bin/printf "enabled\\n" > %q; /usr/bin/printf "enabled\\n" ;;\n  disable) /usr/bin/printf "disabled\\n" > %q; /usr/bin/printf "disabled\\n" ;;\n  *) exit 2 ;;\nesac\n' \
  "$state_file" "$state_file" > "$fake_pkexec"
printf '#!/bin/bash\n/usr/bin/printf "maintainer %%s\\n" "$*" >> %q\n' \
  "$call_log" > "$fake_maintainer"
printf '#!/bin/bash\n[[ ${1:-} == -- ]] && shift\nexec "$@"\n' > "$fake_sudo"
printf '#!/bin/bash\n/usr/bin/printf "omarchy %%s\\n" "$*" >> %q\n' \
  "$call_log" > "$fake_omarchy"
chmod 0755 "$fake_helper" "$fake_pkexec" "$fake_maintainer" "$fake_sudo" "$fake_omarchy"

sed \
  -e "s|readonly helper=/usr/local/libexec/omarchy-escalock-helper|readonly helper=$fake_helper|" \
  -e "s|readonly maintainer=/usr/local/libexec/omarchy-escalock-maintain|readonly maintainer=$fake_maintainer|" \
  -e "s|readonly pkexec=/usr/bin/pkexec|readonly pkexec=$fake_pkexec|" \
  -e "s|readonly sudo=/usr/bin/sudo|readonly sudo=$fake_sudo|" \
  -e "s|readonly omarchy=/usr/share/omarchy/bin/omarchy|readonly omarchy=$fake_omarchy|" \
  "$project_root/bin/omarchy-escalock" > "$test_cli"
chmod 0755 "$test_cli"

[[ $($test_cli status) == off ]]
[[ $($test_cli version) == 2.0.2 ]]
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

"$test_cli" uninstall >/dev/null
/usr/bin/grep -Fxq "maintainer uninstall --user $(/usr/bin/id -un)" "$call_log"
/usr/bin/grep -Fxq "omarchy plugin disable andrewbacon.escalock" "$call_log"
/usr/bin/grep -Fxq "omarchy plugin remove andrewbacon.escalock --yes" "$call_log"

printf '%s\n' inconsistent > "$state_file"
if "$test_cli" uninstall >/dev/null 2>&1; then
  echo "public CLI uninstalled from an inconsistent state" >&2
  exit 1
fi

echo "public CLI mapping tests passed"
