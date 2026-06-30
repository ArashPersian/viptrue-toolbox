# VIPTrue Server Toolbox

VIPTrue Server Toolbox is a Bash menu toolkit for common VPS setup, firewall,
proxy, tunnel, and diagnostics tasks.

## Run

```bash
bash viptrue.sh
```

Most diagnostics can run as a normal user. Setup actions that change services,
firewall rules, routes, or interfaces require root and should be reviewed before
confirmation.

## Current Focus

The urgent focus is the Tunnel Manager under:

```text
Main Menu -> Work -> Utility Tools -> Tunnel Manager
```

The Tunnel Manager is split into product-oriented and lab-oriented paths:

```text
Tunnel Manager -> Auto Tunnel Expert
Tunnel Manager -> Manual Tunnel Lab
Tunnel Manager -> Manage Existing Tunnels
Tunnel Manager -> Test Existing Tunnels
```

Use Auto Tunnel Expert when you want the toolbox to act like a tunnel selector
before it acts like a builder:

```text
Tunnel Manager -> Auto Tunnel Expert
1. Scan Best Tunnel Between Two Servers
2. Build Selected Tunnel From Scan Result
3. Add Another Foreign Server To Existing Iran Entry
4. Show Engine Registry
5. Explain Engine Families
```

The scanner is generic. WireGuard and Xray are destination examples only; the
scanner does not require `wg0`, WireGuard public keys, Xray, PasarGuard, or any
application already installed behind the tunnel. It asks for server role,
traffic type, Iran/Foreign endpoints, a destination host/port from the foreign
server point of view, and an optional profile name.

Pairing Mode is implemented first:

1. Run `Scan Best Tunnel Between Two Servers` on the Foreign / Exit server to
   print a `VIPTRUE_SCAN_BUNDLE` with no runtime auth secrets.
2. Paste that bundle on the Iran / Entry scanner, or enter values manually.
3. Review the ranked engine table.
4. Use `Build Selected Tunnel From Scan Result` for the implemented
   `hysteria2_obfs_udp` generic UDP forward. Other engines are registered and
   scaffolded for later PRs.

The implemented generic builder creates managed Hysteria2 OBFS UDP forwards
under `/etc/viptrue-hy2-wg-forward/auto/`, keeps the proven salamander OBFS,
`sniGuard: disable`, Bing masquerade, self-signed TLS, and non-443 UDP profile,
and supports one Iran entry server mapping to multiple foreign servers by using
one Iran listen port per foreign mapping.

`VIPTRUE_TUNNEL_BUNDLE` contains operational auth/OBFS secrets. Treat it like a
password: do not paste it into public chats, logs, tickets, or commits.

Manual Tunnel Lab keeps the detailed diagnostics and expert tools for preflight
checks, ports, quality tests, GRE, WireGuard, Hysteria2, reverse TLS/SNI
planning, legacy proven mode, Iran server mode, profile management, and
synthetic WireGuard tests.

Architecture notes:

- [Tunnel Engine Registry](docs/TUNNEL_ENGINE_REGISTRY.md)
- [Tunnel Scanner Architecture](docs/TUNNEL_SCANNER_ARCHITECTURE.md)

For PasarGuard WireGuard nodes, use:

```text
Tunnel Manager -> Hysteria2 OBFS -> WireGuard Forward
```

Use Foreign server mode on each foreign WireGuard host, then Iran server mode to
create one local UDP endpoint per foreign profile. Set each PasarGuard
WireGuard node/profile endpoint to the printed `IRAN_IP:IRAN_PORT` value.

When a real local PasarGuard client cannot reach the Iran endpoint, use the
server-side synthetic test:

```text
Tunnel Manager -> Hysteria2 OBFS -> WireGuard Forward -> Synthetic WireGuard Handshake Test
```

The synthetic test creates a temporary Iran WireGuard client interface, sends it
through the Iran local Hysteria listener, and verifies whether the foreign
WireGuard interface sees a recent handshake and byte movement. It does not
persist the temporary Iran interface, does not persist the foreign test peer to
WireGuard config by default, and does not print the generated private key. Use
the cleanup item afterward to remove the temporary foreign peer and Iran test
interface/key. The UDP-only fallback probe can help debug forwarding, but it
does not prove WireGuard authentication.

If the synthetic test needs `wg` or `ip`, it asks before installing packages.
On apt-based systems, confirming the `wg` prompt installs `wireguard-tools` and
`iproute2`; confirming the `ip` prompt installs `iproute2`. Keep the Iran test
target IP at the default `10.255.255.1` unless you intentionally built a
different synthetic WireGuard address plan.

For the proven legacy foreign-server layout, use:

```text
Tunnel Manager -> Hysteria2 OBFS -> WireGuard Forward -> Legacy Proven Foreign Mode (/etc/hysteria + Bing masquerade)
```

This writes `/etc/hysteria/config.yaml`, generates or preserves
`/etc/hysteria/server.crt` and `/etc/hysteria/server.key`, defaults SNI/CN to
`bing.com`, keeps `sniGuard: disable`, uses salamander OBFS, and sets the
masquerade proxy to `https://www.bing.com/`. In Iran server mode, choose
`Use Legacy Proven Foreign Mode` to default the client profile to port `2087`,
SNI `bing.com`, insecure TLS, and WireGuard forwarding to `127.0.0.1:51820`.

To review or fix an already-generated forward, use:

```text
Tunnel Manager -> Hysteria2 OBFS -> WireGuard Forward -> Manage Existing Hysteria2 WireGuard Forwards
```

The management menu can list profiles, show sanitized details, edit generated
profile fields, archive/delete stale profiles, restart services, and rerun
profile tests. If the wrong WireGuard internal port was entered, edit the
profile and change the remote WireGuard UDP port. If old tunnels conflict, use
Delete profile first so files are moved to the archive instead of removed.

Existing legacy Hysteria2 servers under `/etc/hysteria` are detected in the
same management menu as `legacy-proven-foreign`. Use `Import legacy
/etc/hysteria profile` to copy the legacy config, cert, and key into
`/etc/viptrue-hy2-wg-forward/legacy/<profile>/` and create a managed
`viptrue-hy2-wg-legacy-<profile>.service`. The import keeps the old files and
old service in place unless you explicitly disable the old service after the
managed service is active. Use `Check legacy conflicts` to find duplicate UDP
ports or old/new service overlap.

## Safety

Do not commit real secrets, private keys, production endpoints, or server logs
that expose live credentials. Tunnel helpers should default to diagnostics and
dry-run previews before any server-side change.
