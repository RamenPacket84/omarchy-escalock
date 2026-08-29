#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
setup="$project_root/setup.sh"

help_output=$("$setup" --help)
/usr/bin/grep -Fqx \
  'Usage: ./setup.sh [--enable] [--check] [--development]' \
  <<< "$help_output"

for deprecated in --upgrade --dry-run --user; do
  if "$setup" "$deprecated" >/dev/null 2>&1; then
    echo "setup accepted removed option: $deprecated" >&2
    exit 1
  fi
done

check_exit_line=$(/usr/bin/grep -nF \
  'EscaLock setup check completed without installing system files.' "$setup")
check_exit_line=${check_exit_line%%:*}
widget_reload_line=$(/usr/bin/grep -nF \
  'omarchy_escalock_refresh_widget "$version" "$plugin_id"' "$setup")
widget_reload_line=${widget_reload_line%%:*}
(( check_exit_line < widget_reload_line )) || {
  echo "setup check mode can reach the widget reload path" >&2
  exit 1
}
plugin_enable_line=$(/usr/bin/grep -nF '$omarchy plugin enable "$plugin_id"' "$setup")
plugin_enable_line=${plugin_enable_line%%:*}
(( plugin_enable_line < widget_reload_line )) || {
  echo "setup reloads the widget before enabling it" >&2
  exit 1
}

echo "setup option tests passed"
