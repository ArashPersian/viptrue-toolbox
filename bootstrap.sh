#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${VIPTRUE_REPO_URL:-https://github.com/ArashPersian/viptrue-toolbox.git}"
BRANCH="${VIPTRUE_BRANCH:-main}"
INSTALL_DIR="${VIPTRUE_INSTALL_DIR:-/opt/viptrue-toolbox}"
BACKUP_ROOT="${VIPTRUE_BACKUP_ROOT:-/root/viptrue-toolbox-local-backups}"

C_RESET="\033[0m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[0;36m"

say() { echo -e "${C_CYAN}$*${C_RESET}"; }
ok() { echo -e "${C_GREEN}$*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}$*${C_RESET}"; }
err() { echo -e "${C_RED}$*${C_RESET}"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root: curl ... | sudo bash"
    exit 1
  fi
}

install_deps() {
  local missing=()
  for c in git curl tar; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    warn "Installing missing packages: ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates tar
  fi
}

backup_local_copy() {
  local reason="${1:-manual}"
  [[ -d "$INSTALL_DIR" ]] || return 0

  mkdir -p "$BACKUP_ROOT"
  local ts bk
  ts="$(date +%F-%H%M%S)"
  bk="$BACKUP_ROOT/$ts-$reason"
  mkdir -p "$bk"

  warn "Backing up local installation before force sync:"
  echo "  $bk/local-copy.tar.gz"

  tar --exclude='.git' -czf "$bk/local-copy.tar.gz" -C "$INSTALL_DIR" . 2>/dev/null || true

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    (
      cd "$INSTALL_DIR"
      git status --porcelain=v1 > "$bk/git-status.txt" 2>/dev/null || true
      git diff > "$bk/git-diff.patch" 2>/dev/null || true
      git diff --cached > "$bk/git-diff-cached.patch" 2>/dev/null || true
    )
  fi
}

force_update_git_install() {
  cd "$INSTALL_DIR"

  git remote set-url origin "$REPO_URL" 2>/dev/null || true

  say "Fetching latest VIPTrue Toolbox from GitHub..."
  git fetch origin "$BRANCH" --tags --prune

  if [[ -n "$(git status --porcelain=v1 2>/dev/null || true)" ]]; then
    backup_local_copy "dirty-worktree"
  fi

  warn "Force syncing local installation with origin/$BRANCH ..."
  git reset --hard "origin/$BRANCH"
  git clean -fd

  ok "Updated cleanly to $(git rev-parse --short HEAD)"
}

clone_fresh() {
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
}

install_or_update() {
  cd /

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    say "Existing git installation found. Updating with safe force-sync..."
    force_update_git_install
  elif [[ -e "$INSTALL_DIR" ]]; then
    warn "Existing non-git installation found. Moving it to backup, then cloning fresh..."
    backup_local_copy "non-git-install"
    local moved="$BACKUP_ROOT/moved-install-$(date +%F-%H%M%S)"
    mkdir -p "$BACKUP_ROOT"
    mv "$INSTALL_DIR" "$moved" 2>/dev/null || rm -rf "$INSTALL_DIR"
    clone_fresh
  else
    say "Installing VIPTrue Toolbox to $INSTALL_DIR ..."
    clone_fresh
  fi
}

run_toolbox() {
  cd "$INSTALL_DIR"

  if [[ -f VERSION ]]; then
    echo
    ok "VIPTrue Server Toolbox"
    echo -e "${C_GREEN}Version: $(cat VERSION)${C_RESET}"
  fi

  chmod +x bootstrap.sh 2>/dev/null || true
  find menus modules scripts -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

  echo
  say "Starting VIPTrue Toolbox..."
  echo

  if [[ -f "viptrue.sh" ]]; then
    bash viptrue.sh
  elif [[ -f "main.sh" ]]; then
    bash main.sh
  elif [[ -f "menus/main.sh" ]]; then
    BASE_DIR="$INSTALL_DIR"
    export BASE_DIR
    source "$INSTALL_DIR/lib/ui.sh"
    source "$INSTALL_DIR/menus/work.sh" 2>/dev/null || true
    source "$INSTALL_DIR/menus/private.sh" 2>/dev/null || true
    source "$INSTALL_DIR/menus/utility.sh" 2>/dev/null || true
    source "$INSTALL_DIR/menus/main.sh"
    if declare -F viptrue_main_menu >/dev/null 2>&1; then
      viptrue_main_menu
    else
      bash menus/main.sh
    fi
  else
    ok "Installed/updated at $INSTALL_DIR"
    warn "No launcher found. Available files:"
    ls -la "$INSTALL_DIR"
  fi
}

main() {
  need_root
  echo "VIPTrue Toolbox Bootstrap"
  echo "Branch: $BRANCH"
  echo "Install dir: $INSTALL_DIR"
  echo "----------------------------------------"
  install_deps
  install_or_update
  run_toolbox
}

main "$@"
