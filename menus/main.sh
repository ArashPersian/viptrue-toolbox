#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$BASE_DIR/lib/ui.sh"
source "$BASE_DIR/menus/work.sh"
source "$BASE_DIR/menus/private.sh"
source "$BASE_DIR/menus/utility.sh"

viptrue_main_menu() {
  while true; do
    title
    echo -e "${CYAN}Main Menu${NC}"
    echo
    echo "1. Work"
    echo "2. Private"
    echo "0. Exit"
    echo
    line
    read -r -p "Enter your choice [0-2]: " choice

    case "$choice" in
      1) viptrue_work_menu ;;
      2) viptrue_private_menu ;;
      0) echo "Bye."; exit 0 ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  viptrue_main_menu
fi
