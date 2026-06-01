#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"

cd "$PROJECT_DIR"

mkdir -p lib menus modules/work modules/private modules/utility

cat > bootstrap.sh <<'EOF'
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
EOF

cat > lib/ui.sh <<'EOF'
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
EOF

cat > menus/main.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

while true; do
  title
  echo -e "${CYAN}Main Menu${NC}"
  echo
  echo "1. Work"
  echo "2. Private"
  echo "0. Exit"
  echo
  line
  read -r -p "Enter your choice [0-2]: " choice

  case "$choice" in
    1) bash "$BASE_DIR/menus/work.sh" ;;
    2) bash "$BASE_DIR/menus/private.sh" ;;
    0) echo "Bye."; exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF

cat > menus/work.sh <<'EOF'
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
      echo -e "${YELLOW}Root / SSH Preparation is not configured yet.${NC}"
      pause
      ;;
    2)
      echo -e "${YELLOW}Server Update & Basic Packages is not configured yet.${NC}"
      pause
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
EOF

cat > menus/private.sh <<'EOF'
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
EOF

cat > menus/utility.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

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
  read -r -p "Enter your choice [0]: " choice

  case "$choice" in
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF

find . -type f -name "*.sh" -exec chmod +x {} \;

bash -n bootstrap.sh
bash -n lib/ui.sh
bash -n menus/main.sh
bash -n menus/work.sh
bash -n menus/private.sh
bash -n menus/utility.sh

echo
echo "✅ Step 1 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Rebuild menu system for one-line installer' && git push"
