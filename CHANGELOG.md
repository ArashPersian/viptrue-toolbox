# Changelog

## 0.4.6 - Unreleased

- Added a WaterWall binary runtime self-test before Foreign or Iran services are
  written or started, including explicit Illegal instruction / signal ILL /
  exit code `132` handling.
- Added x86_64 AVX2 compatibility warnings and CPU/binary diagnostics for older
  VPS CPUs that can crash newer WaterWall release binaries.
- Added compatible custom binary override support through
  `VIPTRUE_WATERWALL_BIN` or an interactive fallback prompt after self-test
  failure, with the selected path stored in profile metadata and systemd.
- Added an Iran control-port reachability guard before writing the Iran profile,
  plus a WaterWall port reachability probe menu.
- Expanded WaterWall profile tests with binary self-test, service, listener,
  control-port, local entry-port, and destination-listener diagnostics.
- Scoped failed-service stop/reset prompts to the same managed WaterWall profile.

## 0.4.5 - Unreleased

- Added `Tunnel Manager -> Manual Tunnel Lab -> WaterWall Reverse TLS TCP
  Forward` for private TCP apps such as Syncplay.
- Added Foreign / Exit and Iran / Entry setup flows that generate managed
  WaterWall `core.json`, `config.json`, self-signed TLS material on Foreign,
  and scoped systemd services without stopping unrelated tunnels.
- Added managed WaterWall profile list, details, status, logs, restart,
  archive-only delete, TCP listener checks, UFW-active TCP rule prompts, and
  payload proof commands.
- Promoted the WaterWall Reverse TLS engine registry entry from scaffolded to
  implemented/manual-lab.

## 0.4.4 - Unreleased

- Fixed the Syncplay install prompt value handoff so `service_name` is set before
  the install Plan is printed under `set -u`.
- Routed `Private -> Syncplay Server` through a hotfix wrapper that overrides the
  shadowed prompt function while preserving the existing Syncplay manager.
- Added a regression target for the install prompt path before any root/system
  changes are started.

## 0.4.3 - Unreleased

- Added `Private -> Syncplay Server` with install/reinstall, status, restart,
  stop, logs, change port/password, firewall, and uninstall actions.
- Added an Ubuntu/Debian server installer that installs only the Syncplay server
  path, uses `/opt/syncplay`, runs `make install-server`, and creates a managed
  systemd service.
- Stored Syncplay runtime password and salt in
  `/etc/viptrue/syncplay/syncplay.env` with `chmod 600` instead of placing
  secrets in the systemd command line.
- Added UFW-active TCP port opening, provider firewall reminders, listener
  checks, and client connection output for the default `8999/tcp` port.

## 0.4.2 - Unreleased

- Polished Auto Tunnel Expert scan output with a scan summary card before any
  ranking table.
- Replaced the default 49-engine scan table with compact grouped output for
  buildable, manual, priority-next, planned/external, emergency, and
  application-specific engines.
- Added scan options for building the recommendation, compact ranking, full
  ranking, buildable-only, priority-next, emergency/hard-mode, and optional
  forwarding proof commands.
- Added terminal-safe readiness labels: `YES`, `MAN`, `NEXT`, `PLAN`, `EXT`,
  and `EMRG`.
- Saved scan bundles and v2 tunnel bundles to copy-friendly files while
  distinguishing no-secret scan bundles from operational-secret tunnel bundles.
- Updated scan diagnostics summary wording to show checked scope, result,
  tunnel state, next action, and server-side action.

## 0.4.1 - Unreleased

- Added Auto Tunnel Expert as the top Tunnel Manager product path with scanner,
  selected-build, multi-foreign add, registry, and family explanation actions.
- Added a shell-native Tunnel Engine Registry with UDP/QUIC, TCP/web-like,
  reverse, CDN/operator-specific, DNS emergency, raw IP/kernel, and
  spoof/desync helper families.
- Added adaptive scanner prompts and ranked output using standardized
  dependency, port, listener, status, suitability, speed, and detection-risk
  metadata.
- Added v2 generic Hysteria2 OBFS UDP build flow that does not ask for
  WireGuard or Xray details and preserves the proven non-443 UDP, salamander
  OBFS, `sniGuard: disable`, self-signed TLS, and Bing masquerade profile.
- Improved managed profile listing with protocol, entry port, foreign host,
  destination, service, config path, status, and endpoint suggestion fields.
- Added `docs/TUNNEL_ENGINE_REGISTRY.md` and
  `docs/TUNNEL_SCANNER_ARCHITECTURE.md`.

## 0.4.0 - Unreleased

- Added Auto Tunnel Wizard with a safe two-step pairing-code workflow for
  proven UDP Hysteria2 OBFS WireGuard tunnels.
- Added Auto Foreign/Exit setup that generates runtime auth/OBFS secrets,
  writes the legacy proven `/etc/hysteria` server profile, starts a dedicated
  `viptrue-auto-hy2-foreign-*` service, runs checks, and prints a
  `VIPTRUE_TUNNEL_BUNDLE`.
- Added Auto Iran/Entry setup that parses and validates the bundle, asks for
  the real inbound endpoint, writes a dedicated `viptrue-auto-hy2-iran-*`
  client service, runs quick health checks, and prints the PasarGuard endpoint.
- Added Auto Wizard test actions for temporary peer bundles, synthetic
  WireGuard test handoff, UDP-only fallback commands, and recommended profile
  scoring notes.
- Reorganized Tunnel Manager into Auto Tunnel Wizard, Manual Tunnel Lab,
  Manage Existing Tunnels, Test Existing Tunnels, and Diagnostics Summary while
  keeping the detailed/manual tunnel tools available.
- Improved managed tunnel discovery for auto services, clean manual services,
  old generated services, and legacy `/etc/hysteria` profiles.

## 0.3.9 - Unreleased

- Added interactive dependency install prompts in the Synthetic WireGuard
  Handshake Test when `wg` or `ip` is missing.
- Installs `wireguard-tools` with `iproute2` for missing `wg`, and installs
  `iproute2` for missing `ip`, using apt after explicit confirmation.
- Added Iran synthetic client guidance that the test target IP should normally
  remain `10.255.255.1`, with an extra warning for public IPv4 targets.

## 0.3.8 - Unreleased

- Added a Synthetic WireGuard Handshake Test submenu for Hysteria2 OBFS
  WireGuard forwards.
- Added foreign temporary peer preparation, Iran temporary WireGuard client
  generation, foreign handshake verification, cleanup, and UDP-only fallback
  probes.
- Kept synthetic keys/interfaces temporary by default, with private keys stored
  under a VIPTrue temp directory, `chmod 600`, and deleted by default.
- Added diagnosis output for Iran listener issues, Hysteria client/server
  issues, credential/SNI/insecure mismatches, WireGuard port mismatches, and
  UDP firewall/provider blocks.

## 0.3.7 - Unreleased

- Added Legacy Proven Foreign Mode for `/etc/hysteria` with self-signed TLS,
  `sniGuard: disable`, salamander OBFS, and Bing masquerade defaults.
- Added Iran server preset defaults for the legacy proven foreign style:
  UDP `2087`, SNI `bing.com`, insecure TLS, and WireGuard forwarding.
- Updated raw legacy detection to show `/etc/hysteria/config.yaml` as
  `legacy-proven-foreign` and allow service restart/test from the manager.
- Preserved `masquerade.proxy.rewriteHost: true` in generated foreign configs.

## 0.3.6 - Unreleased

- Added detection for legacy Hysteria2 configs under `/etc/hysteria`.
- Added legacy profile details with masked secrets, service discovery, and
  preserved `sniGuard`, salamander OBFS, and masquerade proxy fields.
- Added import for legacy `/etc/hysteria` profiles into the managed
  Hysteria2 WireGuard directory with archive-before-replace safety.
- Added legacy conflict checks for duplicate UDP ports, listener overlap, and
  simultaneous old/imported service activity.

## 0.3.5 - Unreleased

- Added management for existing Hysteria2 OBFS WireGuard forwards under the
  WireGuard Forward helper.
- Added profile listing, sanitized profile details, edit, delete/archive,
  restart, and test actions for generated foreign and Iran/client profiles.
- Added edit-time validation for non-443 Hysteria2 ports, valid port ranges,
  duplicate Iran listen ports, and local listener conflicts.
- Added archive-first delete safety with exact `DELETE` confirmation and
  rollback path output.

## 0.3.4 - Unreleased

- Added a Hysteria2 OBFS WireGuard multi-forward helper for PasarGuard nodes.
- Added foreign server setup for Hysteria2 OBFS with TLS mode selection,
  systemd service creation, config backups, firewall notes, and WireGuard
  status checks.
- Added Iran server setup for multiple foreign profiles with unique local UDP
  ports, one Hysteria2 client config/service per profile, PasarGuard endpoint
  output, and duplicate-port protection.
- Added a WireGuard handshake wait/confidence test for tunnel validation.

## 0.3.3 - Unreleased

- Added a concise governance baseline for project state, roadmap, agent notes,
  changelog, issue templates, PR template, and advisory ShellCheck workflow.
- Reworked Tunnel Manager around safe diagnostics and command previews for
  preflight checks, port checks, quality tests, GRE, WireGuard, Hysteria2, and
  reverse TLS/SNI planning.
- Enforced the user rule that Hysteria2 should not use UDP port 443.
- Added diagnostics summaries after Tunnel Manager checks.

## 0.3.2

- Previous toolbox state before the urgent Tunnel Manager diagnostics batch.
