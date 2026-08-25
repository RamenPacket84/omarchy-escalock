# Omarchy Administrator Mode Toggle

`andrewbacon.admin-toggle` is an Omarchy 4.x bar widget and local security
control for one explicitly configured user. It coordinates that user's
dedicated sudo grant with an early Polkit deny rule so the bar reflects and
changes real authorization state rather than remembering a cosmetic toggle.

This software changes access to root. Review the source, run the dry-run and
tests, preserve the installer backup, and verify recovery before performing a
first OFF transition.

## Meaning of the two states

Administrator Mode **ON** means:

- `/etc/sudoers.d/00_USER` is the exact root-owned grant captured at install;
- the dynamic Admin-OFF Polkit rule is absent; and
- normal Polkit behavior, including the system's `wheel` administrator rule,
  is allowed to apply.

Administrator Mode **OFF** means:

- the dedicated general sudo grant is preserved as
  `/etc/omarchy-admin-toggle/sudoers.disabled`, outside `sudoers.d`;
- `/etc/polkit-1/rules.d/10-omarchy-admin-toggle-off.rules` denies other
  Polkit actions for the configured user; and
- the one early recovery action can still authenticate the active local user
  with `AUTH_SELF` and run only `helper enable`.

OFF does **not** mean that the account has no privileged capabilities at all.
Separate, narrowly scoped Omarchy sudo rules are intentionally retained. On
the test system these include delegated DNS, time-zone, and display-control
operations. OFF removes general-purpose sudo and generic Polkit/root elevation
while leaving those explicit system delegations alone.

The helper reports `inconsistent` instead of guessing whenever the protected
files do not form one of the two exact states.

## Architecture

```text
Omarchy bar widget or CLI
        |
        +-- helper status (authoritative, read-only)
        |
        `-- /usr/bin/pkexec
                  |
                  +-- ...enable action (AUTH_SELF, recovery)
                  +-- ...disable action (AUTH_SELF, ON only)
                  |
                  `-- root-owned helper {enable|disable}
                              |
                              +-- fixed sudo grant/template
                              `-- fixed early Polkit OFF rule
```

The compiled helper is root-owned and setuid so the configured user can obtain
an authoritative status without repeated authentication despite
`/etc/sudoers.d` being mode `0750`. Direct execution retains the caller's real
UID and is accepted only for `status`. A mutation requires real UID 0,
effective UID 0, and a strictly parsed `PKEXEC_UID` equal to the UID in the
root-owned configuration. A user cannot satisfy the real-UID check by merely
inventing that environment variable.

The helper accepts exactly one argument: `status`, `enable`, or `disable`. It
accepts no username, path, executable, shell fragment, environment-selected
command, or sudoers content. Its external validation calls use absolute paths
and a cleared environment. The production binary contains no shell execution
primitive.

Polkit rules are ordered around the dynamic deny rule:

```text
05-omarchy-admin-toggle-recovery.rules  enable -> AUTH_SELF
10-omarchy-admin-toggle-off.rules       target user -> NO (OFF only)
20-omarchy-admin-toggle-manage.rules    disable -> AUTH_SELF
50-default.rules                        normal wheel admin behavior
```

The custom policy binds each action to both the absolute helper path and its
fixed first argument using `org.freedesktop.policykit.exec.path` and
`org.freedesktop.policykit.exec.argv1`. Policy defaults are `no`; only the
generated rules authorize the configured active, local user. Remote, inactive,
and other-user attempts are denied. No rule authorizes arbitrary `pkexec`.

See [the detailed security design](docs/SECURITY-DESIGN.md).

## Threat model and limitations

The feature controls subsequent general elevation attempts by the configured
user. It is intended to reduce the time a daily desktop account operates as a
general administrator and to make the state visible.

It cannot revoke or contain:

- an already-running root shell or process;
- a cached capability, open privileged descriptor, or privileged state
  obtained before switching OFF;
- compromise of root, the kernel, Polkit, sudo, or the helper itself; or
- privilege-escalation bugs in separately delegated narrow commands.

It does not remove the user from `wheel`. Existing graphical processes can
retain supplementary group credentials, so group removal is not dependable as
an immediate-session enforcement mechanism. The early Polkit rule instead
returns the first non-null decision for the configured username.

`AUTH_SELF` recovery is deliberate: the configured user can restore ON using
their own account password even though the OFF rule prevents them from being
treated as a Polkit administrator. Anyone who knows that password and controls
the active local session can therefore restore Administrator Mode; this is a
recovery property, not a second authentication factor.

## Build and test

Requirements include GCC, `visudo`, Polkit, jq, and Omarchy 4.x.

```bash
make clean all
make check
```

The tests compile with strict warnings and hardening, validate the XML and
Omarchy manifest/QML syntax, exercise rule ordering in JavaScript, and run
enable/disable/inconsistent transitions inside an isolated fake filesystem.
The test-only path and caller overrides are compiled out of the production
binary.

## Install

The installer requires an explicit target. On this laptop:

```bash
./install.sh --user abacon --dry-run
./install.sh --user abacon
```

The non-root stage builds and validates the plugin, then uses interactive
`sudo` for the installation stage. It verifies Omarchy 4.x, the account and
UID, the exact existing `/etc/sudoers.d/00_USER` grant, ownership/mode, and the
complete sudoers configuration. Unexpected existing project files or sudo
contents cause a refusal rather than an overwrite.

The installer creates a timestamped root-only backup under
`/var/backups/omarchy-admin-toggle/`, installs and validates recovery, verifies
the helper reports `enabled`, and leaves Administrator Mode ON. It never
performs the first disable.

If the live Omarchy shell is reachable, place the validated widget on the bar:

```bash
omarchy plugin enable andrewbacon.admin-toggle --section right
```

The installed files are:

```text
/usr/local/libexec/omarchy-admin-toggle-helper              root:root 4755
/usr/local/bin/omarchy-admin-toggle                         root:root 0755
/etc/omarchy-admin-toggle/config                            root:root 0600
/etc/omarchy-admin-toggle/sudoers.template                  root:root 0440
/etc/omarchy-admin-toggle/*.rules.template                  root:root 0644
/etc/omarchy-admin-toggle/*.policy.template                 root:root 0644
/etc/polkit-1/rules.d/05-omarchy-admin-toggle-recovery.rules
/etc/polkit-1/rules.d/20-omarchy-admin-toggle-manage.rules
/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-admin-toggle.policy
~/.config/omarchy/plugins/andrewbacon.admin-toggle/
```

The `10-...-off.rules` file and `sudoers.disabled` do not exist immediately
after installation; they appear only in OFF state.

## Use

The compact widget displays `Admin ON`, `Admin OFF`, or `Admin ?`. It polls the
helper's authoritative state. ON-to-OFF requires a confirmation panel that
explains the effect, followed by Polkit authentication. OFF-to-ON immediately
opens the `AUTH_SELF` recovery authentication. Every result is reread from the
helper.

The same mechanism is available from a terminal:

```bash
omarchy-admin-toggle status
omarchy-admin-toggle enable
omarchy-admin-toggle disable
omarchy-admin-toggle toggle
```

Expected status output is `enabled`, `disabled`, or `inconsistent`.
Authentication cancellation changes nothing and is reported separately from
authorization denial.

## Normal recovery

If the widget or shell is unavailable, use:

```bash
omarchy-admin-toggle enable
```

`pkexec` can fall back to a textual authentication agent in a TTY if no
graphical agent is registered. Authenticate as the configured user. Then
verify:

```bash
omarchy-admin-toggle status
sudo -k
sudo whoami
```

Do not delete the helper, policy, recovery rule, configuration, or sudo
template while OFF.

## Emergency recovery from a live environment

Use this only if Polkit or the installed recovery mechanism is broken. Boot an
Arch/Omarchy live environment, mount the system root, and enter it with
`arch-chroot`. Then, as root:

```bash
visudo -cf /etc/omarchy-admin-toggle/sudoers.template
install -o root -g root -m 0440 \
  /etc/omarchy-admin-toggle/sudoers.template \
  /etc/sudoers.d/00_abacon
visudo -c
rm -f /etc/polkit-1/rules.d/10-omarchy-admin-toggle-off.rules
```

Replace `00_abacon` only if the root-owned `config` names a different target.
Do not improvise sudoers contents. Reboot, confirm ON, and investigate why the
normal recovery path failed before using the toggle again.

## Uninstall

Run as the configured user:

```bash
./uninstall.sh --user abacon
```

If OFF, the uninstaller first uses the normal custom recovery action to restore
ON. It refuses inconsistent state or an unverified sudo template. After ON and
full sudoers validation are confirmed, it disables/removes the widget, backs
up project configuration, removes Polkit/helper/config files, revalidates
sudoers, and verifies the general grant remains present. It will not report
success if removing the project would strand the machine without the known
administrator grant.

## License

MIT. See [LICENSE](LICENSE).
