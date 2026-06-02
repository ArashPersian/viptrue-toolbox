#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

cat > modules/work/01-root-ssh.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

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

reload_ssh() {
  if systemctl list-unit-files | grep -q '^ssh.service'; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd.service'; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd
  else
    echo -e "${RED}SSH service not found.${NC}"
    return 1
  fi
}

get_ssh_port() {
  local port=""

  port="$(awk '
    /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
      print $2
      exit
    }
  ' /etc/ssh/sshd_config 2>/dev/null || true)"

  if [[ -z "$port" && -d /etc/ssh/sshd_config.d ]]; then
    port="$(awk '
      /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
        print $2
        exit
      }
    ' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
  fi

  if [[ -z "$port" ]]; then
    port="$(ss -ltnp 2>/dev/null | awk '
      /sshd/ && /LISTEN/ {
        addr=$4

        if (addr ~ /^127\.0\.0\.1:/) next
        if (addr ~ /^\[::1\]:/) next
        if (addr ~ /^localhost:/) next

        n=split(addr,a,":")
        p=a[n]

        if (p ~ /^[0-9]+$/) {
          print p
          exit
        }
      }
    ' || true)"
  fi

  echo "${port:-22}"
}

port_is_in_use() {
  local port="$1"
  ss -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

generate_random_port() {
  local port

  while true; do
    port="$(shuf -i 20000-65000 -n 1)"
    if ! port_is_in_use "$port"; then
      echo "$port"
      return 0
    fi
  done
}

ensure_port_line() {
  local new_port="$1"

  if grep -qE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config; then
    sed -i -E "s/^[[:space:]]*Port[[:space:]]+[0-9]+/Port ${new_port}/" /etc/ssh/sshd_config
  elif grep -qE '^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config; then
    sed -i -E "0,/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+/s//Port ${new_port}/" /etc/ssh/sshd_config
  else
    echo "" >> /etc/ssh/sshd_config
    echo "Port ${new_port}" >> /etc/ssh/sshd_config
  fi
}

allow_ufw_port_if_available() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}UFW detected. Allowing new SSH port ${port}/tcp...${NC}"
    ufw allow "${port}/tcp" || true
  fi
}

test_sshd_config() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -t
  else
    /usr/sbin/sshd -t
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

  echo -e "${YELLOW}Detected SSH port:${NC}"
  get_ssh_port
  echo

  echo -e "${YELLOW}SSH service status:${NC}"
  systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true
  echo

  echo -e "${YELLOW}Important SSH config lines:${NC}"
  grep -nE '^(#)?(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' /etc/ssh/sshd_config || true
  echo

  echo -e "${YELLOW}Listening SSH ports:${NC}"
  ss -ltnp | grep -E 'sshd|:22|:.*' || true
  echo
}

change_ssh_port() {
  title
  echo -e "${CYAN}Change SSH Port${NC}"
  line
  echo

  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return
  fi

  local current_port new_port mode backup_file

  current_port="$(get_ssh_port)"

  echo -e "${YELLOW}Current detected SSH port:${NC} ${current_port}"
  echo
  echo "Choose new SSH port mode:"
  echo "1. Enter custom port manually"
  echo "2. Generate random high port"
  echo "0. Cancel"
  echo
  read -r -p "Enter your choice [0-2]: " mode

  case "$mode" in
    1)
      read -r -p "Enter new SSH port [1-65535]: " new_port
      ;;
    2)
      new_port="$(generate_random_port)"
      echo -e "${GREEN}Generated random SSH port:${NC} ${new_port}"
      ;;
    0)
      echo -e "${YELLOW}Cancelled.${NC}"
      pause
      return
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      pause
      return
      ;;
  esac

  if ! is_valid_port "$new_port"; then
    echo -e "${RED}Invalid port.${NC}"
    pause
    return
  fi

  if [[ "$new_port" == "$current_port" ]]; then
    echo -e "${YELLOW}New port is the same as current port.${NC}"
    pause
    return
  fi

  if port_is_in_use "$new_port"; then
    echo -e "${RED}Port ${new_port} seems to be already in use.${NC}"
    pause
    return
  fi

  echo
  echo -e "${RED}Important safety notes:${NC}"
  echo "- This will change SSH port from ${current_port} to ${new_port}."
  echo "- The current SSH session should stay connected."
  echo "- Do NOT close this session until you test a new SSH connection."
  echo "- Old port will NOT be blocked automatically."
  echo "- If UFW exists, new port will be allowed before SSH reload."
  echo

  read -r -p "Continue changing SSH port to ${new_port}? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      backup_file="/etc/ssh/sshd_config.backup.$(date +%F-%H%M%S)"
      cp /etc/ssh/sshd_config "$backup_file"

      allow_ufw_port_if_available "$new_port"
      ensure_port_line "$new_port"

      echo -e "${YELLOW}Testing sshd config...${NC}"
      if test_sshd_config; then
        reload_ssh
        echo
        echo -e "${GREEN}SSH port changed successfully.${NC}"
        echo
        echo -e "${YELLOW}Old SSH port:${NC} ${current_port}"
        echo -e "${YELLOW}New SSH port:${NC} ${new_port}"
        echo -e "${YELLOW}Backup file:${NC} ${backup_file}"
        echo
        echo "Now open a NEW terminal and test:"
        echo
        echo "ssh root@YOUR_SERVER_IP -p ${new_port}"
        echo
        echo "If the new connection works, you can later remove/deny the old SSH port from UFW."
      else
        echo -e "${RED}sshd config test failed. Restoring backup...${NC}"
        cp "$backup_file" /etc/ssh/sshd_config
        reload_ssh || true
      fi
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

while true; do
  title
  echo -e "${CYAN}Root / SSH Preparation${NC}"
  echo
  echo "1. Show SSH / root status"
  echo "2. Set root password"
  echo "3. Enable root SSH login with password"
  echo "4. Disable root SSH login with password"
  echo "5. Change SSH port"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-5]: " choice

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

          if test_sshd_config; then
            restart_ssh
            echo -e "${GREEN}Root SSH login with password enabled.${NC}"
          else
            echo -e "${RED}sshd config test failed. Please check manually.${NC}"
          fi
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

          if test_sshd_config; then
            restart_ssh
            echo -e "${GREEN}Root password login disabled. SSH key login may still work.${NC}"
          else
            echo -e "${RED}sshd config test failed. Please check manually.${NC}"
          fi
          ;;
        *)
          echo -e "${YELLOW}Cancelled.${NC}"
          ;;
      esac
      pause
      ;;
    5)
      change_ssh_port
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

chmod +x modules/work/01-root-ssh.sh
bash -n modules/work/01-root-ssh.sh

echo
echo "✅ Step 7 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add SSH port change option' && git push"
