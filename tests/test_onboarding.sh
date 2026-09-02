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
cli_log="$test_root/cli-calls"
fake_helper="$test_root/helper"
fake_cli="$test_root/omarchy-escalock"
fake_launcher="$test_root/terminal-launcher"
state_file="$test_root/helper-state"
version_file="$test_root/helper-version"

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

cat > "$fake_cli" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> $(printf '%q' "$cli_log")
if [[ \${1:-} == off ]]; then
  printf 'enabled\n' > $(printf '%q' "$state_file")
  printf 'off\n'
fi
EOF
chmod 0755 "$fake_cli"

sed \
  -e "s|readonly helper=/usr/local/libexec/omarchy-escalock-helper|readonly helper=$fake_helper|" \
  -e "s|readonly installed_cli=/usr/local/bin/omarchy-escalock|readonly installed_cli=$fake_cli|" \
  -e "s|readonly terminal_launcher=/usr/bin/omarchy-launch-floating-terminal-with-presentation|readonly terminal_launcher=$fake_launcher|" \
  "$project_root/bin/omarchy-escalock-onboard" > "$checkout/bin/omarchy-escalock-onboard"
chmod 0755 "$checkout/bin/omarchy-escalock-onboard"

export XDG_STATE_HOME="$test_root/state"

# Fresh installation is offered once automatically and remains manually retryable.
"$checkout/bin/omarchy-escalock-onboard" --automatic
"$checkout/bin/omarchy-escalock-onboard" --automatic
[[ $(wc -l < "$setup_log") == 1 ]]
[[ $(sed -n '1p' "$setup_log") == --enable ]]
[[ $(sed -n '1p' "$launcher_log") == 1 ]]
[[ $(sed -n '2p' "$launcher_log") == *"checkout\\ with\\ spaces/setup.sh --enable" ]]

"$checkout/bin/omarchy-escalock-onboard"
[[ $(wc -l < "$setup_log") == 2 ]]

cat > "$fake_helper" <<EOF
#!/bin/bash
case "\${1:-}" in
  version) /usr/bin/cat $(printf '%q' "$version_file") ;;
  status) /usr/bin/cat $(printf '%q' "$state_file") ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$fake_helper"

# Administrator permission review selects the existing transactional path.
printf '2.2.0\n' > "$version_file"
printf 'inconsistent\n' > "$state_file"
"$checkout/bin/omarchy-escalock-onboard" --review-changes
[[ $(sed -n '3p' "$setup_log") == --rebaseline ]]

# A helper version mismatch completes setup directly when Secure Mode is OFF.
printf '2.1.0\n' > "$version_file"
printf 'enabled\n' > "$state_file"
"$checkout/bin/omarchy-escalock-onboard" --finish-update
[[ $(wc -l < "$setup_log") == 4 ]]
[[ -z $(sed -n '4p' "$setup_log") ]]

# Secure Mode is authenticated OFF before an update can replace system files.
printf 'disabled\n' > "$state_file"
"$checkout/bin/omarchy-escalock-onboard" --finish-update
[[ $(sed -n '1p' "$cli_log") == off ]]
[[ $(cat "$state_file") == enabled ]]
[[ $(wc -l < "$setup_log") == 5 ]]

# Matching healthy components are a no-op unless the Git source changed.
printf '2.2.0\n' > "$version_file"
printf 'enabled\n' > "$state_file"
output=$("$checkout/bin/omarchy-escalock-onboard" --run-finish-update)
grep -Fq 'already up to date' <<< "$output"
[[ $(wc -l < "$setup_log") == 5 ]]

printf 'disabled\n' > "$state_file"
before_cli_calls=$(wc -l < "$cli_log")
output=$("$checkout/bin/omarchy-escalock-onboard" --run-finish-update)
grep -Fq 'Secure Mode remains ON' <<< "$output"
[[ $(wc -l < "$setup_log") == 5 ]]
[[ $(wc -l < "$cli_log") == "$before_cli_calls" ]]

# A changed source is installed even at the same version and safely restores
# Administrator Mode first when Secure Mode was ON.
"$checkout/bin/omarchy-escalock-onboard" --run-finish-update --source-changed
[[ $(wc -l < "$setup_log") == 6 ]]
[[ $(tail -n 1 "$cli_log") == off ]]
[[ $(cat "$state_file") == enabled ]]

# Check-for-update launches the stable installed CLI in the presentation terminal.
"$checkout/bin/omarchy-escalock-onboard" --update
[[ $(tail -n 1 "$cli_log") == update ]]

# Automatic onboarding is suppressed for every existing helper version.
second_state="$test_root/second-state"
before_launches=$(wc -l < "$launcher_log")
XDG_STATE_HOME="$second_state" "$checkout/bin/omarchy-escalock-onboard" --automatic
[[ $(wc -l < "$launcher_log") == "$before_launches" ]]

if "$checkout/bin/omarchy-escalock-onboard" --automatic --review-changes >/dev/null 2>&1; then
  echo "onboarding launcher accepted conflicting modes" >&2
  exit 1
fi
if "$checkout/bin/omarchy-escalock-onboard" --source-changed >/dev/null 2>&1; then
  echo "onboarding launcher accepted source-change state outside the internal workflow" >&2
  exit 1
fi
if "$checkout/bin/omarchy-escalock-onboard" --unknown >/dev/null 2>&1; then
  echo "onboarding launcher accepted an unknown option" >&2
  exit 1
fi

echo "guided onboarding and update tests passed"
