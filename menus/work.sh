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
  echo "3. UFW Firewall"
  echo "4. PasarGuard Node"
  echo "5. Utility Tools"
  echo "0. Back"
  echo "99. Exit toolbox"
  echo
  line
  read -r -p "Enter your choice [0-5]: " choice

  case "$choice" in
    1)
      bash "$BASE_DIR/modules/work/01-root-ssh.sh"
      ;;
    2)
      bash "$BASE_DIR/modules/work/02-update-server.sh"
      ;;
    3)
      bash "$BASE_DIR/modules/work/03-ufw-firewall.sh"
      ;;
    4)
      bash "$BASE_DIR/modules/work/03-pasarguard-node.sh"
      ;;
    5)
      bash "$BASE_DIR/menus/utility.sh"
      ;;
    0)
      break
      ;;    99)
      viptrue_exit_toolbox
      ;;

    *)
      echo -e "${RED}Invalid choice.${NC}"
      sleep 1
      ;;
  esac
done
