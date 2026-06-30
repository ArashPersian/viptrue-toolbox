# Project State

Version: 0.3.4
Branch: fasttrack/hysteria-obfs-wireguard-multi
Base commit: 031556c Merge pull request #3 from ArashPersian/fasttrack/tunnel-manager-urgent
Commit: d2a1ea1 Add Hysteria2 OBFS WireGuard multi-forward
PR status: not opened yet
Release status: no release or tag planned for this batch

## Checks

Local checks:

- Passed: `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- Passed: menu smoke test to reach `Hysteria2 OBFS -> WireGuard Forward`
- Passed: Foreign server mode refuses Hysteria2 UDP port `443`
- Passed: Iran server mode refuses duplicate Iran UDP listen ports
- Passed: `git diff --check`
- Not run locally: ShellCheck is not installed in this Windows/Git Bash environment

## Remaining Issues

- The legacy repo contains many historical step scripts that are not part of
  this cleanup batch.
- The new Hysteria2 OBFS WireGuard helper still requires disposable VPS
  validation before any production PasarGuard traffic is moved.

## Next Exact Step

Open the Hysteria2 OBFS WireGuard PR and review advisory ShellCheck results.
