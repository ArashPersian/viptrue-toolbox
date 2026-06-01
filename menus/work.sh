#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

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
  read -r -p "Enter your choice [0-4]: " choice

  case "$choice" in
    1)
      bash "$BASE_DIR/modules/work/01-root-ssh.sh"
      ;;
    2)
      bash "$BASE_DIR/modules/work/02-update-server.sh"
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
