# Project State

Version: 0.4.7
Branch: fasttrack/waterwall-auto-cpu-installer
Base commit: a72cc3f14b3d71499db89bc80f2c47bcc858e8e3
Commit: pending PR branch
PR status: preparing WaterWall auto CPU installer
Release status: no release, tag, or deploy planned for this batch

## Scope

- Extend `Tunnel Manager -> Manual Tunnel Lab -> WaterWall Reverse TLS TCP
  Forward` with automatic CPU-aware WaterWall binary selection.
- Keep `VIPTRUE_WATERWALL_BIN` as the first-choice override.
- Self-test every selected WaterWall binary before profile config, systemd, or
  service start steps can run.
- Detect old x86_64 CPUs without AVX2 and offer an automatic WaterWall source
  build using the `linux-gcc-x64-old-cpu` preset.
- Install the compatible old-CPU binary at
  `/opt/viptrue-waterwall/bin/waterwall-oldcpu`.
- Store the selected binary path in `profile.meta` as `waterwall_bin` and use
  that path in generated systemd services.
- Add a standalone `Auto install compatible WaterWall binary` WaterWall menu
  action with CPU summary and default-No install/build prompts.

## Safety Rules

- Do not create or start WaterWall services if the selected binary fails the
  runtime self-test.
- Do not silently install packages; dependency and build prompts default to No.
- Do not hard-delete arbitrary paths; only reset the configured safe temporary
  build directory after safety checks.
- Do not stop unrelated tunnels or unrelated services.
- Do not force symlink or replace `/usr/local/bin/waterwall` when the old-CPU
  binary is built; prefer per-profile `waterwall_bin` paths.
- Do not commit real endpoints, secrets, private keys, releases, tags, or
  deployments.

## Checks

Local checks run:

- `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh modules/utility/04-tunnel-manager.sh`
- `git diff --check` (passed; Windows checkout reported LF-to-CRLF warnings only)
- WaterWall menu smoke test including `Auto install compatible WaterWall binary`.
- Existing WaterWall menu route smoke tests for Foreign setup pre-write cancel,
  Iran setup control-port fail-closed, and port reachability probe.
- Static/function harness for `VIPTRUE_WATERWALL_BIN` precedence, missing AVX2
  old-CPU suggestion, Illegal instruction / `signal=ILL` / exit code `132`
  old-CPU build offer path, default-No install/build prompts, selected
  `waterwall_bin` persistence, no-write/no-start ordering, and same-profile
  reset scope.
- Static service check that generated systemd uses
  `ExecStart=$bin_path --run -c core.json`.
- No real endpoints/secrets diff scan; only the documented base commit hash
  matched the broad token pattern.
- Local ShellCheck unavailable on this Windows host.

Pending remote check:

- GitHub Actions ShellCheck on the PR.

## Remaining Issues

- Live old-CPU WaterWall source build still needs an apt-based Linux VPS with
  network access, cmake/snap availability, and enough CPU/RAM for compilation.
- Live end-to-end WaterWall packet proof still needs two controlled Linux VPSes
  with the destination TCP app and provider firewalls allowing the chosen ports.

## Next Exact Step

Run local checks, open the PR, wait for GitHub Actions/ShellCheck, inspect the
diff scope, and merge into `main` only if checks pass. Do not release, tag, or
deploy.
