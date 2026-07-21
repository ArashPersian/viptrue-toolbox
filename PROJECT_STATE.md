# Project State

Version: 0.4.9
Branch: fasttrack/v049-mirror-wrapper-fixes
Base commit: 42e5beac0ebe503a156efb2f2eb1b8ed3213e621
Commit: pending PR branch commit
PR status: preparing Fast Track: Mirror Wrapper Fixes
Release status: no release, tag, or deploy in this batch

## Scope

- Fix `modules/utility/04-tunnel-manager-mirror.sh` so extracted legacy Tunnel
  Manager definitions sourced from `/tmp` keep the real repository `BASE_DIR`.
- Prevent `//lib/ui.sh: No such file or directory` when opening
  `Utility Tools -> Tunnel Manager` through the mirror-aware wrapper.
- Replace the Download / Mirror Manager APT status test with an isolated real
  `apt-get update` probe that writes lists/cache into a temporary directory.
- Keep the system APT lists untouched while avoiding false failures from
  `apt-get -s update` on Ubuntu servers.
- Bump the toolbox version to `0.4.9` and document the fix.

## Safety Rules

- No secrets, credentials, private CDN domains, production endpoints, release
  tags, or deployment configuration were added.
- No traffic forwarding, firewall rule, route, service, or production behavior is
  changed by this patch.
- The APT probe runs with temporary list/cache directories and removes them after
  the check.
- The Tunnel Manager wrapper still loads the legacy manager definitions and only
  pins `BASE_DIR` before sourcing the temporary definitions file.
- No release, tag, deploy, production secret, endpoint, or real traffic change is
  included.

## Checks

Planned / expected checks for this PR:

- `bash -n modules/utility/04-tunnel-manager-mirror.sh`
- `bash -n modules/utility/09-download-mirror-manager.sh`
- `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh lib/download.sh modules/utility/*mirror*.sh`
- Smoke: `Utility Tools -> Tunnel Manager` opens without `//lib/ui.sh` error.
- Smoke: `Utility Tools -> Download / Mirror Manager -> Show download connectivity status` reports the APT probe correctly on an Ubuntu server where `apt-get update` works.
- GitHub Actions ShellCheck remains the remote source of truth if configured.

## Remaining Issues / TODOs

- The legacy `modules/utility/04-tunnel-manager.sh` remains a large monolithic
  module with older Hysteria2/Chisel acquisition paths. The active WaterWall
  menu now runs through `04-tunnel-manager-mirror.sh`, but remaining release
  fetches must still be split into smaller modules and migrated to
  `viptrue_fetch_url`.
- Public-IP lookup and connectivity probe URLs are diagnostics, not install
  assets, and remain direct by design.
- Mirror asset coverage for WaterWall/sing-box/Syncplay must still be completed
  in the external Arvan/Cloudflare bucket before full `mirror-only` asset tests.

## Next Exact Step

Open `Fast Track: Mirror Wrapper Fixes`, wait for GitHub Actions/ShellCheck,
merge only if syntax/ShellCheck pass, then update the Arvan mirror archive
`repo/main.tar.gz` and `checksums.txt` to contain version `0.4.9`. Do not
release, tag, or deploy without explicit confirmation.
