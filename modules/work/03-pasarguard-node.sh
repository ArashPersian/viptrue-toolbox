#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

ENV_FILE="/opt/pg-node/.env"
CERT_FILE="/var/lib/pg-node/certs/ssl_cert.pem"
KEY_FILE="/var/lib/pg-node/certs/ssl_key.pem"

find_node_service() {
  local svc

  for svc in pg-node-service pg-node pasarguard-node pasarguard_node; do
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
      echo "$svc"
      return 0
    fi
  done

  local detected
  detected="$(systemctl list-units --type=service --all 2>/dev/null | awk '{print $1}' | grep -Ei '^pg.*node|pasar.*node' | head -n 1 | sed 's/\.service$//')"

  if [[ -n "${detected:-}" ]]; then
    echo "$detected"
    return 0
  fi

  return 1
}

get_env_value() {
  local key="$1"

  if [[ -f "$ENV_FILE" ]]; then
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
    ' "$ENV_FILE" | tail -n 1
  fi
}

get_public_ip() {
  local ip=""

  ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n' || true)"
  fi

  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  echo "${ip:-UNKNOWN}"
}

get_node_port() {
  local port=""

  port="$(get_env_value "SERVICE_PORT")"
  if [[ -n "$port" ]]; then
    echo "$port"
    return 0
  fi

  echo "UNKNOWN"
}

get_api_port() {
  local port=""

  port="$(get_env_value "API_PORT")"
  if [[ -n "$port" ]]; then
    echo "$port"
    return 0
  fi

  local svc pid
  if svc="$(find_node_service)"; then
    pid="$(systemctl show -p MainPID --value "$svc" 2>/dev/null || true)"
    if [[ -n "$pid" && "$pid" != "0" ]]; then
      port="$(ss -tulpn 2>/dev/null | awk -v pid="$pid" '
        $0 ~ "pid="pid"," && $0 ~ /LISTEN/ {
          split($5,a,":")
          print a[length(a)]
        }' | head -n 1)"
      if [[ -n "$port" ]]; then
        echo "$port"
        return 0
      fi
    fi
  fi

  port="$(journalctl -u pg-node-service -n 200 --no-pager 2>/dev/null | grep -Eo 'port [0-9]+' | awk '{print $2}' | tail -n 1 || true)"
  if [[ -n "$port" ]]; then
    echo "$port"
    return 0
  fi

  echo "UNKNOWN"
}

get_api_key() {
  local value=""

  value="$(get_env_value "API_KEY")"
  if [[ -n "$value" ]]; then
    echo "$value"
    return 0
  fi

  for key in PG_NODE_API_KEY NODE_API_KEY TOKEN NODE_TOKEN; do
    value="$(get_env_value "$key")"
    if [[ -n "$value" ]]; then
      echo "$value"
      return 0
    fi
  done

  echo ""
}

install_node() {
  title
  echo -e "${CYAN}Install / Update PasarGuard Node${NC}"
  line
  echo

  echo -e "${YELLOW}This will run the official PasarGuard Node installer.${NC}"
  echo
  echo "Official installer:"
  echo "https://github.com/PasarGuard/scripts/raw/main/pg-node.sh"
  echo
  echo -e "${RED}Important:${NC} Only continue if this server is ready for PasarGuard Node installation."
  echo

  read -r -p "Continue? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install
          ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

show_status() {
  title
  echo -e "${CYAN}PasarGuard Node Status${NC}"
  line
  echo

  local svc
  if svc="$(find_node_service)"; then
    echo -e "${GREEN}Detected service:${NC} ${svc}.service"
    echo
    systemctl status "$svc" --no-pager || true
  else
    echo -e "${YELLOW}PasarGuard Node service was not detected.${NC}"
    echo
    echo "Existing services related to pasar/pg/node:"
    systemctl list-units --type=service --all 2>/dev/null | grep -Ei 'pasar|pg-|node|xray' || true
  fi

  pause
}

show_logs() {
  title
  echo -e "${CYAN}PasarGuard Node Logs${NC}"
  line
  echo

  local svc
  if svc="$(find_node_service)"; then
    echo -e "${GREEN}Showing last 100 log lines for:${NC} ${svc}.service"
    echo
    journalctl -u "$svc" -n 100 --no-pager || true
  else
    echo -e "${YELLOW}PasarGuard Node service was not detected.${NC}"
    echo
    echo "Existing services related to pasar/pg/node:"
    systemctl list-units --type=service --all 2>/dev/null | grep -Ei 'pasar|pg-|node|xray' || true
  fi

  pause
}

restart_node() {
  title
  echo -e "${CYAN}Restart PasarGuard Node${NC}"
  line
  echo

  local svc
  if svc="$(find_node_service)"; then
    echo -e "${YELLOW}Detected service:${NC} ${svc}.service"
    read -r -p "Restart this service? [y/N]: " confirm

    case "$confirm" in
      y|Y|yes|YES)
        systemctl restart "$svc"
        echo -e "${GREEN}Service restarted.${NC}"
        echo
        systemctl status "$svc" --no-pager || true
        ;;
      *)
        echo -e "${YELLOW}Cancelled.${NC}"
        ;;
    esac
  else
    echo -e "${YELLOW}PasarGuard Node service was not detected.${NC}"
  fi

  pause
}

show_connection_info() {
  title
  echo -e "${CYAN}PasarGuard Node Connection Info${NC}"
  line
  echo

  local svc public_ip node_port api_port api_key

  svc="$(find_node_service || true)"
  public_ip="$(get_public_ip)"
  node_port="$(get_node_port)"
  api_port="$(get_api_port)"
  api_key="$(get_api_key || true)"

  echo -e "${YELLOW}Important:${NC}"
  echo "PasarGuard Node uses two different ports:"
  echo
  echo "1. Node Port = SERVICE_PORT"
  echo "   This is the public node/traffic port used in the panel."
  echo
  echo "2. API Port = API_PORT"
  echo "   This is the HTTPS API port used by pg-node-service."
  echo
  line
  echo

  echo -e "${YELLOW}Use these values in PasarGuard Panel:${NC}"
  echo

  echo "Node Name:"
  hostname
  echo

  echo "Node Address:"
  echo "$public_ip"
  echo

  echo "Node Port:"
  echo "$node_port"
  echo

  echo "API Port:"
  echo "$api_port"
  echo

  echo "Core Configuration:"
  echo "Xray-D-Core"
  echo

  echo "API Key:"
  if [[ -n "${api_key:-}" ]]; then
    echo "$api_key"
  else
    echo "UNKNOWN - API key was not found in $ENV_FILE"
  fi
  echo

  echo -e "${YELLOW}Service:${NC}"
  if [[ -n "${svc:-}" ]]; then
    echo "${svc}.service"
    systemctl is-active "$svc" 2>/dev/null || true
  else
    echo "UNKNOWN"
  fi
  echo

  echo -e "${YELLOW}Local API URL:${NC}"
  echo "https://localhost:${api_port}"
  echo

  echo -e "${YELLOW}Env file:${NC}"
  echo "$ENV_FILE"
  echo

  echo -e "${YELLOW}Detected raw values from .env:${NC}"
  if [[ -f "$ENV_FILE" ]]; then
    grep -E '^(SERVICE_PORT|API_PORT|API_KEY)[[:space:]]*=' "$ENV_FILE" || true
  else
    echo "Env file not found."
  fi
  echo

  echo -e "${YELLOW}Certificate file:${NC}"
  echo "$CERT_FILE"
  echo

  if [[ -f "$CERT_FILE" ]]; then
    echo -e "${YELLOW}Certificate content - copy this into panel:${NC}"
    echo
    cat "$CERT_FILE"
    echo
  else
    echo -e "${RED}Certificate file not found:${NC} $CERT_FILE"
  fi

  echo -e "${YELLOW}Private key file - do NOT paste this in panel unless required:${NC}"
  echo "$KEY_FILE"
  echo

  pause
}

while true; do
  title
  echo -e "${CYAN}PasarGuard Node${NC}"
  echo
  echo "1. Install / Update PasarGuard Node"
  echo "2. Show PasarGuard Node status"
  echo "3. Show PasarGuard Node logs"
  echo "4. Restart PasarGuard Node"
  echo "5. Show Node Connection Info"
  echo "0. Back"
  echo "99. Main Menu"
  echo
  line
  read -r -p "Enter your choice [0-5]: " choice

  case "$choice" in
    99)
      viptrue_main_menu
      ;;
    1) install_node ;;
    2) show_status ;;
    3) show_logs ;;
    4) restart_node ;;
    5) show_connection_info ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
