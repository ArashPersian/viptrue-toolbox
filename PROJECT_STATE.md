# PROJECT_STATE

## Project

- Project name: `viptrue-toolbox`
- Repository: `ArashPersian/viptrue-toolbox`
- Current version: `0.3.2`
- Current phase: `Stage 0 — Governance Bootstrap`
- Default branch: `main`
- Working branch: `stage0/governance-bootstrap`
- Current main commit: `b791606e4393aa8af64ec62a3e50bb0c7df1b394`
- Working branch head: `0629f44aab2734655b1d581609f3b5e6a843e36f`
- Latest known tag: `v0.1.3`
- Latest known release: `VIPTrue Server Toolbox v0.1.3`
- Active issue: `#1 — Stage 0: Project Governance Bootstrap`
- Active PR: `#2 — Add project governance files`

## Completed work

- Repository read-only audit completed.
- Current version checked from `VERSION`.
- Missing governance files identified.
- Stage 0 issue created.
- Stage 0 working branch created from `main`.
- Stage 0 governance files added.
- Draft PR opened for review.

## Current menu map

- Main
  - Work
    - Root / SSH Preparation
    - Server Update & Basic Packages
    - UFW Firewall
    - PasarGuard Node
    - Cloudflare XHTTP Nginx Setup
    - Utility Tools
      - Server Factory-like Reset
      - Temporary Tunnel / Proxy for Installations
      - Offline Assets / Local Installer
      - Tunnel Manager
      - Floating IP Manager
      - Cloudflare Clean IP Scanner
  - Private

## Known risks

- `VERSION` is `0.3.2`, while the latest known release is `v0.1.3`; version and release history need reconciliation.
- Several old step scripts exist at repository root and should be audited in Stage 1.
- Some modules can affect real infrastructure and need conservative prompts, dry-run behavior, and clear review.

## Pending decisions

- Whether Stage 0 should be merged as documentation-only governance.
- Whether the next release should reconcile tags and `VERSION` after governance is merged.
- Whether old step scripts should be archived or removed in Stage 1.

## Tests and checks performed

- Read-only repository metadata check.
- `VERSION` check.
- Governance file existence check.
- Menu entry read-through from repository files.
- Draft PR creation check.
- No real server test performed.

## Release policy

- Keep `VERSION`, changelog, release notes, and tag target aligned.
- Release creation requires explicit user approval.
- Release notes must include checks, known risks, and rollback notes when relevant.

## Deployment policy

- No production deployment without explicit user approval.
- Do not assume real execution happened unless user provides output.
- Use placeholders instead of real production details.

## Next Exact Step

Review the Stage 0 Draft PR and either approve merge or request changes.
