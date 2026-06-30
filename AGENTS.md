# Agent Notes

- Start work from current `main` unless the user explicitly names another base.
- Do not build on `stage0/governance-bootstrap`.
- Do not force-push or rewrite `main`.
- Do not create releases, tags, deployments, production forwarding, real
  private keys, or real production endpoint configs without explicit user
  approval.
- Keep Tunnel Manager changes safety-first: diagnostics, previews, and explicit
  confirmations before server-side mutations.
- Run targeted shell syntax checks before opening PRs.
