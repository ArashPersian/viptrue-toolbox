# Changelog

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
