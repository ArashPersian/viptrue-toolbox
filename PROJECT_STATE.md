# Project State

Version: 0.4.6
Branch: fasttrack/waterwall-preflight-and-probe
Base commit: 4306e2472d7ab5d07a607f70c7a4b8c4265193bf
Commit: pending PR branch
PR status: preparing WaterWall preflight and reachability guard
Release status: no release, tag, or deploy planned for this batch

## Scope

- Patch `Tunnel Manager -> Manual Tunnel Lab -> WaterWall Reverse TLS TCP
  Forward` before more live VPS testing.
- Add a WaterWall binary self-test before any Foreign or Iran service write/start.
- Detect Illegal instruction / invalid opcode / core dump / exit code `132` and
  report CPU/binary incompatibility with CPU and binary hints.
- Warn on x86_64 hosts without AVX2, because some WaterWall release binaries may
  require newer CPUs.
- Add compatible custom binary support through `VIPTRUE_WATERWALL_BIN` or an
  interactive fallback path after self-test failure.
- Add an Iran control-port reachability guard and a standalone port reachability
  probe menu.
- Keep failed-service recovery scoped to the same managed WaterWall profile.

## Safety Rules

- Do not create or start WaterWall services if the selected binary fails the
  runtime self-test.
- Do not hide self-test failures behind `|| true` before capturing the real exit
  code.
- Do not stop unrelated tunnels or unrelated services.
- Do not hard-delete managed files; use archive/reset workflows only.
- Do not commit real endpoints, secrets, private keys, releases, tags, or
  deployments.

## Checks

Local checks run:

- `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- `git diff --check`
- WaterWall menu smoke test.
- Foreign setup reaches pre-write plan.
- Iran setup reaches pre-write plan and defaults to not continuing when the
  Foreign control port probe fails.
- Port reachability probe menu smoke test.
- Static/function harness for self-test rc capture, Illegal instruction,
  `signal=ILL`, exit code `132`, AVX2 warning-only behavior, setup line order,
  and same-profile reset scope.
- Local ShellCheck unavailable on this Windows host.

Pending remote check:

- GitHub Actions ShellCheck on the PR.

## Remaining Issues

- Live end-to-end WaterWall packet proof still needs two controlled Linux VPSes
  with a compatible WaterWall binary and a real destination TCP listener.
- If the release binary crashes on an old CPU, use a newer VPS CPU or provide a
  compatible binary path.
- Provider/security-group firewalls must allow the selected Iran entry TCP port
  and Foreign tunnel control TCP port.

## Next Exact Step

Open the PR, wait for GitHub Actions/ShellCheck, inspect the diff scope, and
merge into `main` only if checks pass. Do not release, tag, or deploy.
