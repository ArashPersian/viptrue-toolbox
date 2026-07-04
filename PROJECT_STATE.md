# Project State

Version: 0.4.3
Branch: fasttrack/private-syncplay-server
Base commit: 7ef52f3 Fast Track: Auto Tunnel Expert UX Polish
Commit: adc2b4d Add private Syncplay server manager
PR status: opened as #13; merge pending GitHub checks
Release status: no release, tag, or deploy planned for this batch

## Scope

- Add `Private -> Syncplay Server` to the existing Private menu.
- Install/reinstall the official Syncplay server on Ubuntu/Debian VPS systems.
- Store runtime config under `/etc/viptrue/syncplay/syncplay.env` with
  `chmod 600`.
- Generate a password and salt by default while keeping passwords out of normal
  status output and systemd `ExecStart`.
- Create and manage a systemd service, default `viptrue-syncplay.service`.
- Open the selected TCP port in UFW only when UFW is active.
- Add status, restart, stop, logs, change port/password, firewall, and uninstall
  actions.

## Checks

Local checks:

- Passed: `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh menus/private.sh modules/private/01-syncplay-server.sh`
- Passed: menu smoke to `Main -> Private`
- Passed: menu smoke to `Private -> Syncplay Server`
- Passed: status path works when not installed
- Passed: install smoke validates invalid port before root actions
- Passed: firewall function refuses invalid port
- Passed: normal status does not print password
- Passed: uninstall confirmation exists
- Passed: generated env/unit smoke keeps password out of `ExecStart`
- Passed: static check for no real secrets/endpoints
- Passed: no forbidden detection wording check
- Passed: `git diff --check`
- Not run locally: ShellCheck is unavailable in PowerShell and Git Bash PATH
- Pending: GitHub Actions ShellCheck for PR #13

## Remaining Issues

- Live install/reinstall requires a real Ubuntu/Debian VPS with root access.
- Provider firewall/security-group rules still must allow the selected TCP port.

## Next Exact Step

Run the local validation matrix, open the Syncplay Server installer PR, review
GitHub ShellCheck, and merge only if checks pass.
