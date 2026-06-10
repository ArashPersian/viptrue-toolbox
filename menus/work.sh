#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$BASE_DIR/lib/ui.sh"

viptrue_work_menu() {
  while true; do
    title
    echo -e "${CYAN}Work Menu${NC}"
    echo
    echo "1. Root / SSH Preparation"
    echo "2. Server Update & Basic Packages"
    echo "3. UFW Firewall"
    echo "4. PasarGuard Node"
    echo "5. Cloudflare XHTTP Nginx Setup"
    echo "6. Utility Tools"
    echo "0. Back"
    echo
    line
    read -r -p "Enter your choice [0-6]: " choice

    case "$choice" in
      1) bash "$BASE_DIR/modules/work/01-root-ssh.sh" ;;
      2) bash "$BASE_DIR/modules/work/02-update-server.sh" ;;
      3) bash "$BASE_DIR/modules/work/03-ufw-firewall.sh" ;;
      4) bash "$BASE_DIR/modules/work/03-pasarguard-node.sh" ;;
      5) bash "$BASE_DIR/modules/work/05-cf-xhttp-nginx.sh" ;;
      6)
        if declare -F viptrue_utility_menu >/dev/null 2>&1; then
          viptrue_utility_menu
        else
          bash "$BASE_DIR/menus/utility.sh"
        fi
        ;;
      0) return 0 ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$BASE_DIR/menus/utility.sh"
  viptrue_work_menu
fi
