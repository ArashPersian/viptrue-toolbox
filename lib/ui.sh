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
  echo " __      ___ ____ _______                  "
  echo " \ \    / (_)  _ \__   __|                 "
  echo "  \ \  / / _| |_) | | |_ __ _   _  ___     "
  echo "   \ \/ / | |  __/  | | '__| | | |/ _ \    "
  echo "    \  /  | | |     | | |  | |_| |  __/    "
  echo "     \/   |_|_|     |_|_|   \__,_|\___|    "
  echo -e "${NC}"
  echo -e "${WHITE}VIPTrue Server Toolbox${NC}"
  echo -e "${GREEN}Version: ${TOOLBOX_VERSION:-0.1.0}${NC}"
  line
}
