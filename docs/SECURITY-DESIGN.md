# Security design

## Objective and boundary

EscaLock controls subsequent general-purpose elevation for one configured
local desktop user without changing supplementary groups or requiring a new
login. It coordinates:

- a dedicated `/etc/sudoers.d/00_USER` general grant, either pre-existing or
  safely derived from Omarchy's standard shared wheel grant;
- the complete effective sudo policy matching that user; and
- Polkit decisions for that user.

It does not revoke an existing root process, open privileged descriptor,
kernel capability, or state acquired before a transition. Executable-scoped
Omarchy sudo delegations may remain only when setup can enumerate them and does
not classify their executable as general-purpose or commonly shell-escapable.
Setup labels exact, patterned, and unrestricted arguments separately. Sudo
argument wildcards can span whitespace, so these rules remain privileged
capabilities rather than proof of least privilege. Bugs or unsafe argument
handling in a retained program remain outside EscaLock's enforcement boundary.

## Source and installation trust

The distribution unit is a Git checkout installed by `omarchy plugin add`, not
an Arch package. Normal setup requires a clean checkout with the canonical
HTTPS GitHub origin and archives the exact Git `HEAD`. The user is shown the
origin and commit and must explicitly type `install`.

The canonical source repository is
`https://github.com/RamenPacket84/omarchy-escalock`. The established plugin ID
`andrewbacon.escalock` and Polkit action namespace
`com.github.andrewbacon.omarchy-escalock` remain stable application identifiers;
they are not repository-origin assertions. Setup's exact HTTPS origin policy is
what binds a published installation to the accepted repository.

The standard one-command installation enables the widget. When the system
helper is absent, the widget invokes the unprivileged onboarding launcher from
that checkout. The launcher opens `setup.sh --enable` in an Omarchy terminal so
the explicit confirmation and sudo authentication still have a real TTY. It
downloads no code, installs no packages, makes no privileged change itself,
and is automatically offered at most once per repository version. Cancellation
leaves a user-triggered retry in the widget. An existing helper, including a
version mismatch, suppresses automatic onboarding so upgrades remain
intentional.

The unprivileged phase builds and validates a fixed payload. It creates a tar
archive containing exactly:

```text
build/omarchy-escalock-helper
bin/omarchy-escalock
bin/omarchy-escalock-maintain
manifest.json
polkit/00-00-omarchy-escalock-on.rules.in
polkit/00-00-omarchy-escalock-off.rules.in
polkit/com.github.andrewbacon.omarchy-escalock.policy
```

The sudo handoff copies this archive to a newly created root-owned mode-0700
directory, recomputes its SHA-256, and requires the exact ordered member list
and regular-file type before extraction. The staged tree is root-owned before
the staged maintenance tool runs. No privileged code resolves a path below the
target user's home, so checkout symlinks and same-user replacement after the
handoff cannot redirect root file operations.

This prevents a time-of-check/time-of-use substitution after confirmation. It
does not make a malicious reviewed commit safe, authenticate a GitHub account,
or replace commit-signature verification. Install metadata records the source
commit and handoff digest for audit and recovery.

## Privileged components

`/usr/local/libexec/omarchy-escalock-helper` is a compiled, root-owned setuid
executable. Setuid is used only so the configured user can inspect protected
state without repeated authentication. It accepts four fixed operations:
`version`, `status`, `enable`, and `disable`.

`version` reads no configuration. `status` requires either the configured real
UID or root invoked by `pkexec` with the matching `PKEXEC_UID`. A mutation
requires all of the following:

1. real and effective UID are both 0;
2. `PKEXEC_UID` contains ASCII decimal digits only and equals the configured
   UID;
3. the configured username still resolves to that UID; and
4. the operation is exactly `enable` or `disable`.

A direct setuid invocation retains the caller's nonzero real UID and cannot
mutate state even if it invents `PKEXEC_UID`. The helper accepts no user, path,
command, environment-selected executable, policy, or shell fragment. Child
validators use fixed absolute executables with a cleared environment. The
production binary is checked for test-only hooks before installation.

`/usr/local/libexec/omarchy-escalock-maintain` is root-owned but not setuid. It
is reached through sudo only for explicit setup/check/uninstall. It operates on
fixed system paths and a verified root-owned staging directory. Installation
and removal create root-only backups and use exit traps to restore the prior
recovery path after a partial failure.

## Polkit policy and precedence

Both custom `pkexec` actions bind the helper's absolute path and fixed first
argument through `org.freedesktop.policykit.exec.path` and
`org.freedesktop.policykit.exec.argv1`.

EscaLock always installs one rule at:

```text
/etc/polkit-1/rules.d/00-00-omarchy-escalock.rules
```

Its Administrator-ON content behaves as follows:

```text
configured active local user + enable action   -> AUTH_SELF
configured active local user + disable action  -> AUTH_SELF
configured inactive/remote user + either       -> NO
other actions/users                             -> fall through
```

Its Administrator-OFF content behaves as follows:

```text
configured active local user + enable recovery -> AUTH_SELF
active local user + shutdown/reboot action      -> fall through
every other action for configured user          -> NO
other users                                     -> fall through
```

The shutdown/reboot exception is limited to systemd-logind's explicit
`power-off`, `power-off-multiple-sessions`, `power-off-ignore-inhibit`,
`reboot`, `reboot-multiple-sessions`, and `reboot-ignore-inhibit` actions.
EscaLock returns no decision for those actions so the installed system policy
still controls them. It does not grant a generic command-execution action,
and the exception does not apply to an inactive or remote session.

Polkit stops at the first non-null rule result. Setup and every status check
therefore scan both `/etc/polkit-1/rules.d` and
`/usr/share/polkit-1/rules.d`. A rule whose basename sorts earlier than
`00-00-omarchy-escalock.rules`, or a same-named vendor rule, makes the state
unusable. Rule directories must be trusted and not group/world-writable.

Writing a rule does not assume Polkit has reloaded it synchronously. The helper
starts a controlled process with the target UID, derives its PID/start-time/UID
subject tuple, and polls non-interactive `pkcheck` results. Administrator OFF
must challenge for recovery, deny the disable action, and deny generic
`pkexec`; Administrator ON must challenge for both custom actions. The sudo
grant is not removed until the OFF decisions are observed. A failed probe
restores the previous rule.

## Effective sudo policy

Setup accepts either an exact root-owned mode-0440 dedicated grant:

```text
USER ALL=(ALL) ALL
```

or Omarchy's exact standard shared grant:

```text
%wheel ALL=(ALL:ALL) ALL
```

For the shared layout, setup preserves the original rule and replaces its live
content with `%wheel, !USER ALL=(ALL:ALL) ALL`. It then creates the exact
per-user `USER ALL=(ALL:ALL) ALL` grant that transitions manage. Sudo applies
matching entries in order and the negated user-list member removes only the
configured account from the shared rule. Other wheel users remain covered,
and later executable-scoped Omarchy rules remain available. The original and
managed shared rules are protected templates and uninstall restores the
original byte-for-byte.

It validates the complete policy with `visudo`, rejects a non-sudoers policy
backend in `/etc/sudo.conf`, and converts the policy matching the target user
to normalized JSON with `cvtsudoers` and `jq`. The enabled snapshot must contain
exactly one effective general `ALL` command. Setup derives the disabled
snapshot by removing that controlled command specification. Every other
matching command is enumerated and screened as a retained delegation.

Both JSON snapshots are root-owned mode 0600. The helper regenerates the live
matching policy with the same fixed tools and requires byte equality after
normalization. This catches grants through the user, groups, aliases, includes,
and later policy changes at the effective-policy level.

`cvtsudoers` may merge duplicate equivalent source rules in its normalized
representation. Such a duplicate does not change the truthful enabled state,
but removing only the managed file leaves the effective policy different from
the disabled snapshot. Final verification then fails and atomically restores
the managed grant and Administrator-ON rule. EscaLock therefore fails closed
instead of claiming Secure Mode ON.

## Authoritative states and transitions

Internal helper state `enabled` means Administrator Mode ON and requires:

- exact live managed grant and absent disabled copy;
- for a migrated Omarchy wheel layout, the exact live exclusion rule and both
  protected original/managed templates;
- exact Administrator-ON Polkit rule;
- exact policy and rule templates, custom policy, helper metadata, rule
  precedence, and protected file modes; and
- live sudo JSON equal to the enabled snapshot.

Internal helper state `disabled` means Administrator Mode OFF and requires:

- absent managed grant and exact protected disabled copy;
- the same exact migrated-wheel state when that layout is configured;
- exact Administrator-OFF Polkit rule;
- the same infrastructure checks; and
- live sudo JSON equal to the disabled snapshot.

Everything else is `inconsistent`. The user interface deliberately maps
`enabled` to **Secure Mode OFF** and `disabled` to **Secure Mode ON**.

Transitions hold an exclusive root-owned lock, use atomic rule writes and grant
renames with directory fsync, validate sudoers, probe Polkit activation, and
verify the complete final state. Disable installs and observes the deny rule
before removing sudo. Enable restores and validates sudo while the deny rule is
still active, then installs and observes the ON rule. Rollbacks prefer retaining
the restricted recovery state when a fully verified enabled state cannot be
established.

## Recovery and lifecycle invariants

- Setup, upgrade, and uninstall start only from verified Administrator Mode ON.
- Setup never automatically enters Administrator Mode OFF.
- First-run onboarding only opens the interactive setup terminal; it cannot
  bypass setup validation, confirmation, or sudo authentication.
- Each lifecycle mutation has a root-only backup under
  `/var/backups/omarchy-escalock/`.
- Root never changes the Omarchy plugin checkout or bar layout. Plugin enable,
  disable, update, and removal remain user-owned Omarchy operations.
- The widget refuses transitions when its expected version differs from the
  installed helper version.
- Uninstall first restores Administrator Mode through the normal authenticated
  action, verifies the grant/template and complete sudoers policy, restores a
  migrated shared wheel grant when applicable, then removes fixed system paths
  transactionally.
