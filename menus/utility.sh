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
