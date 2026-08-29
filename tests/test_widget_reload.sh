#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-widget-reload-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

fake_shell=$test_root/omarchy-shell
fake_lock=$test_root/session-locked
fake_sleep=$test_root/sleep
test_policy=$test_root/widget-reload.sh
call_log=$test_root/calls
shell_state=$test_root/shell-state
lock_state=$test_root/lock-state
enabled_state=$test_root/enabled-state
rescan_state=$test_root/rescan-state
loaded_version=$test_root/loaded-version
desired_version=$test_root/desired-version

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\ncase "${1:-}:${2:-}" in\n  shell:ping) [[ $(cat %q) == running ]] ;;\n  shell:listPlugins) enabled=$(cat %q); printf '\''[{"id":"andrewbacon.escalock","enabled":%%s}]\\n'\'' "$enabled" ;;\n  shell:rescanPlugins) [[ $(cat %q) == success ]] || exit 1; if [[ $(cat %q) != false ]]; then cp %q %q; fi ;;\n  andrewbacon.escalock:version) cat %q ;;\n  *) exit 2 ;;\nesac\n' \
  "$call_log" "$shell_state" "$enabled_state" "$rescan_state" "$desired_version" \
  "$desired_version" "$loaded_version" "$loaded_version" > "$fake_shell"
printf '#!/bin/bash\ncase $(cat %q) in locked) exit 0 ;; unlocked) exit 1 ;; *) exit 2 ;; esac\n' \
  "$lock_state" > "$fake_lock"
printf '#!/bin/bash\nexit 0\n' > "$fake_sleep"
chmod 0755 "$fake_shell" "$fake_lock" "$fake_sleep"

sed \
  -e "s|^readonly omarchy_shell_command=.*|readonly omarchy_shell_command=$fake_shell|" \
  -e "s|^readonly session_locked_command=.*|readonly session_locked_command=$fake_lock|" \
  -e "s|^readonly reload_sleep_command=.*|readonly reload_sleep_command=$fake_sleep|" \
  "$project_root/lib/widget-reload.sh" > "$test_policy"
# shellcheck disable=SC1090
source "$test_policy"

reset_case() {
  : > "$call_log"
  printf 'running\n' > "$shell_state"
  printf 'unlocked\n' > "$lock_state"
  printf 'true\n' > "$enabled_state"
  printf 'success\n' > "$rescan_state"
  printf '2.0.4\n' > "$loaded_version"
  printf '2.0.5\n' > "$desired_version"
}

reset_case
output=$(omarchy_escalock_refresh_widget 2.0.5 andrewbacon.escalock 2>&1)
grep -Fq 'EscaLock bar widget refreshed to version 2.0.5.' <<< "$output"
grep -Fxq 'shell rescanPlugins' "$call_log"
grep -Fxq 'andrewbacon.escalock version' "$call_log"

reset_case
printf 'false\n' > "$enabled_state"
output=$(omarchy_escalock_refresh_widget 2.0.5 andrewbacon.escalock 2>&1)
grep -Fxq 'shell rescanPlugins' "$call_log"
if grep -Fq 'andrewbacon.escalock version' "$call_log"; then
  echo "disabled widget was incorrectly polled after rescan" >&2
  exit 1
fi

reset_case
printf 'locked\n' > "$lock_state"
output=$(omarchy_escalock_refresh_widget 2.0.5 andrewbacon.escalock 2>&1)
grep -Fq "After unlocking, run 'omarchy restart shell'" <<< "$output"
grep -Fxq 'shell ping' "$call_log"
if grep -Fq 'shell rescanPlugins' "$call_log"; then
  echo "locked session received a rescan request" >&2
  exit 1
fi

reset_case
printf 'unknown\n' > "$lock_state"
output=$(omarchy_escalock_refresh_widget 2.0.5 andrewbacon.escalock 2>&1)
grep -Fq 'session lock state is unknown' <<< "$output"
if grep -Fq 'shell rescanPlugins' "$call_log"; then
  echo "unknown lock state received a rescan request" >&2
  exit 1
fi

reset_case
printf 'stopped\n' > "$shell_state"
output=$(omarchy_escalock_refresh_widget 2.0.5 andrewbacon.escalock 2>&1)
grep -Fq 'will load the update when the Omarchy shell next starts' <<< "$output"
if grep -Fq 'shell rescanPlugins' "$call_log"; then
  echo "stopped shell received a rescan request" >&2
  exit 1
fi

reset_case
printf 'failure\n' > "$rescan_state"
output=$(omarchy_escalock_refresh_widget 2.0.5 andrewbacon.escalock 2>&1)
grep -Fq 'bar widget could not be refreshed' <<< "$output"
grep -Fq 'omarchy restart shell' <<< "$output"

reset_case
printf 'false\n' > "$desired_version"
output=$(omarchy_escalock_refresh_widget 2.0.5 andrewbacon.escalock 2>&1)
grep -Fq 'bar widget could not be refreshed' <<< "$output"

grep -Fq 'function version(): string { return root.expectedSystemVersion }' \
  "$project_root/plugin/BarWidget.qml"

echo "widget reload tests passed"
