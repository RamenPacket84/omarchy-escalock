# Release checklist

Use this checklist for each EscaLock release. Record release-specific results in
the GitHub release or issue rather than adding machine-specific reports to the
repository.

## Source and automated checks

- Confirm the release worktree contains only the intended changes.
- Confirm the manifest, helper, and widget use the same version.
- Run `make clean check`.
- Run `git diff --check`.
- Run GCC `-fanalyzer` and Clang static analysis for helper changes.
- Review the complete diff, especially setuid, sudoers, and Polkit changes.
- Confirm the README install command names the canonical GitHub repository.
- Confirm each privileged maintenance component remains within the static
  analysis budget enforced by `tests/test_maintenance_layout.sh`.
- Confirm the unprivileged and root-side payload lists are identical and
  contain no wildcard members.
- After testing, run `make clean` and confirm the ignored build directory and
  obsolete pre-rename binaries are absent.

## Privileged preflight

Run on a current Omarchy 4 system with Administrator Mode ON:

```bash
./setup.sh --check
```

- Confirm the detected sudo grant is the expected file.
- Review every retained command-specific sudo grant and restriction.
- Confirm the preflight makes no persistent system changes.
- Confirm the generated preflight plan is root-owned, mode 0600, and rejected
  if its account, grant basename, migration state, or either snapshot changes
  before install.
- Confirm rebaseline displays, confirms, and commits one digest-bound plan
  inside a single root-owned staging operation after the user types `approve`.
- Confirm negated sudo commands are labeled as restrictions and a later broad
  grant that overrides one causes preflight to fail.

## Live lifecycle test

- Install or upgrade with `./setup.sh` and retain the printed backup path.
- Confirm setup restarts the shell for an enabled widget and its update message
  clears without a computer reboot.
- Confirm a disabled widget and a locked, indeterminate, or unavailable shell
  skip the restart without undoing the successful privileged installation.
- Confirm `omarchy-escalock version` reports the expected version.
- Confirm the initial status is `off`.
- Turn Secure Mode on and confirm status is `on`.
- Run `sudo -k`, then confirm `sudo -n /usr/bin/true` is denied.
- Confirm generic `pkexec /usr/bin/true` is denied.
- Confirm shutdown and reboot actions remain authorized by the normal logind
  policy for the active local session.
- Turn Secure Mode off and confirm authenticated sudo works again.
- Reboot once in each state and confirm the reported state persists.
- From the previous published release, run the documented one-time Omarchy
  update and confirm **Finish update** completes the system upgrade.
- From the current release, test both **Check for updates** and
  `omarchy-escalock update` with no update available; confirm each is a no-op
  that preserves Secure Mode state.
- Test a real update with Secure Mode OFF and ON. Confirm Omarchy shows its diff
  and confirmation, Secure Mode ON is restored to OFF only when setup is
  required, and setup completes without a reboot.
- Cancel Omarchy's update confirmation and simulate a failed fetch. Confirm no
  privileged setup runs and the existing installation remains unchanged.
- Confirm a changed checkout commit forces setup even if its manifest version
  is unchanged.
- On a controlled disposable test installation only, introduce harmless
  executable-scoped sudo policy drift through a separate test-owned rule. Do
  not modify a package-owned sudoers file.
- Confirm the changed policy reports `inconsistent` and **Review changes**
  opens the read-only preflight before asking the user to type `approve`.
- Confirm `omarchy-escalock update` reaches that same review when no source
  update is available, without silently accepting the policy.
- Confirm cancellation makes no change and `--rebaseline` refuses both a fresh
  installation and an already-consistent installation.
- Confirm rebaseline refuses Secure Mode ON, structural damage, unsafe retained
  grants, overridden restrictions, and a live-policy change after preflight.
- Remove the test-owned sudo rule and confirm the resulting policy change is
  detected and can be reviewed without leaving test policy behind.
- Uninstall, verify Administrator Mode remains available, and confirm the
  plugin checkout and EscaLock system files are removed.
- Reinstall from the public GitHub command and repeat one ON/OFF cycle.

## Supported sudo layouts

Before a release that changes grant discovery or migration, test both:

- a dedicated Archinstall grant with a numeric prefix; and
- Omarchy's shared `/etc/sudoers.d/00-omarchy-wheel` grant.

Include a prefix longer than two digits in automated coverage. Do not create an
artificial live sudoers layout solely to satisfy this checklist.

## Publication

- Confirm `README.md`, `manifest.json`, and `preview.png` describe the release.
- Confirm recovery and uninstall instructions match the shipped commands.
- Push the reviewed commit and test installation from the resulting GitHub
  checkout before announcing the release.
