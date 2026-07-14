#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORIGINAL_OFFLINE_MANAGER="$BASE_DIR/modules/utility/03-offline-assets.sh"

load_offline_manager_definitions() {
  local main_line definitions_file
  main_line="$(grep -n '^while true; do$' "$ORIGINAL_OFFLINE_MANAGER" | tail -n 1 | cut -d: -f1)"
  if [[ -z "$main_line" || "$main_line" -le 1 ]]; then
    echo "[FAIL] Could not locate the Offline Assets entry loop." >&2
    return 1
  fi
  definitions_file="$(mktemp)"
  head -n "$((main_line - 1))" "$ORIGINAL_OFFLINE_MANAGER" > "$definitions_file"
  # shellcheck disable=SC1090
  source "$definitions_file"
  rm -f -- "$definitions_file"
}

load_offline_manager_definitions
# shellcheck source=lib/download.sh
source "$BASE_DIR/lib/download.sh"

latest_singbox_version() {
  local metadata version
  metadata="$(mktemp)"
  if ! viptrue_fetch_url \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    "manifest.json" \
    "$metadata"; then
    rm -f -- "$metadata"
    return 1
  fi

  version="$(grep -m1 '"tag_name"' "$metadata" | sed -E 's/.*"v?([^"]+)".*/\1/' || true)"
  if [[ -z "$version" ]]; then
    version="$(tr -d '\n' < "$metadata" | sed -nE 's/.*"sing-box"[[:space:]]*:[[:space:]]*\{[^}]*"latest"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/p' || true)"
  fi
  rm -f -- "$metadata"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

cache_singbox_binary() {
  local arch version asset url checksum_name checksum_url checksum_cache cache_path expected choice confirm
  title
  echo -e "${CYAN}Cache sing-box Binary (Mirror Aware)${NC}"
  line
  echo

  mkdir -p "$SINGBOX_ASSETS_DIR"
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
      echo "Fetching latest version through Download / Mirror Manager..."
      version="$(latest_singbox_version || true)"
      ;;
    2)
      read -r -p "Enter sing-box version, example 1.13.12: " version
      version="${version#v}"
      ;;
    0) return ;;
    *) echo -e "${RED}Invalid choice.${NC}"; pause; return ;;
  esac

  if [[ -z "${version:-}" ]]; then
    echo -e "${RED}Could not determine version.${NC} In mirror-only mode, choose Custom version if the mirror manifest has no sing-box latest field."
    pause
    return
  fi

  asset="sing-box-${version}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"
  checksum_name="sing-box-${version}-checksums.txt"
  checksum_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${checksum_name}"
  cache_path="$(viptrue_asset_cache_path sing-box "$version" "$asset")" || { pause; return; }
  checksum_cache="$(viptrue_asset_cache_path sing-box "$version" "$checksum_name")" || { pause; return; }

  echo
  echo "Official: $url"
  echo "Mirror: assets/sing-box/${version}/${asset}"
  echo "Cache: $cache_path"
  echo
  read -r -p "Download, verify, and cache this asset? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; pause; return ;;
  esac

  viptrue_need_cmd tar tar || { pause; return; }
  viptrue_need_cmd sha256sum coreutils || { pause; return; }

  if ! viptrue_fetch_url "$checksum_url" "assets/sing-box/${version}/${checksum_name}" "$checksum_cache"; then
    echo -e "${RED}Checksum download failed; sing-box asset will not be installed or copied.${NC}"
    pause
    return
  fi
  expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name {print $1; exit}' "$checksum_cache")"
  if [[ -z "$expected" ]]; then
    echo -e "${RED}No checksum entry found for $asset.${NC}"
    pause
    return
  fi

  if ! viptrue_fetch_url "$url" "assets/sing-box/${version}/${asset}" "$cache_path"; then
    pause
    return
  fi
  if ! viptrue_verify_sha256 "$cache_path" "$expected"; then
    rm -f -- "$cache_path"
    pause
    return
  fi

  cp -f -- "$cache_path" "$SINGBOX_ASSETS_DIR/$asset"
  cp -f -- "$checksum_cache" "$SINGBOX_ASSETS_DIR/SHA256SUMS"
  printf '%s\n' "$version" > "$SINGBOX_ASSETS_DIR/VERSION"
  printf '%s\n' "$arch" > "$SINGBOX_ASSETS_DIR/ARCH"
  viptrue_download_pass "Cached verified sing-box asset: $SINGBOX_ASSETS_DIR/$asset"
  pause
}

download_offline_bundle_from_release() {
  local version tag bundle official cache_path checksum_cache expected="" input_tag confirm import_now
  title
  echo -e "${CYAN}Download Offline Bundle (Mirror Aware)${NC}"
  line
  echo

  version="$(tr -d '[:space:]' < "$BASE_DIR/VERSION" 2>/dev/null || true)"
  version="${version:-0.4.8}"
  tag="v$version"
  read -r -p "Enter release tag to download [default: $tag]: " input_tag
  tag="${input_tag:-$tag}"
  version="${tag#v}"
  bundle="viptrue-offline-assets-${version}.tar.gz"
  official="https://github.com/${REPO_SLUG}/releases/download/${tag}/${bundle}"
  cache_path="$(viptrue_asset_cache_path offline-bundle "$version" "$bundle")" || { pause; return; }

  echo
  echo "Official: $official"
  echo "Mirror: assets/offline-bundle/${version}/${bundle}"
  echo "Cache: $cache_path"
  echo
  read -r -p "Download this offline bundle? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; pause; return ;;
  esac

  if ! viptrue_fetch_url "$official" "assets/offline-bundle/${version}/${bundle}" "$cache_path"; then
    pause
    return
  fi

  viptrue_load_mirror_config
  checksum_cache="$VIPTRUE_ASSET_CACHE/checksums.txt"
  if viptrue_fetch_url "" "checksums.txt" "$checksum_cache"; then
    expected="$(awk -v name="$bundle" '{n=$2; sub(/^\*/,"",n); c=split(n,p,"/"); if(n==name || p[c]==name){print $1; exit}}' "$checksum_cache")"
  fi
  if [[ -n "$expected" ]] && ! viptrue_verify_sha256 "$cache_path" "$expected"; then
    rm -f -- "$cache_path"
    pause
    return
  fi
  if [[ -z "$expected" ]]; then
    viptrue_download_warn "No mirror checksum entry found for $bundle; keeping it cached and unexecuted until you confirm import."
  fi

  cp -f -- "$cache_path" "$BASE_DIR/$bundle"
  viptrue_download_pass "Bundle downloaded: $BASE_DIR/$bundle"
  read -r -p "Import this bundle now? [Y/n]: " import_now
  case "$import_now" in
    n|N|no|NO) pause; return ;;
  esac
  import_offline_bundle_file "$BASE_DIR/$bundle"
}

# TODO(download-manager): migrate any future direct release URLs added to the
# original Offline Assets module into these mirror-aware overrides.

while true; do
  title
  echo -e "${CYAN}Offline Assets / Local Installer${NC}"
  line
  echo
  echo "1. Show system architecture"
  echo "2. Show cached assets"
  echo "3. Cache sing-box binary from official/mirror release"
  echo "4. Install sing-box from local cache"
  echo "5. Build portable offline bundle"
  echo "6. Download offline bundle from official/mirror source"
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
