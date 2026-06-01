#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

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
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
