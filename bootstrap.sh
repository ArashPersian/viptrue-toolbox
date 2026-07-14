#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${VIPTRUE_REPO_URL:-https://github.com/ArashPersian/viptrue-toolbox.git}"
BRANCH="${VIPTRUE_BRANCH:-main}"
INSTALL_DIR="${VIPTRUE_INSTALL_DIR:-/opt/viptrue-toolbox}"
BACKUP_ROOT="${VIPTRUE_BACKUP_ROOT:-/root/viptrue-toolbox-local-backups}"
CMD_PATH="/usr/local/bin/viptrue"
MIRROR_CONF="${VIPTRUE_CONFIG_FILE:-/etc/viptrue-toolbox/mirror.conf}"

ENV_MIRROR_BASE="${VIPTRUE_MIRROR_BASE-__VIPTRUE_UNSET__}"
ENV_DOWNLOAD_MODE="${VIPTRUE_DOWNLOAD_MODE-__VIPTRUE_UNSET__}"
ENV_ARCHIVE_URL="${VIPTRUE_ARCHIVE_URL-__VIPTRUE_UNSET__}"
ENV_ARCHIVE_SHA256="${VIPTRUE_ARCHIVE_SHA256-__VIPTRUE_UNSET__}"

VIPTRUE_MIRROR_BASE=""
VIPTRUE_DOWNLOAD_MODE="official-first"
VIPTRUE_ARCHIVE_URL=""
VIPTRUE_ARCHIVE_SHA256=""
INSTALL_SOURCE="unknown"

C_RESET="\033[0m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[0;36m"

say() { echo -e "${C_CYAN}$*${C_RESET}"; }
ok() { echo -e "${C_GREEN}[PASS] $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}[WARN] $*${C_RESET}"; }
err() { echo -e "${C_RED}[FAIL] $*${C_RESET}" >&2; }

load_bootstrap_config() {
  local key value
  if [[ -r "$MIRROR_CONF" ]]; then
    while IFS='=' read -r key value; do
      [[ -n "$key" && "$key" != \#* ]] || continue
      value="${value%$'\r'}"
      case "$key" in
        VIPTRUE_MIRROR_BASE) VIPTRUE_MIRROR_BASE="$value" ;;
        VIPTRUE_DOWNLOAD_MODE) VIPTRUE_DOWNLOAD_MODE="$value" ;;
      esac
    done < "$MIRROR_CONF"
  fi

  [[ "$ENV_MIRROR_BASE" == "__VIPTRUE_UNSET__" ]] || VIPTRUE_MIRROR_BASE="$ENV_MIRROR_BASE"
  [[ "$ENV_DOWNLOAD_MODE" == "__VIPTRUE_UNSET__" ]] || VIPTRUE_DOWNLOAD_MODE="$ENV_DOWNLOAD_MODE"
  [[ "$ENV_ARCHIVE_URL" == "__VIPTRUE_UNSET__" ]] || VIPTRUE_ARCHIVE_URL="$ENV_ARCHIVE_URL"
  [[ "$ENV_ARCHIVE_SHA256" == "__VIPTRUE_UNSET__" ]] || VIPTRUE_ARCHIVE_SHA256="$ENV_ARCHIVE_SHA256"

  VIPTRUE_MIRROR_BASE="${VIPTRUE_MIRROR_BASE%/}"
  case "$VIPTRUE_DOWNLOAD_MODE" in
    mirror-first|official-first|mirror-only|official-only) ;;
    *)
      warn "Invalid download mode '$VIPTRUE_DOWNLOAD_MODE'; using official-first."
      VIPTRUE_DOWNLOAD_MODE="official-first"
      ;;
  esac
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root."
    echo "curl -fsSL https://raw.githubusercontent.com/ArashPersian/viptrue-toolbox/main/bootstrap.sh | sudo bash"
    exit 1
  fi
}

archive_fallback_url() {
  if [[ -n "$VIPTRUE_ARCHIVE_URL" ]]; then
    printf '%s\n' "$VIPTRUE_ARCHIVE_URL"
  elif [[ -n "$VIPTRUE_MIRROR_BASE" ]]; then
    printf '%s/repo/%s.tar.gz\n' "$VIPTRUE_MIRROR_BASE" "$BRANCH"
  fi
}

apt_install_bootstrap() {
  local -a packages=("$@")
  command -v apt-get >/dev/null 2>&1 || return 1
  apt-get -o Acquire::Retries=3 update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y "${packages[@]}"
}

install_deps() {
  local archive_url
  archive_url="$(archive_fallback_url || true)"

  if ! command -v tar >/dev/null 2>&1; then
    warn "Installing required archive package: tar"
    apt_install_bootstrap tar gzip ca-certificates || {
      err "tar is required for archive installation."
      return 1
    }
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "Installing curl for bootstrap downloads."
    apt_install_bootstrap curl ca-certificates || {
      err "curl or wget is required for archive fallback."
      return 1
    }
  fi

  if [[ "$VIPTRUE_DOWNLOAD_MODE" != "mirror-only" ]] && ! command -v git >/dev/null 2>&1; then
    warn "Installing git for the default GitHub path."
    if ! apt_install_bootstrap git ca-certificates; then
      if [[ -n "$archive_url" && "$VIPTRUE_DOWNLOAD_MODE" != "official-only" ]]; then
        warn "git installation failed; continuing because an archive fallback is configured."
      else
        err "git is unavailable and no permitted archive fallback is configured."
        return 1
      fi
    fi
  fi
}

backup_local_copy() {
  local reason="${1:-manual}"
  local ts bk
  [[ -d "$INSTALL_DIR" ]] || return 0

  mkdir -p "$BACKUP_ROOT"
  ts="$(date +%F-%H%M%S)"
  bk="$BACKUP_ROOT/$ts-$reason"
  mkdir -p "$bk"

  warn "Backing up local installation before replacement:"
  echo "  $bk/local-copy.tar.gz"
  if ! tar --exclude='.git' -czf "$bk/local-copy.tar.gz" -C "$INSTALL_DIR" .; then
    warn "Local-copy archive failed; replacement will not continue."
    return 1
  fi

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    (
      cd "$INSTALL_DIR"
      git status --porcelain=v1 > "$bk/git-status.txt" 2>/dev/null || warn "Could not save git status."
      git diff > "$bk/git-diff.patch" 2>/dev/null || warn "Could not save git diff."
      git diff --cached > "$bk/git-diff-cached.patch" 2>/dev/null || warn "Could not save staged git diff."
    )
  fi
}

replace_install_from_dir() {
  local source_dir="$1"
  local reason="$2"
  local moved

  if [[ -e "$INSTALL_DIR" ]]; then
    backup_local_copy "$reason" || return 1
    mkdir -p "$BACKUP_ROOT"
    moved="$BACKUP_ROOT/moved-install-$(date +%F-%H%M%S)-$reason"
    mv "$INSTALL_DIR" "$moved"
    warn "Previous install moved to: $moved"
  fi

  mkdir -p "$(dirname "$INSTALL_DIR")"
  mv "$source_dir" "$INSTALL_DIR"
}

install_from_git() {
  local tmp clone_dir
  command -v git >/dev/null 2>&1 || {
    err "git is unavailable."
    return 1
  }

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    say "Fetching VIPTrue Toolbox from GitHub..."
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
    if ! git -C "$INSTALL_DIR" fetch origin "$BRANCH" --tags --prune; then
      err "Git fetch failed."
      return 1
    fi
    if [[ -n "$(git -C "$INSTALL_DIR" status --porcelain=v1 2>/dev/null || true)" ]]; then
      backup_local_copy "dirty-worktree" || return 1
    fi
    git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH"
    git -C "$INSTALL_DIR" clean -fd
    INSTALL_SOURCE="git"
    ok "Updated from git to $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
    return 0
  fi

  tmp="$(mktemp -d)"
  clone_dir="$tmp/repo"
  say "Cloning VIPTrue Toolbox from GitHub..."
  if ! git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$clone_dir"; then
    rm -rf -- "$tmp"
    err "Git clone failed."
    return 1
  fi
  replace_install_from_dir "$clone_dir" "git-replace" || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$tmp"
  INSTALL_SOURCE="git"
  ok "Installed from git."
}

download_file() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part.$$"
  rm -f -- "$tmp"

  if command -v curl >/dev/null 2>&1; then
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 -o "$tmp" "$url"; then
      mv -f -- "$tmp" "$dest"
      ok "Downloaded archive: $url"
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget --timeout=30 --tries=3 -O "$tmp" "$url"; then
      mv -f -- "$tmp" "$dest"
      ok "Downloaded archive: $url"
      return 0
    fi
  fi

  rm -f -- "$tmp"
  err "Archive download failed: $url"
  return 1
}

verify_archive_sha256() {
  local archive="$1"
  local expected="${VIPTRUE_ARCHIVE_SHA256:-}"
  local actual
  [[ -n "$expected" ]] || return 0
  expected="${expected%%[[:space:]]*}"
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || {
    err "VIPTRUE_ARCHIVE_SHA256 is not a valid SHA256."
    return 1
  }
  command -v sha256sum >/dev/null 2>&1 || apt_install_bootstrap coreutils || {
    err "sha256sum is required for archive verification."
    return 1
  }
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    err "Archive SHA256 mismatch."
    return 1
  fi
  ok "Archive SHA256 verified."
}

archive_is_safe() {
  local archive="$1" entry
  while IFS= read -r entry; do
    [[ "$entry" != /* ]] || return 1
    [[ "$entry" != ".." && "$entry" != ../* && "$entry" != */../* ]] || return 1
  done < <(tar -tzf "$archive")
}

install_from_archive() {
  local url tmp archive extract_dir source_dir only
  url="$(archive_fallback_url || true)"
  if [[ -z "$url" ]]; then
    err "No mirror archive URL is configured. Set VIPTRUE_MIRROR_BASE or VIPTRUE_ARCHIVE_URL."
    return 1
  fi

  tmp="$(mktemp -d)"
  archive="$tmp/repo.tar.gz"
  extract_dir="$tmp/extract"
  mkdir -p "$extract_dir"

  say "Trying repository archive fallback: $url"
  download_file "$url" "$archive" || { rm -rf -- "$tmp"; return 1; }
  verify_archive_sha256 "$archive" || { rm -rf -- "$tmp"; return 1; }
  archive_is_safe "$archive" || { rm -rf -- "$tmp"; err "Archive contains unsafe paths."; return 1; }
  tar -xzf "$archive" -C "$extract_dir" || { rm -rf -- "$tmp"; err "Archive extraction failed."; return 1; }

  source_dir="$extract_dir"
  if [[ "$(find "$extract_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == "1" ]]; then
    only="$(find "$extract_dir" -mindepth 1 -maxdepth 1 | head -n 1)"
    [[ -d "$only" ]] && source_dir="$only"
  fi
  if [[ ! -f "$source_dir/viptrue.sh" || ! -f "$source_dir/VERSION" ]]; then
    rm -rf -- "$tmp"
    err "Archive does not look like a VIPTrue Toolbox repository tree."
    return 1
  fi

  # Move source out of the temporary tree so replace_install_from_dir can own it.
  mv "$source_dir" "$tmp/install-ready"
  replace_install_from_dir "$tmp/install-ready" "archive-replace" || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$tmp"
  INSTALL_SOURCE="mirror archive"
  [[ -n "$VIPTRUE_ARCHIVE_URL" ]] && INSTALL_SOURCE="archive URL"
  ok "Installed from $INSTALL_SOURCE."
}

install_or_update() {
  case "$VIPTRUE_DOWNLOAD_MODE" in
    mirror-first)
      install_from_archive || install_from_git || return 1
      ;;
    mirror-only)
      install_from_archive || return 1
      ;;
    official-first)
      install_from_git || install_from_archive || return 1
      ;;
    official-only)
      if install_from_git; then
        return 0
      fi
      if [[ -n "$VIPTRUE_ARCHIVE_URL" ]]; then
        warn "Git failed; trying the explicit VIPTRUE_ARCHIVE_URL in official-only mode."
        install_from_archive || return 1
      else
        return 1
      fi
      ;;
  esac
}

install_command() {
  chmod +x "$INSTALL_DIR/bootstrap.sh" "$INSTALL_DIR/viptrue.sh" 2>/dev/null || true
  [[ -f "$INSTALL_DIR/main.sh" ]] && chmod +x "$INSTALL_DIR/main.sh"
  local dir
  for dir in menus modules scripts lib; do
    [[ -d "$INSTALL_DIR/$dir" ]] || continue
    find "$INSTALL_DIR/$dir" -type f -name '*.sh' -exec chmod +x {} \;
  done

  cat > "$CMD_PATH" <<EOF_CMD
#!/usr/bin/env bash
exec bash "$INSTALL_DIR/viptrue.sh" "\$@"
EOF_CMD
  chmod +x "$CMD_PATH"
}

print_done() {
  echo
  ok "VIPTrue Server Toolbox installed/updated successfully."
  echo "Install source: $INSTALL_SOURCE"
  if [[ -f "$INSTALL_DIR/VERSION" ]]; then
    echo -e "${C_GREEN}Version: $(cat "$INSTALL_DIR/VERSION")${C_RESET}"
  fi
  echo
  say "To open the interactive menu, run:"
  echo "  viptrue"
  echo
  warn "Do not run the interactive menu directly through curl pipe."
  echo "Use curl pipe only for install/update, then run: viptrue"
}

main() {
  need_root
  load_bootstrap_config

  echo "VIPTrue Toolbox Bootstrap"
  echo "Branch: $BRANCH"
  echo "Install dir: $INSTALL_DIR"
  echo "Download mode: $VIPTRUE_DOWNLOAD_MODE"
  echo "Mirror base: ${VIPTRUE_MIRROR_BASE:-not configured}"
  echo "----------------------------------------"

  install_deps
  install_or_update
  install_command
  print_done
}

main "$@"
