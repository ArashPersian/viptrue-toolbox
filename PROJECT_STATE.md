# Project State

Version: 0.4.8
Branch: fasttrack/download-mirror-manager
Base commit: 54488fae726037d7edbc54b59bee9f68abbebe91
Commit: pending PR branch commit
PR status: preparing Fast Track: Download Mirror Manager
Release status: no release, tag, or deploy in this batch

## Scope

- Add a central mirror-aware download API in `lib/download.sh`.
- Add `Utility Tools -> Download / Mirror Manager`.
- Add provider-neutral bootstrap git/archive fallback.
- Preserve official GitHub-first behavior when no mirror is configured.
- Support mirror-first, official-first, mirror-only, and official-only modes.
- Add the central asset cache under
  `/var/cache/viptrue-toolbox/assets` by default.
- Refactor active WaterWall, Syncplay, sing-box, and offline bundle acquisition
  paths through the central layer.
- Document mirror layout, manifest/checksum conventions, Iran compatibility, and
  remaining direct-download work.

## Safety Rules

- Do not commit secrets, credentials, private CDN domains, production endpoints,
  release tags, or deployment configuration.
- Parse only whitelisted mirror config keys; do not evaluate `mirror.conf` as a
  shell script.
- Never silently ignore a failed download.
- Use partial files and atomic moves for completed downloads.
- Verify SHA256 before chmod/install/execute whenever a checksum is supplied.
- Keep normal non-Iran installs working with official-first defaults.
- Iran mode forces `VIPTRUE_USE_SNAP=no`; apt still requires its own reachable
  mirror or proxy.
- No release, tag, deploy, production secret, endpoint, or real traffic change is
  included.

## Checks

Local checks run:

- `bash -n viptrue.sh menus/main.sh menus/work.sh menus/utility.sh lib/download.sh modules/utility/*mirror*.sh`
- `bash -n bootstrap.sh`
- Utility menu smoke confirms `Download / Mirror Manager` is visible and Back
  returns cleanly.
- Config write/read smoke with a temporary `VIPTRUE_CONFIG_FILE`.
- Static mirror-first order/fallback test with local file-backed fetch stubs.
- Static bootstrap archive fallback path check for
  `VIPTRUE_MIRROR_BASE/repo/<branch>.tar.gz` and `VIPTRUE_ARCHIVE_URL`.
- Repository scan confirms no hardcoded private CDN domain in changed files.
- ShellCheck workflow expanded to include the central library, wrappers, and
  manager; GitHub Actions result remains the remote source of truth.

## Refactored Download Paths

- `bootstrap.sh`: GitHub git path plus mirror/archive fallback.
- WaterWall release ZIP: central asset cache and pinned SHA256 verification.
- Syncplay: git clone/update or mirror archive.
- sing-box: release metadata, checksum, and archive through central fetch.
- VIPTrue offline assets bundle: official/mirror source through central fetch.

## Remaining Issues / TODOs

- The legacy `modules/utility/04-tunnel-manager.sh` remains a large monolithic
  module with older Hysteria2/Chisel acquisition paths. The active WaterWall
  menu now runs through `04-tunnel-manager-mirror.sh`, but remaining release
  fetches must be split into smaller modules and migrated to
  `viptrue_fetch_url`.
- Public-IP lookup and connectivity probe URLs are diagnostics, not install
  assets, and remain direct by design.
- A real mirror/CDN must publish the documented layout and checksums before
  mirror-only mode can be proven end to end on an Iran VPS.
- APT access must be tested separately because the VIPTrue CDN does not proxy
  distro repositories.

## Next Exact Step

Open `Fast Track: Download Mirror Manager`, wait for GitHub Actions/ShellCheck,
inspect the changed-file scope, and merge into `main` only if checks are green or
advisory-only with no actionable errors. Do not release, tag, or deploy.
