# Project State

Version: 0.4.0
Branch: fasttrack/auto-tunnel-wizard
Base commit: a6a4d0d Merge pull request #9 from ArashPersian/fasttrack/synthetic-test-dependency-installer
Commit: 9a29a4f Add Auto Tunnel Wizard
PR status: not opened yet
Release status: no release or tag planned for this batch

## Checks

Local checks:

- Passed: `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- Passed: menu smoke to `Tunnel Manager -> Auto Tunnel Wizard`
- Passed: menu smoke to `Auto Tunnel Wizard -> Foreign/Exit server setup` with cancel before writes
- Passed: menu smoke to `Auto Tunnel Wizard -> Iran/Entry server setup` with valid bundle and cancel before writes
- Passed: menu smoke to `Tunnel Manager -> Manual Tunnel Lab`
- Passed: bundle parser tests for valid bundle, missing field, invalid port, and forbidden Hysteria UDP `443`
- Passed: Iran endpoint prompt test showing detected outbound IP hint, local IPv4 hints, and explicit endpoint entry warning
- Passed: existing tunnel preservation/static check for same-profile-only service stop behavior and no unrelated port stop
- Passed: secret handling/static check for bundle warning and no private key printing
- Passed: synthetic test integration smoke for bundle handoff and `VIPTRUE_TEST_PEER_BUNDLE` guidance
- Passed: `git diff --check`
- Not run locally: ShellCheck is not installed in PowerShell or Git Bash on this Windows workspace

## Remaining Issues

- Auto Wizard is the pairing-code implementation. SSH-driven one-click
  cross-server orchestration is intentionally not included in this PR.
- Real scoring for latency, packet loss, and synthetic handshake quality still
  requires disposable Iran and foreign VPS validation with live Hysteria2 and
  WireGuard services.

## Next Exact Step

Run local validation, open the Auto Tunnel Wizard PR, and review GitHub ShellCheck.
