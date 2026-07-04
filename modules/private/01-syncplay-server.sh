#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/ui.sh
source "$BASE_DIR/lib/ui.sh"

SYNCPLAY_REPO_URL="https://github.com/Syncplay/syncplay.git"
SYNCPLAY_INSTALL_DIR="/opt/syncplay"
SYNCPLAY_CONFIG_DIR="/etc/viptrue/syncplay"
SYNCPLAY_ENV_FILE="$SYNCPLAY_CONFIG_DIR/syncplay.env"
SYNCPLAY_MOTD_FILE="$SYNCPLAY_CONFIG_DIR/motd.txt"
SYNCPLAY_DEFAULT_PORT="8999"
SYNCPLAY_DEFAULT_SERVICE="viptrue-syncplay"
SYNCPLAY_SYSTEM_USER="syncplay"

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

valid_service_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9_.@-]{1,64}$ && "$name" != *"/"* ]]
}

normalize_service_name() {
  local name="$1"
  name="${name%.service}"
  printf '%s\n' "$name"
}

ensure_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Root required.${NC} Run this action with sudo/root."
    return 1
  fi
}

is_debian_like() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" =~ ^(ubuntu|debian)$ || "${ID_LIKE:-}" == *debian* ]]
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "$prompt [$default]: " value
  printf '%s\n' "${value:-$default}"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  read -r -p "$prompt " answer
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

shell_quote() {
  local value="$1"
  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

random_secret() {
  if have_cmd openssl; then
    openssl rand -base64 24 | tr -d '\r\n'
  elif have_cmd od; then
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  else
    date +%s%N
  fi
}

load_syncplay_env() {
  [[ -f "$SYNCPLAY_ENV_FILE" ]] || return 1
  # shellcheck disable=SC1090
  . "$SYNCPLAY_ENV_FILE"
}

service_unit_path() {
  local service_name="$1"
  printf '/etc/systemd/system/%s.service\n' "$service_name"
}

service_status_word() {
  local service_name="$1"
  if have_cmd systemctl; then
    systemctl is-active "$service_name" 2>/dev/null || true
  else
    printf 'systemctl unavailable\n'
  fi
}

detect_public_ip_hint() {
  if have_cmd curl; then
    curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || printf 'SERVER_PUBLIC_IP_OR_DOMAIN\n'
  else
    printf 'SERVER_PUBLIC_IP_OR_DOMAIN\n'
  fi
}

listener_for_port() {
  local port="$1"
  if have_cmd ss; then
    ss -ltnp 2>/dev/null | grep -E "[:.]${port}([[:space:]]|$)" || true
  else
    echo "ss command unavailable; install iproute2 to inspect listeners."
  fi
}

ufw_is_active() {
  have_cmd ufw && ufw status 2>/dev/null | grep -qi "Status: active"
}

install_ufw_if_requested() {
  if have_cmd ufw; then
    return 0
  fi

  echo -e "${YELLOW}UFW is not installed.${NC}"
  if prompt_yes_no "Install UFW now? [y/N]:" "N"; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
  fi
}

open_ufw_port_if_active() {
  local port="$1"

  if ! valid_port "$port"; then
    echo -e "${RED}Invalid port:${NC} $port"
    return 1
  fi

  install_ufw_if_requested || true
  if ufw_is_active; then
    ufw allow "${port}/tcp" comment 'VIPTrue Syncplay Server'
    echo "UFW rule added for ${port}/tcp."
  elif have_cmd ufw; then
    echo "UFW is installed but inactive. Not enabling it automatically."
    echo "Manual command if you enable UFW later:"
    echo "  ufw allow ${port}/tcp comment 'VIPTrue Syncplay Server'"
  else
    echo "UFW is not installed. Provider/security-group must allow TCP $port."
  fi

  echo "Provider/security-group must allow TCP $port."
}

remove_ufw_port_if_requested() {
  local port="$1"
  valid_port "$port" || return 0
  have_cmd ufw || return 0

  if ! ufw_is_active; then
    return 0
  fi

  if prompt_yes_no "Remove old UFW allow rule for ${port}/tcp? [y/N]:" "N"; then
    ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
    echo "Old UFW rule removal attempted for ${port}/tcp."
  fi
}

syncplay_command_path() {
  if have_cmd syncplay-server; then
    command -v syncplay-server
    return 0
  fi

  if [[ -x "$SYNCPLAY_INSTALL_DIR/syncplayServer.py" ]] && have_cmd python3; then
    if python3 "$SYNCPLAY_INSTALL_DIR/syncplayServer.py" --help >/dev/null 2>&1; then
      printf '/usr/bin/python3 %s/syncplayServer.py\n' "$SYNCPLAY_INSTALL_DIR"
      return 0
    fi
  fi

  return 1
}

create_syncplay_user_if_possible() {
  if id "$SYNCPLAY_SYSTEM_USER" >/dev/null 2>&1; then
    return 0
  fi

  if have_cmd useradd; then
    useradd --system --home "$SYNCPLAY_INSTALL_DIR" --shell /usr/sbin/nologin "$SYNCPLAY_SYSTEM_USER" || true
  fi
}

write_env_file() {
  local port="$1"
  local password="$2"
  local salt="$3"
  local isolate="$4"
  local bind_mode="$5"
  local service_name="$6"
  local motd_file="$7"
  local exec_command="$8"

  mkdir -p "$SYNCPLAY_CONFIG_DIR"
  {
    printf 'SYNCPLAY_PORT=%s\n' "$(shell_quote "$port")"
    printf 'SYNCPLAY_PASSWORD=%s\n' "$(shell_quote "$password")"
    printf 'SYNCPLAY_SALT=%s\n' "$(shell_quote "$salt")"
    printf 'SYNCPLAY_ISOLATE_ROOMS=%s\n' "$(shell_quote "$isolate")"
    printf 'SYNCPLAY_BIND_MODE=%s\n' "$(shell_quote "$bind_mode")"
    printf 'SYNCPLAY_SERVICE_NAME=%s\n' "$(shell_quote "$service_name")"
    printf 'SYNCPLAY_MOTD_FILE=%s\n' "$(shell_quote "$motd_file")"
    printf 'SYNCPLAY_EXEC_COMMAND=%s\n' "$(shell_quote "$exec_command")"
  } > "$SYNCPLAY_ENV_FILE"
  chmod 600 "$SYNCPLAY_ENV_FILE"
}

write_motd_file() {
  local motd="$1"
  if [[ -n "${motd// /}" ]]; then
    mkdir -p "$SYNCPLAY_CONFIG_DIR"
    printf '%s\n' "$motd" > "$SYNCPLAY_MOTD_FILE"
    chmod 644 "$SYNCPLAY_MOTD_FILE"
    printf '%s\n' "$SYNCPLAY_MOTD_FILE"
  else
    rm -f "$SYNCPLAY_MOTD_FILE"
    printf '\n'
  fi
}

write_systemd_unit() {
  local service_name="$1"
  local port="$2"
  local isolate="$3"
  local bind_mode="$4"
  local motd_file="$5"
  local exec_command="$6"
  local unit_path user_line args

  unit_path="$(service_unit_path "$service_name")"
  user_line=""
  if id "$SYNCPLAY_SYSTEM_USER" >/dev/null 2>&1; then
    user_line="User=$SYNCPLAY_SYSTEM_USER"
  fi

  args="--port $port"
  if [[ "$isolate" == "yes" ]]; then
    args="$args --isolate-room"
  fi
  if [[ -n "$motd_file" ]]; then
    args="$args --motd-file $motd_file"
  fi
  if [[ "$bind_mode" == "ipv6" ]]; then
    args="$args --ipv6-only --interface-ipv6 ::"
  fi

  cat > "$unit_path" <<EOF_UNIT
[Unit]
Description=VIPTrue Syncplay Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SYNCPLAY_INSTALL_DIR
$user_line
EnvironmentFile=$SYNCPLAY_ENV_FILE
ExecStart=$exec_command $args
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_UNIT

  chmod 644 "$unit_path"
}

install_syncplay_dependencies() {
  if ! is_debian_like || ! have_cmd apt-get; then
    echo -e "${RED}Unsupported OS.${NC} This installer expects Ubuntu/Debian with apt."
    return 1
  fi

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git \
    make \
    python3 \
    python3-twisted \
    ca-certificates
}

clone_or_update_syncplay() {
  if [[ -d "$SYNCPLAY_INSTALL_DIR/.git" ]]; then
    git -C "$SYNCPLAY_INSTALL_DIR" fetch --all --prune
    git -C "$SYNCPLAY_INSTALL_DIR" pull --ff-only
  else
    rm -rf "$SYNCPLAY_INSTALL_DIR"
    git clone "$SYNCPLAY_REPO_URL" "$SYNCPLAY_INSTALL_DIR"
  fi
}

install_syncplay_server_files() {
  make -C "$SYNCPLAY_INSTALL_DIR" install-server
}

read_existing_default() {
  local var_name="$1"
  local fallback="$2"

  if load_syncplay_env; then
    case "$var_name" in
      port) printf '%s\n' "${SYNCPLAY_PORT:-$fallback}" ;;
      service) printf '%s\n' "${SYNCPLAY_SERVICE_NAME:-$fallback}" ;;
      isolate) printf '%s\n' "${SYNCPLAY_ISOLATE_ROOMS:-$fallback}" ;;
      bind) printf '%s\n' "${SYNCPLAY_BIND_MODE:-$fallback}" ;;
      *) printf '%s\n' "$fallback" ;;
    esac
  else
    printf '%s\n' "$fallback"
  fi
}

prompt_install_config() {
  local __port_var="$1"
  local __password_var="$2"
  local __salt_var="$3"
  local __isolate_var="$4"
  local __bind_mode_var="$5"
  local __service_var="$6"
  local __motd_var="$7"
  local port service_name password salt isolate bind_choice bind_mode motd default_port default_service

  default_port="$(read_existing_default port "$SYNCPLAY_DEFAULT_PORT")"
  default_service="$(read_existing_default service "$SYNCPLAY_DEFAULT_SERVICE")"

  port="$(prompt_default "Syncplay server port" "$default_port")"
  if ! valid_port "$port"; then
    echo -e "${RED}Invalid port.${NC} Use 1-65535."
    return 1
  fi

  service_name="$(prompt_default "Service name" "$default_service")"
  service_name="$(normalize_service_name "$service_name")"
  if ! valid_service_name "$service_name"; then
    echo -e "${RED}Invalid service name.${NC} Use letters, numbers, dot, underscore, @, or dash."
    return 1
  fi

  password=""
  if prompt_yes_no "Generate random password? [Y/n]:" "Y"; then
    password="$(random_secret)"
  else
    read -r -s -p "Private server password, optional: " password
    echo
  fi
  salt="$(random_secret)"

  isolate="no"
  if prompt_yes_no "Isolate rooms? [y/N]:" "N"; then
    isolate="yes"
  fi

  read -r -p "MOTD text, optional: " motd

  echo
  echo "Bind mode:"
  echo "1) IPv4/default"
  echo "2) IPv6 only"
  read -r -p "Select bind mode [1-2]: " bind_choice
  case "${bind_choice:-1}" in
    1) bind_mode="ipv4" ;;
    2) bind_mode="ipv6" ;;
    *)
      echo -e "${RED}Invalid bind mode.${NC}"
      return 1
      ;;
  esac

  printf -v "$__port_var" '%s' "$port"
  printf -v "$__password_var" '%s' "$password"
  printf -v "$__salt_var" '%s' "$salt"
  printf -v "$__isolate_var" '%s' "$isolate"
  printf -v "$__bind_mode_var" '%s' "$bind_mode"
  printf -v "$__service_var" '%s' "$service_name"
  printf -v "$__motd_var" '%s' "$motd"
}

print_install_summary() {
  local service_name="$1"
  local port="$2"
  local password="$3"
  local firewall_summary="$4"
  local public_hint status

  status="$(service_status_word "$service_name")"
  public_hint="$(detect_public_ip_hint)"

  echo
  line
  echo -e "${GREEN}Syncplay Server installed${NC}"
  echo
  echo "Service:"
  echo "  ${service_name}.service"
  echo
  echo "Port:"
  echo "  ${port}/tcp"
  echo
  echo "Status:"
  echo "  $status"
  echo
  echo "Connect from Syncplay client:"
  echo "  Server: ${public_hint}:${port}"
  if [[ -n "$password" ]]; then
    echo "  Password: $password"
    echo
    echo "Password stored at $SYNCPLAY_ENV_FILE"
  else
    echo "  Password: none configured"
  fi
  echo
  echo "Firewall:"
  echo "  $firewall_summary"
  echo "  Provider/security-group must allow TCP $port."
  echo
  echo "Useful commands:"
  echo "  systemctl status $service_name --no-pager"
  echo "  journalctl -u $service_name -n 80 --no-pager"
  echo "  ss -ltnp | grep ':$port'"
  echo
  echo "Current listener:"
  listener_for_port "$port"
  line
}

install_or_reinstall_syncplay() {
  local port password salt isolate bind_mode service_name motd motd_file exec_command firewall_summary

  title
  echo -e "${CYAN}Private > Syncplay Server > Install / Reinstall${NC}"
  line
  echo
  prompt_install_config port password salt isolate bind_mode service_name motd || { pause; return; }

  echo
  echo -e "${YELLOW}Plan${NC}"
  echo "  Install path: $SYNCPLAY_INSTALL_DIR"
  echo "  Config path:  $SYNCPLAY_ENV_FILE"
  echo "  Service:      ${service_name}.service"
  echo "  Port:         ${port}/tcp"
  echo "  Password:     stored in env file; printed once after install"
  echo "  Isolate:      $isolate"
  echo "  Bind mode:    $bind_mode"
  echo
  prompt_yes_no "Install/reinstall Syncplay Server now? [y/N]:" "N" || { echo "Cancelled."; pause; return; }

  ensure_root || { pause; return; }
  install_syncplay_dependencies || { pause; return; }
  install_ufw_if_requested || true
  clone_or_update_syncplay || { pause; return; }
  install_syncplay_server_files || { pause; return; }
  exec_command="$(syncplay_command_path)" || {
    echo -e "${RED}syncplay-server command not found and fallback did not validate.${NC}"
    pause
    return
  }
  create_syncplay_user_if_possible
  motd_file="$(write_motd_file "$motd")"
  write_env_file "$port" "$password" "$salt" "$isolate" "$bind_mode" "$service_name" "$motd_file" "$exec_command"
  write_systemd_unit "$service_name" "$port" "$isolate" "$bind_mode" "$motd_file" "$exec_command"
  systemctl daemon-reload
  systemctl enable --now "$service_name"

  firewall_summary="UFW inactive or unavailable"
  if ufw_is_active; then
    ufw allow "${port}/tcp" comment 'VIPTrue Syncplay Server'
    firewall_summary="UFW rule added"
  elif have_cmd ufw; then
    firewall_summary="UFW inactive"
  fi

  print_install_summary "$service_name" "$port" "$password" "$firewall_summary"
  pause
}

show_syncplay_status() {
  local service_name port public_hint

  title
  echo -e "${CYAN}Private > Syncplay Server > Status${NC}"
  line
  echo
  if load_syncplay_env; then
    service_name="${SYNCPLAY_SERVICE_NAME:-$SYNCPLAY_DEFAULT_SERVICE}"
    port="${SYNCPLAY_PORT:-$SYNCPLAY_DEFAULT_PORT}"
  else
    service_name="$SYNCPLAY_DEFAULT_SERVICE"
    port="$SYNCPLAY_DEFAULT_PORT"
    echo -e "${YELLOW}Syncplay Server is not installed by VIPTrue yet.${NC}"
    echo "Expected config path: $SYNCPLAY_ENV_FILE"
    echo
  fi

  echo "Service status:"
  if have_cmd systemctl; then
    systemctl status "$service_name" --no-pager -l 2>/dev/null || echo "Service not found or inactive: $service_name"
  else
    echo "systemctl unavailable"
  fi
  echo
  echo "Port:"
  echo "  ${port}/tcp"
  echo
  echo "Listener:"
  listener_for_port "$port"
  echo
  echo "Config path:"
  echo "  $SYNCPLAY_ENV_FILE"
  echo
  echo "Public IP hint:"
  public_hint="$(detect_public_ip_hint)"
  echo "  ${public_hint}:${port}"
  echo
  echo "Firewall:"
  if ufw_is_active; then
    ufw status | grep -E "${port}/tcp|Status:" || true
  elif have_cmd ufw; then
    echo "  UFW inactive. Provider/security-group must allow TCP $port."
  else
    echo "  UFW missing. Provider/security-group must allow TCP $port."
  fi
  echo
  if [[ -f "$SYNCPLAY_ENV_FILE" ]] && prompt_yes_no "Show password from env file? [y/N]:" "N"; then
    # shellcheck disable=SC2154
    echo "Password: ${SYNCPLAY_PASSWORD:-}"
  else
    echo "Password: hidden"
  fi
  pause
}

restart_syncplay() {
  local service_name="$SYNCPLAY_DEFAULT_SERVICE"
  load_syncplay_env && service_name="${SYNCPLAY_SERVICE_NAME:-$service_name}"
  title
  echo -e "${CYAN}Private > Syncplay Server > Restart${NC}"
  line
  ensure_root || { pause; return; }
  systemctl restart "$service_name"
  systemctl status "$service_name" --no-pager -l 2>/dev/null || true
  pause
}

stop_syncplay() {
  local service_name="$SYNCPLAY_DEFAULT_SERVICE"
  load_syncplay_env && service_name="${SYNCPLAY_SERVICE_NAME:-$service_name}"
  title
  echo -e "${CYAN}Private > Syncplay Server > Stop${NC}"
  line
  ensure_root || { pause; return; }
  systemctl stop "$service_name"
  systemctl status "$service_name" --no-pager -l 2>/dev/null || true
  pause
}

show_syncplay_logs() {
  local service_name="$SYNCPLAY_DEFAULT_SERVICE"
  load_syncplay_env && service_name="${SYNCPLAY_SERVICE_NAME:-$service_name}"
  title
  echo -e "${CYAN}Private > Syncplay Server > Logs${NC}"
  line
  if have_cmd journalctl; then
    journalctl -u "$service_name" -n 100 --no-pager 2>/dev/null || true
  else
    echo "journalctl unavailable"
  fi
  pause
}

change_port_password() {
  local old_port old_password old_salt old_service old_isolate old_bind old_motd_file exec_command
  local new_port password_choice new_password new_salt new_isolate new_bind_choice new_bind motd_choice motd motd_file

  title
  echo -e "${CYAN}Private > Syncplay Server > Change port/password${NC}"
  line
  echo
  load_syncplay_env || {
    echo -e "${YELLOW}No VIPTrue Syncplay config found. Install first.${NC}"
    pause
    return
  }

  old_port="${SYNCPLAY_PORT:-$SYNCPLAY_DEFAULT_PORT}"
  old_password="${SYNCPLAY_PASSWORD:-}"
  old_salt="${SYNCPLAY_SALT:-$(random_secret)}"
  old_service="${SYNCPLAY_SERVICE_NAME:-$SYNCPLAY_DEFAULT_SERVICE}"
  old_isolate="${SYNCPLAY_ISOLATE_ROOMS:-no}"
  old_bind="${SYNCPLAY_BIND_MODE:-ipv4}"
  old_motd_file="${SYNCPLAY_MOTD_FILE:-}"
  exec_command="${SYNCPLAY_EXEC_COMMAND:-}"

  new_port="$(prompt_default "New Syncplay server port" "$old_port")"
  valid_port "$new_port" || { echo -e "${RED}Invalid port.${NC}"; pause; return; }

  echo
  echo "Password:"
  echo "1) Keep current password"
  echo "2) Generate new password"
  echo "3) Enter new password"
  echo "4) Clear password"
  read -r -p "Select password action [1-4]: " password_choice
  case "${password_choice:-1}" in
    1) new_password="$old_password"; new_salt="$old_salt" ;;
    2) new_password="$(random_secret)"; new_salt="$(random_secret)" ;;
    3) read -r -s -p "New password, optional: " new_password; echo; new_salt="$(random_secret)" ;;
    4) new_password=""; new_salt="$(random_secret)" ;;
    *) echo -e "${RED}Invalid password action.${NC}"; pause; return ;;
  esac

  new_isolate="$old_isolate"
  if prompt_yes_no "Isolate rooms? current=${old_isolate} [y/N]:" "$old_isolate"; then
    new_isolate="yes"
  else
    new_isolate="no"
  fi

  echo
  echo "Bind mode:"
  echo "1) IPv4/default"
  echo "2) IPv6 only"
  read -r -p "Select bind mode [1-2]: " new_bind_choice
  case "${new_bind_choice:-$([[ "$old_bind" == "ipv6" ]] && echo 2 || echo 1)}" in
    1) new_bind="ipv4" ;;
    2) new_bind="ipv6" ;;
    *) echo -e "${RED}Invalid bind mode.${NC}"; pause; return ;;
  esac

  echo
  echo "MOTD:"
  echo "1) Keep current"
  echo "2) Enter new MOTD"
  echo "3) Clear MOTD"
  read -r -p "Select MOTD action [1-3]: " motd_choice
  case "${motd_choice:-1}" in
    1) motd_file="$old_motd_file" ;;
    2) read -r -p "New MOTD text: " motd; motd_file="$(write_motd_file "$motd")" ;;
    3) motd_file="$(write_motd_file "")" ;;
    *) echo -e "${RED}Invalid MOTD action.${NC}"; pause; return ;;
  esac

  ensure_root || { pause; return; }
  if [[ -z "$exec_command" ]]; then
    exec_command="$(syncplay_command_path)" || {
      echo -e "${RED}Cannot find syncplay-server command.${NC}"
      pause
      return
    }
  fi

  write_env_file "$new_port" "$new_password" "$new_salt" "$new_isolate" "$new_bind" "$old_service" "$motd_file" "$exec_command"
  write_systemd_unit "$old_service" "$new_port" "$new_isolate" "$new_bind" "$motd_file" "$exec_command"
  open_ufw_port_if_active "$new_port" || true
  if [[ "$new_port" != "$old_port" ]]; then
    remove_ufw_port_if_requested "$old_port"
  fi
  systemctl daemon-reload
  systemctl restart "$old_service"
  echo
  echo -e "${GREEN}Syncplay Server updated.${NC}"
  echo "Service: ${old_service}.service"
  echo "Port: ${new_port}/tcp"
  if [[ "$password_choice" == "2" || "$password_choice" == "3" ]]; then
    echo "Password: $new_password"
    echo "Password stored at $SYNCPLAY_ENV_FILE"
  else
    echo "Password: hidden"
  fi
  systemctl status "$old_service" --no-pager -l 2>/dev/null || true
  pause
}

firewall_open_port_menu() {
  local default_port port
  default_port="$SYNCPLAY_DEFAULT_PORT"
  load_syncplay_env && default_port="${SYNCPLAY_PORT:-$default_port}"

  title
  echo -e "${CYAN}Private > Syncplay Server > Firewall open port${NC}"
  line
  echo
  port="$(prompt_default "TCP port to open" "$default_port")"
  if ! valid_port "$port"; then
    echo -e "${RED}Invalid port.${NC} Use 1-65535."
    pause
    return
  fi
  ensure_root || { pause; return; }
  open_ufw_port_if_active "$port" || true
  echo
  echo "Listener:"
  listener_for_port "$port"
  pause
}

uninstall_syncplay() {
  local service_name port
  title
  echo -e "${CYAN}Private > Syncplay Server > Uninstall${NC}"
  line
  echo
  load_syncplay_env || true
  service_name="${SYNCPLAY_SERVICE_NAME:-$SYNCPLAY_DEFAULT_SERVICE}"
  port="${SYNCPLAY_PORT:-$SYNCPLAY_DEFAULT_PORT}"

  echo -e "${YELLOW}This will stop and disable ${service_name}.service.${NC}"
  prompt_yes_no "Uninstall Syncplay Server service? [y/N]:" "N" || { echo "Cancelled."; pause; return; }
  ensure_root || { pause; return; }

  systemctl stop "$service_name" >/dev/null 2>&1 || true
  systemctl disable "$service_name" >/dev/null 2>&1 || true
  rm -f "$(service_unit_path "$service_name")"

  if prompt_yes_no "Remove $SYNCPLAY_INSTALL_DIR repository? [y/N]:" "N"; then
    rm -rf "$SYNCPLAY_INSTALL_DIR"
  fi
  if prompt_yes_no "Remove $SYNCPLAY_CONFIG_DIR config directory? [y/N]:" "N"; then
    rm -rf "$SYNCPLAY_CONFIG_DIR"
  fi
  if have_cmd ufw && ufw_is_active && prompt_yes_no "Remove UFW allow rule for ${port}/tcp? [y/N]:" "N"; then
    ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi

  systemctl daemon-reload
  echo -e "${GREEN}Uninstall complete.${NC}"
  echo "No unrelated files were removed."
  pause
}

syncplay_server_menu() {
  local choice

  while true; do
    title
    echo -e "${CYAN}Private > Syncplay Server${NC}"
    echo
    echo "1) Install / Reinstall Syncplay Server"
    echo "2) Status"
    echo "3) Restart"
    echo "4) Stop"
    echo "5) Show logs"
    echo "6) Change port/password"
    echo "7) Firewall open port"
    echo "8) Uninstall Syncplay Server"
    echo "0) Back"
    echo
    line
    read -r -p "Enter your choice [0-8]: " choice

    case "$choice" in
      1) install_or_reinstall_syncplay ;;
      2) show_syncplay_status ;;
      3) restart_syncplay ;;
      4) stop_syncplay ;;
      5) show_syncplay_logs ;;
      6) change_port_password ;;
      7) firewall_open_port_menu ;;
      8) uninstall_syncplay ;;
      0) return 0 ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  syncplay_server_menu
fi
