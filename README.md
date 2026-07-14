# VIPTrue Server Toolbox

VIPTrue Server Toolbox is a Bash menu toolkit for VPS setup, firewall, proxy,
tunnel, egress, download, and diagnostics tasks.

Current version: **0.4.8**

## Run

```bash
bash viptrue.sh
```

Actions that change packages, services, firewall rules, routes, or files under
`/etc/viptrue-toolbox` require root and show a confirmation or plan first.

## Install or Update

The normal GitHub-first command remains unchanged:

```bash
curl -fsSL https://raw.githubusercontent.com/ArashPersian/viptrue-toolbox/main/bootstrap.sh | sudo bash
```

If git clone/fetch fails and a mirror is configured, `bootstrap.sh` can install:

```text
<VIPTRUE_MIRROR_BASE>/repo/<branch>.tar.gz
```

A provider-neutral explicit fallback is also supported:

```bash
sudo env VIPTRUE_ARCHIVE_URL=https://cdn.example.com/viptrue/repo/main.tar.gz \
  bash bootstrap.sh
```

Archive installs do not require `.git`. The bootstrap backs up the old local
installation before replacement and prints whether the source was `git`,
`mirror archive`, or `archive URL`.

## Download / Mirror Manager

Version 0.4.8 adds:

```text
Main Menu -> Work -> Utility Tools -> Download / Mirror Manager
```

The manager centralizes toolbox, repository, and release-asset acquisition for
Iran VPSes and other networks where GitHub raw URLs, git clone, release assets,
or Snap may be unreliable.

Configuration:

```text
/etc/viptrue-toolbox/mirror.conf
```

Supported settings:

```ini
VIPTRUE_MIRROR_BASE=
VIPTRUE_DOWNLOAD_MODE=mirror-first|official-first|mirror-only|official-only
VIPTRUE_USE_SNAP=yes|no
VIPTRUE_APT_REGION=auto|iran|default
VIPTRUE_ASSET_CACHE=/var/cache/viptrue-toolbox/assets
```

With no mirror configured, the default is `official-first`, so existing normal
install behavior is preserved.

Expected mirror/CDN layout:

```text
<mirror>/bootstrap.sh
<mirror>/repo/main.tar.gz
<mirror>/assets/<name>/<version>/<file>
<mirror>/manifest.json
<mirror>/checksums.txt
```

The central API is `lib/download.sh`. It provides source ordering, explicit
PASS/FAIL diagnostics, atomic partial downloads, SHA256 verification, git or
archive installation, apt helpers, and asset-cache paths.

Refactored high-risk paths in 0.4.8:

- bootstrap git/archive fallback;
- WaterWall release download and checksum-before-install;
- Syncplay git/archive acquisition;
- sing-box release/checksum caching;
- VIPTrue offline-assets bundle download.

Selecting Iran APT mode forces `VIPTRUE_USE_SNAP=no` and prefers apt packages.
A CDN fixes toolbox and asset delivery; APT still needs a reachable Ubuntu or
Debian mirror/proxy.

Full guide: [Download / Mirror Manager](docs/DOWNLOAD_MIRROR_MANAGER.md)

## Utility Tools

```text
1. Server Factory-like Reset
2. Temporary Tunnel / Proxy for Installations
3. Offline Assets / Local Installer
4. Tunnel Manager
5. Floating IP Manager
6. Cloudflare Clean IP Scanner
7. Egress IP / SNAT Manager
8. Download / Mirror Manager
```

## Syncplay Server

```text
Main Menu -> Private -> Syncplay Server
```

The active wrapper now calls `viptrue_git_or_archive`. The default official
source remains the Syncplay git repository; mirror modes use:

```text
assets/syncplay/master/syncplay-master.tar.gz
```

Runtime passwords and salts remain in the protected Syncplay environment file
and are not added to mirror configuration or normal status output.

## Tunnel Manager and WaterWall

```text
Main Menu -> Work -> Utility Tools -> Tunnel Manager
```

The active WaterWall path uses the central asset cache and the documented mirror
layout. Its pinned SHA256 is checked before extraction, chmod, installation, or
execution. Snap is not required for this path.

The large legacy Tunnel Manager still contains older Hysteria2/Chisel-related
direct acquisition code. These remaining paths are marked and documented as
`TODO(download-manager)` instead of being silently claimed as migrated.

## Offline Assets / sing-box

The active Offline Assets wrapper routes sing-box metadata, checksum files,
release archives, and VIPTrue offline bundles through the central download
layer. sing-box archives must pass SHA256 verification before they are copied to
the local offline cache or installed.

## Egress IP / SNAT Manager

```text
Main Menu -> Work -> Utility Tools -> Egress IP / SNAT Manager
```

Use server-level SNAT when each VPS should expose its own secondary IPv4,
floating IP, or routed IPv6. Use Xray `sendThrough` when one server has multiple
hosts/addresses and routing should happen inside one Xray core.

## Download Safety

- Failed sources are reported and never silently ignored.
- Partial downloads use temporary `.part` files and atomic moves.
- SHA256 is verified whenever an expected checksum is provided.
- Downloaded WaterWall and sing-box files are not executed before verification.
- `mirror.conf` is parsed as a whitelist of supported keys, not evaluated as a
  shell script.
- Do not store secrets, private keys, production endpoints, or private CDN
  hostnames in repository files, manifests, checksums, or logs.
