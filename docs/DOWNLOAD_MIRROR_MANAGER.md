# Download / Mirror Manager

VIPTrue Toolbox 0.4.8 adds a central mirror-aware download layer for VPSes where
GitHub raw URLs, repository clones, release assets, or Snap may be unreliable.
The feature is provider-neutral: the mirror can be any HTTP(S) CDN, object
storage endpoint, web server, or reverse proxy that serves the documented
layout.

## Menu

```text
Main Menu -> Work -> Utility Tools -> Download / Mirror Manager
```

The manager can test official and mirror connectivity, configure the base URL
and source order, set Iran-oriented APT/Snap preferences, refresh an offline
assets bundle, validate cached files, show bootstrap commands, and reset the
configuration.

## Central Configuration

The default configuration file is:

```text
/etc/viptrue-toolbox/mirror.conf
```

Supported keys:

```ini
VIPTRUE_MIRROR_BASE=
VIPTRUE_DOWNLOAD_MODE=official-first
VIPTRUE_USE_SNAP=yes
VIPTRUE_APT_REGION=auto
VIPTRUE_ASSET_CACHE=/var/cache/viptrue-toolbox/assets
```

Valid values:

- `VIPTRUE_DOWNLOAD_MODE`: `mirror-first`, `official-first`, `mirror-only`, or
  `official-only`.
- `VIPTRUE_USE_SNAP`: `yes` or `no`.
- `VIPTRUE_APT_REGION`: `auto`, `iran`, or `default`.
- `VIPTRUE_ASSET_CACHE`: an absolute local directory.

The parser reads only the supported keys. It does not evaluate shell commands,
and the file must not contain tokens, passwords, private endpoints, or other
secrets.

When no mirror is configured, the default remains `official-first`, which keeps
normal non-Iran behavior: official GitHub/git/release sources are tried first.

## Download Modes

| Mode | Order and network policy |
| --- | --- |
| `mirror-first` | Try the configured mirror, then the official source. |
| `official-first` | Try the official source, then the configured mirror. |
| `mirror-only` | Never contact the official source. Fail clearly if a mirror object is unavailable. |
| `official-only` | Keep official-only behavior and never contact the configured mirror. |

Every attempted source prints an `INFO`, `PASS`, or `FAIL` diagnostic. A failed
download is never silently ignored, and partial files use a `.part` path before
an atomic move to the requested destination.

## Expected Mirror / CDN Layout

```text
<mirror>/bootstrap.sh
<mirror>/repo/main.tar.gz
<mirror>/assets/<name>/<version>/<file>
<mirror>/manifest.json
<mirror>/checksums.txt
```

For another branch, publish its repository archive at:

```text
<mirror>/repo/<branch>.tar.gz
```

Examples:

```text
https://cdn.example.com/viptrue/bootstrap.sh
https://cdn.example.com/viptrue/repo/main.tar.gz
https://cdn.example.com/viptrue/assets/waterwall/1.46.3/Waterwall-linux-gcc-x64.zip
https://cdn.example.com/viptrue/assets/sing-box/1.13.12/sing-box-1.13.12-linux-amd64.tar.gz
https://cdn.example.com/viptrue/assets/syncplay/master/syncplay-master.tar.gz
https://cdn.example.com/viptrue/assets/offline-bundle/0.4.8/viptrue-offline-assets-0.4.8.tar.gz
```

No private CDN hostname is built into the repository. `cdn.example.com` is only
an example placeholder.

## Manifest and Checksums

`manifest.json` may contain mirror metadata and latest-version hints. The
sing-box compatibility wrapper recognizes either the official GitHub release
`tag_name` field or a mirror hint shaped like this:

```json
{
  "sing-box": {
    "latest": "1.13.12"
  }
}
```

`checksums.txt` should use the standard SHA256 format:

```text
<64-hex-sha256>  assets/<name>/<version>/<file>
```

A basename-only second field is also accepted by the cache validator. Keep file
names unique when using basename-only entries.

Downloaded executables and archives remain cached files until verification and
an explicit installation/import action. WaterWall and sing-box verify SHA256
before a binary is chmodded, installed, or run. A mismatch deletes the failed
cache entry and stops the operation.

## Bootstrap Fallback

Default command:

```bash
curl -fsSL https://raw.githubusercontent.com/ArashPersian/viptrue-toolbox/main/bootstrap.sh | sudo bash
```

Mirror-first command:

```bash
curl -fsSL https://cdn.example.com/viptrue/bootstrap.sh \
  | sudo env VIPTRUE_MIRROR_BASE=https://cdn.example.com/viptrue \
      VIPTRUE_DOWNLOAD_MODE=mirror-first bash
```

Explicit archive fallback:

```bash
curl -fsSL https://cdn.example.com/viptrue/bootstrap.sh \
  | sudo env VIPTRUE_ARCHIVE_URL=https://cdn.example.com/viptrue/repo/main.tar.gz bash
```

Optional archive checksum:

```bash
sudo env \
  VIPTRUE_ARCHIVE_URL=https://cdn.example.com/viptrue/repo/main.tar.gz \
  VIPTRUE_ARCHIVE_SHA256=<64-hex-sha256> \
  bash bootstrap.sh
```

The bootstrap keeps GitHub git clone/fetch as the default. On failure it uses
`VIPTRUE_ARCHIVE_URL`, or `<VIPTRUE_MIRROR_BASE>/repo/<branch>.tar.gz`. Archive
installs do not need `.git`. Existing local installs are archived and moved to
the backup root before replacement. The final report prints `git`,
`mirror archive`, or `archive URL` as the install source.

## Iran Compatibility

Selecting `VIPTRUE_APT_REGION=iran` in the menu forces:

```ini
VIPTRUE_USE_SNAP=no
```

The updated WaterWall path uses apt packages such as `curl`, `unzip`, and
`coreutils`; it does not require Snap. The mirror-aware sing-box and Syncplay
paths also prefer apt plus cached archives.

A CDN fixes VIPTrue bootstrap, repository archive, and asset delivery. It does
**not** automatically fix Ubuntu/Debian APT repositories. If `apt-get update`
fails, configure a reachable APT mirror or proxy separately. The status screen
reports this distinction explicitly.

## Central Shell API

`lib/download.sh` provides:

```text
viptrue_load_mirror_config
viptrue_download_status
viptrue_fetch_url official_url mirror_path dest
viptrue_fetch_with_fallback official_url mirror_path dest
viptrue_verify_sha256 file expected
viptrue_git_or_archive repo_url branch install_dir mirror_archive_path
viptrue_apt_install package...
viptrue_need_cmd command package
viptrue_asset_cache_path name version file
```

Modules should use these helpers instead of adding new direct `curl`, `wget`,
`git clone`, or Snap installation paths.

## Refactored Paths in 0.4.8

- `bootstrap.sh`: git plus mirror/archive fallback.
- WaterWall release asset download: central cache, source fallback, and SHA256
  verification before install.
- Syncplay repository acquisition: git or mirror archive.
- sing-box release/checksum acquisition and VIPTrue offline bundle download:
  central mirror-aware cache.

## Remaining Direct-Download TODOs

The legacy `modules/utility/04-tunnel-manager.sh` is more than 8,000 lines and
still contains older Hysteria2/Chisel-related acquisition paths. Version 0.4.8
routes the active WaterWall entry through
`04-tunnel-manager-mirror.sh`, and includes this code marker:

```text
TODO(download-manager): split remaining legacy Hysteria2/Chisel release fetches
out of 04-tunnel-manager.sh and route them through viptrue_fetch_url.
```

Future download code should be split into smaller modules and migrated before
new release endpoints are added. Direct diagnostic HTTP calls such as public-IP
lookups are not installation downloads and are outside the asset mirror layer.

## Safety

- Do not place secrets in `mirror.conf`, manifests, URLs, logs, or checksums.
- Do not commit production endpoints or private CDN domains.
- Use HTTPS for public mirrors.
- Publish immutable versioned assets and update `checksums.txt` atomically.
- Test `mirror-only` on a non-critical VPS before depending on it for recovery.
- Keep an official bootstrap copy available for non-Iran installations.
