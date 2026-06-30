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

The Tunnel Manager now prioritizes safe diagnostics and command previews for
preflight checks, ports, quality tests, GRE, WireGuard, Hysteria2, and reverse
TLS/SNI planning.

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
