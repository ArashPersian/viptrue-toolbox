#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

PG_ENV_FILE="/opt/pg-node/.env"

get_env_value() {
  local key="$1"

  if [[ -f "$PG_ENV_FILE" ]]; then
    awk -F= -v k="$key" '
      $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
        val=$0
        sub(/^[^=]*=/, "", val)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        gsub(/^"/, "", val)
        gsub(/"$/, "", val)
        gsub(/^'\''/, "", val)
        gsub(/'\''$/, "", val)
        print val
      }
    ' "$PG_ENV_FILE" | tail -n 1
  fi
}

ensure_ufw_installed() {
  if command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  echo -e "${YELLOW}UFW is not installed.${NC}"
  read -r -p "Install UFW now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      apt-get update
      apt-get install -y ufw
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      return 1
      ;;
  esac
}

get_ssh_port() {
  local port=""

  port="$(awk '
    /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
      print $2
      exit
    }
  ' /etc/ssh/sshd_config 2>/dev/null || true)"

  if [[ -z "$port" ]]; then
    port="$(ss -tulpn 2>/dev/null | awk '
      /sshd/ && /LISTEN/ {
        split($5,a,":")
        print a[length(a)]
        exit
      }
    ' || true)"
  fi

  echo "${port:-22}"
}

show_status() {
  title
  echo -e "${CYAN}UFW Firewall Status${NC}"
  line
  echo

  if ! command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}UFW is not installed.${NC}"
    echo
  else
    echo -e "${YELLOW}UFW status:${NC}"
    ufw status verbose || true
    echo

    echo -e "${YELLOW}UFW numbered rules:${NC}"
    ufw status numbered || true
    echo
  fi

  echo -e "${YELLOW}Detected SSH port:${NC}"
  get_ssh_port
  echo

  echo -e "${YELLOW}Listening TCP/UDP ports:${NC}"
  ss -tulpn || true
  echo

  echo -e "${YELLOW}PasarGuard .env values:${NC}"
  if [[ -f "$PG_ENV_FILE" ]]; then
    grep -E '^(SERVICE_PORT|API_PORT)[[:space:]]*=' "$PG_ENV_FILE" || true
  else
    echo "$PG_ENV_FILE not found."
  fi
  echo

  pause
}

allow_ssh_port() {
  title
  echo -e "${CYAN}Allow Current SSH Port${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  local ssh_port
  ssh_port="$(get_ssh_port)"

  echo -e "${YELLOW}Detected SSH port:${NC} $ssh_port"
  echo
  echo "This is important before enabling UFW, otherwise you may lock yourself out."
  echo

  read -r -p "Allow TCP port ${ssh_port}? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw allow "${ssh_port}/tcp"
      echo -e "${GREEN}Allowed SSH port ${ssh_port}/tcp.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

allow_pasarguard_ports() {
  title
  echo -e "${CYAN}Allow PasarGuard Node Ports${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  local node_port api_port
  node_port="$(get_env_value "SERVICE_PORT" || true)"
  api_port="$(get_env_value "API_PORT" || true)"

  echo -e "${YELLOW}Detected from:${NC} $PG_ENV_FILE"
  echo
  echo "Node Port / SERVICE_PORT:"
  echo "${node_port:-UNKNOWN}"
  echo
  echo "API Port / API_PORT:"
  echo "${api_port:-UNKNOWN}"
  echo

  if [[ -z "${node_port:-}" && -z "${api_port:-}" ]]; then
    echo -e "${RED}Could not detect SERVICE_PORT or API_PORT.${NC}"
    pause
    return
  fi

  echo -e "${YELLOW}Recommended:${NC}"
  echo "- Node Port usually must be reachable from panel/users depending on your setup."
  echo "- API Port must be reachable by the panel if the panel connects remotely to this node API."
  echo

  read -r -p "Allow detected PasarGuard ports in UFW? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      if [[ -n "${node_port:-}" ]]; then
        ufw allow "${node_port}/tcp"
        ufw allow "${node_port}/udp" || true
        echo -e "${GREEN}Allowed Node Port ${node_port}/tcp and udp.${NC}"
      fi

      if [[ -n "${api_port:-}" ]]; then
        ufw allow "${api_port}/tcp"
        echo -e "${GREEN}Allowed API Port ${api_port}/tcp.${NC}"
      fi
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

allow_custom_tcp_port() {
  title
  echo -e "${CYAN}Allow Custom TCP Port${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  read -r -p "Enter TCP port to allow: " port

  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo -e "${RED}Invalid port.${NC}"
    pause
    return
  fi

  read -r -p "Allow TCP port ${port}? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw allow "${port}/tcp"
      echo -e "${GREEN}Allowed ${port}/tcp.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

disable_ufw() {
  title
  echo -e "${CYAN}Disable UFW${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  echo -e "${YELLOW}Current UFW status:${NC}"
  ufw status verbose || true
  echo

  echo -e "${RED}Warning:${NC} This will disable UFW firewall."
  read -r -p "Disable UFW now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw disable
      echo -e "${GREEN}UFW disabled.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

enable_ufw_safely() {
  title
  echo -e "${CYAN}Enable UFW Safely${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  local ssh_port
  ssh_port="$(get_ssh_port)"

  echo -e "${YELLOW}Before enabling UFW, this module will allow SSH port:${NC} $ssh_port"
  echo

  read -r -p "Continue and enable UFW? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw allow "${ssh_port}/tcp"
      ufw --force enable
      echo -e "${GREEN}UFW enabled safely. SSH port ${ssh_port}/tcp is allowed.${NC}"
      echo
      ufw status verbose || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

while true; do
  title
  echo -e "${CYAN}UFW Firewall${NC}"
  echo
  echo "1. Show UFW status and ports"
  echo "2. Allow current SSH port"
  echo "3. Allow PasarGuard Node ports"
  echo "4. Allow custom TCP port"
  echo "5. Disable UFW"
  echo "6. Enable UFW safely"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-6]: " choice

  case "$choice" in
    1) show_status ;;
    2) allow_ssh_port ;;
    3) allow_pasarguard_ports ;;
    4) allow_custom_tcp_port ;;
    5) disable_ufw ;;
    6) enable_ufw_safely ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
