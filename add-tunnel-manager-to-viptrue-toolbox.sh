#!/usr/bin/env bash
set -Eeuo pipefail

# VIPTrue Toolbox - Add Tunnel Manager module
# Run inside the repo root OR on installed path /opt/viptrue-toolbox.

REPO_DIR="${1:-}"
if [[ -z "$REPO_DIR" ]]; then
  if [[ -f ./bootstrap.sh && -d ./menus && -d ./modules ]]; then
    REPO_DIR="$(pwd)"
  elif [[ -d /opt/viptrue-toolbox && -f /opt/viptrue-toolbox/bootstrap.sh ]]; then
    REPO_DIR="/opt/viptrue-toolbox"
  else
    echo "ERROR: Could not detect viptrue-toolbox repo. Run from repo root or pass path:" >&2
    echo "  bash $0 /path/to/viptrue-toolbox" >&2
    exit 1
  fi
fi

cd "$REPO_DIR"
mkdir -p menus modules/utility
TS="$(date +%F-%H%M%S)"
BACKUP_DIR="/root/viptrue-toolbox-patch-backup-$TS"
mkdir -p "$BACKUP_DIR"
cp -a menus/utility.sh "$BACKUP_DIR/utility.sh.bak" 2>/dev/null || true
cp -a modules/utility "$BACKUP_DIR/utility-modules.bak" 2>/dev/null || true

echo "Backup saved to: $BACKUP_DIR"

cat > menus/utility.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

while true; do
  title
  echo -e "${CYAN}Utility Tools${NC}"
  echo
  echo "1. Server Factory-like Reset"
  echo "2. Temporary Tunnel / Proxy for Installations"
  echo "3. Offline Assets / Local Installer"
  echo "4. Tunnel Manager"
  echo "0. Back"
  echo line
  read -r -p "Enter your choice [0-4]: " choice
  case "$choice" in
    1)
      if [[ -f "$BASE_DIR/modules/utility/01-factory-reset.sh" ]]; then
        bash "$BASE_DIR/modules/utility/01-factory-reset.sh"
      else
        echo -e "${YELLOW}Server Factory-like Reset is not configured yet.${NC}"
        pause
      fi
      ;;
    2) bash "$BASE_DIR/modules/utility/02-temp-tunnel.sh" ;;
    3) bash "$BASE_DIR/modules/utility/03-offline-assets.sh" ;;
    4) bash "$BASE_DIR/modules/utility/04-tunnel-manager.sh" ;;
    0) break ;;
    99) viptrue_main_menu ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF

cat > modules/utility/04-tunnel-manager.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

TM_DIR="/opt/viptrue-tunnel-manager"
STATE_DIR="$TM_DIR/state"
BACKUP_DIR="$TM_DIR/backups"
LOG_DIR="$TM_DIR/logs"
mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$LOG_DIR"

DEFAULT_GRE_NAME_IR="greIR"
DEFAULT_GRE_NAME_KH="greKH"
DEFAULT_GRE_CIDR_IR="102.230.9.1/30"
DEFAULT_GRE_CIDR_KH="102.230.9.2/30"
DEFAULT_GRE_PEER_IR="102.230.9.2"
DEFAULT_GRE_PEER_KH="102.230.9.1"
DEFAULT_MTU="1476"

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_pkg_if_missing() {
  local missing=()
  for p in "$@"; do
    if ! have_cmd "$p"; then missing+=("$p"); fi
  done
  if ((${#missing[@]})); then
    echo -e "${YELLOW}Missing tools:${NC} ${missing[*]}"
    read -r -p "Install basic packages now? [y/N]: " ans
    case "$ans" in
      y|Y|yes|YES)
        apt-get update
        apt-get install -y iproute2 iptables iptables-persistent netcat-openbsd tcpdump iperf3 curl dnsutils openssh-client autossh socat stunnel4 || true
        ;;
    esac
  fi
}

print_key_status() {
  echo -e "${YELLOW}OS:${NC}"
  [[ -f /etc/os-release ]] && . /etc/os-release && echo "${PRETTY_NAME:-Unknown}" || echo "Unknown"
  echo
  echo -e "${YELLOW}Public IPv4:${NC}"
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "Unknown"
  echo
  echo -e "${YELLOW}Default route:${NC}"
  ip route | grep '^default' || true
  echo
  echo -e "${YELLOW}GRE modules / tunnels:${NC}"
  lsmod | grep '^ip_gre\|^gre' || true
  ip tunnel show || true
  echo
  echo -e "${YELLOW}Forwarding / rp_filter:${NC}"
  sysctl net.ipv4.ip_forward 2>/dev/null || true
  sysctl net.ipv4.conf.all.rp_filter 2>/dev/null || true
  sysctl net.ipv4.conf.default.rp_filter 2>/dev/null || true
  echo
  echo -e "${YELLOW}Firewall summary:${NC}"
  if have_cmd ufw; then ufw status || true; else echo "UFW not installed."; fi
  echo
  echo -e "${YELLOW}Listening UDP/TCP important ports:${NC}"
  ss -tulpn | grep -E ':22|:80|:443|:8080|:2052|:2053|:2082|:2083|:2095|:51820|:51821|:9940|:9941' || true
}

compatibility_scan() {
  title
  echo -e "${CYAN}Tunnel Manager > Testing / Compatibility Scan${NC}"
  line
  ensure_root || return
  install_pkg_if_missing ip iptables ss tcpdump nc

  print_key_status
  echo
  line
  echo -e "${CYAN}Remote reachability tests${NC}"
  echo "Leave empty to skip each field."
  read -r -p "Remote public IP to test: " remote_ip
  if [[ -n "${remote_ip// /}" ]]; then
    echo
    echo -e "${YELLOW}ICMP ping:${NC} $remote_ip"
    ping -c 3 -W 2 "$remote_ip" || true

    echo
    echo -e "${YELLOW}GRE support note:${NC}"
    echo "GRE uses IP protocol 47. It is not TCP/UDP."
    echo "The best practical test is to create GRE on both sides and ping tunnel IPs."
    echo "If provider firewall blocks protocol 47, GRE will fail even if normal ping works."

    echo
    read -r -p "TCP ports to test on remote, comma-separated [22,80,443]: " tcp_ports
    tcp_ports="${tcp_ports:-22,80,443}"
    IFS=',' read -ra tps <<< "$tcp_ports"
    for p in "${tps[@]}"; do
      p="${p// /}"
      [[ -n "$p" ]] || continue
      timeout 4 bash -c "</dev/tcp/$remote_ip/$p" >/dev/null 2>&1 \
        && echo -e "${GREEN}TCP $p reachable${NC}" \
        || echo -e "${YELLOW}TCP $p not reachable or filtered${NC}"
    done

    echo
    read -r -p "UDP ports to probe with nc, comma-separated [51821,8080,443]: " udp_ports
    udp_ports="${udp_ports:-51821,8080,443}"
    IFS=',' read -ra ups <<< "$udp_ports"
    for p in "${ups[@]}"; do
      p="${p// /}"
      [[ -n "$p" ]] || continue
      echo "viptrue-udp-test" | nc -u -w1 "$remote_ip" "$p" || true
      echo -e "${YELLOW}UDP $p probe sent.${NC} Check tcpdump on remote: tcpdump -ni any udp port $p"
    done
  fi

  echo
  line
  echo -e "${CYAN}Recommendations${NC}"
  echo
  echo "1) GRE Site-to-Site"
  echo "   Best for: simple L3 tunnel, UDP forwarding, WireGuard/Hysteria behind Iran IP."
  echo "   Requirements: public IPv4 both sides, provider allows GRE protocol 47."
  echo "   Test: create GRE both sides, ping 102.230.9.1/102.230.9.2."
  echo
  echo "2) GRE + UDP DNAT Forward"
  echo "   Best for: User -> Iran domain -> GRE -> foreign UDP service."
  echo "   Proven here for WireGuard UDP 51821. Also usable for Hysteria UDP."
  echo "   Requirements: GRE is up, ip_forward=1, NAT rules, FORWARD ACCEPT rules."
  echo
  echo "3) Reverse SSH Tunnel"
  echo "   Best for: TCP-only internal services like PasarGuard pg-node gRPC/API."
  echo "   Requirements: Iran can SSH to panel/foreign; key auth; autossh."
  echo "   Not for high-throughput UDP."
  echo
  echo "4) Raw TCP socat Tunnel"
  echo "   Best for: quick TCP port forwarding test."
  echo "   Requirements: TCP reachable between servers."
  echo
  echo "5) stunnel TLS Tunnel"
  echo "   Best for: wrapping TCP in TLS when raw TCP is blocked or suspicious."
  echo "   Requirements: correct cert/SNI; more complex; not needed for UDP WireGuard."
  echo
  pause
}

gre_status() {
  title
  echo -e "${CYAN}Tunnel Manager > GRE Status${NC}"
  line
  ip tunnel show || true
  echo
  ip addr | grep -A4 -E 'gre|102\.230\.9' || true
  echo
  read -r -p "Ping peer tunnel IP? [default: 102.230.9.2, empty=skip]: " peer
  peer="${peer:-}"
  if [[ -n "$peer" ]]; then ping -c 4 "$peer" || true; fi
  pause
}

create_gre() {
  title
  echo -e "${CYAN}Tunnel Manager > Create / Repair GRE${NC}"
  line
  ensure_root || return
  echo "Choose this server role:"
  echo "1. IRAN side"
  echo "2. KHAREJ / Foreign side"
  read -r -p "Role [1-2]: " role
  local name local_ip remote_ip tunnel_cidr peer_tunnel_ip
  if [[ "$role" == "1" ]]; then
    name="$DEFAULT_GRE_NAME_IR"
    tunnel_cidr="$DEFAULT_GRE_CIDR_IR"
    peer_tunnel_ip="$DEFAULT_GRE_PEER_IR"
  elif [[ "$role" == "2" ]]; then
    name="$DEFAULT_GRE_NAME_KH"
    tunnel_cidr="$DEFAULT_GRE_CIDR_KH"
    peer_tunnel_ip="$DEFAULT_GRE_PEER_KH"
  else
    echo -e "${RED}Invalid role.${NC}"; pause; return
  fi

  local detected_ip
  detected_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  read -r -p "Local public IP [${detected_ip:-manual}]: " local_ip
  local_ip="${local_ip:-$detected_ip}"
  read -r -p "Remote public IP: " remote_ip
  read -r -p "GRE interface name [$name]: " in_name
  name="${in_name:-$name}"
  read -r -p "This side tunnel CIDR [$tunnel_cidr]: " in_cidr
  tunnel_cidr="${in_cidr:-$tunnel_cidr}"
  read -r -p "MTU [$DEFAULT_MTU]: " mtu
  mtu="${mtu:-$DEFAULT_MTU}"

  echo
  echo -e "${YELLOW}Plan:${NC}"
  echo "ip tunnel add $name mode gre remote $remote_ip local $local_ip ttl 255"
  echo "ip addr add $tunnel_cidr dev $name"
  echo "ip link set $name mtu $mtu up"
  echo
  read -r -p "Apply? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac

  ip tunnel del "$name" 2>/dev/null || true
  ip tunnel add "$name" mode gre remote "$remote_ip" local "$local_ip" ttl 255
  ip link set "$name" mtu "$mtu"
  ip addr add "$tunnel_cidr" dev "$name"
  ip link set "$name" up

  cat > "$STATE_DIR/gre-$name.env" <<STATE
name=$name
local_public_ip=$local_ip
remote_public_ip=$remote_ip
tunnel_cidr=$tunnel_cidr
mtu=$mtu
created_at=$(date -Is)
STATE

  echo -e "${GREEN}GRE configured.${NC}"
  echo
  ip addr show "$name"
  echo
  echo "Test peer when both sides are configured:"
  echo "  ping -c 4 $peer_tunnel_ip"
  pause
}

remove_gre() {
  title
  echo -e "${CYAN}Tunnel Manager > Remove GRE${NC}"
  line
  ensure_root || return
  ip tunnel show || true
  read -r -p "GRE interface name to remove [greIR/greKH]: " name
  [[ -n "$name" ]] || { echo "Empty."; pause; return; }
  ip tunnel del "$name" 2>/dev/null || true
  rm -f "$STATE_DIR/gre-$name.env" 2>/dev/null || true
  echo -e "${GREEN}Removed if existed:${NC} $name"
  pause
}

udp_forward_status() {
  title
  echo -e "${CYAN}Tunnel Manager > UDP Forward Status${NC}"
  line
  echo -e "${YELLOW}NAT PREROUTING:${NC}"
  iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E 'DNAT|dpt:|102\.230\.9' || true
  echo
  echo -e "${YELLOW}NAT POSTROUTING:${NC}"
  iptables -t nat -L POSTROUTING -n -v --line-numbers | grep -E 'MASQUERADE|102\.230\.9|dpt:' || true
  echo
  echo -e "${YELLOW}FORWARD:${NC}"
  iptables -L FORWARD -n -v --line-numbers | sed -n '1,80p'
  echo
  echo -e "${YELLOW}ip_forward:${NC}"
  sysctl net.ipv4.ip_forward || true
  pause
}

setup_udp_forward() {
  title
  echo -e "${CYAN}Tunnel Manager > Setup UDP Forward over GRE${NC}"
  line
  ensure_root || return
  echo "Purpose: User -> Iran public UDP port -> GRE peer UDP service."
  echo "Examples: WireGuard 51821, Hysteria 8080/443."
  echo
  read -r -p "Public UDP port on this server [51821]: " public_port
  public_port="${public_port:-51821}"
  read -r -p "GRE destination IP [102.230.9.2]: " dst_ip
  dst_ip="${dst_ip:-102.230.9.2}"
  read -r -p "Destination UDP port [$public_port]: " dst_port
  dst_port="${dst_port:-$public_port}"

  echo
  echo -e "${YELLOW}This will add:${NC}"
  echo "DNAT udp dpt:$public_port -> $dst_ip:$dst_port"
  echo "MASQUERADE udp to $dst_ip dpt:$dst_port"
  echo "FORWARD ACCEPT both directions for udp $dst_port"
  echo
  read -r -p "Apply? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac

  cat > /etc/sysctl.d/99-viptrue-gre-forward.conf <<SYS
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYS
  sysctl --system || true

  iptables -t nat -D PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT 2>/dev/null || true

  iptables -t nat -A PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port"
  iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
  iptables -I FORWARD 1 -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT
  iptables -I FORWARD 2 -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT

  if have_cmd ufw; then ufw allow "$public_port/udp" || true; fi
  if have_cmd netfilter-persistent; then netfilter-persistent save || true; fi

  cat > "$STATE_DIR/udp-forward-$public_port.env" <<STATE
public_port=$public_port
dst_ip=$dst_ip
dst_port=$dst_port
created_at=$(date -Is)
STATE

  echo -e "${GREEN}UDP forward configured.${NC}"
  echo
  echo "Recommended tests:"
  echo "  On Iran:  tcpdump -ni any udp port $public_port"
  echo "  On Iran:  tcpdump -ni greIR udp port $dst_port"
  echo "  On peer:  tcpdump -ni any udp port $dst_port"
  pause
}

remove_udp_forward() {
  title
  echo -e "${CYAN}Tunnel Manager > Remove UDP Forward${NC}"
  line
  ensure_root || return
  read -r -p "Public UDP port to remove [51821]: " public_port
  public_port="${public_port:-51821}"
  read -r -p "GRE destination IP [102.230.9.2]: " dst_ip
  dst_ip="${dst_ip:-102.230.9.2}"
  read -r -p "Destination UDP port [$public_port]: " dst_port
  dst_port="${dst_port:-$public_port}"

  iptables -t nat -D PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT 2>/dev/null || true
  rm -f "$STATE_DIR/udp-forward-$public_port.env" 2>/dev/null || true
  if have_cmd netfilter-persistent; then netfilter-persistent save || true; fi
  echo -e "${GREEN}Removed matching rules if existed.${NC}"
  pause
}

reverse_ssh_status() {
  title
  echo -e "${CYAN}Tunnel Manager > Reverse SSH Status${NC}"
  line
  systemctl status pg-node-reverse-ssh --no-pager 2>/dev/null || echo "pg-node-reverse-ssh.service not found."
  echo
  ss -lntp | grep -E ':2053|:2083|:2095|:9940|:9941' || true
  pause
}

setup_reverse_ssh_pg_node() {
  title
  echo -e "${CYAN}Tunnel Manager > Reverse SSH for PasarGuard pg-node${NC}"
  line
  ensure_root || return
  install_pkg_if_missing autossh ssh
  echo "Run this on the IRAN node server. It opens localhost ports on the PANEL server."
  echo
  read -r -p "Panel server SSH host/IP: " panel_host
  [[ -n "$panel_host" ]] || { echo "Empty panel host."; pause; return; }
  read -r -p "Panel SSH user [root]: " panel_user
  panel_user="${panel_user:-root}"
  read -r -p "Panel SSH port [22]: " panel_ssh_port
  panel_ssh_port="${panel_ssh_port:-22}"
  read -r -p "Local node/gRPC port on this IRAN node [2053]: " local_node_port
  local_node_port="${local_node_port:-2053}"
  read -r -p "Remote localhost node/gRPC port on panel [$local_node_port]: " remote_node_port
  remote_node_port="${remote_node_port:-$local_node_port}"
  read -r -p "Local API port on this IRAN node [2095]: " local_api_port
  local_api_port="${local_api_port:-2095}"
  read -r -p "Remote localhost API port on panel [$local_api_port]: " remote_api_port
  remote_api_port="${remote_api_port:-$local_api_port}"

  local key="/root/.ssh/pg_node_tunnel"
  if [[ ! -f "$key" ]]; then
    ssh-keygen -t ed25519 -f "$key" -N ""
  fi
  echo
  echo -e "${YELLOW}Public key:${NC}"
  cat "$key.pub"
  echo
  echo "If key is not installed on panel server, run:"
  echo "  ssh-copy-id -p $panel_ssh_port -i $key.pub $panel_user@$panel_host"
  echo
  read -r -p "Try ssh-copy-id now? [y/N]: " copy_now
  case "$copy_now" in
    y|Y|yes|YES) ssh-copy-id -p "$panel_ssh_port" -i "$key.pub" "$panel_user@$panel_host" || true ;;
  esac

  cat > /etc/systemd/system/pg-node-reverse-ssh.service <<SERVICE
[Unit]
Description=PG Node Reverse SSH Tunnel to PasarGuard Panel
After=network-online.target
Wants=network-online.target

[Service]
User=root
Environment="AUTOSSH_GATETIME=0"
ExecStart=/usr/bin/autossh -M 0 -N \\
  -i $key \\
  -o ServerAliveInterval=30 \\
  -o ServerAliveCountMax=3 \\
  -o ExitOnForwardFailure=yes \\
  -o StrictHostKeyChecking=no \\
  -R 127.0.0.1:$remote_node_port:127.0.0.1:$local_node_port \\
  -R 127.0.0.1:$remote_api_port:127.0.0.1:$local_api_port \\
  -p $panel_ssh_port $panel_user@$panel_host
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable --now pg-node-reverse-ssh
  systemctl restart pg-node-reverse-ssh
  systemctl status pg-node-reverse-ssh --no-pager || true
  echo
  echo "On panel server, configure node:"
  echo "  Node Address: 127.0.0.1"
  echo "  Node Port: $remote_node_port"
  echo "  API Port: $remote_api_port"
  pause
}

remove_reverse_ssh() {
  title
  echo -e "${CYAN}Tunnel Manager > Remove Reverse SSH${NC}"
  line
  ensure_root || return
  systemctl disable --now pg-node-reverse-ssh 2>/dev/null || true
  rm -f /etc/systemd/system/pg-node-reverse-ssh.service
  systemctl daemon-reload
  systemctl reset-failed || true
  echo -e "${GREEN}Reverse SSH service removed.${NC}"
  pause
}

raw_tcp_socat_info() {
  title
  echo -e "${CYAN}Tunnel Manager > Raw TCP socat helper${NC}"
  line
  echo "This is for TCP only. Do NOT use it for WireGuard/Hysteria UDP."
  echo
  echo "Server side example:"
  echo "  socat -d -d TCP-LISTEN:2052,bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:2053"
  echo
  echo "Client side example:"
  echo "  socat -d -d TCP-LISTEN:2053,bind=127.0.0.1,reuseaddr,fork TCP:REMOTE_IP:2052"
  echo
  echo "For persistent services, prefer the Reverse SSH module for pg-node."
  pause
}

stunnel_info() {
  title
  echo -e "${CYAN}Tunnel Manager > stunnel TLS helper${NC}"
  line
  echo "Advanced TCP-over-TLS helper."
  echo "Use only when raw TCP/Reverse SSH is not suitable."
  echo
  echo "Common issue: wrapping a service that already speaks TLS can break protocol expectations."
  echo "For PasarGuard pg-node, Reverse SSH was more reliable in our tests."
  pause
}

live_tcpdump() {
  title
  echo -e "${CYAN}Tunnel Manager > Live tcpdump${NC}"
  line
  ensure_root || return
  read -r -p "Interface [any]: " iface
  iface="${iface:-any}"
  read -r -p "Filter [udp port 51821]: " filter
  filter="${filter:-udp port 51821}"
  echo "Running: tcpdump -ni $iface $filter"
  echo "Press Ctrl+C to stop."
  tcpdump -ni "$iface" $filter || true
  pause
}

gre_menu() {
  while true; do
    title
    echo -e "${CYAN}Tunnel Manager > GRE Site-to-Site${NC}"
    echo
    echo "1. Create / repair GRE on this server"
    echo "2. GRE status and ping test"
    echo "3. Remove GRE interface"
    echo "0. Back"
    line
    read -r -p "Enter your choice [0-3]: " c
    case "$c" in
      1) create_gre ;;
      2) gre_status ;;
      3) remove_gre ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

udp_forward_menu() {
  while true; do
    title
    echo -e "${CYAN}Tunnel Manager > UDP Forward over GRE${NC}"
    echo
    echo "1. Setup UDP forward: public port -> GRE peer"
    echo "2. Status: NAT / FORWARD rules"
    echo "3. Remove UDP forward"
    echo "4. Live tcpdump"
    echo "0. Back"
    line
    read -r -p "Enter your choice [0-4]: " c
    case "$c" in
      1) setup_udp_forward ;;
      2) udp_forward_status ;;
      3) remove_udp_forward ;;
      4) live_tcpdump ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

reverse_ssh_menu() {
  while true; do
    title
    echo -e "${CYAN}Tunnel Manager > Reverse SSH${NC}"
    echo
    echo "1. Setup PasarGuard pg-node reverse SSH tunnel"
    echo "2. Status"
    echo "3. Remove"
    echo "0. Back"
    line
    read -r -p "Enter your choice [0-3]: " c
    case "$c" in
      1) setup_reverse_ssh_pg_node ;;
      2) reverse_ssh_status ;;
      3) remove_reverse_ssh ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

while true; do
  title
  echo -e "${CYAN}Tunnel Manager${NC}"
  echo
  echo "1. Testing / Compatibility Scan"
  echo "2. GRE Site-to-Site Manager"
  echo "3. UDP Forward over GRE: WireGuard / Hysteria"
  echo "4. Reverse SSH Tunnel: PasarGuard pg-node"
  echo "5. Raw TCP socat helper"
  echo "6. stunnel TLS helper"
  echo "7. Live tcpdump"
  echo "0. Back"
  line
  read -r -p "Enter your choice [0-7]: " choice
  case "$choice" in
    1) compatibility_scan ;;
    2) gre_menu ;;
    3) udp_forward_menu ;;
    4) reverse_ssh_menu ;;
    5) raw_tcp_socat_info ;;
    6) stunnel_info ;;
    7) live_tcpdump ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF

chmod +x menus/utility.sh modules/utility/04-tunnel-manager.sh

echo
printf 'Done. Added Tunnel Manager to: %s\n' "$REPO_DIR"
echo "Files changed:"
echo "  menus/utility.sh"
echo "  modules/utility/04-tunnel-manager.sh"
echo
echo "Test with:"
echo "  bash menus/utility.sh"
