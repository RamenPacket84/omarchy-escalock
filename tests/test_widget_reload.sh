#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d /tmp/omarchy-escalock-widget-reload-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

fake_shell=$test_root/omarchy-shell
fake_restart=$test_root/restart-shell
fake_lock=$test_root/session-locked
fake_sleep=$test_root/sleep
test_policy=$test_root/widget-reload.sh
call_log=$test_root/calls
shell_state=$test_root/shell-state
lock_state=$test_root/lock-state
enabled_state=$test_root/enabled-state
restart_state=$test_root/restart-state
loaded_version=$test_root/loaded-version
desired_version=$test_root/desired-version

printf '#!/bin/bash\nprintf "shell %%s\\n" "$*" >> %q\ncase "${1:-}:${2:-}" in\n  shell:ping) [[ $(cat %q) == running ]] ;;\n  shell:listPlugins) enabled=$(cat %q); [[ $enabled != unavailable ]] || exit 1; printf '\''[{"id":"andrewbacon.escalock","enabled":%%s}]\\n'\'' "$enabled" ;;\n  andrewbacon.escalock:version) cat %q ;;\n  *) exit 2 ;;\nesac\n' \
  "$call_log" "$shell_state" "$enabled_state" "$loaded_version" > "$fake_shell"
printf '#!/bin/bash\nprintf "restart shell\\n" >> %q\n[[ $(cat %q) == success ]] || exit 1\nif [[ $(cat %q) != unavailable ]]; then cp %q %q; fi\n' \
  "$call_log" "$restart_state" "$desired_version" "$desired_version" \
  "$loaded_version" > "$fake_restart"
printf '#!/bin/bash\nprintf "lock check\\n" >> %q\ncase $(cat %q) in locked) exit 0 ;; unlocked) exit 1 ;; *) exit 2 ;; esac\n' \
  "$call_log" "$lock_state" > "$fake_lock"
printf '#!/bin/bash\nexit 0\n' > "$fake_sleep"
chmod 0755 "$fake_shell" "$fake_restart" "$fake_lock" "$fake_sleep"

sed \
  -e "s|^readonly omarchy_shell_command=.*|readonly omarchy_shell_command=$fake_shell|" \
  -e "s|^readonly restart_shell_command=.*|readonly restart_shell_command=$fake_restart|" \
  -e "s|^readonly session_locked_command=.*|readonly session_locked_command=$fake_lock|" \
  -e "s|^readonly reload_sleep_command=.*|readonly reload_sleep_command=$fake_sleep|" \
  "$project_root/lib/widget-reload.sh" > "$test_policy"
# shellcheck disable=SC1090
source "$test_policy"
# setup.sh defines this global before sourcing the policy. Keep that condition
# in the test so function locals cannot accidentally collide with it again.
readonly plugin_id=andrewbacon.escalock

reset_case() {
  : > "$call_log"
  printf 'running\n' > "$shell_state"
  printf 'unlocked\n' > "$lock_state"
  printf 'true\n' > "$enabled_state"
  printf 'success\n' > "$restart_state"
  printf '2.0.6\n' > "$loaded_version"
  printf '2.1.0\n' > "$desired_version"
}

reset_case
output=$(omarchy_escalock_refresh_widget 2.1.0 andrewbacon.escalock 2>&1)
grep -Fq 'EscaLock bar widget restarted at version 2.1.0.' <<< "$output"
grep -Fxq 'restart shell' "$call_log"
grep -Fxq 'shell andrewbacon.escalock version' "$call_log"
if grep -Fq 'rescanPlugins' "$call_log"; then
  echo "successful refresh incorrectly used plugin rescan" >&2
  exit 1
fi

reset_case
printf 'false\n' > "$enabled_state"
output=$(omarchy_escalock_refresh_widget 2.1.0 andrewbacon.escalock 2>&1)
grep -Fq 'disabled EscaLock widget will load the update' <<< "$output"
if grep -Fq 'restart shell' "$call_log"; then
  echo "disabled widget incorrectly restarted the shell" >&2
  exit 1
fi

reset_case
printf 'locked\n' > "$lock_state"
output=$(omarchy_escalock_refresh_widget 2.1.0 andrewbacon.escalock 2>&1)
grep -Fq "After unlocking, run 'omarchy restart shell'" <<< "$output"
grep -Fxq 'shell shell ping' "$call_log"
if grep -Fq 'restart shell' "$call_log"; then
  echo "locked session incorrectly restarted the shell" >&2
  exit 1
fi

reset_case
printf 'unknown\n' > "$lock_state"
output=$(omarchy_escalock_refresh_widget 2.1.0 andrewbacon.escalock 2>&1)
grep -Fq 'session lock state is unknown' <<< "$output"
if grep -Fq 'restart shell' "$call_log"; then
  echo "unknown lock state incorrectly restarted the shell" >&2
  exit 1
fi

reset_case
printf 'stopped\n' > "$shell_state"
output=$(omarchy_escalock_refresh_widget 2.1.0 andrewbacon.escalock 2>&1)
grep -Fq 'will load the update when the Omarchy shell next starts' <<< "$output"
if grep -Fq 'restart shell' "$call_log"; then
  echo "stopped shell incorrectly received a restart request" >&2
  exit 1
fi

reset_case
printf 'failure\n' > "$restart_state"
output=$(omarchy_escalock_refresh_widget 2.1.0 andrewbacon.escalock 2>&1)
grep -Fq 'bar widget could not be refreshed' <<< "$output"
grep -Fq 'omarchy restart shell' <<< "$output"
grep -Fxq 'restart shell' "$call_log"

reset_case
printf 'unavailable\n' > "$desired_version"
output=$(omarchy_escalock_refresh_widget 2.1.0 andrewbacon.escalock 2>&1)
grep -Fq 'bar widget could not be refreshed' <<< "$output"
grep -Fxq 'restart shell' "$call_log"

reset_case
printf 'unavailable\n' > "$enabled_state"
output=$(omarchy_escalock_refresh_widget 2.1.0 andrewbacon.escalock 2>&1)
grep -Fq 'EscaLock bar widget restarted at version 2.1.0.' <<< "$output"
grep -Fxq 'restart shell' "$call_log"

grep -Fq 'function version(): string { return root.expectedSystemVersion }' \
  "$project_root/plugin/BarWidget.qml"
if grep -Fq 'rescanPlugins' "$project_root/lib/widget-reload.sh"; then
  echo "widget refresh policy still uses plugin rescan" >&2
  exit 1
fi

echo "widget reload tests passed"
