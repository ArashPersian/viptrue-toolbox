#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

find_node_service() {
  local svc
  for svc in pg-node pasarguard-node pasarguard_node node; do
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
      echo "$svc"
      return 0
    fi
  done
  return 1
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
    echo "This can mean the node is not installed yet, or the service name is different."
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

while true; do
  title
  echo -e "${CYAN}PasarGuard Node${NC}"
  echo
  echo "1. Install / Update PasarGuard Node"
  echo "2. Show PasarGuard Node status"
  echo "3. Show PasarGuard Node logs"
  echo "4. Restart PasarGuard Node"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-4]: " choice

  case "$choice" in
    1) install_node ;;
    2) show_status ;;
    3) show_logs ;;
    4) restart_node ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
