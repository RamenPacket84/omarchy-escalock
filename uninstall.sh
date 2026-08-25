#!/bin/bash

set -euo pipefail
umask 077

readonly project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly helper=/usr/local/libexec/omarchy-escalock-helper
readonly cli=/usr/local/bin/omarchy-escalock
readonly config_dir=/etc/omarchy-escalock
readonly policy_file=/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-escalock.policy
readonly recovery_rule=/etc/polkit-1/rules.d/05-omarchy-escalock-recovery.rules
readonly off_rule=/etc/polkit-1/rules.d/10-omarchy-escalock-off.rules
readonly manage_rule=/etc/polkit-1/rules.d/20-omarchy-escalock-manage.rules
readonly omarchy=/usr/share/omarchy/bin/omarchy
readonly legacy_helper=/usr/local/libexec/omarchy-admin-toggle-helper
readonly legacy_cli=/usr/local/bin/omarchy-admin-toggle
readonly legacy_config_dir=/etc/omarchy-admin-toggle
readonly legacy_policy_file=/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-admin-toggle.policy
readonly legacy_recovery_rule=/etc/polkit-1/rules.d/05-omarchy-admin-toggle-recovery.rules
readonly legacy_off_rule=/etc/polkit-1/rules.d/10-omarchy-admin-toggle-off.rules
readonly legacy_manage_rule=/etc/polkit-1/rules.d/20-omarchy-admin-toggle-manage.rules

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
    off) ;;
    on)
      echo "Restoring Administrator Mode before uninstall…"
      "$cli" off
      ;;
    *)
      fail "state is inconsistent; refusing to remove the recovery mechanism"
      ;;
  esac
  [[ $($cli status) == off ]] || fail "Administrator Mode could not be verified ON"
  "$omarchy" plugin disable andrewbacon.escalock 2>/dev/null || true
  "$omarchy" plugin disable andrewbacon.admin-toggle 2>/dev/null || true
  exec /usr/bin/sudo -- "$project_root/uninstall.sh" --user "$target_user"
fi

[[ -d $config_dir && ! -L $config_dir ]] || fail "trusted project configuration is missing"
[[ -x $helper ]] || fail "helper is missing; do not remove recovery files manually"

grant="/etc/sudoers.d/00_$target_user"
template="$config_dir/sudoers.template"
plugin_dest="$target_home/.config/omarchy/plugins/andrewbacon.escalock"
legacy_plugin_dest="$target_home/.config/omarchy/plugins/andrewbacon.admin-toggle"

[[ -f $template && ! -L $template ]] || fail "known sudo template is missing"
/usr/bin/visudo -cf "$template" >/dev/null || fail "known sudo template is invalid"

state=$(PKEXEC_UID="$target_uid" "$helper" status) || fail "helper could not verify state"
[[ $state == enabled ]] || fail "Administrator Mode must be ON before uninstall; state is $state"
[[ -f $grant && ! -L $grant ]] || fail "general sudo grant is not restored"
/usr/bin/cmp -s -- "$grant" "$template" || fail "live sudo grant differs from the known template"
[[ ! -e $off_rule ]] || fail "OFF rule is still present"
/usr/bin/visudo -c >/dev/null || fail "complete sudoers configuration is invalid"

[[ ! -e $legacy_off_rule ]] || fail "legacy OFF rule is still present"
if [[ -e $legacy_config_dir || -e $legacy_helper ]]; then
  [[ -d $legacy_config_dir && ! -L $legacy_config_dir ]] ||
    fail "legacy configuration is incomplete or unsafe"
  [[ -x $legacy_helper && ! -L $legacy_helper ]] ||
    fail "legacy helper is incomplete or unsafe"
  legacy_state=$(PKEXEC_UID="$target_uid" "$legacy_helper" status) ||
    fail "legacy helper state could not be verified"
  [[ $legacy_state == enabled ]] || fail "legacy Administrator Mode is not ON"
fi

backup_root=/var/backups/omarchy-escalock
timestamp=$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)
backup_dir="$backup_root/$timestamp-uninstall"
/usr/bin/install -d -o root -g root -m 0700 "$backup_dir"
/usr/bin/cp -a -- "$config_dir" "$backup_dir/config"
/usr/bin/install -o root -g root -m 0440 "$grant" "$backup_dir/00_$target_user.restored"
for legacy_path in \
  "$legacy_config_dir" "$legacy_policy_file" "$legacy_recovery_rule" \
  "$legacy_manage_rule" "$legacy_cli" "$legacy_helper" "$legacy_plugin_dest"; do
  if [[ -e $legacy_path || -L $legacy_path ]]; then
    [[ ! -L $legacy_path ]] || fail "refusing to back up legacy symlink: $legacy_path"
    /usr/bin/install -d -o root -g root -m 0700 "$backup_dir/legacy-leftovers"
    /usr/bin/cp -a -- "$legacy_path" "$backup_dir/legacy-leftovers/"
  fi
done

/usr/bin/rm -f -- "$off_rule"
/usr/bin/rm -f -- "$manage_rule" "$recovery_rule" "$policy_file"
/usr/bin/rm -f -- "$cli"
if [[ -e $plugin_dest ]]; then
  [[ -d $plugin_dest && ! -L $plugin_dest ]] || fail "plugin destination is not a normal directory"
  /usr/bin/rm -rf -- "$plugin_dest"
fi
/usr/bin/rm -f -- "$legacy_off_rule" "$legacy_manage_rule" "$legacy_recovery_rule" \
  "$legacy_policy_file" "$legacy_cli" "$legacy_helper"
if [[ -e $legacy_plugin_dest ]]; then
  [[ -d $legacy_plugin_dest && ! -L $legacy_plugin_dest ]] ||
    fail "legacy plugin destination is not a normal directory"
  /usr/bin/rm -rf -- "$legacy_plugin_dest"
fi
if [[ -e $legacy_config_dir ]]; then
  [[ -d $legacy_config_dir && ! -L $legacy_config_dir ]] ||
    fail "legacy configuration is not a normal directory"
  /usr/bin/rm -rf -- "$legacy_config_dir"
fi
/usr/bin/rm -f -- "$helper"
/usr/bin/rm -rf -- "$config_dir"

/usr/bin/visudo -c >/dev/null || fail "sudoers became invalid after uninstall"
[[ -f $grant ]] || fail "refusing success: restored sudo grant disappeared"

echo "Uninstalled EscaLock. Administrator access remains ON."
echo "Recovery backup: $backup_dir"
