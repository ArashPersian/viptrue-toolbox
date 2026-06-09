#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$BASE_DIR/lib/ui.sh"

viptrue_private_menu() {
  while true; do
    title
    echo -e "${CYAN}Private Menu${NC}"
    echo
    echo -e "${YELLOW}Private menu is empty for now.${NC}"
    echo
    echo "0. Back"
    echo
    line
    read -r -p "Enter your choice [0]: " choice

    case "$choice" in
      0) return 0 ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  viptrue_private_menu
fi
