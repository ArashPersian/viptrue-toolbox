#!/usr/bin/env bash

# Central download and mirror-aware helpers for VIPTrue Toolbox.
# This file intentionally stores no credentials and accepts only public/base URLs.

VIPTRUE_CONFIG_FILE="${VIPTRUE_CONFIG_FILE:-/etc/viptrue-toolbox/mirror.conf}"
VIPTRUE_DEFAULT_ASSET_CACHE="/var/cache/viptrue-toolbox/assets"

viptrue_download_log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*" >&2
}

viptrue_download_pass() { viptrue_download_log PASS "$@"; }
viptrue_download_fail() { viptrue_download_log FAIL "$@"; }
viptrue_download_info() { viptrue_download_log INFO "$@"; }
viptrue_download_warn() { viptrue_download_log WARN "$@"; }

viptrue_trim_slashes() {
  local value="$1"
  value="${value%/}"
  printf '%s\n' "$value"
}

viptrue_valid_download_mode() {
  case "$1" in
    mirror-first|official-first|mirror-only|official-only) return 0 ;;
    *) return 1 ;;
  esac
}

viptrue_valid_apt_region() {
  case "$1" in
    auto|iran|default) return 0 ;;
    *) return 1 ;;
  esac
}

viptrue_valid_yes_no() {
  case "$1" in
    yes|no) return 0 ;;
    *) return 1 ;;
  esac
}

viptrue_load_mirror_config() {
  local config_file="${VIPTRUE_CONFIG_FILE:-/etc/viptrue-toolbox/mirror.conf}"
  local key value

  VIPTRUE_MIRROR_BASE="${VIPTRUE_MIRROR_BASE:-}"
  VIPTRUE_DOWNLOAD_MODE="${VIPTRUE_DOWNLOAD_MODE:-official-first}"
  VIPTRUE_USE_SNAP="${VIPTRUE_USE_SNAP:-yes}"
  VIPTRUE_APT_REGION="${VIPTRUE_APT_REGION:-auto}"
  VIPTRUE_ASSET_CACHE="${VIPTRUE_ASSET_CACHE:-$VIPTRUE_DEFAULT_ASSET_CACHE}"

  if [[ -r "$config_file" ]]; then
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      [[ "$key" == \#* ]] && continue
      value="${value%$'\r'}"
      case "$key" in
        VIPTRUE_MIRROR_BASE) VIPTRUE_MIRROR_BASE="$value" ;;
        VIPTRUE_DOWNLOAD_MODE) VIPTRUE_DOWNLOAD_MODE="$value" ;;
        VIPTRUE_USE_SNAP) VIPTRUE_USE_SNAP="$value" ;;
        VIPTRUE_APT_REGION) VIPTRUE_APT_REGION="$value" ;;
        VIPTRUE_ASSET_CACHE) VIPTRUE_ASSET_CACHE="$value" ;;
      esac
    done < "$config_file"
  fi

  VIPTRUE_MIRROR_BASE="$(viptrue_trim_slashes "$VIPTRUE_MIRROR_BASE")"

  if ! viptrue_valid_download_mode "$VIPTRUE_DOWNLOAD_MODE"; then
    viptrue_download_warn "Invalid VIPTRUE_DOWNLOAD_MODE='$VIPTRUE_DOWNLOAD_MODE'; using official-first."
    VIPTRUE_DOWNLOAD_MODE="official-first"
  fi
  if ! viptrue_valid_yes_no "$VIPTRUE_USE_SNAP"; then
    viptrue_download_warn "Invalid VIPTRUE_USE_SNAP='$VIPTRUE_USE_SNAP'; using yes."
    VIPTRUE_USE_SNAP="yes"
  fi
  if ! viptrue_valid_apt_region "$VIPTRUE_APT_REGION"; then
    viptrue_download_warn "Invalid VIPTRUE_APT_REGION='$VIPTRUE_APT_REGION'; using auto."
    VIPTRUE_APT_REGION="auto"
  fi
  if [[ -z "$VIPTRUE_ASSET_CACHE" || "$VIPTRUE_ASSET_CACHE" != /* ]]; then
    viptrue_download_warn "VIPTRUE_ASSET_CACHE must be an absolute path; using $VIPTRUE_DEFAULT_ASSET_CACHE."
    VIPTRUE_ASSET_CACHE="$VIPTRUE_DEFAULT_ASSET_CACHE"
  fi

  export VIPTRUE_MIRROR_BASE VIPTRUE_DOWNLOAD_MODE VIPTRUE_USE_SNAP VIPTRUE_APT_REGION VIPTRUE_ASSET_CACHE
}

viptrue_download_status() {
  viptrue_load_mirror_config
  printf 'Config file: %s\n' "${VIPTRUE_CONFIG_FILE:-/etc/viptrue-toolbox/mirror.conf}"
  printf 'Mirror base: %s\n' "${VIPTRUE_MIRROR_BASE:-not configured}"
  printf 'Download mode: %s\n' "$VIPTRUE_DOWNLOAD_MODE"
  printf 'Use snap: %s\n' "$VIPTRUE_USE_SNAP"
  printf 'APT region: %s\n' "$VIPTRUE_APT_REGION"
  printf 'Asset cache: %s\n' "$VIPTRUE_ASSET_CACHE"
  if [[ "$VIPTRUE_APT_REGION" == "iran" ]]; then
    viptrue_download_info "CDN/mirror settings cover toolbox and asset downloads. APT still needs a reachable APT mirror or proxy."
  fi
}

viptrue_mirror_url() {
  local mirror_path="$1"
  viptrue_load_mirror_config
  [[ -n "$VIPTRUE_MIRROR_BASE" && -n "$mirror_path" ]] || return 1
  printf '%s/%s\n' "$VIPTRUE_MIRROR_BASE" "${mirror_path#/}"
}

viptrue_download_one() {
  local url="$1"
  local dest="$2"
  local tmp

  [[ -n "$url" ]] || return 1
  mkdir -p "$(dirname "$dest")"
  tmp="${dest}.part.$$"
  rm -f -- "$tmp"

  if command -v curl >/dev/null 2>&1; then
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 -o "$tmp" "$url"; then
      mv -f -- "$tmp" "$dest"
      viptrue_download_pass "Downloaded $url -> $dest"
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget --timeout=30 --tries=3 -O "$tmp" "$url"; then
      mv -f -- "$tmp" "$dest"
      viptrue_download_pass "Downloaded $url -> $dest"
      return 0
    fi
  else
    viptrue_download_fail "Neither curl nor wget is available."
    return 127
  fi

  rm -f -- "$tmp"
  viptrue_download_fail "Download failed: $url"
  return 1
}

viptrue_fetch_with_fallback() {
  local official_url="$1"
  local mirror_path="$2"
  local dest="$3"
  local mirror_url=""
  local -a urls=()
  local url

  viptrue_load_mirror_config
  if [[ -n "$VIPTRUE_MIRROR_BASE" && -n "$mirror_path" ]]; then
    mirror_url="$(viptrue_mirror_url "$mirror_path")"
  fi

  case "$VIPTRUE_DOWNLOAD_MODE" in
    mirror-first)
      [[ -n "$mirror_url" ]] && urls+=("$mirror_url")
      [[ -n "$official_url" ]] && urls+=("$official_url")
      ;;
    mirror-only)
      if [[ -z "$mirror_url" ]]; then
        viptrue_download_fail "mirror-only mode is active but no mirror URL is configured for '$mirror_path'."
        return 1
      fi
      urls+=("$mirror_url")
      ;;
    official-first)
      [[ -n "$official_url" ]] && urls+=("$official_url")
      [[ -n "$mirror_url" ]] && urls+=("$mirror_url")
      ;;
    official-only)
      if [[ -z "$official_url" ]]; then
        viptrue_download_fail "official-only mode is active but no official URL was provided."
        return 1
      fi
      urls+=("$official_url")
      ;;
  esac

  if ((${#urls[@]} == 0)); then
    viptrue_download_fail "No usable download source is available."
    return 1
  fi

  for url in "${urls[@]}"; do
    viptrue_download_info "Trying: $url"
    if viptrue_download_one "$url" "$dest"; then
      return 0
    fi
  done

  viptrue_download_fail "All configured sources failed for destination: $dest"
  return 1
}

viptrue_fetch_url() {
  viptrue_fetch_with_fallback "$@"
}

viptrue_verify_sha256() {
  local file="$1"
  local expected="${2:-}"
  local actual

  if [[ ! -f "$file" ]]; then
    viptrue_download_fail "Checksum target not found: $file"
    return 1
  fi
  if [[ -z "$expected" ]]; then
    viptrue_download_info "No SHA256 supplied for $file; verification skipped."
    return 0
  fi
  expected="${expected%%[[:space:]]*}"
  expected="${expected,,}"
  if [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]]; then
    viptrue_download_fail "Invalid expected SHA256 value."
    return 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    actual="$(openssl dgst -sha256 "$file" | awk '{print $NF}')"
  else
    viptrue_download_fail "sha256sum or openssl is required for checksum verification."
    return 127
  fi

  actual="${actual,,}"
  if [[ "$actual" == "$expected" ]]; then
    viptrue_download_pass "SHA256 verified: $file"
    return 0
  fi

  viptrue_download_fail "SHA256 mismatch for $file (expected $expected, got $actual)."
  return 1
}

viptrue_archive_safe() {
  local archive="$1"
  local entry
  while IFS= read -r entry; do
    [[ "$entry" != /* ]] || return 1
    [[ "$entry" != ".." && "$entry" != ../* && "$entry" != */../* ]] || return 1
  done < <(tar -tzf "$archive")
}

viptrue_install_archive_tree() {
  local archive="$1"
  local install_dir="$2"
  local tmp extract_root backup

  viptrue_archive_safe "$archive" || {
    viptrue_download_fail "Archive contains unsafe paths: $archive"
    return 1
  }

  tmp="$(mktemp -d)"
  mkdir -p "$tmp/extract"
  if ! tar -xzf "$archive" -C "$tmp/extract"; then
    rm -rf -- "$tmp"
    viptrue_download_fail "Could not extract archive: $archive"
    return 1
  fi

  extract_root="$tmp/extract"
  if [[ "$(find "$extract_root" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == "1" ]]; then
    local only
    only="$(find "$extract_root" -mindepth 1 -maxdepth 1 | head -n 1)"
    [[ -d "$only" ]] && extract_root="$only"
  fi

  mkdir -p "$(dirname "$install_dir")"
  if [[ -e "$install_dir" ]]; then
    backup="${install_dir}.viptrue-backup-$(date +%Y%m%d-%H%M%S)"
    mv "$install_dir" "$backup"
    viptrue_download_info "Previous install moved to $backup"
  fi
  mkdir -p "$install_dir"
  cp -a "$extract_root/." "$install_dir/"
  rm -rf -- "$tmp"
  viptrue_download_pass "Installed archive tree into $install_dir"
}

viptrue_git_sync() {
  local repo_url="$1"
  local branch="$2"
  local install_dir="$3"

  if ! command -v git >/dev/null 2>&1; then
    viptrue_download_fail "git is not installed."
    return 127
  fi

  if [[ -d "$install_dir/.git" ]]; then
    git -C "$install_dir" remote set-url origin "$repo_url" || return 1
    git -C "$install_dir" fetch origin "$branch" --prune || return 1
    git -C "$install_dir" checkout -B "$branch" "origin/$branch" || return 1
  else
    [[ ! -e "$install_dir" ]] || mv "$install_dir" "${install_dir}.viptrue-backup-$(date +%Y%m%d-%H%M%S)"
    git clone --depth=1 --branch "$branch" "$repo_url" "$install_dir" || return 1
  fi
  viptrue_download_pass "Git source installed/updated: $repo_url ($branch)"
}

viptrue_git_or_archive() {
  local repo_url="$1"
  local branch="$2"
  local install_dir="$3"
  local mirror_archive_path="$4"
  local tmp_archive mirror_url=""

  viptrue_load_mirror_config
  tmp_archive="$(mktemp)"
  rm -f -- "$tmp_archive"
  if [[ -n "$VIPTRUE_MIRROR_BASE" && -n "$mirror_archive_path" ]]; then
    mirror_url="$(viptrue_mirror_url "$mirror_archive_path")"
  fi

  case "$VIPTRUE_DOWNLOAD_MODE" in
    mirror-first)
      if [[ -n "$mirror_url" ]] && viptrue_download_one "$mirror_url" "$tmp_archive" && viptrue_install_archive_tree "$tmp_archive" "$install_dir"; then
        rm -f -- "$tmp_archive"
        return 0
      fi
      viptrue_git_sync "$repo_url" "$branch" "$install_dir" && { rm -f -- "$tmp_archive"; return 0; }
      ;;
    mirror-only)
      if [[ -n "$mirror_url" ]] && viptrue_download_one "$mirror_url" "$tmp_archive" && viptrue_install_archive_tree "$tmp_archive" "$install_dir"; then
        rm -f -- "$tmp_archive"
        return 0
      fi
      ;;
    official-first)
      if viptrue_git_sync "$repo_url" "$branch" "$install_dir"; then
        rm -f -- "$tmp_archive"
        return 0
      fi
      if [[ -n "$mirror_url" ]] && viptrue_download_one "$mirror_url" "$tmp_archive" && viptrue_install_archive_tree "$tmp_archive" "$install_dir"; then
        rm -f -- "$tmp_archive"
        return 0
      fi
      ;;
    official-only)
      viptrue_git_sync "$repo_url" "$branch" "$install_dir" && { rm -f -- "$tmp_archive"; return 0; }
      ;;
  esac

  rm -f -- "$tmp_archive"
  viptrue_download_fail "Git/archive installation failed for $repo_url ($branch)."
  return 1
}

viptrue_apt_install() {
  local -a packages=("$@")
  viptrue_load_mirror_config
  if ! command -v apt-get >/dev/null 2>&1; then
    viptrue_download_fail "apt-get is unavailable; install manually: ${packages[*]}"
    return 127
  fi
  if [[ "$VIPTRUE_APT_REGION" == "iran" ]]; then
    viptrue_download_info "Iran APT mode selected. Toolbox CDN does not proxy APT; configure a reachable APT mirror/proxy if apt fails."
  fi
  apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 update || {
    viptrue_download_fail "apt-get update failed."
    return 1
  }
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y "${packages[@]}" || {
    viptrue_download_fail "apt install failed: ${packages[*]}"
    return 1
  }
  viptrue_download_pass "APT packages installed: ${packages[*]}"
}

viptrue_need_cmd() {
  local command_name="$1"
  local package_name="$2"
  if command -v "$command_name" >/dev/null 2>&1; then
    viptrue_download_pass "$command_name available at $(command -v "$command_name")"
    return 0
  fi
  viptrue_download_warn "$command_name missing; installing package $package_name."
  viptrue_apt_install "$package_name" || return 1
  if command -v "$command_name" >/dev/null 2>&1; then
    viptrue_download_pass "$command_name installed."
    return 0
  fi
  viptrue_download_fail "$command_name is still unavailable after installing $package_name."
  return 1
}

viptrue_asset_cache_path() {
  local name="$1"
  local version="$2"
  local file="$3"
  viptrue_load_mirror_config
  if [[ -z "$name" || -z "$version" || -z "$file" || "$name" == *..* || "$version" == *..* || "$file" == */* || "$file" == *..* ]]; then
    viptrue_download_fail "Unsafe asset cache path components."
    return 1
  fi
  printf '%s/%s/%s/%s\n' "$VIPTRUE_ASSET_CACHE" "$name" "$version" "$file"
}
