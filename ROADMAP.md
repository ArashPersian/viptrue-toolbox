# ROADMAP

This roadmap keeps `viptrue-toolbox` development stage-based, reviewable, and release-aware.

## Stage 0 — Governance Bootstrap

Create project management files, README, state tracking, roadmap, agent instructions, templates, and check policy.

## Stage 1 — Repository Audit And Stabilization

Audit the current structure, review old step scripts, standardize modules, and verify menu paths, versioning, and installation assumptions.

## Stage 2 — Test Harness And Static Checks

Add ShellCheck, Bash syntax checks, no-confidential-data scan, install dry-run checks, menu path validation, and service-template validation.

## Stage 3 — Installer And Update Safety

Harden the bootstrap/update flow with backup policy, rollback notes, version pinning, safe update behavior, branch override rules, and dirty-worktree handling.

## Stage 4 — Menu UX And Navigation Stabilization

Improve menu navigation, back/exit behavior, user-facing messages, error handling, confirmation prompts, and RTL/LTR-friendly output.

## Stage 5 — PasarGuard Node Module Hardening

Clarify Node Port vs API Port, add input validation, health checks, logs, and safe rollback behavior.

## Stage 6 — Tunnel Manager Stabilization

Stabilize testing, preflight, quality checks, persistent service helpers, and safe port rules.

## Stage 7 — Offline Assets Automation

Automate offline asset setup, bundle import, cached installer behavior, and release asset handling.

## Stage 8 — Proxy Mode And Subscription Tools

Improve config parsing, active selection, delay sorting, service mode, and diagnostics.

## Stage 9 — Cloudflare/Nginx Tools

Improve XHTTP helper, certificate paste flow, TLS checks, and logging hygiene.

## Stage 10 — Floating IP Manager

Add provider-specific helpers with safe prompts and no destructive default behavior.

## Stage 11 — Release Packaging

Prepare GitHub Release automation, assets, checksums, changelog alignment, and rollback notes.

## Stage 12 — Production-ready v1.0

Ship a clean stable release with tested installer, docs, rollback, checks, and known limitations.

## Operating rule

Only one stage should be actively implemented per PR unless the user explicitly approves a larger batch. Merge, tag, release, production deployment, and high-impact real tests require explicit user approval.
