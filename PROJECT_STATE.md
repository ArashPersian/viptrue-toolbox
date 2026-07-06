# Project State

Version: 0.4.7
Branch: fasttrack/egress-snat-manager
Base commit: main at implementation time
Commit: pending PR branch
PR status: preparing Egress IP / SNAT Manager
Release status: release/tag not created; requires explicit user confirmation

## Scope

- Add `Utility Tools -> Egress IP / SNAT Manager` as an independent module.
- Support server-level egress IP / Source NAT for PasarGuard shared Core/Node
  setups where each real VPS must expose its own second, floating, or IPv6
  egress address.
- Keep Xray `sendThrough` guidance separate from server-level SNAT:
  `sendThrough` is suitable for one server with multiple hosts, while
  server-level SNAT is suitable for multiple real servers with separate egress
  IPs.
- Add read-only status diagnostics for addresses, default routes, current
  public IPv4/IPv6 egress, forwarding state, managed SNAT rules, and nft hints.
- Add IPv4 SNAT configuration with safe default scope limited to VPN/private
  source subnets.
- Add IPv6 SNAT configuration with explicit IPv6 support warning and separate
  IPv6 config fields.
- Add persistence through `netfilter-persistent` when selected, otherwise a
  managed idempotent `viptrue-egress-snat.service`.
- Add rollback that removes only rules tagged with `VIPTRUE_EGRESS_SNAT`.
- Add egress tests using `curl -4`, `curl -6`, and optional `curl --interface`.

## Safety Rules

- Do not alter default routes without explicit future work.
- Do not add INPUT rules.
- Do not touch UFW rules directly.
- Do not remove manual iptables/nft rules.
- Before applying or rolling back managed SNAT, write an iptables backup under
  `/root/viptrue-iptables-backup-TIMESTAMP.rules`.
- Tag every managed SNAT rule with comment `VIPTRUE_EGRESS_SNAT`.
- Default IPv4 scope is VPN/private subnets only, not whole-server egress.
- If the selected egress IP is not assigned on the server, warn and require
  explicit confirmation before continuing.

## Checks

Local checks run:

- `bash -n /workspace/viptrue-local/menus/utility.sh /workspace/viptrue-local/modules/utility/08-egress-snat-manager.sh`
- `bash -n /workspace/viptrue-local/modules/utility/08-egress-snat-manager.sh`
- `printf '0\n' | TERM=xterm bash /workspace/viptrue-local/menus/utility.sh`

Pending checks:

- Full repository `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/08-egress-snat-manager.sh` on a local checkout.
- GitHub Actions ShellCheck, if configured.
- Live SNAT proof on Ubuntu 22.04/24.04 VPS with a second IPv4/Floating IP.
- Live IPv6 proof on a VPS with routed IPv6 and ip6tables NAT support.

## Remaining Issues

- The Codex workspace could not clone GitHub directly in this environment, so
  non-destructive local syntax/smoke checks were run against generated files.
- Live SNAT changes must be tested carefully on a non-critical VPS first.
- IPv6 SNAT/NAT66 support varies by kernel/provider and should be treated as
  optional until proven on the target VPS.

## Next Exact Step

Open the PR for `fasttrack/egress-snat-manager`, wait for checks, review the
diff, then test on one non-critical PasarGuard node with a second IPv4. Ask for
explicit confirmation before creating a GitHub Release/tag for `0.4.7`.
