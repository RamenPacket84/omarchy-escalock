#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-update-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

test_home="$test_root/home"
plugin_dir="$test_home/.config/omarchy/plugins/andrewbacon.escalock"
mkdir -p "$plugin_dir/bin"

fake_helper="$test_root/helper"
fake_uninstaller="$test_root/uninstaller"
fake_pkexec="$test_root/pkexec"
fake_sudo="$test_root/sudo"
fake_omarchy="$test_root/omarchy"
fake_git="$test_root/git"
test_cli="$test_root/omarchy-escalock"
onboarding="$plugin_dir/bin/omarchy-escalock-onboard"
commit_file="$test_root/commit"
next_commit_file="$test_root/next-commit"
update_mode_file="$test_root/update-mode"
call_log="$test_root/calls"
onboarding_log="$test_root/onboarding-calls"
state_file="$test_root/state"

printf '%s\n' enabled > "$state_file"
printf '%040d\n' 1 > "$commit_file"
printf '%040d\n' 2 > "$next_commit_file"
printf '%s\n' same > "$update_mode_file"

cat > "$fake_helper" <<EOF
#!/bin/bash
if [[ \${1:-} == version ]]; then printf '2.2.0\n'; exit 0; fi
[[ \${1:-} == status ]] || exit 2
/usr/bin/cat $(printf '%q' "$state_file")
EOF
cat > "$fake_uninstaller" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$fake_pkexec" <<'EOF'
#!/bin/bash
exit 2
EOF
cat > "$fake_sudo" <<'EOF'
#!/bin/bash
exit 2
EOF
cat > "$fake_git" <<EOF
#!/bin/bash
[[ \${1:-} == -C ]] || exit 2
directory=\${2:-}
shift 2
[[ \$directory == $(printf '%q' "$plugin_dir") && \${1:-} == rev-parse ]] || exit 2
case "\${2:-}" in
  --show-toplevel) printf '%s\n' $(printf '%q' "$plugin_dir") ;;
  HEAD) /usr/bin/cat $(printf '%q' "$commit_file") ;;
  *) exit 2 ;;
esac
EOF
cat > "$fake_omarchy" <<EOF
#!/bin/bash
printf 'omarchy %s\n' "\$*" >> $(printf '%q' "$call_log")
[[ \${1:-} == plugin && \${2:-} == update && \${3:-} == andrewbacon.escalock ]] || exit 2
case \$(/usr/bin/cat $(printf '%q' "$update_mode_file")) in
  same) exit 0 ;;
  change) /usr/bin/cp $(printf '%q' "$next_commit_file") $(printf '%q' "$commit_file") ;;
  fail) exit 1 ;;
  change-fail)
    /usr/bin/cp $(printf '%q' "$next_commit_file") $(printf '%q' "$commit_file")
    exit 1
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$onboarding" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> $(printf '%q' "$onboarding_log")
EOF
chmod 0755 "$fake_helper" "$fake_uninstaller" "$fake_pkexec" "$fake_sudo" \
  "$fake_git" "$fake_omarchy" "$onboarding"

sed \
  -e "s|readonly helper=/usr/local/libexec/omarchy-escalock-helper|readonly helper=$fake_helper|" \
  -e "s|readonly uninstaller=/usr/local/libexec/omarchy-escalock-maint-uninstall|readonly uninstaller=$fake_uninstaller|" \
  -e "s|readonly pkexec=/usr/bin/pkexec|readonly pkexec=$fake_pkexec|" \
  -e "s|readonly sudo=/usr/bin/sudo|readonly sudo=$fake_sudo|" \
  -e "s|readonly omarchy=/usr/share/omarchy/bin/omarchy|readonly omarchy=$fake_omarchy|" \
  -e "s|readonly git=/usr/bin/git|readonly git=$fake_git|" \
  -e '/^interactive() {$/,/^}$/c\
interactive() { return 0; }' \
  "$project_root/bin/omarchy-escalock" > "$test_cli"
chmod 0755 "$test_cli"

export HOME="$test_home"

# An up-to-date checkout still asks the guided finisher to verify component state.
"$test_cli" update >/dev/null
[[ $(tail -n 1 "$onboarding_log") == --run-finish-update ]]

# A changed Git HEAD forces setup even if the manifest version was not bumped.
printf '%040d\n' 1 > "$commit_file"
printf '%s\n' change > "$update_mode_file"
"$test_cli" update >/dev/null
[[ $(tail -n 1 "$onboarding_log") == '--run-finish-update --source-changed' ]]

# A failed update that changed nothing never reaches setup.
before_calls=$(wc -l < "$onboarding_log")
printf '%040d\n' 1 > "$commit_file"
printf '%s\n' fail > "$update_mode_file"
if "$test_cli" update >/dev/null 2>&1; then
  echo "failed plugin update unexpectedly succeeded" >&2
  exit 1
fi
[[ $(wc -l < "$onboarding_log") == "$before_calls" ]]

# Omarchy may update files successfully but fail to rescan a stopped shell.
printf '%040d\n' 1 > "$commit_file"
printf '%s\n' change-fail > "$update_mode_file"
output=$("$test_cli" update 2>&1)
grep -Fq 'Continuing with verified EscaLock system setup.' <<< "$output"
[[ $(tail -n 1 "$onboarding_log") == '--run-finish-update --source-changed' ]]

# Missing update infrastructure is rejected before Git or privilege work.
mv "$onboarding" "$onboarding.disabled"
if "$test_cli" update >/dev/null 2>&1; then
  echo "update accepted a missing onboarding launcher" >&2
  exit 1
fi

grep -Fxq 'omarchy plugin update andrewbacon.escalock' "$call_log"
echo "public guided update workflow tests passed"
