# EscaLock rename and migration report — 2026-08-25

## Scope

The pre-publication `andrewbacon.admin-toggle` deployment was renamed to
EscaLock 1.1.0 with plugin ID `andrewbacon.escalock`. The bar continues to
display `Secure Mode ON`, `Secure Mode OFF`, or `Secure Mode ?` from the
authoritative helper state.

## Safety baseline

- The legacy helper initially reported `disabled` (Secure Mode ON).
- Its existing custom recovery action authenticated the configured user and
  restored helper state `enabled` before migration.
- The working tree was clean and the legacy bar entry occupied the right
  section between `omarchy.tray` and `andrewbacon.daynight`.
- No migration step intentionally entered the restricted state.

## Verification before installation

- complete project test suite: passed
- GCC `-fanalyzer`: zero findings
- Clang static analyzer: zero findings
- Omarchy plugin validation: passed
- installer dry run against Omarchy `4.0.1-1`: passed
- legacy helper state immediately before migration: `enabled`

## Installed identity

```text
plugin       andrewbacon.escalock
CLI          /usr/local/bin/omarchy-escalock
helper       /usr/local/libexec/omarchy-escalock-helper
config       /etc/omarchy-escalock
policy       com.github.andrewbacon.omarchy-escalock
```

The installer backup is:

```text
/var/backups/omarchy-escalock/20260825T212305Z-install
```

It contains the captured sudo grant, legacy privileged configuration and
executables, legacy plugin, and the pre-migration `shell.json`.

## Post-install verification

- new helper status: `enabled`
- public CLI status: `off`
- new `enable` and `disable` Polkit actions: registered
- action annotations: fixed EscaLock helper path and fixed `argv1`
- installed Omarchy plugin validation: passed
- bar layout ID: migrated to `andrewbacon.escalock`
- Omarchy shell restart and plugin rescan: `EscaLock` discovered and enabled
- legacy plugin, CLI, helper, and policy: removed
- authenticated new recovery action while already ON: returned public state
  `off`

The migration left Administrator Mode ON and Secure Mode OFF. A post-rename
Secure Mode ON/OFF cycle was intentionally not performed as part of the rename
installation.
