# Changelog

## 0.4.9 - Unreleased

- Fixed `modules/utility/04-tunnel-manager-mirror.sh` so extracted legacy Tunnel Manager definitions keep the real repository `BASE_DIR` instead of resolving it from a temporary `/tmp` file. This prevents `//lib/ui.sh: No such file or directory` when opening `Utility Tools -> Tunnel Manager`.
- Replaced the Download / Mirror Manager APT status check with a real isolated `apt-get update` probe that writes package-list state into a temporary directory. This avoids false failures from `apt-get -s update` while keeping the system APT lists untouched.

## 0.4.8 - Unreleased

- Added central `lib/download.sh` with mirror configuration loading, source-order
  fallback, atomic downloads, SHA256 verification, git-or-archive installation,
  apt helpers, command dependency helpers, and versioned asset cache paths.
- Added `Utility Tools -> Download / Mirror Manager` with connectivity checks,
  mirror/CDN configuration, download modes, Iran APT/Snap preferences, offline
  bundle refresh, cached checksum validation, bootstrap commands, and config
  reset.
- Added provider-neutral bootstrap fallback through
  `<mirror>/repo/<branch>.tar.gz` or `VIPTRUE_ARCHIVE_URL`, including optional
  `VIPTRUE_ARCHIVE_SHA256`, non-git archive installation, old-install backup, and
  final source reporting.
- Routed Syncplay repository acquisition through git-or-mirror archive fallback.
- Routed WaterWall release downloads through the central cache and verified the
  pinned SHA256 before extraction, chmod, installation, or execution.
- Routed sing-box metadata, release checksums/assets, and VIPTrue offline bundle
  downloads through mirror-aware compatibility wrappers.
- Added `/etc/viptrue-toolbox/mirror.conf` support for
  `VIPTRUE_MIRROR_BASE`, `VIPTRUE_DOWNLOAD_MODE`, `VIPTRUE_USE_SNAP`,
  `VIPTRUE_APT_REGION`, and `VIPTRUE_ASSET_CACHE`.
- Added Iran mode behavior that forces `VIPTRUE_USE_SNAP=no`, prefers apt
  packages, and explains that CDN delivery does not replace an APT mirror/proxy.
- Documented the CDN layout, manifest/checksum formats, bootstrap examples,
  safety rules, and explicit remaining Hysteria2/Chisel direct-download TODOs.

## 0.4.7 - Unreleased

- Added `Utility Tools -> Egress IP / SNAT Manager` for server-level egress
  IPv4/IPv6 SNAT on PasarGuard nodes with second IPs, Floating IPs, or routed
  IPv6.
- Added read-only egress diagnostics for local addresses, default routes,
  detected IPv4/IPv6 default interfaces, current public egress IPs, forwarding
  state, and managed SNAT/MASQUERADE rule visibility.
- Added IPv4 egress configuration with the safe default limited to VPN/private
  source subnets, plus an explicit whole-server SNAT mode.
- Added readable config, tagged rules, backups, idempotent persistence, and
  rollback limited to VIPTrue-managed SNAT rules.

## 0.4.6 - Unreleased

- Added a WaterWall binary runtime self-test before Foreign or Iran services are
  written or started, including Illegal instruction / signal ILL / exit code
  `132` handling.
- Added x86_64 AVX2 compatibility warnings, custom binary override support, an
  Iran control-port reachability guard, and expanded WaterWall profile tests.

## 0.4.5 - Unreleased

- Added `Tunnel Manager -> Manual Tunnel Lab -> WaterWall Reverse TLS TCP
  Forward` for private TCP apps such as Syncplay.
- Added Foreign / Exit and Iran / Entry setup flows, scoped systemd services,
  managed profiles, archive-only deletion, listener/UFW checks, and proof
  commands.

## 0.4.4 - Unreleased

- Fixed the Syncplay install prompt value handoff under `set -u`.
- Routed `Private -> Syncplay Server` through a hotfix wrapper while preserving
  the existing manager.

## 0.4.3 - Unreleased

- Added `Private -> Syncplay Server` with install/reinstall, status, restart,
  stop, logs, change port/password, firewall, and uninstall actions.
- Added a managed systemd service and protected Syncplay env file.

## 0.4.2 - Unreleased

- Polished Auto Tunnel Expert scan output with a summary card, compact grouped
  ranking, terminal-safe readiness labels, scan options, and copy-friendly
  bundle files.

## 0.4.1 - Unreleased

- Added Auto Tunnel Expert, the shell-native Tunnel Engine Registry, adaptive
  scanner prompts/ranking, a generic Hysteria2 OBFS UDP builder, and architecture
  documentation.

## 0.4.0 - Unreleased

- Added Auto Tunnel Wizard with pairing-code workflow, Foreign/Exit and
  Iran/Entry setup, synthetic tests, and reorganized tunnel management menus.

## 0.3.9 - Unreleased

- Added interactive dependency installation for synthetic WireGuard tests and
  improved target-IP guidance.

## 0.3.8 - Unreleased

- Added the Synthetic WireGuard Handshake Test submenu, temporary peer/client
  setup, cleanup, UDP fallback probes, and diagnosis output.

## 0.3.7 - Unreleased

- Added Legacy Proven Foreign Mode for `/etc/hysteria`, Bing masquerade defaults,
  Iran presets, and raw legacy detection.

## 0.3.6 - Unreleased

- Added legacy Hysteria2 config detection, sanitized details, managed import,
  and conflict checks.

## 0.3.5 - Unreleased

- Added management for existing Hysteria2 OBFS WireGuard forwards, including
  list, details, edit, archive/delete, restart, test, and validation.

## 0.3.4 - Unreleased

- Added Hysteria2 OBFS WireGuard multi-forward setup for Foreign and Iran
  servers, profile protection, and handshake confidence tests.
- Enforced the rule that Hysteria2 must not use UDP port 443.

## 0.3.2

- Previous toolbox state before the urgent Tunnel Manager diagnostics batch.
