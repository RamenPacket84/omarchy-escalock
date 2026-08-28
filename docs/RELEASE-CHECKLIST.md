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

## Privileged preflight

Run on a current Omarchy 4 system with Administrator Mode ON:

```bash
./setup.sh --check
```

- Confirm the detected sudo grant is the expected file.
- Review every retained command-specific sudo delegation.
- Confirm the preflight makes no persistent system changes.

## Live lifecycle test

- Install or upgrade with `./setup.sh` and retain the printed backup path.
- Confirm `omarchy-escalock version` reports the expected version.
- Confirm the initial status is `off`.
- Turn Secure Mode on and confirm status is `on`.
- Run `sudo -k`, then confirm `sudo -n /usr/bin/true` is denied.
- Confirm generic `pkexec /usr/bin/true` is denied.
- Confirm shutdown and reboot actions remain authorized by the normal logind
  policy for the active local session.
- Turn Secure Mode off and confirm authenticated sudo works again.
- Reboot once in each state and confirm the reported state persists.
- Test an update from the previous published release with Secure Mode off.
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
