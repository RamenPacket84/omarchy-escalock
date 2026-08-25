#!/bin/bash

set -euo pipefail
umask 077

readonly project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly helper_source="$project_root/build/omarchy-escalock-helper"
readonly plugin_source="$project_root/plugin"
readonly omarchy=/usr/share/omarchy/bin/omarchy
readonly helper=/usr/local/libexec/omarchy-escalock-helper
readonly cli=/usr/local/bin/omarchy-escalock
readonly config_dir=/etc/omarchy-escalock
readonly sudoers_dir=/etc/sudoers.d
readonly policy_file=/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-escalock.policy
readonly recovery_rule=/etc/polkit-1/rules.d/05-omarchy-escalock-recovery.rules
readonly off_rule=/etc/polkit-1/rules.d/10-omarchy-escalock-off.rules
readonly manage_rule=/etc/polkit-1/rules.d/20-omarchy-escalock-manage.rules
readonly legacy_helper=/usr/local/libexec/omarchy-admin-toggle-helper
readonly legacy_cli=/usr/local/bin/omarchy-admin-toggle
readonly legacy_config_dir=/etc/omarchy-admin-toggle
readonly legacy_policy_file=/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-admin-toggle.policy
readonly legacy_recovery_rule=/etc/polkit-1/rules.d/05-omarchy-admin-toggle-recovery.rules
readonly legacy_off_rule=/etc/polkit-1/rules.d/10-omarchy-admin-toggle-off.rules
readonly legacy_manage_rule=/etc/polkit-1/rules.d/20-omarchy-admin-toggle-manage.rules

target_user=
dry_run=false

usage() {
  cat <<'USAGE'
Usage: ./install.sh --user USER [--dry-run]

Installs the privileged helper, Polkit policy and rules, CLI, and Omarchy
bar-widget plugin. Administrator Mode is left ON. The target account must
already have exactly one dedicated /etc/sudoers.d/00_USER grant containing:

  USER ALL=(ALL) ALL
USAGE
}

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --user)
      target_user=${2:-}
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ $target_user =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "--user must be an explicit safe local username"

passwd_entry=$(/usr/bin/getent passwd "$target_user") || fail "local user does not exist: $target_user"
IFS=: read -r account _ target_uid target_gid _ target_home target_shell <<<"$passwd_entry"
[[ $account == "$target_user" ]] || fail "account lookup mismatch"
[[ $target_uid =~ ^[0-9]+$ && $target_gid =~ ^[0-9]+$ ]] || fail "account has invalid numeric IDs"
(( target_uid >= 1000 && target_uid != 65534 )) || fail "target UID must be a normal local user"
[[ $target_home == /* && $target_home != / ]] || fail "target home is unsafe: $target_home"
[[ -d $target_home && ! -L $target_home ]] || fail "target home is not a real directory"
[[ $(/usr/bin/stat -c %u "$target_home") == "$target_uid" ]] || fail "target user does not own $target_home"
[[ $target_shell == /* ]] || fail "target account shell is invalid"

version=$($omarchy version) || fail "Omarchy is not available"
[[ $version == 4.* ]] || fail "Omarchy 4.x is required; found $version"

command -v /usr/bin/gcc >/dev/null || fail "gcc is required to build the helper"
command -v /usr/bin/visudo >/dev/null || fail "visudo is required"
command -v /usr/bin/pkaction >/dev/null || fail "pkaction is required"
command -v /usr/bin/pkexec >/dev/null || fail "pkexec is required"
command -v /usr/bin/jq >/dev/null || fail "jq is required"

if (( EUID != 0 )); then
  [[ $(id -u) == "$target_uid" ]] || fail "run this as the selected target user before sudo"
  make -C "$project_root" clean all
  "$omarchy" plugin validate "$plugin_source"
  if [[ -x $legacy_helper || -x $legacy_cli ]]; then
    [[ -x $legacy_helper && -x $legacy_cli ]] ||
      fail "legacy installation is incomplete; refusing automatic migration"
    legacy_state=$($legacy_cli status) ||
      fail "legacy state could not be verified; refusing automatic migration"
    [[ $legacy_state == enabled ]] ||
      fail "legacy Administrator Mode must be ON; run: omarchy-admin-toggle enable"
  fi
  if [[ $dry_run == true ]]; then
    echo "Preflight passed for $target_user (UID $target_uid) on Omarchy $version."
    echo "Dry run: no files were installed."
    exit 0
  fi
  exec /usr/bin/sudo -- "$project_root/install.sh" --user "$target_user"
fi

[[ $dry_run == false ]] || fail "run --dry-run without sudo"
[[ -x $helper_source && ! -L $helper_source ]] || fail "build the helper as the target user first"
[[ -f $plugin_source/manifest.json ]] || fail "plugin source is incomplete"

if [[ -n ${SUDO_UID:-} ]]; then
  [[ $SUDO_UID == "$target_uid" ]] || fail "sudo caller does not match --user"
elif [[ -n ${PKEXEC_UID:-} ]]; then
  [[ $PKEXEC_UID == "$target_uid" ]] || fail "pkexec caller does not match --user"
fi

grant="$sudoers_dir/00_$target_user"
plugin_dest="$target_home/.config/omarchy/plugins/andrewbacon.escalock"
legacy_plugin_dest="$target_home/.config/omarchy/plugins/andrewbacon.admin-toggle"
shell_config="$target_home/.config/omarchy/shell.json"

legacy_present=false
for legacy_path in \
  "$legacy_helper" "$legacy_cli" "$legacy_config_dir" "$legacy_policy_file" \
  "$legacy_recovery_rule" "$legacy_off_rule" "$legacy_manage_rule" "$legacy_plugin_dest"; do
  if [[ -e $legacy_path || -L $legacy_path ]]; then
    legacy_present=true
    break
  fi
done

[[ ! -e $config_dir ]] || fail "$config_dir already exists; uninstall the existing deployment first"
[[ ! -e $off_rule ]] || fail "an Admin-OFF rule already exists without project configuration"
[[ ! -e $helper && ! -e $cli ]] || fail "helper or CLI destination already exists"
[[ ! -e $policy_file && ! -e $recovery_rule && ! -e $manage_rule ]] || fail "Polkit destination already exists"
[[ ! -e $plugin_dest ]] || fail "plugin destination already exists: $plugin_dest"

if [[ $legacy_present == true ]]; then
  [[ -x $legacy_helper && ! -L $legacy_helper ]] || fail "legacy helper is missing or unsafe"
  [[ -x $legacy_cli && ! -L $legacy_cli ]] || fail "legacy CLI is missing or unsafe"
  [[ -d $legacy_config_dir && ! -L $legacy_config_dir ]] || fail "legacy configuration is missing or unsafe"
  [[ -f $legacy_policy_file && ! -L $legacy_policy_file ]] || fail "legacy policy is missing or unsafe"
  [[ -f $legacy_recovery_rule && ! -L $legacy_recovery_rule ]] || fail "legacy recovery rule is missing or unsafe"
  [[ -f $legacy_manage_rule && ! -L $legacy_manage_rule ]] || fail "legacy manage rule is missing or unsafe"
  [[ ! -e $legacy_off_rule ]] || fail "legacy Administrator Mode must be ON before migration"
  [[ -d $legacy_plugin_dest && ! -L $legacy_plugin_dest ]] || fail "legacy plugin is missing or unsafe"
  [[ -f $shell_config && ! -L $shell_config ]] || fail "Omarchy shell configuration is missing or unsafe"
  [[ $(/usr/bin/stat -c %u "$shell_config") == "$target_uid" ]] || fail "target user does not own shell.json"
  legacy_state=$(PKEXEC_UID="$target_uid" "$legacy_helper" status) ||
    fail "legacy helper could not verify its state"
  [[ $legacy_state == enabled ]] || fail "legacy Administrator Mode is not ON"
  expected_legacy_config=$'TARGET_USER='"$target_user"$'\nTARGET_UID='"$target_uid"
  [[ $(<"$legacy_config_dir/config") == "$expected_legacy_config" ]] ||
    fail "legacy configuration belongs to a different account"
fi

[[ -f $grant && ! -L $grant ]] || fail "expected dedicated sudo grant is missing: $grant"
[[ $(/usr/bin/stat -c '%u:%g:%a' "$grant") == 0:0:440 ]] || fail "$grant must be root:root mode 0440"
expected_rule="$target_user ALL=(ALL) ALL"
[[ $(/usr/bin/wc -l < "$grant") == 1 && $(<"$grant") == "$expected_rule" ]] ||
  fail "$grant has unexpected contents; refusing to replace or reinterpret it"
/usr/bin/visudo -cf "$grant" >/dev/null || fail "existing grant fails visudo validation"
/usr/bin/visudo -c >/dev/null || fail "complete sudoers configuration is invalid"

backup_root=/var/backups/omarchy-escalock
timestamp=$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)
backup_dir="$backup_root/$timestamp-install"
/usr/bin/install -d -o root -g root -m 0700 "$backup_dir"
/usr/bin/install -o root -g root -m 0440 "$grant" "$backup_dir/00_$target_user.original"
if [[ $legacy_present == true ]]; then
  /usr/bin/cp -a -- "$legacy_config_dir" "$backup_dir/legacy-config"
  /usr/bin/cp -a -- "$legacy_policy_file" "$legacy_recovery_rule" \
    "$legacy_manage_rule" "$legacy_helper" "$legacy_cli" "$backup_dir/"
  /usr/bin/cp -a -- "$legacy_plugin_dest" "$backup_dir/legacy-plugin"
  /usr/bin/cp -a -- "$shell_config" "$backup_dir/shell.json.before-migration"
fi

staging=$(/usr/bin/mktemp -d /tmp/omarchy-escalock-install.XXXXXX)
install_started=false
install_complete=false
shell_config_changed=false
legacy_cleanup_started=false
legacy_was_enabled=false
cleanup() {
  local rc=$?
  /usr/bin/rm -rf -- "$staging"
  if [[ $rc -ne 0 && $install_started == true && $install_complete == false ]]; then
    if [[ $legacy_cleanup_started == true ]]; then
      echo "Legacy cleanup was interrupted; retaining the verified EscaLock recovery path." >&2
    else
      echo "Installation failed; removing newly installed EscaLock files (sudo grant remains ON)." >&2
      if [[ $shell_config_changed == true ]]; then
        /usr/bin/cp -a -- "$backup_dir/shell.json.before-migration" "$shell_config"
      fi
      /usr/bin/rm -f -- "$off_rule" "$manage_rule" "$recovery_rule" "$policy_file" "$cli" "$helper"
      if [[ -e $plugin_dest && -d $plugin_dest && ! -L $plugin_dest ]]; then
        /usr/bin/rm -rf -- "$plugin_dest"
      fi
      /usr/bin/rm -rf -- "$config_dir"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

/usr/bin/sed "s/@@TARGET_USER@@/$target_user/g" \
  "$project_root/polkit/05-omarchy-escalock-recovery.rules.in" > "$staging/recovery.rules"
/usr/bin/sed "s/@@TARGET_USER@@/$target_user/g" \
  "$project_root/polkit/10-omarchy-escalock-off.rules.in" > "$staging/off.rules"
/usr/bin/sed "s/@@TARGET_USER@@/$target_user/g" \
  "$project_root/polkit/20-omarchy-escalock-manage.rules.in" > "$staging/manage.rules"

install_started=true
/usr/bin/install -d -o root -g root -m 0700 "$config_dir"
/usr/bin/printf 'TARGET_USER=%s\nTARGET_UID=%s\n' "$target_user" "$target_uid" > "$staging/config"
/usr/bin/install -o root -g root -m 0600 "$staging/config" "$config_dir/config"
/usr/bin/install -o root -g root -m 0440 "$grant" "$config_dir/sudoers.template"
/usr/bin/install -o root -g root -m 0644 "$staging/off.rules" \
  "$config_dir/10-omarchy-escalock-off.rules.template"
/usr/bin/install -o root -g root -m 0644 "$staging/recovery.rules" \
  "$config_dir/05-omarchy-escalock-recovery.rules.template"
/usr/bin/install -o root -g root -m 0644 "$staging/manage.rules" \
  "$config_dir/20-omarchy-escalock-manage.rules.template"
/usr/bin/install -o root -g root -m 0644 \
  "$project_root/polkit/com.github.andrewbacon.omarchy-escalock.policy" \
  "$config_dir/com.github.andrewbacon.omarchy-escalock.policy.template"

/usr/bin/install -o root -g root -m 0644 \
  "$project_root/polkit/com.github.andrewbacon.omarchy-escalock.policy" "$policy_file"
/usr/bin/install -o root -g root -m 0644 "$staging/recovery.rules" "$recovery_rule"
/usr/bin/install -o root -g root -m 0644 "$staging/manage.rules" "$manage_rule"
/usr/bin/install -d -o root -g root -m 0755 /usr/local/libexec
/usr/bin/install -o root -g root -m 04755 "$helper_source" "$helper"
/usr/bin/install -o root -g root -m 0755 "$project_root/bin/omarchy-escalock" "$cli"

/usr/bin/install -d -o "$target_uid" -g "$target_gid" -m 0755 \
  "$target_home/.config/omarchy/plugins"
/usr/bin/cp -a -- "$plugin_source" "$plugin_dest"
/usr/bin/chown -R "$target_uid:$target_gid" "$plugin_dest"
/usr/bin/find "$plugin_dest" -type d -exec /usr/bin/chmod 0755 {} +
/usr/bin/find "$plugin_dest" -type f -exec /usr/bin/chmod 0644 {} +

runuser -u "$target_user" -- "$omarchy" plugin validate "$plugin_dest"

if [[ $legacy_present == true ]]; then
  legacy_id_count=$(/usr/bin/jq \
    '[.. | objects | select(.id? == "andrewbacon.admin-toggle")] | length' \
    "$shell_config")
  (( legacy_id_count <= 1 )) ||
    fail "legacy plugin ID appears more than once in shell.json"
  if (( legacy_id_count == 1 )); then
    /usr/bin/sed 's/andrewbacon\.admin-toggle/andrewbacon.escalock/g' \
      "$shell_config" > "$staging/shell.json"
    /usr/bin/jq -e . "$staging/shell.json" >/dev/null || fail "migrated shell.json is invalid"
    shell_mode=$(/usr/bin/stat -c %a "$shell_config")
    /usr/bin/install -o "$target_uid" -g "$target_gid" -m "$shell_mode" \
      "$staging/shell.json" "$shell_config"
    shell_config_changed=true
    legacy_was_enabled=true
  fi
fi

/usr/bin/pkaction --verbose --action-id com.github.andrewbacon.omarchy-escalock.enable >/dev/null
/usr/bin/pkaction --verbose --action-id com.github.andrewbacon.omarchy-escalock.disable >/dev/null
status=$(runuser -u "$target_user" -- "$helper" status)
[[ $status == enabled ]] || fail "post-install state is $status, expected enabled"
/usr/bin/visudo -c >/dev/null || fail "post-install sudoers validation failed"

if [[ $legacy_present == true ]]; then
  legacy_cleanup_started=true
  /usr/bin/rm -f -- "$legacy_off_rule" "$legacy_manage_rule" "$legacy_recovery_rule" \
    "$legacy_policy_file" "$legacy_cli" "$legacy_helper"
  /usr/bin/rm -rf -- "$legacy_plugin_dest" "$legacy_config_dir"
fi
install_complete=true

echo "Installed EscaLock for $target_user (UID $target_uid)."
echo "Administrator Mode remains ON. Backup: $backup_dir"
echo "Plugin validated at $plugin_dest"
if [[ $legacy_was_enabled == true ]]; then
  echo "Migrated the existing bar placement from andrewbacon.admin-toggle."
elif [[ $legacy_present == true ]]; then
  echo "The legacy plugin was disabled; EscaLock remains disabled in the bar layout."
else
  echo "Enable it on the live bar with: omarchy plugin enable andrewbacon.escalock --section right"
fi
