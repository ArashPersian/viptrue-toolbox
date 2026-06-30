# Project State

Version: 0.3.7
Branch: fasttrack/hysteria-legacy-proven-mode
Base commit: ebd18c7 Merge pull request #6 from ArashPersian/fasttrack/hysteria-legacy-import
Commit: pending
PR status: not opened yet
Release status: no release or tag planned for this batch

## Checks

Local checks:

- Passed: `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- Passed: menu smoke test to reach `Legacy Proven Foreign Mode (/etc/hysteria + Bing masquerade)`
- Passed: port `443` guard for Legacy Proven Foreign Mode
- Passed: fixture detection for `/etc/hysteria/config.yaml` as `legacy-proven-foreign`
- Passed: secret masking for legacy proven profile details
- Passed: Iran Server Mode legacy proven preset defaults to UDP `2087`, SNI `bing.com`, insecure TLS, and WireGuard target `127.0.0.1:51820`
- Passed: OpenSSL self-signed certificate generation smoke test for CN `bing.com`
- Passed: static backup-path check for `/etc/hysteria/config.yaml` and cert/key regeneration
- Passed: `git diff --check`
- Not run locally: ShellCheck is not installed in this Windows/Git Bash environment

## Remaining Issues

- The legacy repo contains many historical step scripts that are not part of
  this cleanup batch.
- Legacy proven setup, real service restart, listener checks, and WireGuard
  handshake proof still require disposable VPS validation before any production
  PasarGuard traffic is moved.

## Next Exact Step

Open the Hysteria2 legacy proven mode PR and review advisory ShellCheck results.
