#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

TUNNEL_DIR="/opt/viptrue-temp-tunnel"
SERVICE_NAME="viptrue-temp-tunnel"

show_plan() {
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  line
  echo

  echo -e "${YELLOW}Purpose:${NC}"
  echo "This tool will temporarily route server installation traffic through a VPN/proxy config."
  echo
  echo "Example use cases:"
  echo "- apt update / apt install"
  echo "- curl / wget downloads"
  echo "- git clone"
  echo "- docker pull"
  echo "- npm / pip / go install"
  echo

  echo -e "${YELLOW}Planned modes:${NC}"
  echo
  echo "1. Proxy Mode"
  echo "   Creates local HTTP/SOCKS proxy."
  echo "   Safer, but only works for apps that use proxy settings."
  echo
  echo "2. TUN Mode"
  echo "   Routes most server traffic through the selected outbound config."
  echo "   Better for installation tasks, but must be started/stopped carefully."
  echo

  echo -e "${YELLOW}Isolation rules:${NC}"
  echo "- Uses separate directory:"
  echo "  $TUNNEL_DIR"
  echo
  echo "- Uses separate service:"
  echo "  ${SERVICE_NAME}.service"
  echo
  echo "- Will NOT modify PasarGuard files:"
  echo "  /opt/pg-node"
  echo "  /var/lib/pg-node"
  echo "  pg-node-service"
  echo
  echo "- Will check PasarGuard ports before using any local/public port."
  echo

  echo -e "${YELLOW}Planned supported inputs:${NC}"
  echo "- Single config links:"
  echo "  vless:// vmess:// trojan:// ss:// hysteria2:// tuic:// wireguard://"
  echo
  echo "- Subscription links:"
  echo "  Normal/base64 subscription links"
  echo

  echo -e "${YELLOW}Current status:${NC}"
  echo "Menu skeleton only. No tunnel/proxy is installed or started yet."
  echo

  pause
}

coming_soon() {
  local item="$1"
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  line
  echo
  echo -e "${YELLOW}${item}${NC}"
  echo
  echo "This feature is not implemented yet."
  echo "We will add it step by step after approval."
  echo
  pause
}

while true; do
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  echo
  echo "1. Show plan"
  echo "2. Install / Update sing-box"
  echo "3. Add single config link"
  echo "4. Add subscription link"
  echo "5. Update subscription"
  echo "6. Select active outbound"
  echo "7. Start Proxy Mode"
  echo "8. Start TUN Mode"
  echo "9. Stop tunnel/proxy"
  echo "10. Show status/logs"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-10]: " choice

  case "$choice" in
    1)
      show_plan
      ;;
    2)
      coming_soon "Install / Update sing-box"
      ;;
    3)
      coming_soon "Add single config link"
      ;;
    4)
      coming_soon "Add subscription link"
      ;;
    5)
      coming_soon "Update subscription"
      ;;
    6)
      coming_soon "Select active outbound"
      ;;
    7)
      coming_soon "Start Proxy Mode"
      ;;
    8)
      coming_soon "Start TUN Mode"
      ;;
    9)
      coming_soon "Stop tunnel/proxy"
      ;;
    10)
      coming_soon "Show status/logs"
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
