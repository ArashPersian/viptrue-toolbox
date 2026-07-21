#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/ui.sh
source "$BASE_DIR/lib/ui.sh"
# shellcheck source=lib/download.sh
source "$BASE_DIR/lib/download.sh"

MIRROR_CONF="${VIPTRUE_CONFIG_FILE:-/etc/viptrue-toolbox/mirror.conf}"
OFFICIAL_BOOTSTRAP_URL="https://raw.githubusercontent.com/ArashPersian/viptrue-toolbox/main/bootstrap.sh"
OFFICIAL_REPO_URL="https://github.com/ArashPersian/viptrue-toolbox.git"

mirror_manager_require_root() {
  if [[ "$EUID" -eq 0 ]]; then
    return 0
  fi
  echo -e "${RED}Root required.${NC} Run the toolbox with sudo/root."
  pause
  return 1
}

mirror_manager_valid_base() {
  local value="$1"
  [[ -z "$value" || "$value" =~ ^https?://[^[:space:]]+$ ]]
}

mirror_manager_write_config() {
  local dir tmp
  mirror_manager_require_root || return 1
  dir="$(dirname "$MIRROR_CONF")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.mirror.conf.XXXXXX")"
  {
    printf 'VIPTRUE_MIRROR_BASE=%s\n' "$VIPTRUE_MIRROR_BASE"
    printf 'VIPTRUE_DOWNLOAD_MODE=%s\n' "$VIPTRUE_DOWNLOAD_MODE"
    printf 'VIPTRUE_USE_SNAP=%s\n' "$VIPTRUE_USE_SNAP"
    printf 'VIPTRUE_APT_REGION=%s\n' "$VIPTRUE_APT_REGION"
    printf 'VIPTRUE_ASSET_CACHE=%s\n' "$VIPTRUE_ASSET_CACHE"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$MIRROR_CONF"
  viptrue_download_pass "Saved mirror config: $MIRROR_CONF"
}

mirror_manager_probe_url() {
  local label="$1"
  local url="$2"
  if [[ -z "$url" ]]; then
    viptrue_download_fail "$label: URL is not configured."
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --connect-timeout 10 --max-time 25 -o /dev/null "$url"; then
      viptrue_download_pass "$label: $url"
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=25 -O /dev/null "$url"; then
      viptrue_download_pass "$label: $url"
      return 0
    fi
  else
    viptrue_download_fail "$label: curl/wget unavailable."
    return 1
  fi
  viptrue_download_fail "$label unreachable: $url"
}

mirror_manager_apt_update_probe() {
  local tmp cmd rc=1

  command -v apt-get >/dev/null 2>&1 || {
    viptrue_download_fail "APT status: apt-get is unavailable."
    return 1
  }

  tmp="$(mktemp -d)"
  mkdir -p "$tmp/lists/partial" "$tmp/cache/archives/partial"
  cmd=(
    apt-get
    -o Acquire::Retries=1
    -o Debug::NoLocking=1
    -o "Dir::State::lists=$tmp/lists"
    -o "Dir::Cache::archives=$tmp/cache/archives"
    update
  )

  if command -v timeout >/dev/null 2>&1; then
    timeout 90 "${cmd[@]}" >/dev/null 2>&1 && rc=0 || rc=$?
  else
    "${cmd[@]}" >/dev/null 2>&1 && rc=0 || rc=$?
  fi
  rm -rf -- "$tmp"

  if [[ "$rc" -eq 0 ]]; then
    viptrue_download_pass "APT update probe completed."
    return 0
  fi
  viptrue_download_fail "APT update probe failed. CDN settings do not fix APT access."
  return "$rc"
}

show_download_connectivity_status() {
  local mirror_archive="" mirror_manifest=""
  title
  echo -e "${CYAN}Download / Mirror Manager > Connectivity Status${NC}"
  line
  echo
  viptrue_download_status
  echo

  mirror_manager_probe_url "GitHub raw/bootstrap" "$OFFICIAL_BOOTSTRAP_URL" || true

  if command -v git >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      if timeout 25 git ls-remote --heads "$OFFICIAL_REPO_URL" main >/dev/null 2>&1; then
        viptrue_download_pass "GitHub repository clone endpoint reachable."
      else
        viptrue_download_fail "GitHub repository clone endpoint unreachable."
      fi
    elif git ls-remote --heads "$OFFICIAL_REPO_URL" main >/dev/null 2>&1; then
      viptrue_download_pass "GitHub repository clone endpoint reachable."
    else
      viptrue_download_fail "GitHub repository clone endpoint unreachable."
    fi
  else
    viptrue_download_fail "GitHub clone test skipped: git is not installed."
  fi

  viptrue_load_mirror_config
  if [[ -n "$VIPTRUE_MIRROR_BASE" ]]; then
    mirror_manifest="${VIPTRUE_MIRROR_BASE%/}/manifest.json"
    mirror_archive="${VIPTRUE_MIRROR_BASE%/}/repo/main.tar.gz"
    mirror_manager_probe_url "Configured mirror base/manifest" "$mirror_manifest" || true
    mirror_manager_probe_url "Mirror main archive" "$mirror_archive" || true
  else
    viptrue_download_fail "Configured mirror base: not set."
    viptrue_download_fail "Mirror main archive: cannot test without VIPTRUE_MIRROR_BASE."
  fi

  mirror_manager_apt_update_probe || true

  echo
  echo "CDN/mirror configuration fixes toolbox, repository archive, and asset downloads."
  echo "APT packages still require a reachable APT mirror or proxy."
  pause
}

configure_mirror_base() {
  local value
  title
  echo -e "${CYAN}Configure Mirror / CDN Base URL${NC}"
  line
  viptrue_load_mirror_config
  echo
  echo "Current: ${VIPTRUE_MIRROR_BASE:-not configured}"
  echo "Example: https://cdn.example.com/viptrue"
  echo "Leave empty to disable the mirror."
  echo
  read -r -p "Mirror/CDN base URL: " value
  value="${value%/}"
  if ! mirror_manager_valid_base "$value"; then
    echo -e "${RED}Invalid URL.${NC} Use an http:// or https:// base URL without spaces."
    pause
    return
  fi
  VIPTRUE_MIRROR_BASE="$value"
  mirror_manager_write_config
  pause
}

configure_download_mode() {
  local choice
  title
  echo -e "${CYAN}Configure Download Mode${NC}"
  line
  viptrue_load_mirror_config
  echo
  echo "Current: $VIPTRUE_DOWNLOAD_MODE"
  echo
  echo "1. mirror-first"
  echo "2. official-first"
  echo "3. mirror-only"
  echo "4. official-only"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-4]: " choice
  case "$choice" in
    1) VIPTRUE_DOWNLOAD_MODE="mirror-first" ;;
    2) VIPTRUE_DOWNLOAD_MODE="official-first" ;;
    3) VIPTRUE_DOWNLOAD_MODE="mirror-only" ;;
    4) VIPTRUE_DOWNLOAD_MODE="official-only" ;;
    0) return ;;
    *) echo -e "${RED}Invalid choice.${NC}"; pause; return ;;
  esac
  mirror_manager_write_config
  pause
}

configure_apt_region() {
  local choice snap_choice default_snap
  title
  echo -e "${CYAN}Configure APT Region / Helper${NC}"
  line
  viptrue_load_mirror_config
  echo
  echo "Current APT region: $VIPTRUE_APT_REGION"
  echo "Current snap policy: $VIPTRUE_USE_SNAP"
  echo
  echo "1. auto"
  echo "2. iran"
  echo "3. default"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-3]: " choice
  case "$choice" in
    1) VIPTRUE_APT_REGION="auto"; default_snap="$VIPTRUE_USE_SNAP" ;;
    2) VIPTRUE_APT_REGION="iran"; default_snap="no" ;;
    3) VIPTRUE_APT_REGION="default"; default_snap="$VIPTRUE_USE_SNAP" ;;
    0) return ;;
    *) echo -e "${RED}Invalid choice.${NC}"; pause; return ;;
  esac

  read -r -p "Allow snap fallback? yes/no [$default_snap]: " snap_choice
  VIPTRUE_USE_SNAP="${snap_choice:-$default_snap}"
  if ! viptrue_valid_yes_no "$VIPTRUE_USE_SNAP"; then
    echo -e "${RED}Invalid snap value.${NC} Use yes or no."
    pause
    return
  fi
  if [[ "$VIPTRUE_APT_REGION" == "iran" ]]; then
    VIPTRUE_USE_SNAP="no"
    echo
    echo "Iran mode forces VIPTRUE_USE_SNAP=no."
    echo "Use apt packages where possible. Configure an APT mirror/proxy separately if apt is blocked."
  fi
  mirror_manager_write_config
  pause
}

mirror_manager_lookup_checksum() {
  local checksum_file="$1"
  local wanted="$2"
  awk -v wanted="$wanted" '
    {
      name=$2
      sub(/^\*/, "", name)
      n=split(name, parts, "/")
      if (name == wanted || parts[n] == wanted) { print $1; exit }
    }
  ' "$checksum_file"
}

download_offline_assets_bundle() {
  local version name file official mirror_path dest checksum_cache expected=""
  title
  echo -e "${CYAN}Download / Refresh Offline Assets Bundle${NC}"
  line
  viptrue_load_mirror_config
  echo

  version="$(tr -d '[:space:]' < "$BASE_DIR/VERSION" 2>/dev/null || true)"
  version="${version:-0.4.9}"
  name="offline-bundle"
  file="viptrue-offline-assets-${version}.tar.gz"

  read -r -p "Asset name [$name]: " input_name
  name="${input_name:-$name}"
  read -r -p "Asset version [$version]: " input_version
  version="${input_version:-$version}"
  read -r -p "Asset file [$file]: " input_file
  file="${input_file:-$file}"

  dest="$(viptrue_asset_cache_path "$name" "$version" "$file")" || { pause; return; }
  official="https://github.com/ArashPersian/viptrue-toolbox/releases/download/v${version}/${file}"
  mirror_path="assets/${name}/${version}/${file}"
  echo
  echo "Official: $official"
  echo "Mirror path: $mirror_path"
  echo "Cache: $dest"
  echo

  if ! viptrue_fetch_url "$official" "$mirror_path" "$dest"; then
    pause
    return
  fi

  checksum_cache="$VIPTRUE_ASSET_CACHE/checksums.txt"
  if viptrue_fetch_url "" "checksums.txt" "$checksum_cache"; then
    expected="$(mirror_manager_lookup_checksum "$checksum_cache" "$file")"
  fi
  if [[ -n "$expected" ]]; then
    if ! viptrue_verify_sha256 "$dest" "$expected"; then
      rm -f -- "$dest"
      pause
      return
    fi
  else
    viptrue_download_warn "No matching checksum found for $file. The file was cached but not executed."
  fi

  echo
  viptrue_download_pass "Offline asset cached: $dest"
  pause
}

validate_cached_assets() {
  local checksum_file file expected failures=0 matched=0
  title
  echo -e "${CYAN}Validate Cached Assets / Checksums${NC}"
  line
  viptrue_load_mirror_config
  checksum_file="$VIPTRUE_ASSET_CACHE/checksums.txt"
  echo
  echo "Cache: $VIPTRUE_ASSET_CACHE"
  echo "Checksums: $checksum_file"
  echo

  if [[ ! -r "$checksum_file" ]]; then
    viptrue_download_fail "checksums.txt is not cached. Refresh an offline bundle first."
    pause
    return
  fi

  while IFS= read -r -d '' file; do
    [[ "$file" == "$checksum_file" ]] && continue
    expected="$(mirror_manager_lookup_checksum "$checksum_file" "$(basename "$file")")"
    if [[ -z "$expected" ]]; then
      viptrue_download_warn "No checksum entry: $file"
      continue
    fi
    matched=$((matched + 1))
    if ! viptrue_verify_sha256 "$file" "$expected"; then
      failures=$((failures + 1))
    fi
  done < <(find "$VIPTRUE_ASSET_CACHE" -type f -print0 2>/dev/null)

  if ((matched == 0)); then
    viptrue_download_fail "No cached asset matched checksums.txt."
  elif ((failures == 0)); then
    viptrue_download_pass "All $matched matched cached assets passed SHA256 validation."
  else
    viptrue_download_fail "$failures of $matched matched cached assets failed validation."
  fi
  pause
}

show_bootstrap_commands() {
  title
  echo -e "${CYAN}Bootstrap Commands${NC}"
  line
  viptrue_load_mirror_config
  echo
  echo "Official/default install (GitHub first):"
  echo "  curl -fsSL $OFFICIAL_BOOTSTRAP_URL | sudo bash"
  echo
  if [[ -n "$VIPTRUE_MIRROR_BASE" ]]; then
    echo "Mirror bootstrap:"
    echo "  curl -fsSL ${VIPTRUE_MIRROR_BASE%/}/bootstrap.sh | sudo env VIPTRUE_MIRROR_BASE=${VIPTRUE_MIRROR_BASE%/} VIPTRUE_DOWNLOAD_MODE=mirror-first bash"
    echo
    echo "Explicit archive fallback:"
    echo "  curl -fsSL ${VIPTRUE_MIRROR_BASE%/}/bootstrap.sh | sudo env VIPTRUE_ARCHIVE_URL=${VIPTRUE_MIRROR_BASE%/}/repo/main.tar.gz bash"
  else
    echo "Configure a mirror base to show mirror bootstrap commands."
  fi
  echo
  echo "Downloaded scripts are only run by the explicit curl-pipe bootstrap command above."
  echo "Asset downloads are cached first and checksums are verified when provided."
  pause
}

reset_mirror_config() {
  local confirm
  title
  echo -e "${CYAN}Reset Mirror Config${NC}"
  line
  echo
  echo "Config: $MIRROR_CONF"
  read -r -p "Type RESET to remove this config: " confirm
  [[ "$confirm" == "RESET" ]] || { echo "Cancelled."; pause; return; }
  mirror_manager_require_root || return
  if [[ -e "$MIRROR_CONF" ]]; then
    rm -f -- "$MIRROR_CONF"
    viptrue_download_pass "Removed $MIRROR_CONF"
  else
    viptrue_download_info "Config was already absent."
  fi
  pause
}

download_mirror_manager_menu() {
  local choice
  while true; do
    title
    echo -e "${CYAN}Download / Mirror Manager${NC}"
    line
    echo
    echo "1. Show download connectivity status"
    echo "2. Configure mirror/CDN base URL"
    echo "3. Configure download mode"
    echo "4. Configure apt region/helper"
    echo "5. Download/refresh offline assets bundle"
    echo "6. Validate cached assets/checksums"
    echo "7. Show bootstrap commands"
    echo "8. Reset mirror config"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-8]: " choice
    case "$choice" in
      1) show_download_connectivity_status ;;
      2) configure_mirror_base ;;
      3) configure_download_mode ;;
      4) configure_apt_region ;;
      5) download_offline_assets_bundle ;;
      6) validate_cached_assets ;;
      7) show_bootstrap_commands ;;
      8) reset_mirror_config ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  download_mirror_manager_menu
fi
