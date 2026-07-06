# Egress IP / SNAT Manager

`Egress IP / SNAT Manager` is available under:

```text
Main Menu -> Work -> Utility Tools -> Egress IP / SNAT Manager
```

It is designed for PasarGuard deployments where a shared Core/Node pattern is
used across multiple real VPSes, but each VPS must expose its own egress IP to
websites and remote services.

## When To Use

- Use Xray `sendThrough` when one server has multiple hosts or multiple egress
  addresses and you want routing decisions inside that single core.
- Use server-level SNAT when each real server has its own second IPv4, Floating
  IP, or IPv6 and traffic should leave from that server's selected address.

## Safety Model

- The tool only manages NAT `POSTROUTING` rules.
- It does not create `INPUT` rules.
- It does not change the default route.
- It does not edit UFW rules.
- Every managed rule is tagged with `VIPTRUE_EGRESS_SNAT`.
- Rollback removes only rules with that tag.
- Before apply or rollback, it writes an iptables backup under:

```text
/root/viptrue-iptables-backup-TIMESTAMP.rules
```

## Config And Persistence

Readable config:

```text
/etc/viptrue-toolbox/egress-snat.conf
```

Persistence uses `netfilter-persistent` when selected. Otherwise it creates:

```text
viptrue-egress-snat.service
```

The service reapplies the readable config and removes/re-adds only managed
rules, so repeated execution is idempotent.

## Recommended IPv4 Scope

The safe default is to SNAT only VPN/private source subnets, such as:

```text
10.0.0.0/8
10.99.0.0/24
172.16.0.0/12
192.168.0.0/16
```

Whole-server SNAT is available but requires explicit selection.

## IPv6 Note

IPv6 egress only affects sites and apps that support IPv6. NAT66 also depends on
kernel/provider support for `ip6tables -t nat`.
