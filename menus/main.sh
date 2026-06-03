#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

while true; do
  title
  echo -e "${CYAN}Main Menu${NC}"
  echo
  echo "1. Work"
  echo "2. Private"
  echo "0. Exit"
  echo "99. Exit toolbox"
  echo
  line
  read -r -p "Enter your choice [0-2]: " choice

  case "$choice" in
    1) bash "$BASE_DIR/menus/work.sh" ;;
    2) bash "$BASE_DIR/menus/private.sh" ;;
    0) echo "Bye."; exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
