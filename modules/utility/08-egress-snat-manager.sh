#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/ui.sh
source "$BASE_DIR/lib/ui.sh"

EGRESS_DIR="${VIPTRUE_EGRESS_SNAT_DIR:-/etc/viptrue-toolbox}"
EGRESS_CONF="$EGRESS_DIR/egress-snat.conf"
EGRESS_SERVICE="viptrue-egress-snat.service"
EGRESS_COMMENT="VIPTRUE_EGRESS_SNAT"
EGRESS_SYSCTL_FILE="/etc/sysctl.d/99-viptrue-egress-snat.conf"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
  if [[ "$EUID" -eq 0 ]]; then return 0; fi
  echo -e "${RED}This action must be run as root.${NC}"
  pause
  return 1
}

valid_ipv4() {
  local ip="$1" IFS=.
  local -a octets
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((octet >= 0 && octet <= 255)) || return 1
  done
}

valid_ipv4_cidr() {
  local cidr="$1" ip prefix
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  valid_ipv4 "$ip" || return 1
  ((prefix >= 0 && prefix <= 32))
}

valid_ipv6() {
  local ip="$1"
  [[ "$ip" == *:* ]] || return 1
  [[ "$ip" != *" "* && "$ip" != *";"* && "$ip" != *"="* ]]
}

valid_ipv6_cidr() {
  local cidr="$1" ip prefix
  [[ "$cidr" == */* ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  valid_ipv6 "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  ((prefix >= 0 && prefix <= 128))
}

valid_iface() { [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,32}$ ]]; }

detect_default_iface4() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

detect_default_iface6() {
  ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

detect_public_ip4() { curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "unknown"; }
detect_public_ip6() { curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || echo "unknown"; }
ipv4_exists_on_host() { ip -4 addr show 2>/dev/null | grep -Eq " $1/"; }
ipv6_exists_on_host() { ip -6 addr show 2>/dev/null | grep -Eiq " $1/"; }

get_conf_value() {
  local key="$1"
  [[ -r "$EGRESS_CONF" ]] || return 0
  awk -F= -v key="$key" '$1 == key {val=$0; sub(/^[^=]*=/,"",val); print val; exit}' "$EGRESS_CONF"
}

backup_iptables() {
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="/root/viptrue-iptables-backup-${stamp}.rules"
  if have_cmd iptables-save; then
    iptables-save > "$backup"
    echo -e "${GREEN}iptables backup:${NC} $backup"
  else
    echo -e "${YELLOW}iptables-save not found; backup skipped.${NC}"
  fi
}

show_forwarding_status() {
  echo -e "${YELLOW}Forwarding:${NC}"
  printf '  IPv4 net.ipv4.ip_forward = '
  cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "unknown"
  printf '  IPv6 net.ipv6.conf.all.forwarding = '
  cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo "unknown"
}

show_managed_rules() {
  echo -e "${YELLOW}iptables managed NAT rules:${NC}"
  if have_cmd iptables; then iptables -t nat -S POSTROUTING 2>/dev/null | grep "$EGRESS_COMMENT" || echo "  none"; else echo "  iptables not found"; fi
  echo
  echo -e "${YELLOW}ip6tables managed NAT rules:${NC}"
  if have_cmd ip6tables; then ip6tables -t nat -S POSTROUTING 2>/dev/null | grep "$EGRESS_COMMENT" || echo "  none"; else echo "  ip6tables not found"; fi
  echo
  echo -e "${YELLOW}nft NAT hints:${NC}"
  if have_cmd nft; then nft list ruleset 2>/dev/null | grep -iE 'snat|masquerade|VIPTRUE_EGRESS_SNAT' || echo "  no visible nft snat/masquerade rules"; else echo "  nft not found"; fi
}

show_egress_status() {
  local iface4 iface6
  title
  echo -e "${CYAN}Egress IP / SNAT Manager > Status${NC}"
  line
  echo
  echo "PasarGuard context:"
  echo "  Xray sendThrough fits one server with multiple hosts."
  echo "  Server-level SNAT fits multiple real servers, each with its own egress IP."
  echo
  iface4="$(detect_default_iface4 || true)"
  iface6="$(detect_default_iface6 || true)"
  echo -e "${YELLOW}Addresses:${NC}"
  ip -br addr || true
  echo
  echo -e "${YELLOW}Default routes:${NC}"
  ip route show default || true
  ip -6 route show default 2>/dev/null || true
  echo
  echo -e "${YELLOW}Detected default interfaces:${NC}"
  echo "  IPv4: ${iface4:-unknown}"
  echo "  IPv6: ${iface6:-unknown}"
  echo
  echo -e "${YELLOW}Current public egress:${NC}"
  echo "  IPv4: $(detect_public_ip4)"
  echo "  IPv6: $(detect_public_ip6)"
  echo
  show_forwarding_status
  echo
  show_managed_rules
  echo
  echo -e "${YELLOW}Config:${NC} $EGRESS_CONF"
  if [[ -f "$EGRESS_CONF" ]]; then sed 's/^/  /' "$EGRESS_CONF"; else echo "  no VIPTrue egress config found"; fi
  pause
}

prompt_ipv4_subnets() {
  local choice custom
  echo
  echo "Select source subnet scope for VPN/PasarGuard traffic:"
  echo "1. Common private ranges: 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  echo "2. VIPTrue/WireGuard sample: 10.99.0.0/24"
  echo "3. Custom comma-separated CIDRs"
  echo
  read -r -p "Choice [1]: " choice
  choice="${choice:-1}"
  case "$choice" in
    1) echo "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" ;;
    2) echo "10.99.0.0/24" ;;
    3) read -r -p "Custom IPv4 CIDRs: " custom; echo "$custom" ;;
    *) echo "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" ;;
  esac
}

validate_ipv4_subnets_csv() { local subnet; for subnet in ${1//,/ }; do valid_ipv4_cidr "$subnet" || return 1; done; }
validate_ipv6_subnets_csv() { local subnet; for subnet in ${1//,/ }; do valid_ipv6_cidr "$subnet" || return 1; done; }

write_config() {
  local ipv4_enabled="$1" ipv4_addr="$2" ipv4_iface="$3" ipv4_scope="$4" ipv4_subnets="$5" ipv4_forward="$6"
  local ipv6_enabled="${7:-no}" ipv6_addr="${8:-}" ipv6_iface="${9:-}" ipv6_scope="${10:-}" ipv6_subnets="${11:-}" ipv6_forward="${12:-no}"
  mkdir -p "$EGRESS_DIR"
  chmod 700 "$EGRESS_DIR" 2>/dev/null || true
  cat > "$EGRESS_CONF" <<EOF_CONF
# Managed by VIPTrue Egress IP / SNAT Manager.
# Rules are tagged with comment: $EGRESS_COMMENT
IPV4_ENABLED=$ipv4_enabled
IPV4_EGRESS=$ipv4_addr
IPV4_IFACE=$ipv4_iface
IPV4_SCOPE=$ipv4_scope
IPV4_SUBNETS=$ipv4_subnets
IPV4_FORWARDING=$ipv4_forward
IPV6_ENABLED=$ipv6_enabled
IPV6_EGRESS=$ipv6_addr
IPV6_IFACE=$ipv6_iface
IPV6_SCOPE=$ipv6_scope
IPV6_SUBNETS=$ipv6_subnets
IPV6_FORWARDING=$ipv6_forward
EOF_CONF
  chmod 600 "$EGRESS_CONF" 2>/dev/null || true
  echo -e "${GREEN}Config written:${NC} $EGRESS_CONF"
}

remove_managed_rules_for_cmd() {
  local cmd="$1" rule
  have_cmd "$cmd" || return 0
  while rule="$($cmd -t nat -S POSTROUTING 2>/dev/null | grep "$EGRESS_COMMENT" | head -n 1)"; [[ -n "$rule" ]]; do
    rule="${rule/-A POSTROUTING/-D POSTROUTING}"
    # shellcheck disable=SC2086
    "$cmd" -t nat $rule 2>/dev/null || break
  done
}

remove_managed_rules() { remove_managed_rules_for_cmd iptables; remove_managed_rules_for_cmd ip6tables; }

add_ipv4_snat_rule() { iptables -t nat -C POSTROUTING -s "$1" -o "$2" -m comment --comment "$EGRESS_COMMENT" -j SNAT --to-source "$3" 2>/dev/null || iptables -t nat -A POSTROUTING -s "$1" -o "$2" -m comment --comment "$EGRESS_COMMENT" -j SNAT --to-source "$3"; }
add_ipv4_all_snat_rule() { iptables -t nat -C POSTROUTING -o "$1" -m comment --comment "$EGRESS_COMMENT" -j SNAT --to-source "$2" 2>/dev/null || iptables -t nat -A POSTROUTING -o "$1" -m comment --comment "$EGRESS_COMMENT" -j SNAT --to-source "$2"; }
add_ipv6_snat_rule() { ip6tables -t nat -C POSTROUTING -s "$1" -o "$2" -m comment --comment "$EGRESS_COMMENT" -j SNAT --to-source "$3" 2>/dev/null || ip6tables -t nat -A POSTROUTING -s "$1" -o "$2" -m comment --comment "$EGRESS_COMMENT" -j SNAT --to-source "$3"; }
add_ipv6_all_snat_rule() { ip6tables -t nat -C POSTROUTING -o "$1" -m comment --comment "$EGRESS_COMMENT" -j SNAT --to-source "$2" 2>/dev/null || ip6tables -t nat -A POSTROUTING -o "$1" -m comment --comment "$EGRESS_COMMENT" -j SNAT --to-source "$2"; }

apply_forwarding_from_config() {
  local ipv4_forward ipv6_forward
  ipv4_forward="$(get_conf_value IPV4_FORWARDING)"
  ipv6_forward="$(get_conf_value IPV6_FORWARDING)"
  if [[ "$ipv4_forward" == "yes" ]]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    mkdir -p "$(dirname "$EGRESS_SYSCTL_FILE")"
    grep -q '^net.ipv4.ip_forward=1$' "$EGRESS_SYSCTL_FILE" 2>/dev/null || echo "net.ipv4.ip_forward=1" >> "$EGRESS_SYSCTL_FILE"
  fi
  if [[ "$ipv6_forward" == "yes" ]]; then
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true
    mkdir -p "$(dirname "$EGRESS_SYSCTL_FILE")"
    grep -q '^net.ipv6.conf.all.forwarding=1$' "$EGRESS_SYSCTL_FILE" 2>/dev/null || echo "net.ipv6.conf.all.forwarding=1" >> "$EGRESS_SYSCTL_FILE"
  fi
}

apply_config() {
  local ipv4_enabled ipv4_addr ipv4_iface ipv4_scope ipv4_subnets ipv6_enabled ipv6_addr ipv6_iface ipv6_scope ipv6_subnets subnet
  [[ -r "$EGRESS_CONF" ]] || { echo "Config not found: $EGRESS_CONF"; return 1; }
  have_cmd iptables || { echo "iptables command not found"; return 1; }
  remove_managed_rules
  apply_forwarding_from_config
  ipv4_enabled="$(get_conf_value IPV4_ENABLED)"; ipv4_addr="$(get_conf_value IPV4_EGRESS)"; ipv4_iface="$(get_conf_value IPV4_IFACE)"; ipv4_scope="$(get_conf_value IPV4_SCOPE)"; ipv4_subnets="$(get_conf_value IPV4_SUBNETS)"
  if [[ "$ipv4_enabled" == "yes" ]]; then
    if [[ "$ipv4_scope" == "all" ]]; then add_ipv4_all_snat_rule "$ipv4_iface" "$ipv4_addr"; else for subnet in ${ipv4_subnets//,/ }; do [[ -n "$subnet" ]] && add_ipv4_snat_rule "$subnet" "$ipv4_iface" "$ipv4_addr"; done; fi
  fi
  ipv6_enabled="$(get_conf_value IPV6_ENABLED)"; ipv6_addr="$(get_conf_value IPV6_EGRESS)"; ipv6_iface="$(get_conf_value IPV6_IFACE)"; ipv6_scope="$(get_conf_value IPV6_SCOPE)"; ipv6_subnets="$(get_conf_value IPV6_SUBNETS)"
  if [[ "$ipv6_enabled" == "yes" ]]; then
    have_cmd ip6tables || { echo "ip6tables command not found"; return 1; }
    ip6tables -t nat -S >/dev/null 2>&1 || { echo "ip6tables nat table is not available on this host"; return 1; }
    if [[ "$ipv6_scope" == "all" ]]; then add_ipv6_all_snat_rule "$ipv6_iface" "$ipv6_addr"; else for subnet in ${ipv6_subnets//,/ }; do [[ -n "$subnet" ]] && add_ipv6_snat_rule "$subnet" "$ipv6_iface" "$ipv6_addr"; done; fi
  fi
}

write_systemd_service() {
  local script_path service_path
  script_path="$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")"
  service_path="/etc/systemd/system/$EGRESS_SERVICE"
  cat > "$service_path" <<EOF_SERVICE
[Unit]
Description=VIPTrue Egress IP / Source NAT rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script_path --apply-config
ExecStop=$script_path --flush-managed

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload
  systemctl enable --now "$EGRESS_SERVICE"
  echo -e "${GREEN}Persistence enabled:${NC} $EGRESS_SERVICE"
}

configure_persistence() {
  local ans
  if have_cmd netfilter-persistent && systemctl list-unit-files netfilter-persistent.service >/dev/null 2>&1; then
    echo
    echo "netfilter-persistent exists on this system."
    read -r -p "Save current iptables rules with netfilter-persistent instead of systemd? [y/N]: " ans
    case "$ans" in y|Y|yes|YES) netfilter-persistent save; systemctl enable netfilter-persistent.service >/dev/null 2>&1 || true; echo -e "${GREEN}Persistence saved via netfilter-persistent.${NC}"; return ;; esac
  fi
  write_systemd_service
}

configure_ipv4_egress() {
  local egress_ip iface scope subnets ip_missing_ans apply_ans forward_ans persist_ans old_ipv6_enabled old_ipv6_addr old_ipv6_iface old_ipv6_scope old_ipv6_subnets old_ipv6_forward
  title; echo -e "${CYAN}Egress IP / SNAT Manager > Configure IPv4 Egress IP${NC}"; line
  ensure_root || return
  echo; echo "Safe default: only VPN/private source subnets are SNATed."; echo "This tool does not change default route and does not add INPUT rules."; echo
  read -r -p "IPv4 egress/source IP to show on websites: " egress_ip
  valid_ipv4 "$egress_ip" || { echo -e "${RED}Invalid IPv4 address.${NC}"; pause; return; }
  iface="$(detect_default_iface4 || true)"; read -r -p "Outgoing interface [$iface]: " iface; iface="${iface:-$(detect_default_iface4 || true)}"
  if [[ -z "$iface" ]] || ! valid_iface "$iface" || ! ip link show "$iface" >/dev/null 2>&1; then echo -e "${RED}Invalid or missing interface:${NC} ${iface:-empty}"; pause; return; fi
  if ! ipv4_exists_on_host "$egress_ip"; then echo -e "${YELLOW}Warning:${NC} $egress_ip is not currently assigned on this server."; read -r -p "Continue anyway? [y/N]: " ip_missing_ans; case "$ip_missing_ans" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac; fi
  echo; echo "Scope:"; echo "1. VPN/private source subnets only (recommended)"; echo "2. All outbound IPv4 traffic from this server"; read -r -p "Choice [1]: " scope; scope="${scope:-1}"
  if [[ "$scope" == "2" ]]; then scope="all"; subnets=""; echo -e "${YELLOW}Warning:${NC} all outbound IPv4 traffic will be SNATed on $iface."; else scope="vpn_subnets"; subnets="$(prompt_ipv4_subnets)"; validate_ipv4_subnets_csv "$subnets" || { echo -e "${RED}Invalid IPv4 CIDR list.${NC}"; pause; return; }; fi
  read -r -p "Enable IPv4 forwarding for routed VPN traffic? [Y/n]: " forward_ans; case "${forward_ans:-Y}" in y|Y|yes|YES) forward_ans="yes" ;; *) forward_ans="no" ;; esac
  echo; echo -e "${YELLOW}Plan:${NC}"; echo "  IPv4 egress IP: $egress_ip"; echo "  Out interface: $iface"; echo "  Scope: $scope"; echo "  Source subnets: ${subnets:-all outbound IPv4}"; echo "  Comment tag: $EGRESS_COMMENT"; echo "  Backup: /root/viptrue-iptables-backup-TIMESTAMP.rules"; echo "  Config: $EGRESS_CONF"; echo "  Default route: unchanged"; echo "  INPUT rules: none"; echo
  read -r -p "Apply IPv4 SNAT now? [y/N]: " apply_ans; case "$apply_ans" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac
  backup_iptables
  old_ipv6_enabled="$(get_conf_value IPV6_ENABLED)"; old_ipv6_addr="$(get_conf_value IPV6_EGRESS)"; old_ipv6_iface="$(get_conf_value IPV6_IFACE)"; old_ipv6_scope="$(get_conf_value IPV6_SCOPE)"; old_ipv6_subnets="$(get_conf_value IPV6_SUBNETS)"; old_ipv6_forward="$(get_conf_value IPV6_FORWARDING)"
  write_config "yes" "$egress_ip" "$iface" "$scope" "$subnets" "$forward_ans" "${old_ipv6_enabled:-no}" "${old_ipv6_addr:-}" "${old_ipv6_iface:-}" "${old_ipv6_scope:-}" "${old_ipv6_subnets:-}" "${old_ipv6_forward:-no}"
  if apply_config; then echo -e "${GREEN}IPv4 SNAT applied.${NC}"; else echo -e "${RED}Apply failed. Use Rollback / Disable if partial rules were created.${NC}"; fi
  read -r -p "Enable persistence after reboot? [Y/n]: " persist_ans; case "${persist_ans:-Y}" in y|Y|yes|YES) configure_persistence ;; *) echo "Persistence skipped." ;; esac
  pause
}

configure_ipv6_egress() {
  local egress_ip iface scope subnets ip_missing_ans apply_ans forward_ans persist_ans old_ipv4_enabled old_ipv4_addr old_ipv4_iface old_ipv4_scope old_ipv4_subnets old_ipv4_forward
  title; echo -e "${CYAN}Egress IP / SNAT Manager > Configure IPv6 Egress${NC}"; line
  ensure_root || return
  echo; echo -e "${YELLOW}IPv6 note:${NC} IPv6 egress only affects sites/apps that support IPv6."; echo "IPv6 NAT support depends on kernel/ip6tables nat availability."; echo; ip -6 -br addr show || true; echo
  read -r -p "IPv6 egress/source IP: " egress_ip; valid_ipv6 "$egress_ip" || { echo -e "${RED}Invalid IPv6 address.${NC}"; pause; return; }
  iface="$(detect_default_iface6 || detect_default_iface4 || true)"; read -r -p "Outgoing interface [$iface]: " iface; iface="${iface:-$(detect_default_iface6 || detect_default_iface4 || true)}"
  if [[ -z "$iface" ]] || ! valid_iface "$iface" || ! ip link show "$iface" >/dev/null 2>&1; then echo -e "${RED}Invalid or missing interface:${NC} ${iface:-empty}"; pause; return; fi
  if ! ipv6_exists_on_host "$egress_ip"; then echo -e "${YELLOW}Warning:${NC} $egress_ip is not currently assigned on this server."; read -r -p "Continue anyway? [y/N]: " ip_missing_ans; case "$ip_missing_ans" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac; fi
  echo; echo "Scope:"; echo "1. Custom IPv6 source subnet(s), recommended for VPN traffic"; echo "2. All outbound IPv6 traffic from this server"; read -r -p "Choice [1]: " scope; scope="${scope:-1}"
  if [[ "$scope" == "2" ]]; then scope="all"; subnets=""; echo -e "${YELLOW}Warning:${NC} all outbound IPv6 traffic will be SNATed on $iface."; else scope="vpn_subnets"; read -r -p "IPv6 source CIDRs [fd00::/8]: " subnets; subnets="${subnets:-fd00::/8}"; validate_ipv6_subnets_csv "$subnets" || { echo -e "${RED}Invalid IPv6 CIDR list.${NC}"; pause; return; }; fi
  read -r -p "Enable IPv6 forwarding for routed VPN traffic? [Y/n]: " forward_ans; case "${forward_ans:-Y}" in y|Y|yes|YES) forward_ans="yes" ;; *) forward_ans="no" ;; esac
  echo; echo -e "${YELLOW}Plan:${NC}"; echo "  IPv6 egress IP: $egress_ip"; echo "  Out interface: $iface"; echo "  Scope: $scope"; echo "  Source subnets: ${subnets:-all outbound IPv6}"; echo "  Comment tag: $EGRESS_COMMENT"; echo "  IPv4 config: kept separate"; echo
  read -r -p "Apply IPv6 SNAT now? [y/N]: " apply_ans; case "$apply_ans" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac
  backup_iptables
  old_ipv4_enabled="$(get_conf_value IPV4_ENABLED)"; old_ipv4_addr="$(get_conf_value IPV4_EGRESS)"; old_ipv4_iface="$(get_conf_value IPV4_IFACE)"; old_ipv4_scope="$(get_conf_value IPV4_SCOPE)"; old_ipv4_subnets="$(get_conf_value IPV4_SUBNETS)"; old_ipv4_forward="$(get_conf_value IPV4_FORWARDING)"
  write_config "${old_ipv4_enabled:-no}" "${old_ipv4_addr:-}" "${old_ipv4_iface:-}" "${old_ipv4_scope:-}" "${old_ipv4_subnets:-}" "${old_ipv4_forward:-no}" "yes" "$egress_ip" "$iface" "$scope" "$subnets" "$forward_ans"
  if apply_config; then echo -e "${GREEN}IPv6 SNAT applied.${NC}"; else echo -e "${RED}Apply failed. Use Rollback / Disable if partial rules were created.${NC}"; fi
  read -r -p "Enable persistence after reboot? [Y/n]: " persist_ans; case "${persist_ans:-Y}" in y|Y|yes|YES) configure_persistence ;; *) echo "Persistence skipped." ;; esac
  pause
}

test_egress() {
  local expected4 expected6 actual4 actual6 source4 source6
  title; echo -e "${CYAN}Egress IP / SNAT Manager > Test Egress${NC}"; line; echo
  expected4="$(get_conf_value IPV4_EGRESS)"; expected6="$(get_conf_value IPV6_EGRESS)"
  read -r -p "Expected IPv4 egress IP [$expected4]: " expected4; expected4="${expected4:-$(get_conf_value IPV4_EGRESS)}"
  read -r -p "Expected IPv6 egress IP [$expected6]: " expected6; expected6="${expected6:-$(get_conf_value IPV6_EGRESS)}"
  echo; actual4="$(detect_public_ip4)"; actual6="$(detect_public_ip6)"
  echo "Expected IPv4 egress IP: ${expected4:-not set}"; echo "Actual IPv4 egress IP:   $actual4"; if [[ -n "${expected4:-}" && "$actual4" == "$expected4" ]]; then echo "IPv4 Status: OK"; else echo "IPv4 Status: CHECK"; fi
  echo; echo "Expected IPv6 egress IP: ${expected6:-not set}"; echo "Actual IPv6 egress IP:   $actual6"; if [[ -n "${expected6:-}" && "$actual6" == "$expected6" ]]; then echo "IPv6 Status: OK"; else echo "IPv6 Status: CHECK"; fi
  echo; read -r -p "Test curl --interface for a specific IPv4? [${expected4:-none}]: " source4; source4="${source4:-${expected4:-}}"; if [[ -n "$source4" ]]; then echo "curl --interface $source4 -4 https://api.ipify.org"; curl --interface "$source4" -4fsS --max-time 10 https://api.ipify.org || true; echo; fi
  read -r -p "Test curl --interface for a specific IPv6? [${expected6:-none}]: " source6; source6="${source6:-${expected6:-}}"; if [[ -n "$source6" ]]; then echo "curl --interface $source6 -6 https://api64.ipify.org"; curl --interface "$source6" -6fsS --max-time 10 https://api64.ipify.org || true; echo; fi
  pause
}

rollback_disable() {
  local remove_conf
  title; echo -e "${CYAN}Egress IP / SNAT Manager > Rollback / Disable${NC}"; line
  ensure_root || return
  echo; echo "This removes only rules tagged with comment: $EGRESS_COMMENT"; echo "It does not touch UFW rules, INPUT rules, default routes, or manual rules."; echo
  read -r -p "Rollback VIPTrue Egress SNAT now? [y/N]: " remove_conf; case "$remove_conf" in y|Y|yes|YES) ;; *) echo "Cancelled."; pause; return ;; esac
  backup_iptables
  remove_managed_rules
  systemctl disable --now "$EGRESS_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$EGRESS_SERVICE"
  systemctl daemon-reload 2>/dev/null || true
  read -r -p "Remove $EGRESS_CONF too? [y/N]: " remove_conf; case "$remove_conf" in y|Y|yes|YES) rm -f "$EGRESS_CONF" ;; esac
  echo -e "${GREEN}Rollback complete.${NC}"
  echo; echo "Current egress after rollback:"; echo "  IPv4: $(detect_public_ip4)"; echo "  IPv6: $(detect_public_ip6)"
  pause
}

egress_snat_menu() {
  local choice
  while true; do
    title
    echo -e "${CYAN}Egress IP / SNAT Manager${NC}"
    line
    echo
    echo "For PasarGuard shared Core/Node setups:"
    echo "  - Xray sendThrough: good for one server with multiple hosts."
    echo "  - Server-level SNAT: good when each real server has its own second/floating IP."
    echo
    echo "1. Show current egress status"
    echo "2. Configure IPv4 egress IP"
    echo "3. Configure IPv6 egress"
    echo "4. Apply saved config / enable persistence"
    echo "5. Rollback / Disable"
    echo "6. Test egress"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-6]: " choice
    case "$choice" in
      1) show_egress_status ;;
      2) configure_ipv4_egress ;;
      3) configure_ipv6_egress ;;
      4) ensure_root || continue; backup_iptables; if apply_config; then echo -e "${GREEN}Saved config applied.${NC}"; configure_persistence; else echo -e "${RED}Apply failed.${NC}"; fi; pause ;;
      5) rollback_disable ;;
      6) test_egress ;;
      0) return 0 ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  --apply-config) apply_config ;;
  --flush-managed) remove_managed_rules ;;
  *) egress_snat_menu ;;
esac
