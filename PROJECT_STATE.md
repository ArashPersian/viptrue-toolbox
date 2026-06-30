# Project State

Version: 0.3.6
Branch: fasttrack/hysteria-legacy-import
Base commit: 4edfa71 Merge pull request #5 from ArashPersian/fasttrack/hysteria-wg-profile-management
Commit: pending
PR status: not opened yet
Release status: no release or tag planned for this batch

## Checks

Local checks:

- Passed: `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- Passed: menu smoke test to reach `Import legacy /etc/hysteria profile`
- Passed: legacy sample config parse test for listen `:2087`, cert/key, `sniGuard: disable`, salamander OBFS, and Bing masquerade URL
- Passed: legacy profile details mask auth and OBFS secrets
- Passed: legacy conflict check detects duplicate UDP port between old and managed configs
- Passed: Delete Profile refuses to move imported managed legacy files unless exact `DELETE` is entered
- Passed: `git diff --check`
- Not run locally: ShellCheck is not installed in this Windows/Git Bash environment

## Remaining Issues

- The legacy repo contains many historical step scripts that are not part of
  this cleanup batch.
- Legacy import, service restart, listener checks, and WireGuard handshake proof
  still require disposable VPS validation before any production PasarGuard
  traffic is moved.

## Next Exact Step

Open the Hysteria2 legacy import PR and review advisory ShellCheck results.
