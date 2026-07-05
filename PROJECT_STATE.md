# Project State

Version: 0.4.5
Branch: fasttrack/waterwall-reverse-tcp-forward
Base commit: d47d0b4 Merge pull request #14 from ArashPersian/fasttrack/fix-syncplay-install-prompt
Commit: pending PR branch
PR status: preparing WaterWall Reverse TLS TCP helper
Release status: no release, tag, or deploy planned for this batch

## Scope

- Add `Tunnel Manager -> Manual Tunnel Lab -> WaterWall Reverse TLS TCP Forward`.
- Support Foreign / Exit setup and Iran / Entry setup for private TCP apps.
- Generate managed WaterWall configs, `core.json`, systemd services, Foreign
  self-signed TLS material, and UFW-active TCP prompts.
- Add managed profile list, details, status, logs, restart, archive-only delete,
  and test/proof-command actions.
- Preserve safety constraints: no unrelated tunnel stops, no hard deletion, no
  real secrets or production endpoint configs in the repo.

## Route

```text
Iran 0.0.0.0:<entry_port> -> WaterWall Reverse TLS -> Foreign <dest_host>:<dest_port>
```

Syncplay-shaped example:

```text
Iran public IP:5049 -> Foreign 127.0.0.1:5049
```

Use a separate tunnel control TCP port, for example `8443`, between Iran and
Foreign.

## Checks

Planned checks before merge:

- `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- Menu smoke test to `Manual Tunnel Lab -> WaterWall Reverse TLS TCP Forward`.
- Static review of generated WaterWall `core.json` / `config.json` shapes
  against upstream node docs and test fixtures.
- Archive-only delete safety review.
- `git diff --check`
- ShellCheck locally if available.
- GitHub Actions ShellCheck on the PR.

## Remaining Issues

- Full end-to-end WaterWall packet proof still needs two controlled Linux VPSes
  with the downloaded WaterWall binary and a real destination TCP listener.
- Provider/security-group firewalls must allow the selected Iran entry TCP port
  and Foreign tunnel control TCP port.
- The helper uses a self-signed Foreign TLS certificate and `TlsClient`
  `verify: false` for this private tunnel workflow.

## Next Exact Step

Open the PR, wait for GitHub Actions/ShellCheck, inspect that the diff only
contains this WaterWall helper/documentation/version batch, and merge into
`main` only if checks pass. Do not release, tag, or deploy.
