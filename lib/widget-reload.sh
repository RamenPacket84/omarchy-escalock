# shellcheck shell=bash

readonly omarchy_shell_command=/usr/bin/omarchy-shell
readonly restart_shell_command=/usr/bin/omarchy-restart-shell
readonly session_locked_command=/usr/bin/omarchy-hyprland-session-locked
readonly reload_sleep_command=/usr/bin/sleep

omarchy_escalock_reload_fallback() {
  echo "EscaLock system components were updated, but the bar widget could not be refreshed." >&2
  echo "After unlocking the session, run: omarchy restart shell" >&2
}

omarchy_escalock_refresh_widget() {
  local expected_version=$1 plugin_id=$2
  local enabled_state loaded_version
  local attempt lock_result

  if ! "$omarchy_shell_command" shell ping >/dev/null 2>&1; then
    echo "The EscaLock widget will load the update when the Omarchy shell next starts."
    return 0
  fi

  enabled_state=$("$omarchy_shell_command" shell listPlugins 2>/dev/null |
    /usr/bin/jq -er --arg id "$plugin_id" \
      '.[] | select(.id == $id) | if .enabled then "enabled" else "disabled" end' \
      2>/dev/null) || enabled_state=unknown
  if [[ $enabled_state == disabled ]]; then
    echo "The disabled EscaLock widget will load the update when it is next enabled."
    return 0
  fi

  if "$session_locked_command"; then
    lock_result=0
  else
    lock_result=$?
  fi
  if (( lock_result == 0 )); then
    echo "EscaLock system components were updated while the session is locked." >&2
    echo "After unlocking, run 'omarchy restart shell' if the widget still requests an update." >&2
    return 0
  fi
  if (( lock_result != 1 )); then
    echo "EscaLock could not safely refresh the widget because the session lock state is unknown." >&2
    echo "From the unlocked desktop, run: omarchy restart shell" >&2
    return 0
  fi

  if ! "$restart_shell_command"; then
    omarchy_escalock_reload_fallback
    return 0
  fi

  for (( attempt = 0; attempt < 30; attempt++ )); do
    loaded_version=$("$omarchy_shell_command" "$plugin_id" version 2>/dev/null || true)
    if [[ $loaded_version == "$expected_version" ]]; then
      echo "EscaLock bar widget restarted at version $expected_version."
      return 0
    fi
    "$reload_sleep_command" 0.1
  done

  omarchy_escalock_reload_fallback
  return 0
}
