#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

while true; do
  title
  echo -e "${CYAN}Work Menu${NC}"
  echo
  echo "1. Root / SSH Preparation"
  echo "2. Server Update & Basic Packages"
  echo "3. PasarGuard Node"
  echo "4. Utility Tools"
  echo "0. Back"
  echo
  line
  read -rp "Enter your choice [0-4]: " choice

  case "$choice" in
    1)
      echo -e "${YELLOW}Root / SSH Preparation is not configured yet.${NC}"
      pause
      ;;
    2)
      echo -e "${YELLOW}Server Update & Basic Packages is not configured yet.${NC}"
      pause
      ;;
    3)
      echo -e "${YELLOW}PasarGuard Node is not configured yet.${NC}"
      pause
      ;;
    4)
      bash "$BASE_DIR/menus/utility.sh"
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
