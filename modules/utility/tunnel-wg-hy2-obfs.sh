#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
ensure_root(){ [[ ${EUID} -eq 0 ]] || { echo -e "${RED}Run as root.${NC}"; pause; return 1; }; }
pub_ip(){ curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }

refuse_443(){
  [[ "${1:-}" != "443" ]] || { echo -e "${RED}Port 443 is forbidden for tunnel tests. Choose another port.${NC}"; pause; return 1; }
}

install_hy2(){
  if ! have_cmd hysteria; then
    bash <(curl -fsSL https://get.hy2.sh/)
  fi
}

check_port(){
  title; echo -e "${CYAN}WG over HY2 obfs > Port Check${NC}"; line
  read -r -p "Ports [2087,51822,51823,51821]: " ports
  ports="${ports:-2087,51822,51823,51821}"
  IFS=',' read -ra arr <<< "$ports"
  for p in "${arr[@]}"; do
    p="${p// /}"; [[ -n "$p" ]] || continue
    echo; echo -e "${YELLOW}Port $p${NC}"
    if [[ "$p" == "443" ]]; then echo -e "${RED}443 skipped.${NC}"; continue; fi
    ss -lunp | grep ":$p " || echo -e "${GREEN}UDP $p is free${NC}"
    ss -lntp | grep ":$p " || echo -e "${GREEN}TCP $p is free${NC}"
  done
  pause
}

write_client_service(){
  cat > /etc/systemd/system/hysteria-client.service <<'EOF_SVC'
[Unit]
Description=Hysteria2 Client Service for VIPTrue WireGuard UDP Forward
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
EOF_SVC
  systemctl daemon-reload
}

setup_server(){
  title; echo -e "${CYAN}KHAREJ/AWS: Hysteria2 obfs salamander server${NC}"; line
  ensure_root || return
  local port pass obfs sni
  read -r -p "HY2 UDP port [2087]: " port; port="${port:-2087}"; refuse_443 "$port" || return
  if ss -lunp | grep -q ":$port "; then echo -e "${RED}UDP $port already in use.${NC}"; ss -lunp | grep ":$port "; pause; return; fi
  read -r -p "Auth password [VIPTrue-HY2-WG-Test-ChangeMe]: " pass; pass="${pass:-VIPTrue-HY2-WG-Test-ChangeMe}"
  read -r -p "Obfs password [VIPTrue-HY2-Obfs-Test-ChangeMe]: " obfs; obfs="${obfs:-VIPTrue-HY2-Obfs-Test-ChangeMe}"
  read -r -p "SNI/CN [bing.com]: " sni; sni="${sni:-bing.com}"
  install_hy2
  mkdir -p /etc/hysteria
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=$sni" >/dev/null 2>&1
  chmod 644 /etc/hysteria/server.crt
  chmod 640 /etc/hysteria/server.key
  chown root:root /etc/hysteria/server.crt /etc/hysteria/server.key
  chown root:hysteria /etc/hysteria/server.key 2>/dev/null || chmod 644 /etc/hysteria/server.key
  cat > /etc/hysteria/config.yaml <<EOF_HY2
listen: :$port

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
  sniGuard: disable

auth:
  type: password
  password: "$pass"

obfs:
  type: salamander
  salamander:
    password: "$obfs"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

disableUDP: false
udpIdleTimeout: 60s
EOF_HY2
  have_cmd ufw && ufw status | grep -qi active && ufw allow "$port/udp" || true
  systemctl daemon-reload
  systemctl enable --now hysteria-server.service
  systemctl restart hysteria-server.service
  systemctl status hysteria-server.service --no-pager -l || true
  ss -lunp | grep ":$port" || echo -e "${RED}UDP $port not listening${NC}"
  pause
}

setup_socks_client(){
  title; echo -e "${CYAN}IRAN: Hysteria2 obfs SOCKS test client${NC}"; line
  ensure_root || return
  local server port pass obfs sni socks
  read -r -p "Server public IP: " server
  read -r -p "Server HY2 UDP port [2087]: " port; port="${port:-2087}"; refuse_443 "$port" || return
  read -r -p "Auth password [VIPTrue-HY2-WG-Test-ChangeMe]: " pass; pass="${pass:-VIPTrue-HY2-WG-Test-ChangeMe}"
  read -r -p "Obfs password [VIPTrue-HY2-Obfs-Test-ChangeMe]: " obfs; obfs="${obfs:-VIPTrue-HY2-Obfs-Test-ChangeMe}"
  read -r -p "SNI [bing.com]: " sni; sni="${sni:-bing.com}"
  read -r -p "SOCKS listen [127.0.0.1:10809]: " socks; socks="${socks:-127.0.0.1:10809}"
  [[ -n "$server" ]] || { echo -e "${RED}Server IP required.${NC}"; pause; return; }
  install_hy2
  systemctl stop hysteria-client.service 2>/dev/null || true; pkill -f "hysteria client" 2>/dev/null || true
  mkdir -p /etc/hysteria
  cat > /etc/hysteria/config.yaml <<EOF_HY2
server: $server:$port

auth: "$pass"

obfs:
  type: salamander
  salamander:
    password: "$obfs"

tls:
  sni: $sni
  insecure: true

socks5:
  listen: $socks
EOF_HY2
  write_client_service
  systemctl enable --now hysteria-client.service
  systemctl restart hysteria-client.service
  sleep 2
  systemctl status hysteria-client.service --no-pager -l || true
  echo; echo -e "${YELLOW}Test:${NC} curl -x socks5h://$socks https://api.ipify.org"
  pause
}

setup_wg_forward(){
  title; echo -e "${CYAN}IRAN: WireGuard UDP forward over Hysteria2 obfs${NC}"; line
  ensure_root || return
  local server port listen remote pass obfs sni
  read -r -p "Server public IP: " server
  read -r -p "Server HY2 UDP port [2087]: " port; port="${port:-2087}"; refuse_443 "$port" || return
  read -r -p "IRAN public UDP listen for users [51822]: " listen; listen="${listen:-51822}"; refuse_443 "$listen" || return
  if ss -lunp | grep -q ":$listen "; then echo -e "${RED}UDP $listen already in use.${NC}"; ss -lunp | grep ":$listen "; pause; return; fi
  read -r -p "Remote WG target on server [127.0.0.1:51821]: " remote; remote="${remote:-127.0.0.1:51821}"
  read -r -p "Auth password [VIPTrue-HY2-WG-Test-ChangeMe]: " pass; pass="${pass:-VIPTrue-HY2-WG-Test-ChangeMe}"
  read -r -p "Obfs password [VIPTrue-HY2-Obfs-Test-ChangeMe]: " obfs; obfs="${obfs:-VIPTrue-HY2-Obfs-Test-ChangeMe}"
  read -r -p "SNI [bing.com]: " sni; sni="${sni:-bing.com}"
  [[ -n "$server" ]] || { echo -e "${RED}Server IP required.${NC}"; pause; return; }
  install_hy2
  systemctl stop hysteria-client.service 2>/dev/null || true; pkill -f "hysteria client" 2>/dev/null || true
  mkdir -p /etc/hysteria
  cat > /etc/hysteria/config.yaml <<EOF_HY2
server: $server:$port

auth: "$pass"

obfs:
  type: salamander
  salamander:
    password: "$obfs"

tls:
  sni: $sni
  insecure: true

udpForwarding:
  - listen: 0.0.0.0:$listen
    remote: $remote
    timeout: 60s
EOF_HY2
  have_cmd ufw && ufw status | grep -qi active && ufw allow "$listen/udp" || true
  write_client_service
  systemctl enable --now hysteria-client.service
  systemctl restart hysteria-client.service
  sleep 2
  systemctl status hysteria-client.service --no-pager -l || true
  ss -lunp | grep ":$listen" || echo -e "${RED}UDP $listen not listening${NC}"
  echo; echo -e "${GREEN}Panel Host:${NC} Address=$(pub_ip) Port=$listen MTU=1280"
  pause
}

move_gre_dnat(){
  title; echo -e "${CYAN}Move old GRE WireGuard DNAT to another public port${NC}"; line
  ensure_root || return
  local old new dst dst_ip dst_port
  read -r -p "Old IRAN public UDP port [51821]: " old; old="${old:-51821}"
  read -r -p "New IRAN public UDP port for GRE [51823]: " new; new="${new:-51823}"; refuse_443 "$new" || return
  read -r -p "GRE destination [102.230.9.2:51821]: " dst; dst="${dst:-102.230.9.2:51821}"
  dst_ip="${dst%:*}"; dst_port="${dst##*:}"
  echo "Plan: IRAN:$new -> $dst_ip:$dst_port ; remove old IRAN:$old if matched"
  read -r -p "Apply? [y/N]: " ok; case "$ok" in y|Y|yes|YES) ;; *) pause; return ;; esac
  iptables -t nat -D PREROUTING -p udp --dport "$old" -j DNAT --to-destination "$dst_ip:$dst_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp --dport "$new" -j DNAT --to-destination "$dst_ip:$dst_port"
  iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
  iptables -I FORWARD 1 -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT
  iptables -I FORWARD 2 -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT
  if have_cmd netfilter-persistent; then netfilter-persistent save; fi
  iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E "$new|$old|$dst_ip" || true
  pause
}

status_all(){
  title; echo -e "${CYAN}HY2/WG Tunnel Status${NC}"; line
  systemctl status hysteria-server.service --no-pager -l 2>/dev/null || true
  echo; systemctl status hysteria-client.service --no-pager -l 2>/dev/null || true
  echo; ss -tulpn | grep -E ':2087|:51822|:51823|:51821|hysteria|wireguard' || true
  echo; have_cmd wg && wg show || echo "wg command not installed."
  pause
}

print_tests(){
  title; echo -e "${CYAN}HY2/WG Test Commands${NC}"; line
  cat <<'EOF_TEST'
AWS/KHAREJ:
  tcpdump -ni any udp port 2087
  tcpdump -ni any udp port 51821
  wg show

IRAN SOCKS test:
  curl -x socks5h://127.0.0.1:10809 https://api.ipify.org

IRAN UDP forward test:
  echo test | nc -u -w1 127.0.0.1 51822

Panel Host HY2/WG:
  Address: IRAN_PUBLIC_IP
  Port: 51822
  MTU: 1280

Panel Host old GRE/WG:
  Address: IRAN_PUBLIC_IP
  Port: 51823
EOF_TEST
  pause
}

while true; do
  title
  echo -e "${CYAN}Tunnel Manager > WireGuard over Hysteria2 obfs/salamander${NC}"
  line
  echo "1. Check port availability"
  echo "2. KHAREJ/AWS: Setup Hysteria2 server obfs salamander"
  echo "3. IRAN: Setup SOCKS test client"
  echo "4. IRAN: Setup WireGuard UDP forward client"
  echo "5. IRAN: Move old GRE WireGuard DNAT to another port"
  echo "6. Show Hysteria/WireGuard tunnel status"
  echo "7. Print test commands"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-7]: " c
  case "$c" in
    1) check_port ;;
    2) setup_server ;;
    3) setup_socks_client ;;
    4) setup_wg_forward ;;
    5) move_gre_dnat ;;
    6) status_all ;;
    7) print_tests ;;
    0) exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}"; pause ;;
  esac
done
