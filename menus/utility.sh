#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$BASE_DIR/lib/ui.sh"

viptrue_utility_menu() {
  while true; do
    title
    echo -e "${CYAN}Utility Tools${NC}"
    echo
    echo "1. Server Factory-like Reset"
    echo "2. Temporary Tunnel / Proxy for Installations"
    echo "3. Offline Assets / Local Installer"
    echo "4. Tunnel Manager"
    echo "5. Floating IP Manager"
    echo "0. Back"
    echo
    line
    read -r -p "Enter your choice [0-5]: " choice

    case "$choice" in
      1) bash "$BASE_DIR/modules/utility/01-factory-reset.sh" ;;
      2) bash "$BASE_DIR/modules/utility/02-temp-tunnel.sh" ;;
      3) bash "$BASE_DIR/modules/utility/03-offline-assets.sh" ;;
      4) bash "$BASE_DIR/modules/utility/04-tunnel-manager.sh" ;;
      5) bash "$BASE_DIR/modules/utility/06-floating-ip-manager.sh" ;;
      0) return 0 ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  viptrue_utility_menu
fi
