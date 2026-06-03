#!/usr/bin/env bash

NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m'

line() {
  echo -e "${GREEN}============================================================${NC}"
}

pause() {
  echo
  read -r -p "Press Enter to continue..." _
}

title() {
  clear
  echo -e "${CYAN}"
  cat <<'EOF'
 __      ___ _____ _______             
 \ \    / (_)  __ \__   __|            
  \ \  / / _| |__) | | |_ __ _   _  ___ 
   \ \/ / | |  ___/  | | '__| | | |/ _ \
    \  /  | | |      | | |  | |_| |  __/
     \/   |_|_|      |_|_|   \__,_|\___|
EOF
  echo -e "${NC}"
  echo "VIPTrue Server Toolbox"
  echo -e "${GREEN}Version:${NC} $(viptrue_get_version)"
  line
}

# Backward compatibility for old handlers.


viptrue_get_version() {
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if [[ -f "$base_dir/VERSION" ]]; then
    tr -d '[:space:]' < "$base_dir/VERSION"
  else
    echo "${TOOLBOX_VERSION:-0.1.0}"
  fi
}

