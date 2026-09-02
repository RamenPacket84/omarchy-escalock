#!/bin/bash

set -euo pipefail
umask 077
export LC_ALL=C

readonly project_root=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly omarchy=/usr/share/omarchy/bin/omarchy
readonly plugin_id=andrewbacon.escalock
readonly origin_policy="$project_root/lib/source-origin.sh"
readonly widget_reload_policy="$project_root/lib/widget-reload.sh"

readonly target_user=$(/usr/bin/id -un)
enable_plugin=false
check_only=false
development=false
rebaseline=false

fail() {
  echo "setup.sh: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./setup.sh [--enable] [--check] [--rebaseline] [--development]

Builds and validates the exact local Git HEAD from the plugin checkout,
performs an explicit privileged setup, and optionally enables the EscaLock
widget.

--check        Run the privileged preflight without installing system files.
--rebaseline   After review, replace stale policy snapshots from a structurally
               verified Administrator Mode ON state, then perform the upgrade.
--development  Use the current working tree instead of Git HEAD. Never use this
               option for a published installation.
USAGE
}

[[ -f $origin_policy && ! -L $origin_policy ]] || fail "source-origin policy is missing or unsafe"
[[ -f $widget_reload_policy && ! -L $widget_reload_policy ]] ||
  fail "widget-reload policy is missing or unsafe"
# shellcheck source=lib/source-origin.sh
source "$origin_policy"
# shellcheck source=lib/widget-reload.sh
source "$widget_reload_policy"

while (( $# > 0 )); do
  case "$1" in
    --enable)
      enable_plugin=true
      shift
      ;;
    --check)
      check_only=true
      shift
      ;;
    --development)
      development=true
      shift
      ;;
    --rebaseline)
      rebaseline=true
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

[[ $check_only == false || $rebaseline == false ]] ||
  fail "--check and --rebaseline cannot be used together"

(( EUID != 0 )) || fail "run setup as the target user, not with sudo"
[[ $target_user =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "invalid target username"

for command_path in /usr/bin/awk /usr/bin/cvtsudoers /usr/bin/gcc /usr/bin/git \
  /usr/bin/grep /usr/bin/jq /usr/bin/make /usr/bin/pkaction /usr/bin/pkcheck \
  /usr/bin/omarchy-hyprland-session-locked /usr/bin/omarchy-restart-shell \
  /usr/bin/omarchy-shell /usr/bin/sed /usr/bin/sha256sum /usr/bin/sleep \
  /usr/bin/strings /usr/bin/sudo /usr/bin/tar /usr/bin/visudo /usr/bin/xmllint; do
  [[ -x $command_path ]] || fail "required command is missing: $command_path"
done
[[ -x $omarchy ]] || fail "Omarchy is not installed"
omarchy_version=$($omarchy version) || fail "could not determine the Omarchy version"
[[ $omarchy_version == 4.* ]] || fail "Omarchy 4.x is required; found $omarchy_version"

git_root=$(/usr/bin/git -C "$project_root" rev-parse --show-toplevel 2>/dev/null) ||
  fail "setup must run from a Git-managed EscaLock checkout"
[[ $git_root == "$project_root" ]] || fail "the plugin checkout must be the Git repository root"
source_commit=$(/usr/bin/git -C "$project_root" rev-parse HEAD)
[[ $source_commit =~ ^[0-9a-f]{40,64}$ ]] || fail "could not resolve the source commit"
origin_url=$(/usr/bin/git -C "$project_root" remote get-url origin 2>/dev/null || true)

if [[ $development == false ]]; then
  omarchy_escalock_origin_is_canonical "$origin_url" ||
    fail "published setup requires $OMARCHY_ESCALOCK_CANONICAL_ORIGIN; found: ${origin_url:-none}"
  /usr/bin/git -C "$project_root" diff --quiet -- || fail "tracked working-tree changes are not included; review or commit them first"
  /usr/bin/git -C "$project_root" diff --cached --quiet -- || fail "staged changes are not included; commit them first"
fi

snapshot_root=$(/usr/bin/mktemp -d /tmp/omarchy-escalock-source.XXXXXX)
trap '/usr/bin/rm -rf -- "$snapshot_root"' EXIT
/usr/bin/install -d -m 0700 "$snapshot_root/source"
if [[ $development == true ]]; then
  echo "WARNING: development mode uses uncommitted working-tree files." >&2
  /usr/bin/tar -C "$project_root" --exclude=.git --exclude=build -cf - . |
    /usr/bin/tar -C "$snapshot_root/source" -xf -
else
  /usr/bin/git -C "$project_root" archive --format=tar "$source_commit" |
    /usr/bin/tar -C "$snapshot_root/source" -xf -
fi

/usr/bin/make -C "$snapshot_root/source" CC=/usr/bin/gcc clean all
$omarchy plugin validate "$snapshot_root/source"
if /usr/bin/strings "$snapshot_root/source/build/omarchy-escalock-helper" |
    /usr/bin/grep 'OMARCHY_ESCALOCK_TEST_' >/dev/null; then
  fail "production helper contains test-only hooks"
fi

payload_files=(
  build/omarchy-escalock-helper
  bin/omarchy-escalock
  bin/omarchy-escalock-maint-common
  bin/omarchy-escalock-maint-grant
  bin/omarchy-escalock-maint-policy
  bin/omarchy-escalock-maint-transaction
  bin/omarchy-escalock-maint-preflight
  bin/omarchy-escalock-maint-install
  bin/omarchy-escalock-maint-rebaseline
  bin/omarchy-escalock-maint-uninstall
  manifest.json
  polkit/00-00-omarchy-escalock-on.rules.in
  polkit/00-00-omarchy-escalock-off.rules.in
  polkit/com.github.andrewbacon.omarchy-escalock.policy
)
for relative in "${payload_files[@]}"; do
  [[ -f $snapshot_root/source/$relative && ! -L $snapshot_root/source/$relative ]] ||
    fail "source snapshot is missing payload member: $relative"
done

payload_archive="$snapshot_root/payload.tar"
/usr/bin/tar -C "$snapshot_root/source" -cf "$payload_archive" "${payload_files[@]}"
payload_digest=$(/usr/bin/sha256sum "$payload_archive")
payload_digest=${payload_digest%% *}
version=$(/usr/bin/jq -er '.version' "$snapshot_root/source/manifest.json") || fail "invalid manifest version"

cat <<EOF
EscaLock privileged setup
  Version: $version
  Commit:  $source_commit
  Origin:  ${origin_url:-local development checkout}
  User:    $target_user

The next step installs a setuid status helper, root-owned maintenance components,
sudo policy snapshots, and Polkit policy. Administrator Mode remains ON.
Review this repository and preserve the recovery backup before continuing.
EOF

readonly bootstrap='set -euo pipefail
umask 077
export LC_ALL=C
archive=$1
expected_digest=$2
target_user=$3
source_commit=$4
operation=$5
stage=$(/usr/bin/mktemp -d /tmp/omarchy-escalock-root.XXXXXX)
cleanup() { /usr/bin/rm -rf -- "$stage"; }
trap cleanup EXIT
/usr/bin/chown root:root "$stage"
/usr/bin/chmod 0700 "$stage"
/usr/bin/install -o root -g root -m 0600 "$archive" "$stage/payload.tar"
actual_digest=$(/usr/bin/sha256sum "$stage/payload.tar")
actual_digest=${actual_digest%% *}
[[ $actual_digest == "$expected_digest" ]] || { echo "EscaLock payload changed during privilege handoff" >&2; exit 1; }
expected_members=(
  build/omarchy-escalock-helper
  bin/omarchy-escalock
  bin/omarchy-escalock-maint-common
  bin/omarchy-escalock-maint-grant
  bin/omarchy-escalock-maint-policy
  bin/omarchy-escalock-maint-transaction
  bin/omarchy-escalock-maint-preflight
  bin/omarchy-escalock-maint-install
  bin/omarchy-escalock-maint-rebaseline
  bin/omarchy-escalock-maint-uninstall
  manifest.json
  polkit/00-00-omarchy-escalock-on.rules.in
  polkit/00-00-omarchy-escalock-off.rules.in
  polkit/com.github.andrewbacon.omarchy-escalock.policy
)
mapfile -t archive_members < <(/usr/bin/tar -tf "$stage/payload.tar")
[[ ${#archive_members[@]} == ${#expected_members[@]} ]] || {
  echo "EscaLock payload archive has an unexpected member count" >&2
  exit 1
}
for index in "${!expected_members[@]}"; do
  [[ ${archive_members[$index]} == "${expected_members[$index]}" ]] || {
    echo "EscaLock payload archive has an unexpected member: ${archive_members[$index]}" >&2
    exit 1
  }
done
/usr/bin/tar -tvf "$stage/payload.tar" |
  /usr/bin/awk '\''substr($1, 1, 1) != "-" { unsafe = 1 } END { exit unsafe }'\'' || {
    echo "EscaLock payload archive contains a link or non-regular member" >&2
    exit 1
  }
/usr/bin/install -d -o root -g root -m 0700 "$stage/payload"
/usr/bin/tar -C "$stage/payload" --no-same-owner --no-same-permissions -xf "$stage/payload.tar"
/usr/bin/chown -R root:root "$stage/payload"
/usr/bin/chmod 0700 "$stage/payload"
case "$operation" in
  check)
    "$stage/payload/bin/omarchy-escalock-maint-preflight" check \
      --stage "$stage/payload" --user "$target_user" --commit "$source_commit" --digest "$expected_digest"
    ;;
  install)
    "$stage/payload/bin/omarchy-escalock-maint-install" \
      --stage "$stage/payload" --user "$target_user" --commit "$source_commit" --digest "$expected_digest"
    ;;
  rebaseline)
    "$stage/payload/bin/omarchy-escalock-maint-install" \
      --stage "$stage/payload" --user "$target_user" --commit "$source_commit" --digest "$expected_digest" \
      --rebaseline
    ;;
  *)
    echo "EscaLock bootstrap received an invalid operation" >&2
    exit 2
    ;;
esac'

run_root_operation() {
  /usr/bin/sudo -- /usr/bin/bash -c "$bootstrap" omarchy-escalock-bootstrap \
    "$payload_archive" "$payload_digest" "$target_user" "$source_commit" "$1"
}

if [[ $check_only == true ]]; then
  run_root_operation check
else
  [[ -t 0 ]] || fail "interactive confirmation requires a terminal"
  if [[ $rebaseline == true ]]; then
    echo "Policy rebaseline was requested. The privileged operation will list retained sudo rules,"
    echo "verify the existing Administrator Mode structure, and ask for confirmation before changing snapshots."
    run_root_operation rebaseline
  else
    read -r -p "Type 'install' to continue: " confirmation
    [[ $confirmation == install ]] || fail "setup canceled"
    run_root_operation install
  fi
fi

if [[ $check_only == true ]]; then
  echo "EscaLock setup check completed without installing system files."
  exit 0
fi

if [[ $enable_plugin == true ]]; then
  $omarchy plugin enable "$plugin_id"
  echo "EscaLock was enabled on the Omarchy bar."
else
  echo "System setup is complete. If needed, enable the widget with: omarchy plugin enable $plugin_id"
fi
omarchy_escalock_refresh_widget "$version" "$plugin_id"
