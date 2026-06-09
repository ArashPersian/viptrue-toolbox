#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_DIR

source "$BASE_DIR/menus/main.sh"

if declare -F viptrue_main_menu >/dev/null 2>&1; then
  viptrue_main_menu
else
  echo "ERROR: viptrue_main_menu not found."
  exit 1
fi
