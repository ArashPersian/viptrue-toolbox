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
  echo "2. Temporary Tunnel / Proxy for Installations"
  echo "0. Back"
  echo "99. Exit toolbox"
  echo
  line
  read -r -p "Enter your choice [0-2]: " choice

  case "$choice" in
    1)
      if [[ -f "$BASE_DIR/modules/utility/01-factory-reset.sh" ]]; then
        bash "$BASE_DIR/modules/utility/01-factory-reset.sh"
      else
        echo -e "${YELLOW}Server Factory-like Reset is not configured yet.${NC}"
        pause
      fi
      ;;
    2)
      bash "$BASE_DIR/modules/utility/02-temp-tunnel.sh"
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
