#!/usr/bin/env bash
set -Eeuo pipefail

# Step 20-C — Add Tunnel Quality Tests + Persistent GRE
# Adds iperf3 TCP/UDP/jitter/loss testing, report export, and systemd persistent GRE.

REPO_DIR="${1:-}"
if [[ -z "$REPO_DIR" ]]; then
  if [[ -f ./bootstrap.sh && -d ./menus && -d ./modules ]]; then
    REPO_DIR="$(pwd)"
  elif [[ -d /opt/viptrue-toolbox && -f /opt/viptrue-toolbox/bootstrap.sh ]]; then
    REPO_DIR="/opt/viptrue-toolbox"
  elif [[ -d "$HOME/viptrue-toolbox" && -f "$HOME/viptrue-toolbox/bootstrap.sh" ]]; then
    REPO_DIR="$HOME/viptrue-toolbox"
  else
    echo "ERROR: Could not detect viptrue-toolbox repo. Run from repo root or pass path:" >&2
    echo "  bash $0 /opt/viptrue-toolbox" >&2
    exit 1
  fi
fi

cd "$REPO_DIR"
mkdir -p modules/utility menus
TS="$(date +%F-%H%M%S)"
BACKUP_DIR="/root/viptrue-toolbox-step20c-backup-$TS"
mkdir -p "$BACKUP_DIR"
cp -a VERSION "$BACKUP_DIR/VERSION.bak" 2>/dev/null || true
cp -a menus/utility.sh "$BACKUP_DIR/utility.sh.bak" 2>/dev/null || true
cp -a modules/utility/04-tunnel-manager.sh "$BACKUP_DIR/04-tunnel-manager.sh.bak" 2>/dev/null || true

echo "0.1.5" > VERSION

echo "Backup saved to: $BACKUP_DIR"

# Ensure Utility menu contains Tunnel Manager.
python3 - <<'PY'
from pathlib import Path
import re
p = Path('menus/utility.sh')
if not p.exists():
    raise SystemExit('menus/utility.sh not found')
text = p.read_text()
text = text.replace('echo line', 'line')
# normalize old names
text = text.replace('Tunnel Tools', 'Tunnel Manager')
if 'Tunnel Manager' not in text:
    if 'Offline Assets / Local Installer' in text:
        text = re.sub(r'(echo "3\. Offline Assets / Local Installer".*)', r'\1\n  echo "4. Tunnel Manager"', text, count=1)
    else:
        text = re.sub(r'(echo "2\. Temporary Tunnel / Proxy for Installations".*)', r'\1\n  echo "4. Tunnel Manager"', text, count=1)
if 'Enter your choice [0-3]' in text:
    text = text.replace('Enter your choice [0-3]', 'Enter your choice [0-4]')
if not re.search(r'\n\s*4\)', text):
    text = re.sub(r'(\n\s*0\)\s*\n\s*break\s*\n\s*;;)', r'\n    4)\n      bash "$BASE_DIR/modules/utility/04-tunnel-manager.sh"\n      ;;\1', text, count=1)
# If handler still points to old 04-tunnel-tools.sh, fix it.
text = text.replace('modules/utility/04-tunnel-tools.sh', 'modules/utility/04-tunnel-manager.sh')
p.write_text(text)
PY

cat > modules/utility/04-tunnel-manager.sh <<'EOF_TM'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

TM_DIR="/opt/viptrue-tunnel-manager"
STATE_DIR="$TM_DIR/state"
LOG_DIR="$TM_DIR/logs"
mkdir -p "$STATE_DIR" "$LOG_DIR"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return 1
  fi
}

pub_ip() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || echo "unknown"
}

safe_install_tools() {
  local needed=()
  for c in ip iptables ss tcpdump nc curl iperf3 mtr; do
    have_cmd "$c" || needed+=("$c")
  done
  if ((${#needed[@]})); then
    echo -e "${YELLOW}Missing tools:${NC} ${needed[*]}"
    read -r -p "Install required packages now? [y/N]: " ans
    case "$ans" in
      y|Y|yes|YES)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
          iproute2 iptables iptables-persistent netcat-openbsd tcpdump curl dnsutils \
          autossh socat stunnel4 iperf3 mtr-tiny || true
        ;;
    esac
  fi
}

save_firewall() {
  if have_cmd netfilter-persistent; then
    netfilter-persistent save || true
  elif have_cmd iptables-save; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 || true
  fi
}

sysctl_forwarding_on() {
  cat > /etc/sysctl.d/99-viptrue-gre-forward.conf <<'SYS'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYS
  sysctl --system >/dev/null || true
}

get_gre_ifaces() {
  ip -o link show type gre 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' | sed 's/@.*//' || true
}

service_name_for_gre() {
  local ifname="$1"
  echo "viptrue-gre-${ifname}.service"
}

write_persistent_gre_service() {
  local ifname="$1" local_pub="$2" remote_pub="$3" cidr="$4" mtu="$5"
  local svc
  svc="$(service_name_for_gre "$ifname")"

  cat > "/etc/systemd/system/$svc" <<EOF_SVC
[Unit]
Description=VIPTrue persistent GRE tunnel $ifname
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/ip tunnel del $ifname
ExecStartPre=-/usr/sbin/modprobe ip_gre
ExecStart=/usr/sbin/ip tunnel add $ifname mode gre remote $remote_pub local $local_pub ttl 255
ExecStart=/usr/sbin/ip link set $ifname mtu $mtu
ExecStart=/usr/sbin/ip addr add $cidr dev $ifname
ExecStart=/usr/sbin/ip link set $ifname up
ExecStop=-/usr/sbin/ip tunnel del $ifname

[Install]
WantedBy=multi-user.target
EOF_SVC

  systemctl daemon-reload
  systemctl enable --now "$svc"

  echo -e "${GREEN}Persistent GRE service enabled:${NC} $svc"
  echo "Service file: /etc/systemd/system/$svc"
}

remove_persistent_gre_service() {
  local ifname="$1"
  local svc
  svc="$(service_name_for_gre "$ifname")"
  systemctl disable --now "$svc" 2>/dev/null || true
  rm -f "/etc/systemd/system/$svc"
  systemctl daemon-reload
}

print_scan() {
  echo -e "${YELLOW}OS:${NC}"
  if [[ -f /etc/os-release ]]; then . /etc/os-release; echo "${PRETTY_NAME:-Unknown}"; else echo "Unknown"; fi
  echo
  echo -e "${YELLOW}Public IPv4:${NC}"
  pub_ip
  echo
  echo -e "${YELLOW}Default route:${NC}"
  ip route | grep '^default' || true
  echo
  echo -e "${YELLOW}GRE modules / tunnels:${NC}"
  lsmod | grep -E '^ip_gre|^gre' || true
  ip tunnel show || true
  echo
  echo -e "${YELLOW}Forwarding / rp_filter:${NC}"
  sysctl net.ipv4.ip_forward 2>/dev/null || true
  sysctl net.ipv4.conf.all.rp_filter 2>/dev/null || true
  sysctl net.ipv4.conf.default.rp_filter 2>/dev/null || true
  echo
  echo -e "${YELLOW}Firewall:${NC}"
  if have_cmd ufw; then ufw status || true; else echo "UFW not installed"; fi
  echo
  echo -e "${YELLOW}Important listeners:${NC}"
  ss -tulpn | grep -E ':22|:80|:443|:8080|:2052|:2053|:2082|:2083|:2095|:51820|:51821|:9940|:9941' || true
  echo
  echo -e "${YELLOW}Persistent GRE services:${NC}"
  systemctl list-unit-files 'viptrue-gre-*.service' 2>/dev/null || true
}

recommendations() {
  echo
  line
  echo -e "${CYAN}Recommended tunnel choices${NC}"
  echo
  echo "1) GRE Site-to-Site"
  echo "   Use when both servers have public IPv4 and provider allows GRE protocol 47."
  echo "   Best for WireGuard/Hysteria behind Iran IP via UDP DNAT."
  echo
  echo "2) GRE + UDP Forward"
  echo "   Use when UDP payload passes through GRE. Ping may fail while UDP still works."
  echo "   Proven presets: WireGuard UDP 51821, Hysteria UDP 8080/443."
  echo
  echo "3) Reverse SSH"
  echo "   Use for TCP-only internal services like PasarGuard pg-node gRPC/API."
  echo "   Not suitable for high-throughput UDP."
  echo
  echo "4) Raw TCP / stunnel"
  echo "   Use when only TCP can pass. stunnel wraps TCP in TLS."
  echo
}

compatibility_scan() {
  title
  echo -e "${CYAN}Tunnel Manager > Testing / Compatibility Scan${NC}"
  line
  ensure_root || return
  safe_install_tools
  print_scan
  echo
  read -r -p "Remote public IP to test, empty=skip: " remote_ip
  if [[ -n "${remote_ip// /}" ]]; then
    echo
    echo -e "${YELLOW}ICMP public path test:${NC} $remote_ip"
    ping -c 3 -W 2 "$remote_ip" || true
    echo
    read -r -p "Remote GRE tunnel IP to ping, empty=skip: " remote_tun
    if [[ -n "${remote_tun// /}" ]]; then
      ping -c 4 -W 2 "$remote_tun" || true
    fi
    echo
    read -r -p "TCP ports to test [22,80,443]: " tcp_ports
    tcp_ports="${tcp_ports:-22,80,443}"
    IFS=',' read -ra tps <<< "$tcp_ports"
    for p in "${tps[@]}"; do
      p="${p// /}"
      [[ -n "$p" ]] || continue
      timeout 3 bash -c "</dev/tcp/$remote_ip/$p" >/dev/null 2>&1 && echo -e "${GREEN}TCP $p reachable${NC}" || echo -e "${YELLOW}TCP $p closed/filtered${NC}"
    done
    echo
    read -r -p "UDP ports to probe with nc [51821,8080,443]: " udp_ports
    udp_ports="${udp_ports:-51821,8080,443}"
    IFS=',' read -ra ups <<< "$udp_ports"
    for p in "${ups[@]}"; do
      p="${p// /}"
      [[ -n "$p" ]] || continue
      echo "viptrue-udp-test" | nc -u -w1 "$remote_ip" "$p" || true
      echo -e "${YELLOW}UDP $p probe sent. Verify on remote with:${NC} tcpdump -ni any udp port $p"
    done
  fi
  recommendations
  pause
}

gre_status() {
  title
  echo -e "${CYAN}Tunnel Manager > GRE Status${NC}"
  line
  echo -e "${YELLOW}GRE tunnels:${NC}"
  ip tunnel show || true
  echo
  echo -e "${YELLOW}Tunnel addresses:${NC}"
  ip addr | grep -A4 -E 'gre|102\.230\.9|10\.99\.' || true
  echo
  echo -e "${YELLOW}Routes:${NC}"
  ip route | grep -E '102\.230\.9|gre' || true
  echo
  echo -e "${YELLOW}Persistent services:${NC}"
  systemctl list-units 'viptrue-gre-*.service' --all 2>/dev/null || true
  echo
  read -r -p "Ping peer tunnel IP, empty=skip: " peer
  [[ -n "$peer" ]] && ping -c 4 -W 2 "$peer" || true
  pause
}

create_gre() {
  title
  echo -e "${CYAN}Tunnel Manager > Create / Repair GRE${NC}"
  line
  ensure_root || return
  echo "Role:"
  echo "1. IRAN side:    102.230.9.1/30 -> peer 102.230.9.2"
  echo "2. KHAREJ side:  102.230.9.2/30 -> peer 102.230.9.1"
  read -r -p "Select role [1-2]: " role
  local ifname cidr peer default_if
  case "$role" in
    1) default_if="greIR"; cidr="102.230.9.1/30"; peer="102.230.9.2" ;;
    2) default_if="greKH"; cidr="102.230.9.2/30"; peer="102.230.9.1" ;;
    *) echo -e "${RED}Invalid role.${NC}"; pause; return ;;
  esac
  local detected local_pub remote_pub mtu in_cidr persistent
  detected="$(pub_ip)"
  read -r -p "Local public IP [$detected]: " local_pub; local_pub="${local_pub:-$detected}"
  read -r -p "Remote public IP: " remote_pub
  read -r -p "Interface name [$default_if]: " ifname; ifname="${ifname:-$default_if}"
  read -r -p "This side tunnel CIDR [$cidr]: " in_cidr; cidr="${in_cidr:-$cidr}"
  read -r -p "MTU [1476]: " mtu; mtu="${mtu:-1476}"
  [[ -n "$local_pub" && -n "$remote_pub" ]] || { echo -e "${RED}Local/remote IP required.${NC}"; pause; return; }
  echo
  echo -e "${YELLOW}Plan:${NC} $ifname remote=$remote_pub local=$local_pub cidr=$cidr mtu=$mtu"
  echo "Runtime GRE will be created now. Persistent systemd service can also be created."
  read -r -p "Apply? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac

  ip tunnel del "$ifname" 2>/dev/null || true
  modprobe ip_gre 2>/dev/null || true
  ip tunnel add "$ifname" mode gre remote "$remote_pub" local "$local_pub" ttl 255
  ip link set "$ifname" mtu "$mtu"
  ip addr add "$cidr" dev "$ifname"
  ip link set "$ifname" up

  cat > "$STATE_DIR/gre-$ifname.env" <<STATE
ifname=$ifname
local_public_ip=$local_pub
remote_public_ip=$remote_pub
tunnel_cidr=$cidr
mtu=$mtu
created_at=$(date -Is)
STATE

  echo -e "${GREEN}GRE configured.${NC}"
  ip addr show "$ifname"
  echo
  read -r -p "Make this GRE persistent after reboot with systemd? [Y/n]: " persistent
  persistent="${persistent:-Y}"
  case "$persistent" in
    y|Y|yes|YES)
      write_persistent_gre_service "$ifname" "$local_pub" "$remote_pub" "$cidr" "$mtu"
      ;;
    *)
      echo -e "${YELLOW}Persistent service skipped. GRE will disappear after reboot.${NC}"
      ;;
  esac
  echo
  echo "When both sides are ready: ping -c 4 $peer"
  echo "Note: ping may fail while UDP/WireGuard over GRE still works. Use Quality Tests."
  pause
}

remove_gre() {
  title
  echo -e "${CYAN}Tunnel Manager > Remove GRE${NC}"
  line
  ensure_root || return
  echo "Existing GRE interfaces:"
  get_gre_ifaces || true
  echo
  echo "Persistent GRE services:"
  systemctl list-unit-files 'viptrue-gre-*.service' 2>/dev/null || true
  echo
  read -r -p "Interface to remove [greIR/greKH]: " ifname
  [[ -n "$ifname" ]] || { echo "Empty."; pause; return; }
  ip tunnel del "$ifname" 2>/dev/null || true
  remove_persistent_gre_service "$ifname"
  rm -f "$STATE_DIR/gre-$ifname.env" 2>/dev/null || true
  echo -e "${GREEN}Removed runtime and persistent GRE if existed:${NC} $ifname"
  pause
}

udp_forward_status() {
  title
  echo -e "${CYAN}Tunnel Manager > UDP Forward Status${NC}"
  line
  echo -e "${YELLOW}NAT PREROUTING:${NC}"
  iptables -t nat -L PREROUTING -n -v --line-numbers | sed -n '1,160p'
  echo
  echo -e "${YELLOW}NAT POSTROUTING:${NC}"
  iptables -t nat -L POSTROUTING -n -v --line-numbers | sed -n '1,160p'
  echo
  echo -e "${YELLOW}FORWARD:${NC}"
  iptables -L FORWARD -n -v --line-numbers | sed -n '1,160p'
  echo
  sysctl net.ipv4.ip_forward 2>/dev/null || true
  pause
}

setup_udp_forward() {
  title
  echo -e "${CYAN}Tunnel Manager > Setup UDP Forward over GRE${NC}"
  line
  ensure_root || return
  echo "This configures: Public UDP port -> GRE peer UDP service"
  read -r -p "Public UDP port on this server [51821]: " public_port; public_port="${public_port:-51821}"
  read -r -p "GRE destination IP [102.230.9.2]: " dst_ip; dst_ip="${dst_ip:-102.230.9.2}"
  read -r -p "Destination UDP port [$public_port]: " dst_port; dst_port="${dst_port:-$public_port}"
  echo
  echo "DNAT udp dpt:$public_port -> $dst_ip:$dst_port"
  echo "MASQUERADE to $dst_ip:$dst_port"
  echo "FORWARD ACCEPT both directions"
  read -r -p "Apply? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac
  sysctl_forwarding_on
  iptables -t nat -D PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port"
  iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
  iptables -I FORWARD 1 -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT
  iptables -I FORWARD 2 -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT
  if have_cmd ufw; then ufw allow "$public_port/udp" || true; fi
  save_firewall
  cat > "$STATE_DIR/udp-forward-$public_port.env" <<STATE
public_port=$public_port
dst_ip=$dst_ip
dst_port=$dst_port
created_at=$(date -Is)
STATE
  echo -e "${GREEN}UDP forward configured and firewall rules saved.${NC}"
  echo "Tests:"
  echo "  tcpdump -ni any udp port $public_port"
  echo "  tcpdump -ni greIR udp port $dst_port"
  echo "  On peer: tcpdump -ni any udp port $dst_port"
  pause
}

remove_udp_forward() {
  title
  echo -e "${CYAN}Tunnel Manager > Remove UDP Forward${NC}"
  line
  ensure_root || return
  read -r -p "Public UDP port to remove [51821]: " public_port; public_port="${public_port:-51821}"
  read -r -p "GRE destination IP [102.230.9.2]: " dst_ip; dst_ip="${dst_ip:-102.230.9.2}"
  read -r -p "Destination UDP port [$public_port]: " dst_port; dst_port="${dst_port:-$public_port}"
  iptables -t nat -D PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT 2>/dev/null || true
  rm -f "$STATE_DIR/udp-forward-$public_port.env" 2>/dev/null || true
  save_firewall
  echo -e "${GREEN}Removed matching rules if existed.${NC}"
  pause
}

wireguard_over_gre_preset() {
  title
  echo -e "${CYAN}Tunnel Manager > Preset: WireGuard over GRE${NC}"
  line
  echo "Use this on IRAN server after GRE is created."
  echo "Default: User -> Iran UDP 51821 -> GRE peer 102.230.9.2:51821"
  echo "Note: GRE ping can fail while UDP/WireGuard still works."
  echo
  read -r -p "Apply WireGuard UDP forward preset now? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac
  public_port=51821 dst_ip=102.230.9.2 dst_port=51821
  sysctl_forwarding_on
  iptables -t nat -D PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port"
  iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
  iptables -I FORWARD 1 -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT
  iptables -I FORWARD 2 -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT
  if have_cmd ufw; then ufw allow 51821/udp || true; fi
  save_firewall
  echo -e "${GREEN}WireGuard over GRE preset applied and saved.${NC}"
  echo "Recommended client MTU behind GRE: 1360, fallback: 1280"
  pause
}

hysteria_over_gre_preset() {
  title
  echo -e "${CYAN}Tunnel Manager > Preset: Hysteria over GRE${NC}"
  line
  echo "Use this on IRAN server after Hysteria works directly on KHAREJ."
  read -r -p "Public UDP port [8080]: " p; p="${p:-8080}"
  read -r -p "GRE destination IP [102.230.9.2]: " dst; dst="${dst:-102.230.9.2}"
  read -r -p "Destination UDP port [$p]: " dp; dp="${dp:-$p}"
  echo
  public_port="$p" dst_ip="$dst" dst_port="$dp"
  read -r -p "Apply Hysteria UDP forward now? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac
  sysctl_forwarding_on
  iptables -t nat -D PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp --dport "$public_port" -j DNAT --to-destination "$dst_ip:$dst_port"
  iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
  iptables -I FORWARD 1 -p udp -d "$dst_ip" --dport "$dst_port" -j ACCEPT
  iptables -I FORWARD 2 -p udp -s "$dst_ip" --sport "$dst_port" -j ACCEPT
  if have_cmd ufw; then ufw allow "$public_port/udp" || true; fi
  save_firewall
  echo -e "${GREEN}Hysteria over GRE preset applied and saved.${NC}"
  pause
}

quality_server() {
  title
  echo -e "${CYAN}Tunnel Manager > Quality Test Server${NC}"
  line
  ensure_root || return
  safe_install_tools
  echo "Run this on the server that should receive tests."
  echo "For KHAREJ side usually bind to: 102.230.9.2"
  echo "For IRAN side usually bind to: 102.230.9.1"
  echo
  read -r -p "Bind tunnel IP [102.230.9.2]: " bind_ip; bind_ip="${bind_ip:-102.230.9.2}"
  read -r -p "iperf3 port [5201]: " port; port="${port:-5201}"
  echo
  echo -e "${GREEN}Starting iperf3 server:${NC} iperf3 -s -B $bind_ip -p $port"
  echo "Keep this window open. Press Ctrl+C to stop."
  echo
  iperf3 -s -B "$bind_ip" -p "$port" || true
  pause
}

quality_client_full() {
  title
  echo -e "${CYAN}Tunnel Manager > Full GRE Quality Test Client${NC}"
  line
  ensure_root || return
  safe_install_tools
  echo "Before running this, start option 1 on the peer server."
  echo
  read -r -p "Local tunnel IP to bind [102.230.9.1]: " local_ip; local_ip="${local_ip:-102.230.9.1}"
  read -r -p "Peer tunnel IP / iperf3 server [102.230.9.2]: " peer_ip; peer_ip="${peer_ip:-102.230.9.2}"
  read -r -p "iperf3 port [5201]: " port; port="${port:-5201}"
  read -r -p "Test duration seconds [20]: " duration; duration="${duration:-20}"
  read -r -p "UDP bitrates to test, comma separated [5M,10M,20M,50M]: " rates; rates="${rates:-5M,10M,20M,50M}"

  local report
  report="$LOG_DIR/gre-quality-$(date +%F-%H%M%S).log"

  {
    echo "VIPTrue GRE Quality Report"
    echo "Created: $(date -Is)"
    echo "Local bind: $local_ip"
    echo "Peer: $peer_ip:$port"
    echo "Duration: $duration"
    echo
    echo "===== System / tunnel status ====="
    ip addr | grep -A4 -E 'gre|102\.230\.9' || true
    ip route | grep -E '102\.230\.9|gre' || true
    echo
    echo "===== iperf3 TCP upload: local -> peer ====="
    iperf3 -c "$peer_ip" -B "$local_ip" -p "$port" -t "$duration" || true
    echo
    echo "===== iperf3 TCP reverse: peer -> local ====="
    iperf3 -c "$peer_ip" -B "$local_ip" -p "$port" -t "$duration" -R || true
    echo
    echo "===== iperf3 UDP tests: loss / jitter ====="
    IFS=',' read -ra rr <<< "$rates"
    for rate in "${rr[@]}"; do
      rate="${rate// /}"
      [[ -n "$rate" ]] || continue
      echo
      echo "----- UDP bitrate $rate local -> peer -----"
      iperf3 -c "$peer_ip" -B "$local_ip" -p "$port" -u -b "$rate" -t "$duration" || true
      echo
      echo "----- UDP bitrate $rate peer -> local reverse -----"
      iperf3 -c "$peer_ip" -B "$local_ip" -p "$port" -u -b "$rate" -t "$duration" -R || true
    done
    echo
    echo "===== WireGuard status if available ====="
    if have_cmd wg; then wg show || true; else echo "wg command not installed."; fi
    echo
    echo "===== NAT / FORWARD counters ====="
    iptables -t nat -L PREROUTING -n -v --line-numbers | sed -n '1,120p' || true
    iptables -t nat -L POSTROUTING -n -v --line-numbers | sed -n '1,120p' || true
    iptables -L FORWARD -n -v --line-numbers | sed -n '1,120p' || true
    echo
    echo "===== Interpretation guide ====="
    echo "UDP Lost/Total above 2% = bad for VPN/gaming."
    echo "High jitter = unstable tunnel."
    echo "TCP Retr high = congestion or packet loss."
    echo "If ping fails but UDP works, GRE may still be usable for WireGuard/Hysteria."
  } 2>&1 | tee "$report"

  echo
  echo -e "${GREEN}Report saved:${NC} $report"
  echo "Send this report output/file for analysis."
  pause
}

quality_public_path() {
  title
  echo -e "${CYAN}Tunnel Manager > Public Path MTR Test${NC}"
  line
  safe_install_tools
  read -r -p "Remote public IP: " remote_ip
  [[ -n "${remote_ip// /}" ]] || { echo "Empty."; pause; return; }
  local report
  report="$LOG_DIR/public-path-mtr-$(date +%F-%H%M%S).log"
  {
    echo "VIPTrue Public Path Report"
    echo "Created: $(date -Is)"
    echo "Remote public IP: $remote_ip"
    echo
    echo "===== ping public IP ====="
    ping -c 20 -W 2 "$remote_ip" || true
    echo
    echo "===== mtr TCP/ICMP path ====="
    if have_cmd mtr; then
      mtr -rwzc 50 "$remote_ip" || true
    else
      echo "mtr not available."
    fi
  } 2>&1 | tee "$report"
  echo
  echo -e "${GREEN}Report saved:${NC} $report"
  pause
}

quality_mtu_helper() {
  title
  echo -e "${CYAN}Tunnel Manager > MTU Helper${NC}"
  line
  echo "This uses ICMP DF ping. If ICMP is blocked, results may be invalid."
  read -r -p "Peer tunnel IP [102.230.9.2]: " peer; peer="${peer:-102.230.9.2}"
  for size in 1436 1400 1360 1320 1280 1200; do
    echo
    echo "Testing payload size $size:"
    ping -M do -s "$size" -c 3 -W 2 "$peer" || true
  done
  echo
  echo "For WireGuard behind GRE, try client MTU 1360 first; fallback 1280."
  pause
}

show_quality_reports() {
  title
  echo -e "${CYAN}Tunnel Manager > Saved Quality Reports${NC}"
  line
  ls -lh "$LOG_DIR"/*.log 2>/dev/null || echo "No reports yet."
  echo
  read -r -p "Show latest report now? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES)
      latest="$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1 || true)"
      if [[ -n "$latest" ]]; then
        echo
        echo "===== $latest ====="
        sed -n '1,260p' "$latest"
      fi
      ;;
  esac
  pause
}

reverse_ssh_menu() {
  title
  echo -e "${CYAN}Tunnel Manager > Reverse SSH pg-node helper${NC}"
  line
  echo "This helper is TCP-only and useful for PasarGuard pg-node behind restricted networks."
  echo "Recommended final panel settings from our tested scenario:"
  echo "  Node Address: 127.0.0.1"
  echo "  Node Port:    remote localhost port, e.g. 2053"
  echo "  API Port:     remote localhost API port, e.g. 2095"
  echo
  echo "For full setup, use earlier pg-node reverse SSH guide or request next Step."
  pause
}

live_tcpdump() {
  title
  echo -e "${CYAN}Tunnel Manager > Live tcpdump${NC}"
  line
  ensure_root || return
  read -r -p "Interface [any]: " iface; iface="${iface:-any}"
  read -r -p "Filter [udp port 51821]: " filter; filter="${filter:-udp port 51821}"
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
    echo "3. Remove GRE interface + persistent service"
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

udp_menu() {
  while true; do
    title
    echo -e "${CYAN}Tunnel Manager > UDP Forward over GRE${NC}"
    echo
    echo "1. Setup UDP forward manually"
    echo "2. Preset: WireGuard 51821 over GRE"
    echo "3. Preset: Hysteria UDP over GRE"
    echo "4. Status: NAT / FORWARD counters"
    echo "5. Remove UDP forward"
    echo "6. Live tcpdump"
    echo "0. Back"
    line
    read -r -p "Enter your choice [0-6]: " c
    case "$c" in
      1) setup_udp_forward ;;
      2) wireguard_over_gre_preset ;;
      3) hysteria_over_gre_preset ;;
      4) udp_forward_status ;;
      5) remove_udp_forward ;;
      6) live_tcpdump ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

quality_menu() {
  while true; do
    title
    echo -e "${CYAN}Tunnel Manager > Quality / Speed Tests${NC}"
    line
    echo
    echo "1. Start iperf3 server on this tunnel IP"
    echo "2. Run full quality client test: TCP/Reverse/UDP loss+jitter"
    echo "3. Public path ping + MTR test"
    echo "4. MTU helper"
    echo "5. Show saved reports"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-5]: " c
    case "$c" in
      1) quality_server ;;
      2) quality_client_full ;;
      3) quality_public_path ;;
      4) quality_mtu_helper ;;
      5) show_quality_reports ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

while true; do
  title
  echo -e "${CYAN}Tunnel Manager${NC}"
  line
  echo
  echo "1. Testing / Compatibility Scan"
  echo "2. GRE Site-to-Site"
  echo "3. UDP Forward over GRE: WireGuard / Hysteria"
  echo "4. Quality / Speed Tests"
  echo "5. Reverse SSH helper: PasarGuard pg-node"
  echo "6. Live tcpdump"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-6]: " choice
  case "$choice" in
    1) compatibility_scan ;;
    2) gre_menu ;;
    3) udp_menu ;;
    4) quality_menu ;;
    5) reverse_ssh_menu ;;
    6) live_tcpdump ;;
    0) break ;;
    99) viptrue_main_menu ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF_TM

chmod +x modules/utility/04-tunnel-manager.sh

# Syntax check all scripts
find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 20-C completed successfully."
echo "Version: $(cat VERSION)"
echo
echo "Next: commit and push, then test from GitHub main:"
echo "  git add ."
echo "  git commit -m 'Add tunnel quality tests and persistent GRE services'"
echo "  git push"
echo
echo "Clean GitHub test:"
echo "  rm -rf /opt/viptrue-toolbox"
echo "  curl -sSL https://raw.githubusercontent.com/ArashPersian/viptrue-toolbox/main/bootstrap.sh | sudo bash"
echo
echo "Release after stable test:"
echo "  git tag v0.1.5"
echo "  git push origin v0.1.5"
echo "  gh release create v0.1.5 --title 'VIPTrue Server Toolbox v0.1.5' --notes 'Adds Tunnel Manager quality tests, iperf3 reports, and persistent GRE systemd services.'"
