# Security design

## Objective

The toggle controls subsequent general-purpose elevation for one configured
local user without changing their supplementary groups or requiring a new
graphical login. It coordinates two independent authorization systems:

- the user's dedicated general sudo grant; and
- Polkit's treatment of that user while the OFF rule is present.

Separate, narrowly delegated Omarchy sudo rules are outside the project's
scope and remain installed.

Unless explicitly labeled as Secure Mode, ON and OFF in this technical design
refer to the helper's internal Administrator Mode state.

## Fixed trust boundary

The only privileged program exposed by the project is
`/usr/local/libexec/omarchy-admin-toggle-helper`. It is a compiled, root-owned
setuid executable with exactly three accepted arguments: `status`, `enable`,
and `disable`.

Setuid is used only so `status` can inspect the protected sudoers directory
without authentication. A state-changing invocation is accepted only when all
of these are true:

1. the process real and effective UIDs are both 0 (as they are after `pkexec`);
2. `PKEXEC_UID` is present, strictly numeric, and equals the configured UID;
3. the configured username still resolves to that UID; and
4. the argument is exactly `enable` or `disable`.

A direct setuid invocation retains the user's real UID and therefore cannot
change state, even if the caller invents a `PKEXEC_UID` environment variable.
The helper accepts no path, username, command, content, or shell input.

## Polkit rule order

The installed rules intentionally straddle the dynamic OFF rule:

```text
05-omarchy-admin-toggle-recovery.rules  enable action -> AUTH_SELF
10-omarchy-admin-toggle-off.rules       configured user -> NO (OFF only)
20-omarchy-admin-toggle-manage.rules    disable action -> AUTH_SELF
50-default.rules                        wheel -> Polkit administrator
```

The recovery rule returns `AUTH_SELF` only for the configured active, local
user and only for the action whose `org.freedesktop.policykit.exec.path` and
`org.freedesktop.policykit.exec.argv1` annotations bind it to the helper's
`enable` operation. Remote, inactive, and other-user subjects receive `NO`.

While OFF, the first non-null result for the recovery action is `AUTH_SELF`.
Every other action reaches the dynamic rule and receives `NO`, including the
project's disable action and generic `org.freedesktop.policykit.exec` requests.
While ON, the dynamic rule is absent, so the later manage rule permits the
same active local user to authenticate their own disable request. Normal
vendor rules then handle all unrelated actions.

## Authoritative states

The helper reports `enabled` only when the known sudo template and live grant
are identical, protected, the disabled copy is absent, and the OFF rule is
absent. It reports `disabled` only when the live grant is absent, the original
grant is preserved outside `sudoers.d`, and the installed OFF rule exactly
matches its root-owned template. Every other combination is `inconsistent`.

Transitions hold an exclusive root-owned lock, validate the known sudo
template, use fixed absolute paths, perform atomic renames/copies, validate the
complete sudoers configuration, and verify the final state. A failed disable
attempt rolls back the sudo grant and OFF rule where possible. A failed enable
attempt keeps the OFF rule until a valid sudo grant has been restored.

The desktop uses the inverse, novice-facing terminology: authoritative
`enabled` is displayed as **Secure Mode OFF**, authoritative `disabled` as
**Secure Mode ON**, and every other combination as **Secure Mode ?**. This is a
presentation mapping only; helper output, CLI operations, policy action IDs,
and enforcement semantics remain unchanged.

## Deliberate limitations

OFF affects later elevation attempts. It cannot revoke an existing root shell,
an already-running root process, or credentials and privileged state acquired
before the transition. It also does not remove narrow sudo delegations owned
by Omarchy, so OFF must not be described as eliminating every privileged
operation on the system.
