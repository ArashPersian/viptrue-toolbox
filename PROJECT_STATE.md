# Project State

Version: 0.3.5
Branch: fasttrack/hysteria-wg-profile-management
Base commit: 807056d Merge pull request #4 from ArashPersian/fasttrack/hysteria-obfs-wireguard-multi
Commit: pending
PR status: not opened yet
Release status: no release or tag planned for this batch

## Checks

Local checks:

- Passed: `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- Passed: menu smoke test to reach `Hysteria2 OBFS -> WireGuard Forward -> Manage Existing Hysteria2 WireGuard Forwards`
- Passed: Edit Profile refuses Hysteria2 UDP port `443`
- Passed: Edit Profile refuses duplicate Iran UDP listen ports
- Passed: Edit Profile refuses ports outside `1-65535`
- Passed: Show Profile Details masks auth and OBFS secrets in details and sanitized config output
- Passed: Delete Profile refuses to move files unless exact `DELETE` is entered
- Passed: Delete Profile implementation moves files into the archive directory instead of hard-deleting by default
- Passed: `git diff --check`
- Not run locally: ShellCheck is not installed in this Windows/Git Bash environment

## Remaining Issues

- The legacy repo contains many historical step scripts that are not part of
  this cleanup batch.
- The Hysteria2 OBFS WireGuard profile management paths still require
  disposable VPS validation before any production PasarGuard traffic is moved.

## Next Exact Step

Open the Hysteria2 WireGuard profile management PR and review advisory ShellCheck results.
