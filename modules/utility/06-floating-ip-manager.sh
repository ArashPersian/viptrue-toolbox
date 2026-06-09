#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

FIP_DIR="/opt/viptrue-floating-ip-manager"
mkdir -p "$FIP_DIR/state" "$FIP_DIR/logs"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return 1
  fi
}

safe_install_fip_tools() {
  local needed=()
  for c in ip ss curl ping awk sed grep systemctl; do
    have_cmd "$c" || needed+=("$c")
  done
  if ((${#needed[@]})); then
    echo -e "${YELLOW}Missing tools:${NC} ${needed[*]}"
    read -r -p "Install basic networking tools now? [y/N]: " ans
    case "$ans" in
      y|Y|yes|YES)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 iputils-ping curl net-tools || true
        ;;
    esac
  fi
}

detect_default_iface() {
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

pub_ip() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown"
}

print_fip_status() {
  title
  echo -e "${CYAN}Floating IP Manager > Status / Detect${NC}"
  line
  local iface
  iface="$(detect_default_iface || true)"
  echo -e "${YELLOW}Default interface:${NC} ${iface:-unknown}"
  echo
  echo -e "${YELLOW}Public IPv4 detected:${NC}"
  pub_ip
  echo
  echo -e "${YELLOW}IPv4 addresses:${NC}"
  ip -4 -br addr show || true
  echo
  echo -e "${YELLOW}Default route:${NC}"
  ip route show default || true
  echo
  echo -e "${YELLOW}Netplan files:${NC}"
  ls -l /etc/netplan/ 2>/dev/null || echo "No /etc/netplan directory"
  echo
  echo -e "${YELLOW}VIPTrue floating IP services:${NC}"
  systemctl list-units 'viptrue-floating-ip-*.service' --all 2>/dev/null || true
  pause
}

service_name_for_ip() {
  local ip="$1"
  echo "viptrue-floating-ip-${ip//./-}.service"
}

add_runtime_ip() {
  local ip="$1" iface="$2"
  if ip -4 addr show dev "$iface" | grep -qE " ${ip}/"; then
    echo -e "${GREEN}$ip is already assigned on $iface.${NC}"
  else
    ip addr add "$ip/32" dev "$iface"
    echo -e "${GREEN}Runtime IP added:${NC} $ip/32 dev $iface"
  fi
}

write_systemd_persistent_ip() {
  local ip="$1" iface="$2"
  local svc
  svc="$(service_name_for_ip "$ip")"

  cat > "/etc/systemd/system/$svc" <<EOF_SVC
[Unit]
Description=VIPTrue Floating/Reserved IPv4 $ip on $iface
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/ip -4 addr show dev $iface | /bin/grep -q " $ip/" || /usr/sbin/ip addr add $ip/32 dev $iface'
ExecStop=-/usr/sbin/ip addr del $ip/32 dev $iface

[Install]
WantedBy=multi-user.target
EOF_SVC

  systemctl daemon-reload
  systemctl enable --now "$svc"
  echo -e "${GREEN}Persistent systemd service enabled:${NC} $svc"
}

vultr_add_reserved_ip_safe() {
  title
  echo -e "${CYAN}Floating IP Manager > Vultr > Add Reserved IPv4 safely${NC}"
  line
  ensure_root || return
  safe_install_fip_tools

  local iface detected ip
  detected="$(detect_default_iface || true)"
  echo "Vultr note: Reserved/Additional IPv4 must already be attached in Vultr panel."
  echo "This safe mode adds the IP as /32 now and creates a boot-persistent systemd service."
  echo "It does not rewrite your main netplan file, so it is safer for SSH."
  echo
  read -r -p "Network interface [$detected]: " iface
  iface="${iface:-$detected}"
  read -r -p "Vultr Reserved IPv4 to add: " ip

  [[ -n "$iface" && -n "$ip" ]] || { echo -e "${RED}Interface and IP are required.${NC}"; pause; return; }
  if ! ip link show "$iface" >/dev/null 2>&1; then
    echo -e "${RED}Interface not found:${NC} $iface"
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Plan:${NC}"
  echo "  Provider: Vultr"
  echo "  Interface: $iface"
  echo "  Reserved IPv4: $ip/32"
  echo "  Persistence: systemd service"
  echo
  read -r -p "Apply? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac

  add_runtime_ip "$ip" "$iface"
  write_systemd_persistent_ip "$ip" "$iface"

  echo
  echo -e "${YELLOW}Testing source IP:${NC}"
  ping -c 2 -W 2 -I "$ip" 1.1.1.1 || true
  echo
  curl --interface "$ip" -4fsS --max-time 8 https://api.ipify.org || true
  echo
  echo
  echo -e "${GREEN}Done. If curl prints the reserved IP, it is working.${NC}"
  pause
}

vultr_add_reserved_ip_netplan() {
  title
  echo -e "${CYAN}Floating IP Manager > Vultr > Add Reserved IPv4 with Netplan${NC}"
  line
  ensure_root || return
  safe_install_fip_tools

  local iface detected ip file
  detected="$(detect_default_iface || true)"
  echo -e "${YELLOW}Warning:${NC} Netplan changes can affect SSH if your provider image has unusual networking."
  echo "Recommended first: use option 2 safe systemd mode. Use this if you specifically want Netplan."
  echo
  read -r -p "Network interface [$detected]: " iface
  iface="${iface:-$detected}"
  read -r -p "Vultr Reserved IPv4 to add: " ip
  file="/etc/netplan/60-viptrue-floating-ip-vultr-${ip//./-}.yaml"

  [[ -n "$iface" && -n "$ip" ]] || { echo -e "${RED}Interface and IP are required.${NC}"; pause; return; }
  if ! ip link show "$iface" >/dev/null 2>&1; then
    echo -e "${RED}Interface not found:${NC} $iface"
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Plan:${NC}"
  echo "  Write: $file"
  echo "  Interface: $iface"
  echo "  Address: $ip/32"
  echo
  read -r -p "Write netplan and run 'netplan try'? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac

  cp -a /etc/netplan "/etc/netplan.backup.viptrue.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

  cat > "$file" <<EOF_NP
network:
  version: 2
  ethernets:
    $iface:
      addresses:
        - $ip/32
EOF_NP

  echo -e "${GREEN}Written:${NC} $file"
  echo
  echo -e "${YELLOW}Running netplan try. If SSH gets risky, it should rollback automatically.${NC}"
  netplan try || true
  echo
  read -r -p "Run netplan apply now? [y/N]: " apply
  case "$apply" in
    y|Y|yes|YES) netplan apply || true ;;
    *) echo "Skipped netplan apply." ;;
  esac

  echo
  ip -4 -br addr show dev "$iface" || true
  echo
  curl --interface "$ip" -4fsS --max-time 8 https://api.ipify.org || true
  echo
  pause
}

remove_floating_ip() {
  title
  echo -e "${CYAN}Floating IP Manager > Remove Floating/Reserved IPv4${NC}"
  line
  ensure_root || return

  local iface detected ip svc file
  detected="$(detect_default_iface || true)"
  read -r -p "Network interface [$detected]: " iface
  iface="${iface:-$detected}"
  read -r -p "Floating/Reserved IPv4 to remove: " ip

  [[ -n "$iface" && -n "$ip" ]] || { echo -e "${RED}Interface and IP are required.${NC}"; pause; return; }

  ip addr del "$ip/32" dev "$iface" 2>/dev/null || true

  svc="$(service_name_for_ip "$ip")"
  systemctl disable --now "$svc" 2>/dev/null || true
  rm -f "/etc/systemd/system/$svc"
  systemctl daemon-reload

  file="/etc/netplan/60-viptrue-floating-ip-vultr-${ip//./-}.yaml"
  if [[ -f "$file" ]]; then
    read -r -p "Remove netplan file $file too? [y/N]: " ok
    case "$ok" in y|Y|yes|YES) rm -f "$file"; netplan apply || true ;; esac
  fi

  echo -e "${GREEN}Removed runtime/service/netplan if matched:${NC} $ip"
  pause
}

test_source_ip() {
  title
  echo -e "${CYAN}Floating IP Manager > Test Source IP${NC}"
  line
  local ip
  read -r -p "Source IPv4 to test: " ip
  [[ -n "$ip" ]] || { echo -e "${RED}IP required.${NC}"; pause; return; }

  echo -e "${YELLOW}Local address check:${NC}"
  ip -4 addr | grep "$ip" || echo -e "${RED}$ip is not currently assigned locally.${NC}"
  echo
  echo -e "${YELLOW}Ping via source IP:${NC}"
  ping -c 3 -W 2 -I "$ip" 1.1.1.1 || true
  echo
  echo -e "${YELLOW}External IP via curl --interface:${NC}"
  curl --interface "$ip" -4fsS --max-time 10 https://api.ipify.org || true
  echo
  pause
}

provider_notes() {
  title
  echo -e "${CYAN}Floating IP Manager > Provider Notes${NC}"
  line
  cat <<'EOF_NOTES'
Vultr Reserved/Additional IPv4:
  1) Attach the IP in Vultr panel first.
  2) Then configure the IP inside Ubuntu.
  3) Safe recommended method:
       IP/32 on main interface + systemd persistence.
  4) Netplan method is available, but systemd mode is safer for SSH.

Important:
  - Do not change the primary default route unless you know what you are doing.
  - Use curl --interface FLOATING_IP https://api.ipify.org to verify.
  - If your panel says "manually configure it within your operating system",
    the provider side is attached but the OS has not assigned it yet.

Future providers planned:
  - Hetzner Additional IP
  - Contabo Additional IP
  - AWS Elastic IP note/check
  - Azure Public IP note/check
  - ArvanCloud additional IP if supported by OS config
EOF_NOTES
  pause
}

floating_ip_manager_main() {
  while true; do
    title
    echo -e "${CYAN}Floating IP Manager${NC}"
    line
    echo "1. Status / detect interfaces and current IPs"
    echo "2. Vultr: Add Reserved IPv4 safely (runtime + systemd persistent)"
    echo "3. Vultr: Add Reserved IPv4 with Netplan"
    echo "4. Remove Floating/Reserved IPv4"
    echo "5. Test source IP"
    echo "6. Provider notes / roadmap"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-6]: " choice
    case "$choice" in
      1) print_fip_status ;;
      2) vultr_add_reserved_ip_safe ;;
      3) vultr_add_reserved_ip_netplan ;;
      4) remove_floating_ip ;;
      5) test_source_ip ;;
      6) provider_notes ;;
      0) break ;;
      99) viptrue_main_menu 2>/dev/null || break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; pause ;;
    esac
  done
}

floating_ip_manager_main
