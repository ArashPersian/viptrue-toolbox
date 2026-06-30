# Changelog

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
