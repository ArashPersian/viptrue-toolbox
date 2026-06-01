#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/ArashPersian/viptrue-toolbox.git"
INSTALL_DIR="/opt/viptrue-toolbox"
TOOLBOX_VERSION="0.1.0"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}VIPTrue Toolbox Bootstrap${NC}"
echo -e "${GREEN}Version: ${TOOLBOX_VERSION}${NC}"
echo "----------------------------------------"

if [[ "${EUID}" -ne 0 ]]; then
  echo -e "${RED}Please run with sudo/root.${NC}"
  echo
  echo "Example:"
  echo "curl -sSL https://raw.githubusercontent.com/ArashPersian/viptrue-toolbox/main/bootstrap.sh | sudo bash"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo -e "${YELLOW}Git not found. Installing git...${NC}"
  apt-get update
  apt-get install -y git ca-certificates curl
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo -e "${YELLOW}Existing installation found. Updating...${NC}"
  git -C "$INSTALL_DIR" pull --ff-only
else
  echo -e "${YELLOW}Installing VIPTrue Toolbox to ${INSTALL_DIR} ...${NC}"
  rm -rf "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

find "$INSTALL_DIR" -type f -name "*.sh" -exec chmod +x {} \;

echo -e "${GREEN}Starting VIPTrue Toolbox...${NC}"
echo

if [[ -e /dev/tty ]]; then
  exec bash "$INSTALL_DIR/menus/main.sh" < /dev/tty > /dev/tty 2>&1
else
  exec bash "$INSTALL_DIR/menus/main.sh"
fi
