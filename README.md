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

## Safety

Do not commit real secrets, private keys, production endpoints, or server logs
that expose live credentials. Tunnel helpers should default to diagnostics and
dry-run previews before any server-side change.
