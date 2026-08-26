# Live test report — 2026-08-25

> Historical record: this live cycle predates EscaLock 2.0.0. Its results do
> not substitute for a 2.0.0 privileged `setup.sh --check` and live transition
> test.

This report records the pre-publication deployment before it was renamed to
EscaLock. Legacy executable names and `enabled`/`disabled` CLI output below are
retained because they are the exact interface that was tested. EscaLock 1.1.0
keeps the same helper and enforcement semantics while exposing public CLI
states as `on` and `off`.

## System

- Omarchy `4.0.1-1`
- target user `abacon`, UID `1000`
- target remained a member of `wheel`
- dedicated initial grant `/etc/sudoers.d/00_abacon`

## Build and static verification

- strict GCC production build: passed
- GCC `-fanalyzer`: zero findings
- Clang static analyzer: zero findings
- PIE, non-executable stack, RELRO, and immediate binding: verified
- Polkit XML and rule-order tests: passed
- Omarchy manifest and QML syntax validation: passed
- isolated helper transition/rollback/inconsistent-state tests: passed

## Installed ON-state preflight

- installed helper: `root:root`, mode `4755`
- trusted configuration: `root:root`, mode `0600`
- sudo template and live grant: `root:root`, mode `0440`, byte-identical
- both custom actions discovered by `pkaction` with the expected absolute helper
  path and fixed `argv1` annotations
- direct non-root mutation with an invented `PKEXEC_UID`: rejected
- unexpected helper argument: rejected
- custom `enable` recovery action authenticated and returned `enabled` while
  already ON
- generic ON-state Polkit execution returned `root`
- complete sudoers configuration passed `visudo -c`
- live plugin rescan, enable, and shell restart succeeded without QML errors

## Approved first OFF cycle

The authenticated custom disable action returned `disabled`. While OFF:

- helper status: `disabled`
- CLI status: `disabled`
- noninteractive `sudo -n /usr/bin/whoami`: exit `1`, no command execution
  (`sudo: a password is required`)
- `pkexec /usr/bin/whoami`: exit `127`, `Not authorized`
- `pkexec /usr/bin/bash -c /usr/bin/whoami`: exit `127`, `Not authorized`
- the project's custom disable action: exit `127`, `Not authorized`

The last check demonstrates that the dynamic early rule blocks even the later
project management action; only the earlier custom enable recovery action is
available to the target user.

## Recovery and restored state

Only the legacy `omarchy-admin-toggle enable` command was used to regain
Administrator Mode. Its
custom `AUTH_SELF` action authenticated the configured user and returned
`enabled`.

Post-recovery verification:

- helper and CLI status: `enabled`
- exact `pkexec /usr/bin/whoami`: `root`
- `/etc/sudoers.d/00_abacon`: present
- live grant matches root-owned template: yes
- `/etc/omarchy-admin-toggle/sudoers.disabled`: absent
- `/etc/polkit-1/rules.d/10-omarchy-admin-toggle-off.rules`: absent
- complete `visudo -c`: passed
- `sudo -l -U abacon`: general `(ALL) ALL` restored; narrow Omarchy rules intact
- bar plugin: enabled
- `omarchy.polkit`: enabled

## Tests not performed in this cycle

- reboot persistence (avoided disrupting the active test laptop)
- logout/login persistence (not required by the rule-based design)
- authentication cancellation through the graphical dialog
- a real second local account attempt (covered by deterministic rule tests)
- live corruption of root-owned templates/rules (covered in the isolated test
  root; intentionally not performed against `/etc`)
- uninstallation (the deployed feature was retained)
