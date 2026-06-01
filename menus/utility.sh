#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

while true; do
  title
  echo -e "${CYAN}Utility Tools${NC}"
  echo
  echo -e "${YELLOW}Utility Tools menu is empty for now.${NC}"
  echo -e "${YELLOW}We will add tools one by one after approval.${NC}"
  echo
  echo "0. Back"
  echo
  line
  read -rp "Enter your choice [0]: " choice

  case "$choice" in
    0)
      break
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      sleep 1
      ;;
  esac
done
