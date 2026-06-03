#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

ASSETS_DIR="$BASE_DIR/assets"
SINGBOX_ASSETS_DIR="$ASSETS_DIR/sing-box"

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

  local bundle_name
  bundle_name="viptrue-offline-assets-$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo 0.1.0).tar.gz"

  echo "This will create:"
  echo "$BASE_DIR/$bundle_name"
  echo
  echo "Included:"
  echo "- assets/sing-box/"
  echo "- VERSION"
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
    VERSION \
    assets/sing-box

  echo
  echo -e "${GREEN}Bundle created:${NC}"
  echo "$BASE_DIR/$bundle_name"
  echo
  ls -lh "$BASE_DIR/$bundle_name"
  echo

  pause
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
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-5]: " choice

  case "$choice" in
    1) show_arch ;;
    2) show_cached_assets ;;
    3) cache_singbox_binary ;;
    4) install_singbox_from_cache ;;
    5) build_offline_bundle ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
