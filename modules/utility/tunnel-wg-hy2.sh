#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

HY2_AUTH_DEFAULT="VIPTrue-HY2-WG-Test-ChangeMe"
HY2_OBFS_DEFAULT="VIPTrue-HY2-Obfs-Test-ChangeMe"
HY2_SNI_DEFAULT="bing.com"
HY2_PORT_DEFAULT="2087"
IRAN_LISTEN_DEFAULT="51822"
GRE_LISTEN_DEFAULT="51823"
WG_REMOTE_DEFAULT="127.0.0.1:51821"
SOCKS_LISTEN_DEFAULT="127.0.0.1:10809"
CONFIG="/etc/hysteria/config.yaml"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return 1
  fi
}

safe_port() {
  local p="$1"
  if [[ "$p" == "443" ]]; then
    echo -e "${RED}Port 443 is blocked by VIPTrue policy for tunnel tests.${NC}"
    echo "Use another UDP port, example: 2087, 8443, 2053, 1443."
    pause
    return 1
  fi
  return 0
}

ensure_hysteria() {
  if command -v hysteria >/dev/null 2>&1; then
    echo -e "${GREEN}Hysteria installed.${NC}"
    hysteria version 2>/dev/null | sed -n '1,12p' || true
    return 0
  fi
  echo -e "${YELLOW}Installing Hysteria2...${NC}"
  bash <(curl -fsSL https://get.hy2.sh/)
}

ensure_client_service() {
  cat > /etc/systemd/system/hysteria-client.service <<'SERVICEEOF'
[Unit]
Description=Hysteria2 Client Service for VIPTrue Tunnel Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria client --config /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SERVICEEOF
  systemctl daemon-reload
}

show_port_state() {
  local port="$1"
  echo
  echo -e "${CYAN}Checking port ${port}${NC}"
  ss -lunp | grep ":${port}" || echo "UDP ${port} is free"
  ss -lntp | grep ":${port}" || echo "TCP ${port} is free"
  echo
  if command -v ufw >/dev/null 2>&1; then ufw status || true; fi
}

check_ports() {
  title
  echo -e "${CYAN}WireGuard over Hysteria2 > Port Check${NC}"
  line
  echo
  read -r -p "UDP port to check [${HY2_PORT_DEFAULT}]: " p
  p="${p:-$HY2_PORT_DEFAULT}"
  safe_port "$p" || return
  show_port_state "$p"
  pause
}

setup_server() {
  need_root || return
  title
  echo -e "${CYAN}KHAREJ/AWS: Setup Hysteria2 Server obfs salamander${NC}"
  line
  echo "Tested successful mode: obfs salamander + UDP 2087. Port 443 is blocked by policy."
  echo

  read -r -p "Hysteria UDP listen port [${HY2_PORT_DEFAULT}]: " hy2_port
  hy2_port="${hy2_port:-$HY2_PORT_DEFAULT}"
  safe_port "$hy2_port" || return
  read -r -p "Auth password [default test password]: " hy2_auth
  hy2_auth="${hy2_auth:-$HY2_AUTH_DEFAULT}"
  read -r -p "Obfs salamander password [default test password]: " hy2_obfs
  hy2_obfs="${hy2_obfs:-$HY2_OBFS_DEFAULT}"
  read -r -p "TLS SNI / cert CN [${HY2_SNI_DEFAULT}]: " hy2_sni
  hy2_sni="${hy2_sni:-$HY2_SNI_DEFAULT}"

  show_port_state "$hy2_port"
  if ss -lunp | grep -q ":${hy2_port}"; then
    echo -e "${RED}ERROR: UDP ${hy2_port} is already in use.${NC}"
    pause
    return
  fi

  ensure_hysteria
  systemctl disable --now hysteria-client.service 2>/dev/null || true
  systemctl disable --now hysteria-server.service 2>/dev/null || true
  pkill -f hysteria 2>/dev/null || true
  mkdir -p /etc/hysteria

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -days 3650 \
    -subj "/CN=${hy2_sni}" >/dev/null 2>&1

  chmod 644 /etc/hysteria/server.crt
  chmod 640 /etc/hysteria/server.key
  chown root:hysteria /etc/hysteria/server.key 2>/dev/null || true

  cat > "$CONFIG" <<EOF
listen: :${hy2_port}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
  sniGuard: disable

auth:
  type: password
  password: "${hy2_auth}"

obfs:
  type: salamander
  salamander:
    password: "${hy2_obfs}"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

disableUDP: false
udpIdleTimeout: 60s
EOF

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then ufw allow "${hy2_port}/udp"; fi
  systemctl daemon-reload
  systemctl enable --now hysteria-server.service
  echo
  systemctl status hysteria-server.service --no-pager -l || true
  echo
  ss -lunp | grep ":${hy2_port}" || echo "WARNING: UDP ${hy2_port} not listening"
  echo
  echo -e "${GREEN}Server setup done.${NC}"
  echo "Provider firewall/security group must allow UDP ${hy2_port}."
  echo "tcpdump: tcpdump -ni any -vvv 'udp port ${hy2_port}'"
  pause
}

setup_client_socks() {
  need_root || return
  title
  echo -e "${CYAN}IRAN: Setup SOCKS Test Client${NC}"
  line
  echo "Use this before WireGuard forwarding to confirm Hysteria2 path works."
  echo
  read -r -p "KHAREJ/AWS public IP: " server_ip
  [[ -z "${server_ip// /}" ]] && { echo "Server IP is required."; pause; return; }
  read -r -p "Hysteria UDP port [${HY2_PORT_DEFAULT}]: " hy2_port
  hy2_port="${hy2_port:-$HY2_PORT_DEFAULT}"
  safe_port "$hy2_port" || return
  read -r -p "Auth password [default test password]: " hy2_auth
  hy2_auth="${hy2_auth:-$HY2_AUTH_DEFAULT}"
  read -r -p "Obfs salamander password [default test password]: " hy2_obfs
  hy2_obfs="${hy2_obfs:-$HY2_OBFS_DEFAULT}"
  read -r -p "TLS SNI [${HY2_SNI_DEFAULT}]: " hy2_sni
  hy2_sni="${hy2_sni:-$HY2_SNI_DEFAULT}"
  read -r -p "Local SOCKS listen [${SOCKS_LISTEN_DEFAULT}]: " socks_listen
  socks_listen="${socks_listen:-$SOCKS_LISTEN_DEFAULT}"

  ensure_hysteria
  ensure_client_service
  systemctl stop hysteria-client.service 2>/dev/null || true
  systemctl stop hysteria-server.service 2>/dev/null || true
  pkill -f hysteria 2>/dev/null || true
  mkdir -p /etc/hysteria

  cat > "$CONFIG" <<EOF
server: ${server_ip}:${hy2_port}

auth: "${hy2_auth}"

obfs:
  type: salamander
  salamander:
    password: "${hy2_obfs}"

tls:
  sni: ${hy2_sni}
  insecure: true

socks5:
  listen: ${socks_listen}
EOF
  systemctl enable --now hysteria-client.service
  sleep 2
  systemctl status hysteria-client.service --no-pager -l || true
  echo
  ss -lntup | grep -E "$(echo "$socks_listen" | awk -F: '{print $NF}')|hysteria" || echo "No local Hysteria listener found"
  echo
  echo "Test command: curl -x socks5h://${socks_listen} https://api.ipify.org"
  pause
}

setup_client_udp_forward() {
  need_root || return
  title
  echo -e "${CYAN}IRAN: Setup WireGuard UDP Forward over Hysteria2${NC}"
  line
  echo "Flow: IRAN:51822/udp -> HY2 obfs :2087 -> KHAREJ/AWS:127.0.0.1:51821"
  echo
  read -r -p "KHAREJ/AWS public IP: " server_ip
  [[ -z "${server_ip// /}" ]] && { echo "Server IP is required."; pause; return; }
  read -r -p "Hysteria UDP port [${HY2_PORT_DEFAULT}]: " hy2_port
  hy2_port="${hy2_port:-$HY2_PORT_DEFAULT}"
  safe_port "$hy2_port" || return
  read -r -p "IRAN UDP listen port for users [${IRAN_LISTEN_DEFAULT}]: " listen_port
  listen_port="${listen_port:-$IRAN_LISTEN_DEFAULT}"
  safe_port "$listen_port" || return
  read -r -p "Remote WireGuard target on KHAREJ/AWS [${WG_REMOTE_DEFAULT}]: " wg_remote
  wg_remote="${wg_remote:-$WG_REMOTE_DEFAULT}"
  read -r -p "Auth password [default test password]: " hy2_auth
  hy2_auth="${hy2_auth:-$HY2_AUTH_DEFAULT}"
  read -r -p "Obfs salamander password [default test password]: " hy2_obfs
  hy2_obfs="${hy2_obfs:-$HY2_OBFS_DEFAULT}"
  read -r -p "TLS SNI [${HY2_SNI_DEFAULT}]: " hy2_sni
  hy2_sni="${hy2_sni:-$HY2_SNI_DEFAULT}"

  show_port_state "$listen_port"
  if ss -lunp | grep -q ":${listen_port}"; then
    echo -e "${RED}ERROR: UDP ${listen_port} is already in use.${NC}"
    pause
    return
  fi

  ensure_hysteria
  ensure_client_service
  systemctl stop hysteria-client.service 2>/dev/null || true
  systemctl stop hysteria-server.service 2>/dev/null || true
  pkill -f hysteria 2>/dev/null || true
  mkdir -p /etc/hysteria

  cat > "$CONFIG" <<EOF
server: ${server_ip}:${hy2_port}

auth: "${hy2_auth}"

obfs:
  type: salamander
  salamander:
    password: "${hy2_obfs}"

tls:
  sni: ${hy2_sni}
  insecure: true

udpForwarding:
  - listen: 0.0.0.0:${listen_port}
    remote: ${wg_remote}
    timeout: 60s
EOF

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then ufw allow "${listen_port}/udp"; fi
  systemctl enable --now hysteria-client.service
  sleep 2
  systemctl status hysteria-client.service --no-pager -l || true
  echo
  ss -lunp | grep ":${listen_port}" || echo "WARNING: UDP ${listen_port} not listening"
  echo
  echo -e "${GREEN}Forward setup done.${NC}"
  echo "Panel Host: Address=IRAN_PUBLIC_IP Port=${listen_port} MTU=1280"
  echo "AWS tcpdump: tcpdump -ni any udp port $(echo "$wg_remote" | awk -F: '{print $NF}')"
  echo "IRAN test: echo test | nc -u -w1 127.0.0.1 ${listen_port}"
  pause
}

move_gre_wg_port() {
  need_root || return
  title
  echo -e "${CYAN}IRAN: Move GRE WireGuard DNAT Port${NC}"
  line
  echo "Example tested layout: GRE inbound 51823 -> GRE peer 102.230.9.2:51821"
  echo
  read -r -p "Old IRAN inbound UDP port to remove [51821]: " old_port
  old_port="${old_port:-51821}"
  read -r -p "New IRAN inbound UDP port for GRE [${GRE_LISTEN_DEFAULT}]: " new_port
  new_port="${new_port:-$GRE_LISTEN_DEFAULT}"
  safe_port "$new_port" || return
  read -r -p "GRE peer tunnel IP [102.230.9.2]: " gre_peer
  gre_peer="${gre_peer:-102.230.9.2}"
  read -r -p "Remote WireGuard UDP port on GRE peer [51821]: " wg_port
  wg_port="${wg_port:-51821}"

  iptables -t nat -D PREROUTING -p udp --dport "$old_port" -j DNAT --to-destination "${gre_peer}:${wg_port}" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p udp -d "$gre_peer" --dport "$wg_port" -j MASQUERADE 2>/dev/null || true
  iptables -t nat -C PREROUTING -p udp --dport "$new_port" -j DNAT --to-destination "${gre_peer}:${wg_port}" 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport "$new_port" -j DNAT --to-destination "${gre_peer}:${wg_port}"
  iptables -t nat -C POSTROUTING -p udp -d "$gre_peer" --dport "$wg_port" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -p udp -d "$gre_peer" --dport "$wg_port" -j MASQUERADE
  iptables -C FORWARD -p udp -d "$gre_peer" --dport "$wg_port" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -p udp -d "$gre_peer" --dport "$wg_port" -j ACCEPT
  iptables -C FORWARD -p udp -s "$gre_peer" --sport "$wg_port" -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -p udp -s "$gre_peer" --sport "$wg_port" -j ACCEPT

  if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save || true; else echo -e "${YELLOW}netfilter-persistent not found. Rules may not persist after reboot.${NC}"; fi
  iptables -t nat -L PREROUTING -n -v --line-numbers | sed -n '1,80p'
  echo
  iptables -L FORWARD -n -v --line-numbers | sed -n '1,100p'
  echo -e "${GREEN}GRE DNAT moved. Panel GRE Host: IRAN_PUBLIC_IP:${new_port}${NC}"
  pause
}

show_status() {
  title
  echo -e "${CYAN}WireGuard over Hysteria2 > Status${NC}"
  line
  echo -e "${YELLOW}Services:${NC}"
  systemctl status hysteria-server.service --no-pager -l 2>/dev/null | sed -n '1,18p' || true
  echo
  systemctl status hysteria-client.service --no-pager -l 2>/dev/null | sed -n '1,18p' || true
  echo
  echo -e "${YELLOW}Listening ports:${NC}"
  ss -lntup | grep -E 'hysteria|:2087|:51822|:51823|:51821|:10809' || true
  echo
  echo -e "${YELLOW}Current config:${NC}"
  [[ -f /etc/hysteria/config.yaml ]] && cat /etc/hysteria/config.yaml || echo "No config found."
  pause
}

print_test_commands() {
  title
  echo -e "${CYAN}WireGuard over Hysteria2 > Test Commands${NC}"
  line
  cat <<'EOF'
AWS/KHAREJ checks:
  ss -lunp | grep ':2087'
  tcpdump -ni any -vvv 'udp port 2087'
  tcpdump -ni any udp port 51821
  wg show

IRAN SOCKS test:
  curl -x socks5h://127.0.0.1:10809 https://api.ipify.org

IRAN UDP forward test:
  echo test | nc -u -w1 127.0.0.1 51822

Panel host recommendations:
  HY2/WG host: IRAN_PUBLIC_IP:51822  MTU 1280
  GRE/WG host: IRAN_PUBLIC_IP:51823  MTU 1280-1360

Important:
  Do not use port 443 for Tunnel Manager auto tests.
  Always check ss -lunp before choosing any port.
EOF
  pause
}

while true; do
  title
  echo -e "${CYAN}WireGuard over Hysteria2 obfs${NC}"
  line
  echo "1. Check port availability"
  echo "2. KHAREJ/AWS: Setup Hysteria2 server obfs salamander"
  echo "3. IRAN: Setup SOCKS test client"
  echo "4. IRAN: Setup WireGuard UDP forward client"
  echo "5. IRAN: Move GRE WireGuard DNAT to another port"
  echo "6. Show Hysteria/WG tunnel status"
  echo "7. Print test commands"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-7]: " choice
  case "$choice" in
    1) check_ports ;;
    2) setup_server ;;
    3) setup_client_socks ;;
    4) setup_client_udp_forward ;;
    5) move_gre_wg_port ;;
    6) show_status ;;
    7) print_test_commands ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
