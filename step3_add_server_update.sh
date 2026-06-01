#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"

cd "$PROJECT_DIR"

mkdir -p modules/work

cat > modules/work/02-update-server.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

show_system_info() {
  title
  echo -e "${CYAN}Server System Info${NC}"
  line
  echo

  echo -e "${YELLOW}Hostname:${NC}"
  hostnamectl --static 2>/dev/null || hostname
  echo

  echo -e "${YELLOW}OS:${NC}"
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-Unknown}"
  else
    echo "Unknown"
  fi
  echo

  echo -e "${YELLOW}Kernel:${NC}"
  uname -r
  echo

  echo -e "${YELLOW}Uptime:${NC}"
  uptime -p || true
  echo

  echo -e "${YELLOW}Disk usage:${NC}"
  df -h / || true
  echo

  echo -e "${YELLOW}Memory:${NC}"
  free -h || true
  echo
}

install_basic_packages() {
  title
  echo -e "${CYAN}Server Update & Basic Packages${NC}"
  line
  echo

  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return
  fi

  echo -e "${YELLOW}This will update the server and install basic packages.${NC}"
  echo
  echo "Packages:"
  echo "curl wget git nano vim htop unzip zip tar jq ca-certificates"
  echo "gnupg lsb-release ufw fail2ban net-tools dnsutils iproute2 cron"
  echo
  read -r -p "Continue? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      export DEBIAN_FRONTEND=noninteractive

      apt-get update

      apt-get upgrade -y

      apt-get install -y \
        curl \
        wget \
        git \
        nano \
        vim \
        htop \
        unzip \
        zip \
        tar \
        jq \
        ca-certificates \
        gnupg \
        lsb-release \
        ufw \
        fail2ban \
        net-tools \
        dnsutils \
        iproute2 \
        software-properties-common \
        cron

      systemctl enable cron >/dev/null 2>&1 || true
      systemctl start cron >/dev/null 2>&1 || true

      echo
      echo -e "${GREEN}Server update and basic packages installation completed.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

while true; do
  title
  echo -e "${CYAN}Server Update & Basic Packages${NC}"
  echo
  echo "1. Show system info"
  echo "2. Update server and install basic packages"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-2]: " choice

  case "$choice" in
    1)
      show_system_info
      pause
      ;;
    2)
      install_basic_packages
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
      bash "$BASE_DIR/modules/work/01-root-ssh.sh"
      ;;
    2)
      bash "$BASE_DIR/modules/work/02-update-server.sh"
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

find . -type f -name "*.sh" -exec chmod +x {} \;

bash -n modules/work/02-update-server.sh
bash -n menus/work.sh

echo
echo "✅ Step 3 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add server update basic packages menu' && git push"
