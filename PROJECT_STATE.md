# Project State

Version: 0.4.4
Branch: fasttrack/fix-syncplay-install-prompt
Base commit: 5ebaa17 Merge pull request #13 from ArashPersian/fasttrack/private-syncplay-server
Commit: pending PR branch
PR status: preparing Syncplay install prompt hotfix
Release status: no release, tag, or deploy planned for this batch

## Scope

- Fix `Private -> Syncplay Server -> Install / Reinstall` crashing before the
  install confirmation with `service_name: unbound variable`.
- Preserve the existing Syncplay manager behavior while routing the Private menu
  through a small hotfix wrapper.
- Avoid using Codex for this small patch unless GitHub checks fail or deeper
  refactor is needed.

## Root Cause

- `prompt_install_config` used local variable names that matched the output
  variable names passed by `install_or_reinstall_syncplay`.
- With Bash local scoping and `printf -v`, the caller's `service_name` stayed
  unset.
- Because the script runs with `set -u`, printing the install Plan failed before
  any root/install action started.

## Checks

Planned checks before asking for user VPS testing:

- `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh menus/private.sh modules/private/01-syncplay-server.sh modules/private/01-syncplay-server-fixed.sh`
- Menu route review: `Main -> Private -> Syncplay Server` uses the fixed wrapper.
- Install prompt review: `service_name`, `port`, `password`, `salt`, `isolate`,
  `bind_mode`, and `motd` are populated before the Plan output.
- No real secrets/endpoints committed.
- GitHub Actions ShellCheck if configured.

## Remaining Issues

- Live install/reinstall still needs a real Ubuntu/Debian VPS with root after
  this hotfix is merged.
- Provider/security-group firewall must still allow the selected TCP port.

## Next Exact Step

Open a small PR for the Syncplay prompt hotfix, inspect the diff and GitHub
checks, merge only if checks pass, then ask the user to pull `main` and retry the
Syncplay install from the normal menu.
