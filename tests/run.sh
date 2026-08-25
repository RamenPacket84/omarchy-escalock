#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

bash -n \
  "$project_root/bin/omarchy-admin-toggle" \
  "$project_root/install.sh" \
  "$project_root/uninstall.sh" \
  "$project_root/tests/test_helper.sh"

/usr/bin/xmllint --noout "$project_root/polkit/com.github.andrewbacon.omarchy-admin-toggle.policy"
/usr/share/omarchy/bin/omarchy plugin validate "$project_root/plugin"
/usr/bin/qmlformat -n "$project_root/plugin/BarWidget.qml" >/dev/null
node "$project_root/tests/test_rules.js"
node "$project_root/tests/test_state_model.js"
"$project_root/tests/test_helper.sh"

if rg -n '(/bin/(ba)?sh|eval[[:space:]]*\(|system[[:space:]]*\(|popen[[:space:]]*\()' \
  "$project_root/src/omarchy-admin-toggle-helper.c"; then
  echo "privileged helper contains a forbidden shell execution primitive" >&2
  exit 1
fi

echo "all tests passed"
