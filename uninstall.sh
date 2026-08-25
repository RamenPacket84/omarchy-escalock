#!/bin/bash

set -euo pipefail
umask 077

readonly project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly helper=/usr/local/libexec/omarchy-admin-toggle-helper
readonly cli=/usr/local/bin/omarchy-admin-toggle
readonly config_dir=/etc/omarchy-admin-toggle
readonly policy_file=/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-admin-toggle.policy
readonly recovery_rule=/etc/polkit-1/rules.d/05-omarchy-admin-toggle-recovery.rules
readonly off_rule=/etc/polkit-1/rules.d/10-omarchy-admin-toggle-off.rules
readonly manage_rule=/etc/polkit-1/rules.d/20-omarchy-admin-toggle-manage.rules
readonly omarchy=/usr/share/omarchy/bin/omarchy

target_user=

fail() {
  echo "uninstall.sh: $*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --user)
      target_user=${2:-}
      shift 2
      ;;
    -h | --help)
      echo "Usage: ./uninstall.sh --user USER"
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ $target_user =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "--user must be an explicit safe local username"
passwd_entry=$(/usr/bin/getent passwd "$target_user") || fail "local user does not exist"
IFS=: read -r account _ target_uid target_gid _ target_home _ <<<"$passwd_entry"
[[ $account == "$target_user" && $target_uid =~ ^[0-9]+$ && $target_gid =~ ^[0-9]+$ ]] || fail "account lookup mismatch"

if (( EUID != 0 )); then
  [[ $(id -u) == "$target_uid" ]] || fail "run as the configured target user"
  [[ -x $helper && -x $cli ]] || fail "installed recovery tools are missing"
  case "$($cli status)" in
    enabled) ;;
    disabled)
      echo "Restoring Administrator Mode before uninstall…"
      "$cli" enable
      ;;
    *)
      fail "state is inconsistent; refusing to remove the recovery mechanism"
      ;;
  esac
  [[ $($cli status) == enabled ]] || fail "Administrator Mode could not be verified ON"
  "$omarchy" plugin disable andrewbacon.admin-toggle 2>/dev/null || true
  exec /usr/bin/sudo -- "$project_root/uninstall.sh" --user "$target_user"
fi

[[ -d $config_dir && ! -L $config_dir ]] || fail "trusted project configuration is missing"
[[ -x $helper ]] || fail "helper is missing; do not remove recovery files manually"

grant="/etc/sudoers.d/00_$target_user"
template="$config_dir/sudoers.template"
plugin_dest="$target_home/.config/omarchy/plugins/andrewbacon.admin-toggle"

[[ -f $template && ! -L $template ]] || fail "known sudo template is missing"
/usr/bin/visudo -cf "$template" >/dev/null || fail "known sudo template is invalid"

state=$(PKEXEC_UID="$target_uid" "$helper" status) || fail "helper could not verify state"
[[ $state == enabled ]] || fail "Administrator Mode must be ON before uninstall; state is $state"
[[ -f $grant && ! -L $grant ]] || fail "general sudo grant is not restored"
/usr/bin/cmp -s -- "$grant" "$template" || fail "live sudo grant differs from the known template"
[[ ! -e $off_rule ]] || fail "OFF rule is still present"
/usr/bin/visudo -c >/dev/null || fail "complete sudoers configuration is invalid"

backup_root=/var/backups/omarchy-admin-toggle
timestamp=$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)
backup_dir="$backup_root/$timestamp-uninstall"
/usr/bin/install -d -o root -g root -m 0700 "$backup_dir"
/usr/bin/cp -a -- "$config_dir" "$backup_dir/config"
/usr/bin/install -o root -g root -m 0440 "$grant" "$backup_dir/00_$target_user.restored"

/usr/bin/rm -f -- "$off_rule"
/usr/bin/rm -f -- "$manage_rule" "$recovery_rule" "$policy_file"
/usr/bin/rm -f -- "$cli"
if [[ -e $plugin_dest ]]; then
  [[ -d $plugin_dest && ! -L $plugin_dest ]] || fail "plugin destination is not a normal directory"
  /usr/bin/rm -rf -- "$plugin_dest"
fi
/usr/bin/rm -f -- "$helper"
/usr/bin/rm -rf -- "$config_dir"

/usr/bin/visudo -c >/dev/null || fail "sudoers became invalid after uninstall"
[[ -f $grant ]] || fail "refusing success: restored sudo grant disappeared"

echo "Uninstalled Omarchy Admin Toggle. Administrator access remains ON."
echo "Recovery backup: $backup_dir"
