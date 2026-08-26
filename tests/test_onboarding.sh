#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-onboarding-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

checkout="$test_root/checkout with spaces"
mkdir -p "$checkout/bin"
cp "$project_root/manifest.json" "$checkout/manifest.json"

setup_log="$test_root/setup-calls"
launcher_log="$test_root/launcher-calls"
fake_helper="$test_root/helper"
fake_launcher="$test_root/terminal-launcher"

cat > "$checkout/setup.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> $(printf '%q' "$setup_log")
EOF
chmod 0755 "$checkout/setup.sh"

cat > "$fake_launcher" <<EOF
#!/bin/bash
printf '%s\n' "\$#" "\${1:-}" >> $(printf '%q' "$launcher_log")
/usr/bin/bash -c "\${1:-}"
EOF
chmod 0755 "$fake_launcher"

sed \
  -e "s|readonly helper=/usr/local/libexec/omarchy-escalock-helper|readonly helper=$fake_helper|" \
  -e "s|readonly terminal_launcher=/usr/bin/omarchy-launch-floating-terminal-with-presentation|readonly terminal_launcher=$fake_launcher|" \
  "$project_root/bin/omarchy-escalock-onboard" > "$checkout/bin/omarchy-escalock-onboard"
chmod 0755 "$checkout/bin/omarchy-escalock-onboard"

export XDG_STATE_HOME="$test_root/state"

"$checkout/bin/omarchy-escalock-onboard" --automatic
"$checkout/bin/omarchy-escalock-onboard" --automatic
[[ $(wc -l < "$setup_log") == 1 ]]
[[ $(sed -n '1p' "$setup_log") == --enable ]]
[[ $(sed -n '1p' "$launcher_log") == 1 ]]
[[ $(sed -n '2p' "$launcher_log") == *"checkout\\ with\\ spaces/setup.sh --enable" ]]

"$checkout/bin/omarchy-escalock-onboard"
[[ $(wc -l < "$setup_log") == 2 ]]

cat > "$fake_helper" <<'EOF'
#!/bin/bash
[[ ${1:-} == version ]] || exit 2
printf '1.0.0\n'
EOF
chmod 0755 "$fake_helper"

second_state="$test_root/second-state"
XDG_STATE_HOME="$second_state" "$checkout/bin/omarchy-escalock-onboard" --automatic
[[ $(wc -l < "$setup_log") == 2 ]]

if "$checkout/bin/omarchy-escalock-onboard" --unknown >/dev/null 2>&1; then
  echo "onboarding launcher accepted an unknown option" >&2
  exit 1
fi

echo "first-run onboarding tests passed"
