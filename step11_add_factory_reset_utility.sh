#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p menus modules/utility

cat > menus/utility.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

while true; do
  title
  echo -e "${CYAN}Utility Tools${NC}"
  echo
  echo "1. Server Factory-like Reset"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-1]: " choice

  case "$choice" in
    1)
      bash "$BASE_DIR/modules/utility/01-factory-reset.sh"
      ;;
    0)
      break
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      sleep 1
      ;;
  esac
done
EOF

cat > modules/utility/01-factory-reset.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

RESET_LOG_DIR="/root/viptrue-reset-logs"
RESET_BACKUP_DIR="/root/viptrue-reset-backup-$(date +%F-%H%M%S)"

KNOWN_SERVICES=(
  pg-node-service
  pg-node
  xray
  xray-d
  sing-box
  singbox
  hysteria-server
  hysteria
  tuic
  wg-quick@wg0
  docker
)

KNOWN_PATHS=(
  /opt/pg-node
  /var/lib/pg-node
  /etc/pg-node
  /etc/xray
  /usr/local/etc/xray
  /usr/local/bin/xray
  /etc/wireguard
  /usr/local/etc/sing-box
  /etc/sing-box
  /etc/hysteria
  /usr/local/etc/hysteria
  /etc/tuic
  /usr/local/etc/tuic
)

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return 1
  fi
}

confirm_danger() {
  local phrase="FACTORY RESET"
  echo
  echo -e "${RED}Danger zone:${NC}"
  echo "This can remove VPN/node services, configs, firewall rules, cache, and logs."
  echo "This is NOT a real cloud provider rebuild."
  echo
  echo "To continue, type exactly:"
  echo "$phrase"
  echo
  read -r -p "Confirmation: " input

  [[ "$input" == "$phrase" ]]
}

show_reset_plan() {
  title
  echo -e "${CYAN}Server Factory-like Reset Plan${NC}"
  line
  echo

  echo -e "${YELLOW}Important:${NC}"
  echo "A real rebuild must be done from AWS/Vultr/Azure/Hetzner panel or provider API."
  echo "This tool only cleans the current OS to a near-fresh state."
  echo

  echo "Reset levels:"
  echo
  echo "1. Dry-run scan only"
  echo "   فقط بررسی می‌کند چه سرویس‌ها و فایل‌هایی پیدا شده‌اند."
  echo
  echo "2. Soft cleanup"
  echo "   apt cache, temp files, old logs, journal cleanup."
  echo
  echo "3. Reset VPN stack"
  echo "   Stops/removes known VPN/node services and configs:"
  echo "   PasarGuard, Xray, WireGuard, Sing-box, Hysteria, TUIC."
  echo
  echo "4. Full factory-like reset"
  echo "   VPN stack cleanup + Docker cleanup + UFW reset + cache/log cleanup."
  echo
  echo -e "${YELLOW}SSH safety:${NC}"
  echo "This module does not intentionally close your current SSH port."
  echo
  pause
}

dry_run_scan() {
  title
  echo -e "${CYAN}Dry-run Scan Only${NC}"
  line
  echo

  echo -e "${YELLOW}Hostname:${NC}"
  hostname
  echo

  echo -e "${YELLOW}OS:${NC}"
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-Unknown}"
  else
    echo "Unknown"
  fi
  echo

  echo -e "${YELLOW}Detected services:${NC}"
  for svc in "${KNOWN_SERVICES[@]}"; do
    if systemctl list-units --type=service --all 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
      echo "- ${svc}.service : $(systemctl is-active "$svc" 2>/dev/null || true)"
    fi
  done
  echo

  echo -e "${YELLOW}Detected paths:${NC}"
  for path in "${KNOWN_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      echo "- $path"
    fi
  done
  echo

  echo -e "${YELLOW}Docker:${NC}"
  if command -v docker >/dev/null 2>&1; then
    docker ps -a || true
  else
    echo "Docker not installed."
  fi
  echo

  echo -e "${YELLOW}UFW:${NC}"
  if command -v ufw >/dev/null 2>&1; then
    ufw status numbered || true
  else
    echo "UFW not installed."
  fi
  echo

  echo -e "${YELLOW}Listening ports:${NC}"
  ss -tulpn || true
  echo

  pause
}

soft_cleanup() {
  title
  echo -e "${CYAN}Soft Cleanup${NC}"
  line
  echo

  ensure_root || return

  echo "This will clean apt cache, temp files, and old logs."
  read -r -p "Continue? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      mkdir -p "$RESET_LOG_DIR"

      apt-get clean || true
      apt-get autoremove -y || true

      rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

      journalctl --vacuum-time=1d || true

      find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
      find /var/log -type f -name "*.1" -delete 2>/dev/null || true

      echo -e "${GREEN}Soft cleanup completed.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

backup_known_configs() {
  mkdir -p "$RESET_BACKUP_DIR"

  for path in "${KNOWN_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      mkdir -p "$RESET_BACKUP_DIR$(dirname "$path")"
      cp -a "$path" "$RESET_BACKUP_DIR$path" 2>/dev/null || true
    fi
  done

  if [[ -d /etc/systemd/system ]]; then
    mkdir -p "$RESET_BACKUP_DIR/etc/systemd/system"
    cp -a /etc/systemd/system/*pg* "$RESET_BACKUP_DIR/etc/systemd/system/" 2>/dev/null || true
    cp -a /etc/systemd/system/*xray* "$RESET_BACKUP_DIR/etc/systemd/system/" 2>/dev/null || true
    cp -a /etc/systemd/system/*sing* "$RESET_BACKUP_DIR/etc/systemd/system/" 2>/dev/null || true
    cp -a /etc/systemd/system/*hysteria* "$RESET_BACKUP_DIR/etc/systemd/system/" 2>/dev/null || true
    cp -a /etc/systemd/system/*tuic* "$RESET_BACKUP_DIR/etc/systemd/system/" 2>/dev/null || true
  fi

  echo "$RESET_BACKUP_DIR"
}

reset_vpn_stack() {
  title
  echo -e "${CYAN}Reset VPN Stack${NC}"
  line
  echo

  ensure_root || return

  echo -e "${YELLOW}This will stop/disable/remove known VPN/node services and configs.${NC}"
  echo "Known stack:"
  echo "PasarGuard, Xray, WireGuard, Sing-box, Hysteria, TUIC"
  echo

  if ! confirm_danger; then
    echo -e "${YELLOW}Cancelled.${NC}"
    pause
    return
  fi

  local backup_dir
  backup_dir="$(backup_known_configs)"

  echo
  echo -e "${YELLOW}Backup saved to:${NC}"
  echo "$backup_dir"
  echo

  for svc in "${KNOWN_SERVICES[@]}"; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done

  systemctl daemon-reload >/dev/null 2>&1 || true

  for path in "${KNOWN_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      rm -rf "$path"
      echo -e "${GREEN}Removed:${NC} $path"
    fi
  done

  rm -f /etc/systemd/system/pg-node-service.service 2>/dev/null || true
  rm -f /etc/systemd/system/pg-node.service 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box.service 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria.service 2>/dev/null || true
  rm -f /etc/systemd/system/tuic.service 2>/dev/null || true

  systemctl daemon-reload >/dev/null 2>&1 || true

  echo
  echo -e "${GREEN}VPN stack reset completed.${NC}"
  pause
}

full_factory_like_reset() {
  title
  echo -e "${CYAN}Full Factory-like Reset${NC}"
  line
  echo

  ensure_root || return

  echo -e "${RED}This is destructive.${NC}"
  echo
  echo "It will:"
  echo "- Reset VPN stack"
  echo "- Remove Docker containers/images/volumes if Docker exists"
  echo "- Reset UFW rules if UFW exists"
  echo "- Clean cache/temp/logs"
  echo
  echo "It will NOT:"
  echo "- Reinstall the OS"
  echo "- Delete your cloud instance"
  echo "- Intentionally close the current SSH port"
  echo

  if ! confirm_danger; then
    echo -e "${YELLOW}Cancelled.${NC}"
    pause
    return
  fi

  local backup_dir
  backup_dir="$(backup_known_configs)"

  echo
  echo -e "${YELLOW}Backup saved to:${NC}"
  echo "$backup_dir"
  echo

  for svc in "${KNOWN_SERVICES[@]}"; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done

  if command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}Cleaning Docker...${NC}"
    docker ps -aq | xargs -r docker rm -f || true
    docker images -aq | xargs -r docker rmi -f || true
    docker volume ls -q | xargs -r docker volume rm -f || true
    docker network prune -f || true
  fi

  for path in "${KNOWN_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      rm -rf "$path"
      echo -e "${GREEN}Removed:${NC} $path"
    fi
  done

  rm -f /etc/systemd/system/pg-node-service.service 2>/dev/null || true
  rm -f /etc/systemd/system/pg-node.service 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box.service 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria.service 2>/dev/null || true
  rm -f /etc/systemd/system/tuic.service 2>/dev/null || true

  systemctl daemon-reload >/dev/null 2>&1 || true

  if command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}Resetting UFW...${NC}"
    ufw --force reset || true
    ufw disable || true
  fi

  apt-get clean || true
  apt-get autoremove -y || true
  rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
  journalctl --vacuum-time=1d || true

  echo
  echo -e "${GREEN}Full factory-like reset completed.${NC}"
  echo
  echo "Recommended next step:"
  echo "Reboot the server, then run the toolbox again."
  echo
  read -r -p "Reboot now? [y/N]: " reboot_confirm
  case "$reboot_confirm" in
    y|Y|yes|YES)
      reboot
      ;;
    *)
      echo -e "${YELLOW}Reboot skipped.${NC}"
      ;;
  esac

  pause
}

while true; do
  title
  echo -e "${CYAN}Server Factory-like Reset${NC}"
  echo
  echo "1. Show reset plan"
  echo "2. Dry-run scan only"
  echo "3. Soft cleanup: cache/log/temp only"
  echo "4. Reset VPN stack"
  echo "5. Full factory-like reset - dangerous"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-5]: " choice

  case "$choice" in
    1) show_reset_plan ;;
    2) dry_run_scan ;;
    3) soft_cleanup ;;
    4) reset_vpn_stack ;;
    5) full_factory_like_reset ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF

chmod +x menus/utility.sh modules/utility/01-factory-reset.sh

bash -n menus/utility.sh
bash -n modules/utility/01-factory-reset.sh

echo
echo "✅ Step 11 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add server factory-like reset utility' && git push"
