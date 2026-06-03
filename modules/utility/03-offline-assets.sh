#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

ASSETS_DIR="$BASE_DIR/assets"
SINGBOX_ASSETS_DIR="$ASSETS_DIR/sing-box"
REPO_SLUG="ArashPersian/viptrue-toolbox"

TUNNEL_DIR="/opt/viptrue-temp-tunnel"
SINGBOX_TARGET_DIR="$TUNNEL_DIR/bin"
SINGBOX_TARGET_BIN="$SINGBOX_TARGET_DIR/sing-box"

detect_arch() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    i386|i686) echo "386" ;;
    *) echo "" ;;
  esac
}

latest_singbox_version() {
  curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"v?([^"]+)".*/\1/'
}

show_arch() {
  title
  echo -e "${CYAN}System Architecture${NC}"
  line
  echo
  echo "uname -m:"
  uname -m
  echo
  echo "VIPTrue detected arch:"
  detect_arch
  echo
  echo "Most Ubuntu VPS servers are:"
  echo "x86_64 -> amd64"
  echo
  pause
}

cache_singbox_binary() {
  title
  echo -e "${CYAN}Cache sing-box Binary from Official Release${NC}"
  line
  echo

  mkdir -p "$SINGBOX_ASSETS_DIR"

  local arch version asset url checksum_file
  arch="$(detect_arch)"

  if [[ -z "$arch" ]]; then
    echo -e "${RED}Unsupported architecture:${NC} $(uname -m)"
    pause
    return
  fi

  echo "Detected arch: $arch"
  echo
  echo "1. Latest stable"
  echo "2. Custom version"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-2]: " choice

  case "$choice" in
    1)
      echo "Fetching latest version..."
      version="$(latest_singbox_version || true)"
      ;;
    2)
      read -r -p "Enter sing-box version, example 1.13.12: " version
      version="${version#v}"
      ;;
    0)
      return
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      pause
      return
      ;;
  esac

  if [[ -z "${version:-}" ]]; then
    echo -e "${RED}Could not determine version.${NC}"
    pause
    return
  fi

  asset="sing-box-${version}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"

  echo
  echo "Download:"
  echo "$url"
  echo
  read -r -p "Download and cache this asset? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      pause
      return
      ;;
  esac

  apt-get update
  apt-get install -y curl ca-certificates tar gzip sha256sum coreutils 2>/dev/null || apt-get install -y curl ca-certificates tar gzip coreutils

  curl -fL "$url" -o "$SINGBOX_ASSETS_DIR/$asset"

  checksum_file="$SINGBOX_ASSETS_DIR/SHA256SUMS"
  (
    cd "$SINGBOX_ASSETS_DIR"
    sha256sum "$asset" >> "$checksum_file"
  )

  echo "$version" > "$SINGBOX_ASSETS_DIR/VERSION"
  echo "$arch" > "$SINGBOX_ASSETS_DIR/ARCH"

  echo
  echo -e "${GREEN}Cached successfully:${NC}"
  echo "$SINGBOX_ASSETS_DIR/$asset"
  echo
  echo "SHA256:"
  tail -n 1 "$checksum_file"
  echo

  pause
}

install_singbox_from_cache() {
  title
  echo -e "${CYAN}Install sing-box from Local Cache${NC}"
  line
  echo

  local arch version asset tmpdir extracted_dir
  arch="$(detect_arch)"

  if [[ -f "$SINGBOX_ASSETS_DIR/VERSION" ]]; then
    version="$(cat "$SINGBOX_ASSETS_DIR/VERSION" | tr -d '[:space:]')"
  else
    echo -e "${RED}No cached VERSION found.${NC}"
    echo "Run: Cache sing-box binary first."
    pause
    return
  fi

  asset="sing-box-${version}-linux-${arch}.tar.gz"

  if [[ ! -f "$SINGBOX_ASSETS_DIR/$asset" ]]; then
    echo -e "${RED}Cached asset not found:${NC}"
    echo "$SINGBOX_ASSETS_DIR/$asset"
    echo
    echo "Available assets:"
    ls -lah "$SINGBOX_ASSETS_DIR" || true
    pause
    return
  fi

  echo "Install from:"
  echo "$SINGBOX_ASSETS_DIR/$asset"
  echo
  echo "Install target:"
  echo "$SINGBOX_TARGET_BIN"
  echo
  read -r -p "Install now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      pause
      return
      ;;
  esac

  mkdir -p "$SINGBOX_TARGET_DIR"

  tmpdir="$(mktemp -d)"
  tar -xzf "$SINGBOX_ASSETS_DIR/$asset" -C "$tmpdir"

  extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -name "sing-box-${version}-linux-${arch}" | head -n 1)"

  if [[ -z "$extracted_dir" || ! -f "$extracted_dir/sing-box" ]]; then
    echo -e "${RED}sing-box binary not found inside archive.${NC}"
    rm -rf "$tmpdir"
    pause
    return
  fi

  cp "$extracted_dir/sing-box" "$SINGBOX_TARGET_BIN"
  chmod +x "$SINGBOX_TARGET_BIN"

  mkdir -p "$TUNNEL_DIR/state"
  echo "$version" > "$TUNNEL_DIR/state/sing-box.version"

  rm -rf "$tmpdir"

  echo
  echo -e "${GREEN}sing-box installed from local cache.${NC}"
  "$SINGBOX_TARGET_BIN" version || true
  echo

  pause
}

build_offline_bundle() {
  title
  echo -e "${CYAN}Build Portable Offline Bundle${NC}"
  line
  echo

  mkdir -p "$ASSETS_DIR"

  local version bundle_name
  version="$(cat "$BASE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  version="${version:-0.1.3}"

  bundle_name="viptrue-offline-assets-${version}.tar.gz"

  # Store asset bundle version INSIDE assets, not root VERSION.
  # This prevents offline bundle import from downgrading toolbox VERSION.
  echo "$version" > "$ASSETS_DIR/OFFLINE_BUNDLE_VERSION"

  echo "This will create:"
  echo "$BASE_DIR/$bundle_name"
  echo
  echo "Included:"
  echo "- assets/sing-box/"
  echo "- assets/OFFLINE_BUNDLE_VERSION"
  echo
  read -r -p "Build bundle? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      pause
      return
      ;;
  esac

  tar -czf "$BASE_DIR/$bundle_name" \
    -C "$BASE_DIR" \
    assets/sing-box \
    assets/OFFLINE_BUNDLE_VERSION

  echo
  echo -e "${GREEN}Bundle created:${NC}"
  echo "$BASE_DIR/$bundle_name"
  echo
  ls -lh "$BASE_DIR/$bundle_name"
  echo

  pause
}

download_offline_bundle_from_release() {
  title
  echo -e "${CYAN}Download Offline Bundle from VIPTrue Release${NC}"
  line
  echo

  local version tag bundle url tmp_bundle
  version="$(cat "$BASE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  version="${version:-0.1.3}"
  tag="v$version"
  bundle="viptrue-offline-assets-${version}.tar.gz"

  echo "Repository:"
  echo "$REPO_SLUG"
  echo
  echo "Current local version:"
  echo "$version"
  echo
  echo "Default release tag:"
  echo "$tag"
  echo
  read -r -p "Enter release tag to download [default: $tag]: " input_tag
  tag="${input_tag:-$tag}"

  bundle="viptrue-offline-assets-${tag#v}.tar.gz"
  url="https://github.com/${REPO_SLUG}/releases/download/${tag}/${bundle}"

  echo
  echo "Download URL:"
  echo "$url"
  echo
  echo "Target:"
  echo "$BASE_DIR/$bundle"
  echo
  read -r -p "Download this offline bundle? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      pause
      return
      ;;
  esac

  apt-get update >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates tar gzip >/dev/null 2>&1 || true

  tmp_bundle="$(mktemp)"
  if ! curl -fL --connect-timeout 20 --max-time 180 "$url" -o "$tmp_bundle"; then
    echo -e "${RED}Download failed.${NC}"
    echo
    echo "Check that this asset exists in GitHub Release:"
    echo "$bundle"
    rm -f "$tmp_bundle"
    pause
    return
  fi

  mv "$tmp_bundle" "$BASE_DIR/$bundle"

  echo
  echo -e "${GREEN}Bundle downloaded:${NC}"
  ls -lh "$BASE_DIR/$bundle"
  echo

  read -r -p "Import this bundle now? [Y/n]: " import_now
  case "$import_now" in
    n|N|no|NO)
      pause
      return
      ;;
  esac

  import_offline_bundle_file "$BASE_DIR/$bundle"
}

import_offline_bundle_file() {
  local bundle_path="$1"

  if [[ ! -f "$bundle_path" ]]; then
    echo -e "${RED}Bundle not found:${NC}"
    echo "$bundle_path"
    return 1
  fi

  echo
  echo -e "${YELLOW}Importing bundle:${NC}"
  echo "$bundle_path"

  mkdir -p "$BASE_DIR/assets"

  # Important:
  # Bundle must not overwrite root VERSION.
  # If an old bundle contains VERSION, extract it to temp first and only copy assets.
  local tmpdir
  tmpdir="$(mktemp -d)"

  tar -xzf "$bundle_path" -C "$tmpdir"

  if [[ -d "$tmpdir/assets" ]]; then
    cp -a "$tmpdir/assets/." "$BASE_DIR/assets/"
  else
    echo -e "${RED}Invalid bundle: assets directory not found.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  rm -rf "$tmpdir"

  echo
  echo -e "${GREEN}Bundle imported successfully.${NC}"
  echo "Toolbox VERSION was not overwritten."
  echo

  show_cached_assets
}

import_offline_bundle_manual() {
  title
  echo -e "${CYAN}Import Offline Bundle from Local File${NC}"
  line
  echo

  echo "Example:"
  echo "$BASE_DIR/viptrue-offline-assets-0.1.2.tar.gz"
  echo
  read -r -p "Enter local bundle path: " bundle_path

  if [[ -z "${bundle_path// /}" ]]; then
    echo -e "${RED}Empty path.${NC}"
    pause
    return
  fi

  if import_offline_bundle_file "$bundle_path"; then
    :
  else
    pause
  fi
}


show_cached_assets() {
  title
  echo -e "${CYAN}Cached Offline Assets${NC}"
  line
  echo

  echo "Assets directory:"
  echo "$ASSETS_DIR"
  echo

  if [[ -d "$SINGBOX_ASSETS_DIR" ]]; then
    echo "sing-box assets:"
    ls -lah "$SINGBOX_ASSETS_DIR"
  else
    echo "No sing-box assets cached yet."
  fi

  echo
  pause
}

while true; do
  title
  echo -e "${CYAN}Offline Assets / Local Installer${NC}"
  line
  echo
  echo "1. Show system architecture"
  echo "2. Show cached assets"
  echo "3. Cache sing-box binary from official release"
  echo "4. Install sing-box from local cache"
  echo "5. Build portable offline bundle"
  echo "6. Download offline bundle from VIPTrue Release"
  echo "7. Import offline bundle from local file"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-7]: " choice

  case "$choice" in
    1) show_arch ;;
    2) show_cached_assets ;;
    3) cache_singbox_binary ;;
    4) install_singbox_from_cache ;;
    5) build_offline_bundle ;;
    6) download_offline_bundle_from_release ;;
    7) import_offline_bundle_manual ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
