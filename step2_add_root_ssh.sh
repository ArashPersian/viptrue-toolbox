#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"

cd "$PROJECT_DIR"

mkdir -p modules/work

cat > modules/work/01-root-ssh.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

restart_ssh() {
  if systemctl list-unit-files | grep -q '^ssh.service'; then
    systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd.service'; then
    systemctl restart sshd
  else
    echo -e "${RED}SSH service not found.${NC}"
    return 1
  fi
}

show_status() {
  title
  echo -e "${CYAN}Root / SSH Status${NC}"
  line
  echo

  echo -e "${YELLOW}Current user:${NC}"
  whoami
  id
  echo

  echo -e "${YELLOW}Root account status:${NC}"
  passwd -S root || true
  echo

  echo -e "${YELLOW}SSH service status:${NC}"
  systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true
  echo

  echo -e "${YELLOW}Important SSH config lines:${NC}"
  grep -nE '^(#)?(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' /etc/ssh/sshd_config || true
  echo

  echo -e "${YELLOW}Listening SSH ports:${NC}"
  ss -tulpn | grep -E ':(22|[0-9]+).*ssh' || true
  echo
}

while true; do
  title
  echo -e "${CYAN}Root / SSH Preparation${NC}"
  echo
  echo "1. Show SSH / root status"
  echo "2. Set root password"
  echo "3. Enable root SSH login with password"
  echo "4. Disable root SSH login with password"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-4]: " choice

  case "$choice" in
    1)
      show_status
      pause
      ;;
    2)
      echo -e "${YELLOW}Set a new password for root user.${NC}"
      passwd root
      pause
      ;;
    3)
      title
      echo -e "${RED}Warning:${NC} Enabling root SSH login with password is risky on public servers."
      echo
      read -r -p "Are you sure you want to enable it? [y/N]: " confirm
      case "$confirm" in
        y|Y|yes|YES)
          cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%F-%H%M%S)"
          sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
          sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

          if ! grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
            echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
          fi

          if ! grep -q '^PasswordAuthentication' /etc/ssh/sshd_config; then
            echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
          fi

          restart_ssh
          echo -e "${GREEN}Root SSH login with password enabled.${NC}"
          ;;
        *)
          echo -e "${YELLOW}Cancelled.${NC}"
          ;;
      esac
      pause
      ;;
    4)
      title
      echo -e "${YELLOW}This will disable root SSH password login.${NC}"
      read -r -p "Continue? [y/N]: " confirm
      case "$confirm" in
        y|Y|yes|YES)
          cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%F-%H%M%S)"
          sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
          restart_ssh
          echo -e "${GREEN}Root password login disabled. SSH key login may still work.${NC}"
          ;;
        *)
          echo -e "${YELLOW}Cancelled.${NC}"
          ;;
      esac
      pause
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

find . -type f -name "*.sh" -exec chmod +x {} \;

bash -n modules/work/01-root-ssh.sh
bash -n menus/work.sh

echo
echo "✅ Step 2 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add root SSH preparation menu' && git push"
