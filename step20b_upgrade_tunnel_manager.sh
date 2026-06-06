#!/usr/bin/env bash
set -Eeuo pipefail

# Step 20-B — Upgrade VIPTrue Tunnel Manager
# Adds better testing, tunnel recommendations, GRE status, UDP forward diagnostics,
# WireGuard/Hysteria over GRE presets, and fixes utility menu line typo.

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
BACKUP_DIR="/root/viptrue-toolbox-step20b-backup-$TS"
mkdir -p "$BACKUP_DIR"
cp -a VERSION "$BACKUP_DIR/VERSION.bak" 2>/dev/null || true
cp -a menus/utility.sh "$BACKUP_DIR/utility.sh.bak" 2>/dev/null || true
cp -a modules/utility/04-tunnel-manager.sh "$BACKUP_DIR/04-tunnel-manager.sh.bak" 2>/dev/null || true

echo "0.1.4" > VERSION

echo "Backup saved to: $BACKUP_DIR"

# Ensure Utility menu contains Tunnel Manager and fix common typo: echo line -> line
python3 - <<'PY'
from pathlib import Path
import re
p = Path('menus/utility.sh')
if not p.exists():
    raise SystemExit('menus/utility.sh not found')
text = p.read_text()
text = text.replace('echo line', 'line')
if 'Tunnel Manager' not in text:
    # Add visible option after offline assets when possible
    if 'Offline Assets / Local Installer' in text:
        text = re.sub(r'(echo "3\. Offline Assets / Local Installer".*)', r'\1\n  echo "4. Tunnel Manager"', text, count=1)
    else:
        text = re.sub(r'(echo "2\. Temporary Tunnel / Proxy for Installations".*)', r'\1\n  echo "4. Tunnel Manager"', text, count=1)
    text = text.replace('Enter your choice [0-3]', 'Enter your choice [0-4]')
    if not re.search(r'\n\s*4\)', text):
        text = re.sub(r'(\n\s*0\)\s*\n\s*break\s*\n\s*;;)', r'\n    4)\n      bash "$BASE_DIR/modules/utility/04-tunnel-manager.sh"\n      ;;\1', text, count=1)
else:
    text = text.replace('Enter your choice [0-3]', 'Enter your choice [0-4]')
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
  for c in ip iptables ss tcpdump nc curl; do
    have_cmd "$c" || needed+=("$c")
  done
  if ((${#needed[@]})); then
    echo -e "${YELLOW}Missing tools:${NC} ${needed[*]}"
    read -r -p "Install required packages now? [y/N]: " ans
    case "$ans" in
      y|Y|yes|YES)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 iptables iptables-persistent netcat-openbsd tcpdump curl dnsutils autossh socat stunnel4 iperf3 || true
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
}

recommendations() {
  echo
  line
  echo -e "${CYAN}Recommended tunnel choices${NC}"
  echo
  echo "1) GRE Site-to-Site"
  echo "   Use when: both servers have public IPv4 and provider allows GRE protocol 47."
  echo "   Best for: WireGuard/Hysteria behind Iran IP via UDP DNAT."
  echo
  echo "2) GRE + UDP Forward"
  echo "   Use when: GRE ping works and you need User -> Iran -> Foreign UDP service."
  echo "   Proven presets: WireGuard UDP 51821, Hysteria UDP 8080/443."
  echo
  echo "3) Reverse SSH"
  echo "   Use when: TCP-only internal services like PasarGuard pg-node gRPC/API."
  echo "   Not suitable for high-throughput UDP."
  echo
  echo "4) Raw TCP / stunnel"
  echo "   Use when: only TCP can pass. stunnel wraps TCP in TLS."
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
    echo -e "${YELLOW}ICMP test:${NC} $remote_ip"
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
  ip tunnel show || true
  echo
  ip addr | grep -A4 -E 'gre|102\.230\.9' || true
  echo
  ip route | grep -E '102\.230\.9|gre' || true
  echo
  read -r -p "Ping peer tunnel IP, empty=skip [102.230.9.2]: " peer
  peer="${peer:-}"
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
  local detected local_pub remote_pub mtu
  detected="$(pub_ip)"
  read -r -p "Local public IP [$detected]: " local_pub; local_pub="${local_pub:-$detected}"
  read -r -p "Remote public IP: " remote_pub
  read -r -p "Interface name [$default_if]: " ifname; ifname="${ifname:-$default_if}"
  read -r -p "This side tunnel CIDR [$cidr]: " in_cidr; cidr="${in_cidr:-$cidr}"
  read -r -p "MTU [1476]: " mtu; mtu="${mtu:-1476}"
  [[ -n "$local_pub" && -n "$remote_pub" ]] || { echo -e "${RED}Local/remote IP required.${NC}"; pause; return; }
  echo
  echo -e "${YELLOW}Plan:${NC} $ifname remote=$remote_pub local=$local_pub cidr=$cidr mtu=$mtu"
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
  echo "When both sides are ready: ping -c 4 $peer"
  pause
}

remove_gre() {
  title
  echo -e "${CYAN}Tunnel Manager > Remove GRE${NC}"
  line
  ensure_root || return
  echo "Existing GRE interfaces:"
  get_gre_ifaces || true
  read -r -p "Interface to remove [greIR/greKH]: " ifname
  [[ -n "$ifname" ]] || { echo "Empty."; pause; return; }
  ip tunnel del "$ifname" 2>/dev/null || true
  rm -f "$STATE_DIR/gre-$ifname.env" 2>/dev/null || true
  echo -e "${GREEN}Removed if existed:${NC} $ifname"
  pause
}

udp_forward_status() {
  title
  echo -e "${CYAN}Tunnel Manager > UDP Forward Status${NC}"
  line
  echo -e "${YELLOW}NAT PREROUTING:${NC}"
  iptables -t nat -L PREROUTING -n -v --line-numbers | sed -n '1,120p'
  echo
  echo -e "${YELLOW}NAT POSTROUTING:${NC}"
  iptables -t nat -L POSTROUTING -n -v --line-numbers | sed -n '1,120p'
  echo
  echo -e "${YELLOW}FORWARD:${NC}"
  iptables -L FORWARD -n -v --line-numbers | sed -n '1,120p'
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
  echo -e "${GREEN}UDP forward configured.${NC}"
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
  echo "Use this on IRAN server after GRE ping works."
  echo "Default: User -> Iran UDP 51821 -> GRE peer 102.230.9.2:51821"
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
  echo -e "${GREEN}WireGuard over GRE preset applied.${NC}"
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
  echo -e "${GREEN}Hysteria over GRE preset applied.${NC}"
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
  echo "For full setup, use earlier pg-node reverse SSH guide or request Step 20-C."
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

while true; do
  title
  echo -e "${CYAN}Tunnel Manager${NC}"
  line
  echo
  echo "1. Testing / Compatibility Scan"
  echo "2. GRE Site-to-Site"
  echo "3. UDP Forward over GRE: WireGuard / Hysteria"
  echo "4. Reverse SSH helper: PasarGuard pg-node"
  echo "5. Live tcpdump"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-5]: " choice
  case "$choice" in
    1) compatibility_scan ;;
    2) gre_menu ;;
    3) udp_menu ;;
    4) reverse_ssh_menu ;;
    5) live_tcpdump ;;
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
echo "✅ Step 20-B completed successfully."
echo "Version: $(cat VERSION)"
echo
echo "Test now:"
echo "  bash menus/utility.sh"
echo
echo "When OK, push:"
echo "  git add ."
echo "  git commit -m 'Upgrade tunnel manager testing and UDP forward presets'"
echo "  git push"
echo
echo "Release after stable test:"
echo "  git tag v0.1.4"
echo "  git push origin v0.1.4"
echo "  gh release create v0.1.4 --title 'VIPTrue Server Toolbox v0.1.4' --notes 'Adds Tunnel Manager testing, GRE status, UDP forward diagnostics, and WireGuard/Hysteria over GRE presets.'"
