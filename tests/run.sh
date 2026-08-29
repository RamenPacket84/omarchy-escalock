#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

bash -n \
  "$project_root/lib/source-origin.sh" \
  "$project_root/setup.sh" \
  "$project_root/bin/omarchy-escalock-maint-common" \
  "$project_root/bin/omarchy-escalock-maint-grant" \
  "$project_root/bin/omarchy-escalock-maint-transaction" \
  "$project_root/bin/omarchy-escalock-maint-preflight" \
  "$project_root/bin/omarchy-escalock-maint-install" \
  "$project_root/bin/omarchy-escalock-maint-uninstall" \
  "$project_root/bin/omarchy-escalock" \
  "$project_root/bin/omarchy-escalock-onboard" \
  "$project_root/tests/test_helper.sh" \
  "$project_root/tests/test_grant_discovery.sh" \
  "$project_root/tests/test_maintenance_layout.sh" \
  "$project_root/tests/test_maintenance_plan.sh" \
  "$project_root/tests/test_maintenance_transaction.sh" \
  "$project_root/tests/test_cli.sh" \
  "$project_root/tests/test_onboarding.sh" \
  "$project_root/tests/test_setup_options.sh" \
  "$project_root/tests/test_source_origin.sh"

/usr/bin/xmllint --noout "$project_root/polkit/com.github.andrewbacon.omarchy-escalock.policy"
/usr/share/omarchy/bin/omarchy plugin validate "$project_root"
/usr/bin/qmlformat -n "$project_root/plugin/BarWidget.qml" >/dev/null

manifest_version=$(/usr/bin/jq -er '.version' "$project_root/manifest.json")
helper_version=$("$project_root/build/omarchy-escalock-helper" version)
qml_version=$(/usr/bin/sed -n \
  's/.*expectedSystemVersion: "\([^"]*\)".*/\1/p' \
  "$project_root/plugin/BarWidget.qml")
[[ -n $manifest_version && $manifest_version == "$helper_version" &&
   $manifest_version == "$qml_version" ]] || {
  echo "manifest, helper, and widget versions do not agree" >&2
  exit 1
}

node "$project_root/tests/test_rules.js"
node "$project_root/tests/test_state_model.js"
"$project_root/tests/test_helper.sh"
"$project_root/tests/test_grant_discovery.sh"
"$project_root/tests/test_maintenance_layout.sh"
"$project_root/tests/test_maintenance_plan.sh"
"$project_root/tests/test_maintenance_transaction.sh"
"$project_root/tests/test_cli.sh"
"$project_root/tests/test_onboarding.sh"
"$project_root/tests/test_setup_options.sh"
"$project_root/tests/test_source_origin.sh"

if rg -n '(/bin/(ba)?sh|eval[[:space:]]*\(|system[[:space:]]*\(|popen[[:space:]]*\()' \
  "$project_root/src/omarchy-escalock-helper.c"; then
  echo "privileged helper contains a forbidden shell execution primitive" >&2
  exit 1
fi

echo "all tests passed"
