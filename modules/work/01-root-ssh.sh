#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

SSH_STATE_FILE="/opt/viptrue-toolbox/state/ssh-port-change.env"
VIPTRUE_SSH_DROPIN="/etc/ssh/sshd_config.d/00-viptrue-toolbox.conf"

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

get_ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "ssh.service"; then
    echo "ssh"
    return 0
  fi

  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "sshd.service"; then
    echo "sshd"
    return 0
  fi

  if systemctl status ssh >/dev/null 2>&1; then
    echo "ssh"
    return 0
  fi

  if systemctl status sshd >/dev/null 2>&1; then
    echo "sshd"
    return 0
  fi

  echo ""
}

test_sshd_config() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -t
  else
    /usr/sbin/sshd -t
  fi
}

restart_ssh() {
  local svc
  svc="$(get_ssh_service_name)"

  if [[ -n "$svc" ]]; then
    systemctl restart "$svc"
    return 0
  fi

  if command -v service >/dev/null 2>&1; then
    if service ssh status >/dev/null 2>&1; then
      service ssh restart
      return 0
    fi

    if service sshd status >/dev/null 2>&1; then
      service sshd restart
      return 0
    fi
  fi

  echo -e "${RED}SSH service not found.${NC}"
  echo
  echo "Debug:"
  systemctl list-units --type=service --all 2>/dev/null | grep -Ei 'ssh|sshd|dropbear' || true
  return 1
}

reload_ssh() {
  local svc
  svc="$(get_ssh_service_name)"

  if [[ -n "$svc" ]]; then
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
    return 0
  fi

  restart_ssh
}

ssh_socket_exists() {
  systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "ssh.socket"
}

ssh_socket_active_or_enabled() {
  if ssh_socket_exists; then
    systemctl is-active --quiet ssh.socket 2>/dev/null && return 0
    systemctl is-enabled --quiet ssh.socket 2>/dev/null && return 0
  fi

  return 1
}

disable_ssh_socket_if_needed() {
  if ssh_socket_exists; then
    if ssh_socket_active_or_enabled; then
      echo -e "${YELLOW}ssh.socket detected. Disabling socket activation to allow custom SSH port...${NC}"
      systemctl disable --now ssh.socket >/dev/null 2>&1 || true
      systemctl mask ssh.socket >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi
}

enable_ssh_service() {
  local svc
  svc="$(get_ssh_service_name)"

  if [[ -z "$svc" ]]; then
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "ssh.service"; then
      svc="ssh"
    elif systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "sshd.service"; then
      svc="sshd"
    fi
  fi

  if [[ -n "$svc" ]]; then
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc"
    return 0
  fi

  echo -e "${RED}Could not enable/restart SSH service.${NC}"
  return 1
}

get_configured_ssh_port() {
  local port=""

  if command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
  elif [[ -x /usr/sbin/sshd ]]; then
    port="$(/usr/sbin/sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
  fi

  if [[ -z "$port" ]]; then
    port="$(awk '
      /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
        print $2
        exit
      }
    ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
  fi

  echo "${port:-22}"
}

get_listening_ssh_ports() {
  ss -ltnp 2>/dev/null | awk '
    /sshd/ && /LISTEN/ {
      addr=$4

      if (addr ~ /^127\.0\.0\.1:/) next
      if (addr ~ /^\[::1\]:/) next
      if (addr ~ /^localhost:/) next

      n=split(addr,a,":")
      p=a[n]

      if (p ~ /^[0-9]+$/) {
        print p
      }
    }
  ' | sort -n -u
}

get_primary_listening_ssh_port() {
  local port
  port="$(get_listening_ssh_ports | head -n 1 || true)"
  echo "${port:-UNKNOWN}"
}

get_current_session_ssh_port() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "$SSH_CONNECTION" | awk '{print $4}'
  else
    echo ""
  fi
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

allow_ufw_port_if_available() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}UFW detected. Allowing SSH port ${port}/tcp...${NC}"
    ufw allow "${port}/tcp" || true
  fi
}

backup_ssh_files() {
  local backup_dir="/etc/ssh/viptrue-backup-$(date +%F-%H%M%S)"
  mkdir -p "$backup_dir"

  cp /etc/ssh/sshd_config "$backup_dir/sshd_config" 2>/dev/null || true

  if [[ -d /etc/ssh/sshd_config.d ]]; then
    cp -a /etc/ssh/sshd_config.d "$backup_dir/sshd_config.d" 2>/dev/null || true
  fi

  echo "$backup_dir"
}

write_viptrue_ssh_dropin() {
  local port="$1"
  local enable_root_password="${2:-yes}"

  mkdir -p /etc/ssh/sshd_config.d

  cat > "$VIPTRUE_SSH_DROPIN" <<EOF2
# Managed by VIPTrue Toolbox
# This file is created to make SSH settings explicit on cloud images.

Port ${port}
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin ${enable_root_password}
EOF2
}

fix_cloudimg_password_override() {
  local file

  if [[ -d /etc/ssh/sshd_config.d ]]; then
    for file in /etc/ssh/sshd_config.d/*.conf; do
      [[ -f "$file" ]] || continue

      if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$file"; then
        cp "$file" "${file}.backup.$(date +%F-%H%M%S)"
        sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+no/# Disabled by VIPTrue Toolbox: PasswordAuthentication no/g' "$file"
        echo -e "${GREEN}Disabled cloud override in:${NC} $file"
      fi

      if grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+(no|prohibit-password|forced-commands-only)' "$file"; then
        cp "$file" "${file}.backup.$(date +%F-%H%M%S)"
        sed -i -E 's/^[[:space:]]*PermitRootLogin[[:space:]]+(no|prohibit-password|forced-commands-only)/# Disabled by VIPTrue Toolbox: &/g' "$file"
        echo -e "${GREEN}Disabled root login override in:${NC} $file"
      fi
    done
  fi
}

fix_aws_root_authorized_keys() {
  if [[ -f /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "/root/.ssh/authorized_keys.backup.$(date +%F-%H%M%S)" 2>/dev/null || true

    sed -i '/Please login as the user/d' /root/.ssh/authorized_keys 2>/dev/null || true
    sed -i '/exit 142/d' /root/.ssh/authorized_keys 2>/dev/null || true
    sed -i '/command=.*login as/d' /root/.ssh/authorized_keys 2>/dev/null || true

    chown -R root:root /root/.ssh
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

    echo -e "${GREEN}Checked/fixed root authorized_keys restrictions.${NC}"
  fi
}

verify_ssh_listening_on_port() {
  local expected_port="$1"
  local tries=10
  local i

  for ((i=1; i<=tries; i++)); do
    if get_listening_ssh_ports | grep -qx "$expected_port"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

apply_ssh_settings() {
  local port="$1"
  local root_mode="${2:-yes}"

  backup_ssh_files >/dev/null

  write_viptrue_ssh_dropin "$port" "$root_mode"
  fix_cloudimg_password_override
  fix_aws_root_authorized_keys
  allow_ufw_port_if_available "$port"
  disable_ssh_socket_if_needed

  echo -e "${YELLOW}Testing sshd config...${NC}"
  test_sshd_config

  echo -e "${YELLOW}Restarting SSH service...${NC}"
  enable_ssh_service

  if verify_ssh_listening_on_port "$port"; then
    echo -e "${GREEN}SSH is now listening on port ${port}.${NC}"
    return 0
  fi

  echo -e "${RED}SSH did not start listening on expected port ${port}.${NC}"
  echo
  echo -e "${YELLOW}Current listening SSH ports:${NC}"
  get_listening_ssh_ports || true
  echo
  return 1
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

  echo -e "${YELLOW}Configured SSH port:${NC}"
  get_configured_ssh_port
  echo

  echo -e "${YELLOW}Listening SSH ports:${NC}"
  get_listening_ssh_ports || true
  echo

  echo -e "${YELLOW}Current SSH session server port:${NC}"
  get_current_session_ssh_port || true
  echo

  echo -e "${YELLOW}SSH service status:${NC}"
  systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true
  echo

  echo -e "${YELLOW}ssh.socket status:${NC}"
  if ssh_socket_exists; then
    echo "active:  $(systemctl is-active ssh.socket 2>/dev/null || true)"
    echo "enabled: $(systemctl is-enabled ssh.socket 2>/dev/null || true)"
  else
    echo "not found"
  fi
  echo

  echo -e "${YELLOW}Important SSH config lines:${NC}"
  grep -RniE '^[[:space:]]*#?[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|UsePAM|PubkeyAuthentication|Match)' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null || true
  echo

  echo -e "${YELLOW}Recent auth log:${NC}"
  tail -n 30 /var/log/auth.log 2>/dev/null | grep -Ei 'root|ubuntu|sshd|failed|accepted|closed|disconnect|listening' || true
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

  local current_port new_port mode

  current_port="$(get_configured_ssh_port)"

  echo -e "${YELLOW}Current configured SSH port:${NC} ${current_port}"
  echo -e "${YELLOW}Current listening SSH ports:${NC}"
  get_listening_ssh_ports || true
  echo

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

  if port_is_in_use "$new_port"; then
    echo -e "${RED}Port ${new_port} seems to be already in use.${NC}"
    pause
    return
  fi

  echo
  echo -e "${RED}Important safety notes:${NC}"
  echo "- This will change SSH port to ${new_port}."
  echo "- The current SSH session should stay connected."
  echo "- Do NOT close this session until you test a new SSH connection."
  echo "- Old port will NOT be blocked automatically."
  echo "- If UFW exists, new port will be allowed before SSH restart."
  echo

  read -r -p "Continue changing SSH port to ${new_port}? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      if apply_ssh_settings "$new_port" "yes"; then
        mkdir -p "$(dirname "$SSH_STATE_FILE")"
        {
          echo "OLD_SSH_PORT=${current_port}"
          echo "NEW_SSH_PORT=${new_port}"
          echo "CHANGED_AT=$(date -Is)"
        } > "$SSH_STATE_FILE"

        echo
        echo -e "${GREEN}SSH port changed and verified successfully.${NC}"
        echo
        echo "Now open a NEW terminal and test:"
        echo
        echo "ssh root@YOUR_SERVER_IP -p ${new_port}"
        echo
        echo "After successful login with the new port, run:"
        echo "Root / SSH Preparation > Close old SSH port in UFW"
      else
        echo -e "${RED}Port change was not fully verified. Do not close current session.${NC}"
      fi
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

close_old_ssh_port_in_ufw() {
  title
  echo -e "${CYAN}Close Old SSH Port in UFW${NC}"
  line
  echo

  if [[ ! -f "$SSH_STATE_FILE" ]]; then
    echo -e "${YELLOW}No saved SSH port change state was found.${NC}"
    echo
    echo "Expected file:"
    echo "$SSH_STATE_FILE"
    pause
    return
  fi

  # shellcheck disable=SC1090
  source "$SSH_STATE_FILE"

  local old_port="${OLD_SSH_PORT:-}"
  local new_port="${NEW_SSH_PORT:-}"
  local session_port

  session_port="$(get_current_session_ssh_port)"

  echo -e "${YELLOW}Saved SSH port change:${NC}"
  echo "Old SSH port: ${old_port:-UNKNOWN}"
  echo "New SSH port: ${new_port:-UNKNOWN}"
  echo
  echo -e "${YELLOW}Current SSH session server port:${NC}"
  echo "${session_port:-UNKNOWN}"
  echo

  if ! is_valid_port "${old_port:-}" || ! is_valid_port "${new_port:-}"; then
    echo -e "${RED}Saved port values are invalid.${NC}"
    pause
    return
  fi

  if [[ -n "$session_port" && "$session_port" != "$new_port" ]]; then
    echo -e "${RED}Safety check failed.${NC}"
    echo
    echo "You are not connected through the new SSH port yet."
    echo "Current session port: $session_port"
    echo "Expected new port: $new_port"
    echo
    echo "Open a new terminal first and connect with:"
    echo "ssh root@YOUR_SERVER_IP -p ${new_port}"
    pause
    return
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}UFW is not installed. Nothing to close in UFW.${NC}"
    pause
    return
  fi

  echo -e "${RED}Warning:${NC}"
  echo "This will close old SSH port ${old_port}/tcp in UFW."
  echo
  read -r -p "Continue? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw allow "${new_port}/tcp" || true
      ufw --force delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
      ufw deny "${old_port}/tcp" || true

      echo
      echo -e "${GREEN}Old SSH port closed in UFW.${NC}"
      ufw status numbered || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

ssh_doctor() {
  title
  echo -e "${CYAN}SSH Doctor / Fix AWS Ubuntu SSH${NC}"
  line
  echo

  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return
  fi

  local configured_port listening_ports suggested_port

  configured_port="$(get_configured_ssh_port)"
  listening_ports="$(get_listening_ssh_ports || true)"

  echo -e "${YELLOW}Current diagnosis:${NC}"
  echo
  echo "Configured SSH port:"
  echo "$configured_port"
  echo
  echo "Listening SSH ports:"
  echo "${listening_ports:-NONE}"
  echo
  echo "ssh.socket:"
  if ssh_socket_exists; then
    echo "active:  $(systemctl is-active ssh.socket 2>/dev/null || true)"
    echo "enabled: $(systemctl is-enabled ssh.socket 2>/dev/null || true)"
  else
    echo "not found"
  fi
  echo
  echo "Cloud overrides:"
  grep -RniE 'PasswordAuthentication[[:space:]]+no|PermitRootLogin[[:space:]]+(no|prohibit-password|forced-commands-only)' \
    /etc/ssh/sshd_config.d 2>/dev/null || true
  echo

  suggested_port="$configured_port"
  if ! is_valid_port "$suggested_port"; then
    suggested_port="22"
  fi

  echo -e "${YELLOW}Fix plan:${NC}"
  echo "- Write explicit VIPTrue SSH drop-in config"
  echo "- Disable cloud PasswordAuthentication no overrides"
  echo "- Fix AWS root authorized_keys forced command restrictions"
  echo "- Disable ssh.socket if it forces port 22"
  echo "- Enable/restart SSH service"
  echo "- Verify SSH is really listening on configured port"
  echo
  echo -e "${YELLOW}Target SSH port:${NC} $suggested_port"
  echo

  read -r -p "Run SSH Doctor fix now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      if apply_ssh_settings "$suggested_port" "yes"; then
        echo
        echo -e "${GREEN}SSH Doctor completed successfully.${NC}"
        echo
        echo "Now test from a NEW terminal:"
        echo "ssh root@YOUR_SERVER_IP -p ${suggested_port}"
      else
        echo
        echo -e "${RED}SSH Doctor could not verify the expected port.${NC}"
        echo "Do not close your current session."
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
  echo "6. Close old SSH port in UFW"
  echo "7. SSH Doctor / Fix AWS Ubuntu SSH"
  echo "0. Back"
echo
  line
  read -r -p "Enter your choice [0-7]: " choice

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
          local_port="$(get_configured_ssh_port)"
          apply_ssh_settings "$local_port" "yes" || true
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
          local_port="$(get_configured_ssh_port)"
          apply_ssh_settings "$local_port" "prohibit-password" || true
          echo -e "${GREEN}Root password login disabled. SSH key login may still work.${NC}"
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
    6)
      close_old_ssh_port_in_ufw
      ;;
    7)
      ssh_doctor
      ;;
    0)
      break
      ;;    99)
      viptrue_main_menu
      ;;
*)
      echo -e "${RED}Invalid choice.${NC}"
      sleep 1
      ;;
  esac
done
