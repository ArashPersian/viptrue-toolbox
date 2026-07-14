#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORIGINAL_TUNNEL_MANAGER="$BASE_DIR/modules/utility/04-tunnel-manager.sh"

load_tunnel_manager_definitions() {
  local main_line definitions_file
  main_line="$(grep -n '^while true; do$' "$ORIGINAL_TUNNEL_MANAGER" | tail -n 1 | cut -d: -f1)"
  if [[ -z "$main_line" || "$main_line" -le 1 ]]; then
    echo "[FAIL] Could not locate the Tunnel Manager entry loop." >&2
    return 1
  fi
  definitions_file="$(mktemp)"
  head -n "$((main_line - 1))" "$ORIGINAL_TUNNEL_MANAGER" > "$definitions_file"
  # shellcheck disable=SC1090
  source "$definitions_file"
  rm -f -- "$definitions_file"
}

load_tunnel_manager_definitions
# shellcheck source=lib/download.sh
source "$BASE_DIR/lib/download.sh"

# Mirror-aware WaterWall dependency installation. Snap is intentionally not
# required; apt packages are preferred, especially in Iran mode.
waterwall_reverse_install_download_deps() {
  local install
  local -a missing=()

  if ! have_cmd curl && ! have_cmd wget; then
    missing+=(curl)
  fi
  have_cmd unzip || missing+=(unzip)
  have_cmd sha256sum || missing+=(coreutils)
  have_cmd install || missing+=(coreutils)
  ((${#missing[@]} == 0)) && return 0

  warn_line "download dependencies missing" "${missing[*]}"
  read -r -p "Install WaterWall download dependencies now? [y/N]: " install
  case "$install" in
    y|Y|yes|YES) viptrue_apt_install "${missing[@]}" ;;
    *)
      fail_line "download dependencies" "required before installing WaterWall"
      return 1
      ;;
  esac
}

ensure_waterwall_ready() {
  local install_now asset url expected_sha tmp_dir extract_dir binary_path bin_path
  local asset_file asset_version cache_path mirror_path

  bin_path="$(waterwall_reverse_bin_path)"
  if [[ -x "$bin_path" ]]; then
    pass_line "WaterWall command" "$bin_path"
    return 0
  fi

  warn_line "WaterWall command" "not installed at $WW_REV_BIN"
  asset="$(waterwall_reverse_asset_for_arch)" || return 1
  url="${asset%|*}"
  expected_sha="${asset##*|}"
  asset_file="$(basename "${url%%\?*}")"
  asset_version="${WW_REV_RELEASE_TAG#v}"
  mirror_path="assets/waterwall/${asset_version}/${asset_file}"
  cache_path="$(viptrue_asset_cache_path waterwall "$asset_version" "$asset_file")" || { pause; return; }

  echo "Release: $WW_REV_RELEASE_TAG"
  echo "Official asset: $url"
  echo "Mirror path: $mirror_path"
  echo "SHA256: $expected_sha"
  echo "Cache path: $cache_path"
  echo "Install path: $WW_REV_BIN"
  echo
  read -r -p "Download, verify, and install WaterWall now? [y/N]: " install_now
  case "$install_now" in
    y|Y|yes|YES) ;;
    *)
      fail_line "WaterWall command" "install WaterWall before creating services"
      return 1
      ;;
  esac

  ensure_root || return 1
  waterwall_reverse_install_download_deps || return 1

  if [[ -f "$cache_path" ]] && viptrue_verify_sha256 "$cache_path" "$expected_sha"; then
    viptrue_download_pass "Using verified cached WaterWall asset."
  else
    rm -f -- "$cache_path"
    viptrue_fetch_url "$url" "$mirror_path" "$cache_path" || return 1
    if ! viptrue_verify_sha256 "$cache_path" "$expected_sha"; then
      rm -f -- "$cache_path"
      return 1
    fi
  fi

  tmp_dir="$(mktemp -d)"
  extract_dir="$tmp_dir/extract"
  mkdir -p "$extract_dir"
  if ! unzip -q "$cache_path" -d "$extract_dir"; then
    fail_line "WaterWall archive" "could not extract $cache_path"
    rm -rf -- "$tmp_dir"
    return 1
  fi

  binary_path="$(find "$extract_dir" -type f \( -name 'Waterwall' -o -name 'waterwall' \) -perm /111 -print 2>/dev/null | head -n 1)"
  if [[ -z "$binary_path" ]]; then
    binary_path="$(find "$extract_dir" -type f \( -name 'Waterwall' -o -name 'waterwall' \) -print 2>/dev/null | head -n 1)"
  fi
  if [[ -z "$binary_path" ]]; then
    fail_line "WaterWall archive" "no Waterwall binary found in release asset"
    rm -rf -- "$tmp_dir"
    return 1
  fi

  # The archive is verified before the binary is chmodded/installed.
  install -m 0755 "$binary_path" "$WW_REV_BIN"
  rm -rf -- "$tmp_dir"

  if [[ -x "$WW_REV_BIN" ]]; then
    pass_line "WaterWall command" "$WW_REV_BIN"
    return 0
  fi
  fail_line "WaterWall command" "install completed but $WW_REV_BIN is not executable"
  return 1
}

# TODO(download-manager): split remaining legacy Hysteria2/Chisel release fetches
# out of 04-tunnel-manager.sh and route them through viptrue_fetch_url. The
# WaterWall path is covered now; the remaining direct paths are documented in
# docs/DOWNLOAD_MIRROR_MANAGER.md.

while true; do
  title
  echo -e "${CYAN}Tunnel Manager${NC}"
  line
  echo
  echo "1. Auto Tunnel Expert"
  echo "2. Manual Tunnel Lab"
  echo "3. Manage Existing Tunnels"
  echo "4. Test Existing Tunnels"
  echo "5. Diagnostics Summary"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-5]: " choice

  case "$choice" in
    1) auto_tunnel_expert_menu ;;
    2) manual_tunnel_lab_menu ;;
    3) manage_existing_tunnels_menu ;;
    4) test_existing_tunnels_menu ;;
    5) diagnostics_summary_screen ;;
    6|0) break ;;
    99) exit_toolbox ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
