#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${VIPTRUE_REPO_URL:-https://github.com/ArashPersian/viptrue-toolbox.git}"
BRANCH="${VIPTRUE_BRANCH:-main}"
INSTALL_DIR="${VIPTRUE_INSTALL_DIR:-/opt/viptrue-toolbox}"
BACKUP_ROOT="${VIPTRUE_BACKUP_ROOT:-/root/viptrue-toolbox-local-backups}"
CMD_PATH="/usr/local/bin/viptrue"

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
    err "Please run as root:"
    echo "curl -sSL https://raw.githubusercontent.com/ArashPersian/viptrue-toolbox/main/bootstrap.sh | sudo bash"
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

  warn "Backing up local installation before sync:"
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

    mkdir -p "$BACKUP_ROOT"
    local moved="$BACKUP_ROOT/moved-install-$(date +%F-%H%M%S)"
    mv "$INSTALL_DIR" "$moved" 2>/dev/null || rm -rf "$INSTALL_DIR"

    clone_fresh

  else
    say "Installing VIPTrue Toolbox to $INSTALL_DIR ..."
    clone_fresh
  fi
}

install_command() {
  chmod +x "$INSTALL_DIR/bootstrap.sh" 2>/dev/null || true
  chmod +x "$INSTALL_DIR/viptrue.sh" 2>/dev/null || true
  chmod +x "$INSTALL_DIR/main.sh" 2>/dev/null || true
  find "$INSTALL_DIR/menus" "$INSTALL_DIR/modules" "$INSTALL_DIR/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

  cat > "$CMD_PATH" <<EOF_CMD
#!/usr/bin/env bash
exec bash "$INSTALL_DIR/viptrue.sh" "\$@"
EOF_CMD

  chmod +x "$CMD_PATH"
}

print_done() {
  echo
  ok "VIPTrue Server Toolbox installed/updated successfully."

  if [[ -f "$INSTALL_DIR/VERSION" ]]; then
    echo -e "${C_GREEN}Version: $(cat "$INSTALL_DIR/VERSION")${C_RESET}"
  fi

  echo
  say "To open the interactive menu, run:"
  echo
  echo "  viptrue"
  echo
  warn "Important:"
  echo "Do not run the interactive menu directly through curl pipe."
  echo "Use curl pipe only for install/update, then run: viptrue"
  echo
}

main() {
  need_root

  echo "VIPTrue Toolbox Bootstrap"
  echo "Branch: $BRANCH"
  echo "Install dir: $INSTALL_DIR"
  echo "----------------------------------------"

  install_deps
  install_or_update
  install_command
  print_done
}

main "$@"
