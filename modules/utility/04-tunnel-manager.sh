#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/ui.sh
source "$BASE_DIR/lib/ui.sh"

LAST_CHECKED="No diagnostics have been run yet."
LAST_ISSUE="Run a Tunnel Manager check first."
LAST_ACTION="Start with Preflight Checks."
LAST_SERVER_ACTION="Unknown."

HY2_WG_DIR="${VIPTRUE_HY2_WG_DIR:-/etc/viptrue-hy2-wg-forward}"
HY2_WG_CLIENT_DIR="$HY2_WG_DIR/clients"
HY2_WG_CERT_DIR="$HY2_WG_DIR/certs"
HY2_WG_LEGACY_DIR="$HY2_WG_DIR/legacy"
HY2_WG_ARCHIVE_DIR="$HY2_WG_DIR/archive"
HY2_WG_SERVICE_PREFIX="viptrue-hy2-wg"
HY2_LEGACY_DIR="${VIPTRUE_HYSTERIA_LEGACY_DIR:-/etc/hysteria}"
HY2_LEGACY_CONFIG="$HY2_LEGACY_DIR/config.yaml"
HY2_LEGACY_CERT="$HY2_LEGACY_DIR/server.crt"
HY2_LEGACY_KEY="$HY2_LEGACY_DIR/server.key"
HY2_SYSTEMD_SYSTEM_DIR="${VIPTRUE_SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
HY2_SYSTEMD_SEARCH_DIRS="${VIPTRUE_SYSTEMD_SEARCH_DIRS:-$HY2_SYSTEMD_SYSTEM_DIR /lib/systemd/system /usr/lib/systemd/system}"
HY2_DEFAULT_MASQUERADE_URL="https://www.bing.com/"
HY2_DEFAULT_LEGACY_SNI="bing.com"
HY2_LEGACY_SERVICE_NAME="${VIPTRUE_HYSTERIA_LEGACY_SERVICE:-hysteria-server.service}"
HY2_WG_SYNTHETIC_TMP_DIR="${VIPTRUE_HY2_WG_SYNTHETIC_TMP_DIR:-/tmp/viptrue-wg-synthetic}"
HY2_PROMPTED_PORT=""
HY2_WRITTEN_CONFIG=""

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

status_line() {
  local level="$1"
  local label="$2"
  local detail="${3:-}"
  local color="$NC"

  case "$level" in
    PASS) color="$GREEN" ;;
    WARN) color="$YELLOW" ;;
    FAIL) color="$RED" ;;
    INFO) color="$CYAN" ;;
  esac

  printf '%b[%s]%b %s' "$color" "$level" "$NC" "$label"
  if [[ -n "$detail" ]]; then
    printf ' - %s' "$detail"
  fi
  printf '\n'
}

pass_line() {
  status_line "PASS" "$1" "${2:-}"
}

warn_line() {
  status_line "WARN" "$1" "${2:-}"
}

fail_line() {
  status_line "FAIL" "$1" "${2:-}"
}

info_line() {
  status_line "INFO" "$1" "${2:-}"
}

set_summary() {
  LAST_CHECKED="$1"
  LAST_ISSUE="$2"
  LAST_ACTION="$3"
  LAST_SERVER_ACTION="$4"
}

print_summary() {
  echo
  line
  echo -e "${CYAN}Diagnostics Summary${NC}"
  echo "Checked: $LAST_CHECKED"
  echo "Likely issue: $LAST_ISSUE"
  echo "Suggested next action: $LAST_ACTION"
  echo "Server-side action needed: $LAST_SERVER_ACTION"
  line
}

install_hint() {
  local packages=("$@")

  if have_cmd apt-get; then
    printf 'apt-get install -y %s' "${packages[*]}"
  elif have_cmd dnf; then
    printf 'dnf install -y %s' "${packages[*]}"
  elif have_cmd yum; then
    printf 'yum install -y %s' "${packages[*]}"
  elif have_cmd pacman; then
    printf 'pacman -S --needed %s' "${packages[*]}"
  else
    printf 'install package(s): %s' "${packages[*]}"
  fi
}

check_command() {
  local cmd="$1"
  local pkg="$2"
  local hint

  if have_cmd "$cmd"; then
    pass_line "$cmd" "$(command -v "$cmd")"
  else
    hint="$(install_hint "$pkg")"
    warn_line "$cmd missing" "suggest: $hint"
  fi
}

ensure_root() {
  if [[ "$EUID" -eq 0 ]]; then
    return 0
  fi

  fail_line "root required for this action" "run the toolbox with sudo/root"
  return 1
}

require_cmd() {
  local cmd="$1"
  local pkg="$2"

  if have_cmd "$cmd"; then
    return 0
  fi

  fail_line "$cmd missing" "suggest: $(install_hint "$pkg")"
  return 1
}

valid_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

valid_ipv4() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

valid_cidr() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]
}

valid_iface() {
  [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "$prompt [$default]: " value
  printf '%s\n' "${value:-$default}"
}

read_os_name() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s\n' "${PRETTY_NAME:-Unknown Linux}"
  else
    uname -a
  fi
}

preflight_checks() {
  local route dns_ok public_hint

  title
  echo -e "${CYAN}Tunnel Manager > Preflight Checks${NC}"
  line
  echo

  info_line "OS" "$(read_os_name)"

  if [[ "$EUID" -eq 0 ]]; then
    pass_line "root status" "running as root"
  elif have_cmd sudo && sudo -n true 2>/dev/null; then
    pass_line "sudo status" "sudo is available without an interactive prompt"
  else
    warn_line "root/sudo status" "diagnostics can run, but setup commands need sudo/root"
  fi

  echo
  echo -e "${YELLOW}Core commands${NC}"
  check_command ip iproute2
  check_command ss iproute2
  check_command curl curl
  check_command ping iputils-ping
  check_command getent libc-bin
  check_command openssl openssl

  echo
  echo -e "${YELLOW}Tunnel-specific commands${NC}"
  check_command wg wireguard-tools
  check_command wg-quick wireguard-tools
  check_command iperf3 iperf3
  check_command tracepath iputils-tracepath
  check_command traceroute traceroute
  check_command ufw ufw
  check_command nc netcat-openbsd

  echo
  echo -e "${YELLOW}Network basics${NC}"
  if have_cmd ip; then
    route="$(ip route show default 2>/dev/null | head -n 1 || true)"
    if [[ -n "$route" ]]; then
      pass_line "default route" "$route"
    else
      fail_line "default route" "none found"
    fi
  else
    fail_line "default route" "ip command missing"
  fi

  public_hint="curl -4fsS --max-time 5 https://api.ipify.org"
  if have_cmd curl; then
    pass_line "public IP lookup command" "$public_hint"
  elif have_cmd wget; then
    pass_line "public IP lookup command" "wget can be used as fallback"
  else
    warn_line "public IP lookup command" "install curl or wget"
  fi

  dns_ok="no"
  if have_cmd getent && getent hosts example.com >/dev/null 2>&1; then
    dns_ok="yes"
  elif have_cmd dig && dig +short example.com >/dev/null 2>&1; then
    dns_ok="yes"
  fi

  if [[ "$dns_ok" == "yes" ]]; then
    pass_line "DNS resolution" "example.com resolves"
  else
    warn_line "DNS resolution" "could not confirm DNS with getent/dig"
  fi

  if have_cmd ping; then
    pass_line "ping availability" "latency tests can run"
  else
    warn_line "ping availability" "install iputils-ping"
  fi

  if have_cmd curl; then
    pass_line "curl availability" "HTTP diagnostics can run"
  else
    warn_line "curl availability" "install curl"
  fi

  if have_cmd ip; then
    pass_line "iproute2 availability" "ip command exists"
  else
    fail_line "iproute2 availability" "install iproute2 before GRE/WireGuard work"
  fi

  set_summary \
    "OS, privileges, command availability, default route, DNS, ping, curl, and iproute2." \
    "Missing commands or route/DNS failures are the most likely blockers." \
    "Install only the missing packages suggested above, then rerun Preflight Checks." \
    "Only package installation or network configuration fixes; no tunnel changes were made."
  print_summary
  pause
}

list_listeners() {
  local proto="$1"
  local port="$2"
  local output=""

  if have_cmd ss; then
    if [[ "$proto" == "tcp" ]]; then
      output="$(ss -H -ltnp 2>/dev/null | grep -E "[:.]${port}([[:space:]]|$)" || true)"
    else
      output="$(ss -H -lunp 2>/dev/null | grep -E "[:.]${port}([[:space:]]|$)" || true)"
    fi
  elif have_cmd netstat; then
    if [[ "$proto" == "tcp" ]]; then
      output="$(netstat -ltnp 2>/dev/null | grep -E "[:.]${port}([[:space:]]|$)" || true)"
    else
      output="$(netstat -lunp 2>/dev/null | grep -E "[:.]${port}([[:space:]]|$)" || true)"
    fi
  fi

  printf '%s\n' "$output"
}

check_local_listener() {
  local proto="$1"
  local port="$2"
  local output

  output="$(list_listeners "$proto" "$port")"
  if [[ -n "$output" ]]; then
    pass_line "local ${proto^^} listener on $port" "found"
    printf '%s\n' "$output"
  else
    warn_line "local ${proto^^} listener on $port" "not found"
  fi
}

ufw_port_status() {
  local port="$1"
  local proto="$2"
  local status

  if ! have_cmd ufw; then
    warn_line "UFW" "not installed"
    return
  fi

  status="$(ufw status 2>/dev/null || true)"
  if [[ -z "$status" ]]; then
    warn_line "UFW" "status unavailable; try with sudo/root"
    return
  fi

  if printf '%s\n' "$status" | grep -qi "inactive"; then
    warn_line "UFW" "installed but inactive"
    return
  fi

  if [[ "$proto" == "both" ]]; then
    if printf '%s\n' "$status" | grep -Eiq "(^|[[:space:]])${port}(/(tcp|udp))?([[:space:]]|$)"; then
      pass_line "UFW rule for $port" "matching rule appears in ufw status"
    else
      warn_line "UFW rule for $port" "active UFW, but no obvious allow rule found"
    fi
  elif printf '%s\n' "$status" | grep -Eiq "(^|[[:space:]])${port}(/${proto})?([[:space:]]|$)"; then
    pass_line "UFW rule for $port/$proto" "matching rule appears in ufw status"
  else
    warn_line "UFW rule for $port/$proto" "active UFW, but no obvious allow rule found"
  fi
}

port_checks() {
  local proto port proto_lower

  title
  echo -e "${CYAN}Tunnel Manager > Port Checks${NC}"
  line
  echo

  read -r -p "Protocol [tcp/udp/both]: " proto
  proto_lower="${proto:-both}"
  proto_lower="${proto_lower,,}"

  case "$proto_lower" in
    tcp|udp|both) ;;
    *)
      fail_line "protocol" "choose tcp, udp, or both"
      set_summary "Port protocol input." "Invalid protocol." "Rerun Port Checks with tcp, udp, or both." "No server-side change needed."
      print_summary
      pause
      return
      ;;
  esac

  read -r -p "Port number: " port
  if ! valid_port "$port"; then
    fail_line "port number" "must be 1-65535"
    set_summary "Port number input." "Invalid port." "Rerun Port Checks with a valid port number." "No server-side change needed."
    print_summary
    pause
    return
  fi

  if [[ "$proto_lower" == "tcp" || "$proto_lower" == "both" ]]; then
    check_local_listener tcp "$port"
  fi

  if [[ "$proto_lower" == "udp" || "$proto_lower" == "both" ]]; then
    check_local_listener udp "$port"
  fi

  echo
  ufw_port_status "$port" "$proto_lower"
  echo
  warn_line "remote reachability" "must be tested from another server or client outside this host"
  info_line "safe firewall note" "this check did not change UFW, iptables, nftables, or services"

  set_summary \
    "Local listener and UFW visibility for $proto_lower port $port." \
    "If no listener is shown, the service may not be running; if UFW lacks a rule, traffic may be blocked." \
    "Start the service or add a reviewed firewall allow rule, then test remotely from another server." \
    "Possibly yes: service start, firewall allow, or provider security-group change may be required."
  print_summary
  pause
}

num_ge() {
  local left="$1"
  local right="$2"

  have_cmd awk || return 1
  awk -v left="$left" -v right="$right" 'BEGIN { exit !(left >= right) }'
}

recommend_connection() {
  local loss="$1"
  local avg="$2"

  if [[ -z "$loss" ]]; then
    printf 'blocked / needs different tunnel'
    return
  fi

  if num_ge "$loss" 50; then
    printf 'blocked / needs different tunnel'
  elif num_ge "$loss" 10; then
    printf 'unstable'
  elif num_ge "$loss" 3; then
    printf 'acceptable'
  elif [[ -n "$avg" ]] && num_ge "$avg" 250; then
    printf 'unstable'
  elif [[ -n "$avg" ]] && num_ge "$avg" 150; then
    printf 'acceptable'
  else
    printf 'good'
  fi
}

iperf3_helper_preview() {
  local bind_ip peer_ip port duration bitrate

  bind_ip="$(prompt_default "Local bind IP or interface IP" "0.0.0.0")"
  peer_ip="$(prompt_default "Peer/server IP for client command" "PEER_TUNNEL_IP")"
  port="$(prompt_default "iperf3 port" "5201")"
  duration="$(prompt_default "Test duration seconds" "20")"
  bitrate="$(prompt_default "UDP bitrate preview" "10M")"

  if ! valid_port "$port"; then
    warn_line "iperf3 port" "invalid input; showing default 5201 instead"
    port="5201"
  fi

  echo
  echo -e "${YELLOW}iperf3 preview commands${NC}"
  cat <<EOF_IPERF
Server side:
  iperf3 -s -B $bind_ip -p $port

Client TCP:
  iperf3 -c $peer_ip -p $port -t $duration

Client TCP reverse:
  iperf3 -c $peer_ip -p $port -t $duration -R

Client UDP:
  iperf3 -c $peer_ip -p $port -u -b $bitrate -t $duration
EOF_IPERF
  echo
  info_line "iperf3 helper" "preview only; start server/client only on hosts you control"
}

quality_tests() {
  local target count ping_out loss avg recommendation trace_choice

  title
  echo -e "${CYAN}Tunnel Manager > Quality Tests${NC}"
  line
  echo

  read -r -p "Target IP/host for latency test: " target
  if [[ -z "${target// /}" ]]; then
    fail_line "target" "empty"
    set_summary "Quality test target input." "No target was provided." "Rerun Quality Tests with a tunnel peer or public test host." "No server-side change needed."
    print_summary
    pause
    return
  fi

  count="$(prompt_default "Ping count" "10")"
  if ! [[ "$count" =~ ^[0-9]+$ ]] || ((count < 1 || count > 100)); then
    warn_line "ping count" "invalid input; using 10"
    count="10"
  fi

  loss=""
  avg=""
  if have_cmd ping; then
    echo
    echo -e "${YELLOW}Latency and packet loss${NC}"
    ping_out="$(ping -c "$count" -W 2 "$target" 2>&1 || true)"
    printf '%s\n' "$ping_out"
    loss="$(printf '%s\n' "$ping_out" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p' | tail -n 1)"
    avg="$(printf '%s\n' "$ping_out" | sed -nE 's#.*= [0-9.]+/([0-9.]+)/.*#\1#p' | tail -n 1)"
  else
    fail_line "ping" "missing; install iputils-ping"
  fi

  echo
  read -r -p "Run route trace if traceroute/tracepath exists? [Y/n]: " trace_choice
  trace_choice="${trace_choice:-Y}"
  case "$trace_choice" in
    y|Y|yes|YES)
      if have_cmd tracepath; then
        echo
        echo -e "${YELLOW}Route trace via tracepath${NC}"
        tracepath -m 12 "$target" || true
      elif have_cmd traceroute; then
        echo
        echo -e "${YELLOW}Route trace via traceroute${NC}"
        traceroute "$target" || true
      else
        warn_line "route trace" "install tracepath or traceroute"
      fi
      ;;
  esac

  echo
  read -r -p "Show iperf3 server/client preview commands? [Y/n]: " trace_choice
  trace_choice="${trace_choice:-Y}"
  case "$trace_choice" in
    y|Y|yes|YES) iperf3_helper_preview ;;
  esac

  recommendation="$(recommend_connection "$loss" "$avg")"
  echo
  echo -e "${GREEN}Final recommendation:${NC} $recommendation"

  set_summary \
    "Ping latency/loss, optional route trace, and optional iperf3 preview for $target." \
    "Packet loss, high latency, missing trace tools, or blocked ICMP can make the tunnel unreliable." \
    "Use the recommendation above; if unstable or blocked, test another transport such as WireGuard, Hysteria2, or TLS/SNI." \
    "Maybe: peer-side iperf3, firewall, provider routing, or tunnel protocol changes may be needed."
  print_summary
  pause
}

gre_helper() {
  local local_pub remote_pub local_tun remote_tun ifname mtu confirm

  title
  echo -e "${CYAN}Tunnel Manager > GRE Helper${NC}"
  line
  echo
  warn_line "GRE filtering" "many providers/networks block protocol 47 even when TCP/UDP works"
  echo

  local_pub="$(prompt_default "Local public IPv4" "LOCAL_PUBLIC_IP")"
  remote_pub="$(prompt_default "Remote public IPv4" "REMOTE_PUBLIC_IP")"
  local_tun="$(prompt_default "Local tunnel CIDR" "10.99.0.1/30")"
  remote_tun="$(prompt_default "Remote tunnel CIDR" "10.99.0.2/30")"
  ifname="$(prompt_default "Interface name" "gre-viptrue")"
  mtu="$(prompt_default "MTU" "1476")"

  if [[ "$local_pub" != "LOCAL_PUBLIC_IP" ]] && ! valid_ipv4 "$local_pub"; then
    fail_line "local public IPv4" "invalid"
    pause
    return
  fi

  if [[ "$remote_pub" != "REMOTE_PUBLIC_IP" ]] && ! valid_ipv4 "$remote_pub"; then
    fail_line "remote public IPv4" "invalid"
    pause
    return
  fi

  if [[ "$local_tun" != "10.99.0.1/30" ]] && ! valid_cidr "$local_tun"; then
    fail_line "local tunnel CIDR" "use IPv4/CIDR like 10.99.0.1/30"
    pause
    return
  fi

  if [[ "$remote_tun" != "10.99.0.2/30" ]] && ! valid_cidr "$remote_tun"; then
    fail_line "remote tunnel CIDR" "use IPv4/CIDR like 10.99.0.2/30"
    pause
    return
  fi

  if ! valid_iface "$ifname"; then
    fail_line "interface name" "use 1-15 characters: letters, numbers, dot, underscore, colon, dash"
    pause
    return
  fi

  if ! [[ "$mtu" =~ ^[0-9]+$ ]] || ((mtu < 576 || mtu > 9000)); then
    fail_line "MTU" "use a number between 576 and 9000"
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Preview: run on this server${NC}"
  cat <<EOF_GRE_LOCAL
modprobe ip_gre
ip tunnel del $ifname 2>/dev/null || true
ip tunnel add $ifname mode gre remote $remote_pub local $local_pub ttl 255
ip link set $ifname mtu $mtu
ip addr add $local_tun dev $ifname
ip link set $ifname up
ip addr show $ifname
EOF_GRE_LOCAL

  echo
  echo -e "${YELLOW}Preview: run on the peer server${NC}"
  cat <<EOF_GRE_REMOTE
modprobe ip_gre
ip tunnel del $ifname 2>/dev/null || true
ip tunnel add $ifname mode gre remote $local_pub local $remote_pub ttl 255
ip link set $ifname mtu $mtu
ip addr add $remote_tun dev $ifname
ip link set $ifname up
ip addr show $ifname
EOF_GRE_REMOTE

  echo
  echo -e "${YELLOW}Persistence note${NC}"
  echo "Create a reviewed systemd oneshot service after runtime testing passes."
  echo "Do not enable persistence until both sides work and SSH access is safe."
  echo "Suggested service actions after review:"
  echo "  systemctl daemon-reload"
  echo "  systemctl enable --now viptrue-gre-$ifname.service"

  echo
  read -r -p "Type APPLY to run the runtime GRE commands on this server only: " confirm
  if [[ "$confirm" == "APPLY" ]]; then
    ensure_root || { pause; return; }
    require_cmd ip iproute2 || { pause; return; }
    if have_cmd modprobe; then
      modprobe ip_gre 2>/dev/null || true
    fi
    ip tunnel del "$ifname" 2>/dev/null || true
    ip tunnel add "$ifname" mode gre remote "$remote_pub" local "$local_pub" ttl 255
    ip link set "$ifname" mtu "$mtu"
    ip addr add "$local_tun" dev "$ifname"
    ip link set "$ifname" up
    pass_line "runtime GRE applied" "$ifname"
    ip addr show "$ifname" || true
  else
    info_line "runtime GRE" "not applied"
  fi

  set_summary \
    "GRE command preview for both sides, MTU guidance, optional runtime apply prompt." \
    "GRE may be blocked by the provider/network, or one side may have wrong public/tunnel IP values." \
    "Apply only after reviewing both sides; then test ping and UDP traffic across the tunnel." \
    "Yes: both servers need matching GRE configuration; provider filtering may require a different tunnel."
  print_summary
  pause
}

wireguard_helper() {
  local local_addr peer_addr listen_port endpoint peer_port

  title
  echo -e "${CYAN}Tunnel Manager > WireGuard Helper${NC}"
  line
  echo

  if have_cmd wg; then
    pass_line "wg command" "$(command -v wg)"
    echo
    echo -e "${YELLOW}WireGuard status${NC}"
    wg show || true
  else
    warn_line "wg command" "suggest: $(install_hint wireguard-tools)"
  fi

  if have_cmd wg-quick; then
    pass_line "wg-quick command" "$(command -v wg-quick)"
  else
    warn_line "wg-quick command" "suggest: $(install_hint wireguard-tools)"
  fi

  if [[ -d /sys/module/wireguard ]] || grep -q '^wireguard ' /proc/modules 2>/dev/null; then
    pass_line "kernel support" "wireguard module is loaded"
  elif have_cmd modinfo && modinfo wireguard >/dev/null 2>&1; then
    pass_line "kernel support" "wireguard module is available"
  elif have_cmd modprobe && modprobe -n wireguard >/dev/null 2>&1; then
    pass_line "kernel support" "modprobe dry-run can find wireguard"
  else
    warn_line "kernel support" "wireguard module not confirmed"
  fi

  echo
  echo -e "${YELLOW}Point-to-point preview${NC}"
  local_addr="$(prompt_default "This server tunnel address" "10.88.0.1/30")"
  peer_addr="$(prompt_default "Peer tunnel address" "10.88.0.2/30")"
  listen_port="$(prompt_default "This server UDP listen port" "51820")"
  endpoint="$(prompt_default "Peer endpoint host/IP" "PEER_PUBLIC_IP")"
  peer_port="$(prompt_default "Peer endpoint UDP port" "$listen_port")"

  if ! valid_port "$listen_port" || ! valid_port "$peer_port"; then
    fail_line "WireGuard port" "ports must be 1-65535"
    pause
    return
  fi

  cat <<EOF_WG
This server /etc/wireguard/wg0.conf preview:
  [Interface]
  Address = $local_addr
  ListenPort = $listen_port
  PrivateKey = <LOCAL_PRIVATE_KEY_ON_THIS_SERVER>

  [Peer]
  PublicKey = <PEER_PUBLIC_KEY>
  AllowedIPs = ${peer_addr%/*}/32
  Endpoint = $endpoint:$peer_port
  PersistentKeepalive = 25

Peer server preview swaps the addresses and keys:
  Address = $peer_addr
  AllowedIPs = ${local_addr%/*}/32
  Endpoint = THIS_SERVER_PUBLIC_IP:$listen_port

Safety:
  No private keys were generated, stored, or printed by this helper.
  Review firewall and provider UDP rules before starting wg-quick.
EOF_WG

  set_summary \
    "WireGuard command/kernel diagnostics and point-to-point config preview." \
    "Missing wireguard-tools/kernel support or blocked UDP are common blockers." \
    "Install wireguard-tools if missing, create keys only on the server, then test with non-production peers." \
    "Yes: both servers need keys, peer configs, UDP firewall/provider rules, and wg-quick service decisions."
  print_summary
  pause
}

hysteria2_helper() {
  local port listener

  title
  echo -e "${CYAN}Tunnel Manager > Hysteria2 Helper${NC}"
  line
  echo
  echo "Rule: do not use UDP port 443 for Hysteria2 in this toolbox."
  echo "Suggested non-443 UDP ports: 8080, 8443, 2087, or another reviewed port."
  echo

  port="$(prompt_default "UDP port to evaluate" "8080")"
  if ! valid_port "$port"; then
    fail_line "Hysteria2 port" "ports must be 1-65535"
    pause
    return
  fi

  if [[ "$port" == "443" ]]; then
    fail_line "Hysteria2 port 443" "forbidden by user rule; choose 8080, 8443, 2087, or another non-443 UDP port"
    set_summary \
      "Hysteria2 port policy." \
      "Port 443 was selected, which is forbidden for Hysteria2 in this toolbox." \
      "Rerun with a non-443 UDP port such as 8080 or 8443." \
      "Yes: update planned Hysteria2/firewall/provider rules to a non-443 UDP port."
    print_summary
    pause
    return
  fi

  if have_cmd hysteria; then
    pass_line "hysteria command" "$(command -v hysteria)"
    hysteria version 2>/dev/null || true
  else
    warn_line "hysteria command" "not installed; diagnostic only in this batch"
  fi

  listener="$(list_listeners udp "$port")"
  if [[ -n "$listener" ]]; then
    pass_line "UDP listener on $port" "found"
    printf '%s\n' "$listener"
  else
    warn_line "UDP listener on $port" "not found"
  fi

  ufw_port_status "$port" udp
  echo
  echo -e "${YELLOW}Diagnostic commands to run after reviewing config${NC}"
  cat <<EOF_HY2
Check service:
  systemctl status hysteria-server.service --no-pager -l

Check UDP listener:
  ss -lunp | grep ':$port'

Watch packets:
  tcpdump -ni any udp port $port
EOF_HY2

  set_summary \
    "Hysteria2 command presence, non-443 port policy, local UDP listener, and UFW visibility." \
    "Missing hysteria binary, no UDP listener, blocked firewall, or accidental 443 usage can block Hysteria2." \
    "Use a non-443 UDP port, then configure and test Hysteria2 only on servers you control." \
    "Yes: Hysteria2 service, UDP firewall/provider rules, and peer/client config must match."
  print_summary
  pause
}

valid_profile_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]
}

yaml_quote() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/'/''/g")"
  printf "'%s'" "$escaped"
}

yaml_double_quote() {
  local escaped
  escaped="${1//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '"%s"' "$escaped"
}

prompt_secret_required() {
  local prompt="$1"
  local value

  while true; do
    read -r -s -p "$prompt: " value
    echo
    if [[ -n "${value// /}" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    fail_line "$prompt" "value is required"
  done
}

prompt_yes_no_value() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "$prompt [$default]: " value
  value="${value:-$default}"
  case "$value" in
    y|Y|yes|YES|true|TRUE) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

detect_public_ip() {
  local ip

  if have_cmd curl; then
    ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi

  if have_cmd hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi

  printf 'IRAN_PUBLIC_IP\n'
}

hy2_prompt_non443_port() {
  local label="$1"
  local default="$2"
  local port

  port="$(prompt_default "$label" "$default")"
  if ! valid_port "$port"; then
    fail_line "$label" "ports must be 1-65535"
    return 1
  fi

  if [[ "$port" == "443" ]]; then
    fail_line "$label" "UDP port 443 is forbidden for Hysteria2; choose another port"
    return 1
  fi

  HY2_PROMPTED_PORT="$port"
}

hy2_wg_service_name() {
  local profile="$1"

  printf '%s-%s.service\n' "$HY2_WG_SERVICE_PREFIX" "$profile"
}

hy2_bin_path() {
  if have_cmd hysteria; then
    command -v hysteria
  else
    printf '/usr/local/bin/hysteria\n'
  fi
}

ensure_hysteria2_ready() {
  local install

  if have_cmd hysteria; then
    pass_line "hysteria command" "$(command -v hysteria)"
    hysteria version 2>/dev/null || true
    return 0
  fi

  warn_line "hysteria command" "not installed"
  echo "Suggested installer:"
  echo "  curl -fsSL https://get.hy2.sh/ | bash"
  echo
  read -r -p "Install Hysteria2 now? [y/N]: " install
  case "$install" in
    y|Y|yes|YES)
      require_cmd curl curl || return 1
      curl -fsSL https://get.hy2.sh/ | bash
      ;;
    *)
      fail_line "hysteria command" "install Hysteria2 before creating services"
      return 1
      ;;
  esac

  if have_cmd hysteria; then
    pass_line "hysteria command" "$(command -v hysteria)"
    return 0
  fi

  fail_line "hysteria command" "installer finished but hysteria is still not in PATH"
  return 1
}

ensure_hy2_wg_dirs() {
  mkdir -p "$HY2_WG_CLIENT_DIR" "$HY2_WG_CERT_DIR" "$HY2_WG_LEGACY_DIR" "$HY2_WG_ARCHIVE_DIR"
  chmod 700 "$HY2_WG_DIR" "$HY2_WG_CLIENT_DIR" "$HY2_WG_CERT_DIR" "$HY2_WG_LEGACY_DIR" "$HY2_WG_ARCHIVE_DIR" 2>/dev/null || true
}

backup_existing_file() {
  local path="$1"
  local backup

  if [[ -e "$path" ]]; then
    backup="${path}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "$backup"
    pass_line "backup created" "$backup"
  fi
}

hy2_wg_print_firewall_notes() {
  local port

  echo
  echo -e "${YELLOW}Firewall notes${NC}"
  for port in "$@"; do
    echo "  ufw allow $port/udp"
    echo "  provider/security-group: allow UDP $port"
  done
}

hy2_wg_apply_ufw_rules() {
  local apply port

  hy2_wg_print_firewall_notes "$@"
  echo
  read -r -p "Apply UFW allow rules now if UFW is active? [y/N]: " apply
  case "$apply" in
    y|Y|yes|YES)
      if ! have_cmd ufw; then
        warn_line "UFW" "not installed; apply provider firewall rules manually"
        return 0
      fi

      if ! ufw status 2>/dev/null | grep -qi active; then
        warn_line "UFW" "not active; provider firewall may still need rules"
        return 0
      fi

      for port in "$@"; do
        ufw allow "$port/udp"
      done
      ;;
    *) info_line "UFW" "no firewall changes applied" ;;
  esac
}

hy2_wg_write_foreign_config() {
  local listen_port="$1"
  local auth_pass="$2"
  local obfs_pass="$3"
  local tls_mode="$4"
  local cert_path="$5"
  local key_path="$6"
  local masquerade_url="${7:-$HY2_DEFAULT_MASQUERADE_URL}"
  local config_path="${8:-$HY2_WG_DIR/foreign-server.yaml}"
  local auth_q obfs_q cert_q key_q masquerade_q

  auth_q="$(yaml_quote "$auth_pass")"
  obfs_q="$(yaml_quote "$obfs_pass")"
  cert_q="$(yaml_quote "$cert_path")"
  key_q="$(yaml_quote "$key_path")"
  masquerade_q="$(yaml_quote "$masquerade_url")"

  backup_existing_file "$config_path"
  {
    echo "listen: :$listen_port"
    echo
    echo "tls:"
    echo "  cert: $cert_q"
    echo "  key: $key_q"
    if [[ "$tls_mode" == "self-signed" ]]; then
      echo "  sniGuard: disable"
    fi
    echo
    echo "auth:"
    echo "  type: password"
    echo "  password: $auth_q"
    echo
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: $obfs_q"
    if [[ -n "${masquerade_url// /}" ]]; then
      echo
      echo "masquerade:"
      echo "  type: proxy"
      echo "  proxy:"
      echo "    url: $masquerade_q"
      echo "    rewriteHost: true"
    fi
    echo
    echo "disableUDP: false"
    echo "udpIdleTimeout: 60s"
  } > "$config_path"
  chmod 600 "$config_path"

  HY2_WRITTEN_CONFIG="$config_path"
}

hy2_wg_write_legacy_proven_config() {
  local listen_port="$1"
  local auth_pass="$2"
  local obfs_pass="$3"
  local cert_path="$4"
  local key_path="$5"
  local masquerade_url="$6"
  local auth_q obfs_q

  auth_q="$(yaml_double_quote "$auth_pass")"
  obfs_q="$(yaml_double_quote "$obfs_pass")"
  backup_existing_file "$HY2_LEGACY_CONFIG"
  {
    echo "listen: :$listen_port"
    echo
    echo "tls:"
    echo "  cert: $cert_path"
    echo "  key: $key_path"
    echo "  sniGuard: disable"
    echo
    echo "auth:"
    echo "  type: password"
    echo "  password: $auth_q"
    echo
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: $obfs_q"
    echo
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: $masquerade_url"
    echo "    rewriteHost: true"
    echo
    echo "disableUDP: false"
    echo "udpIdleTimeout: 60s"
  } > "$HY2_LEGACY_CONFIG"
  chmod 600 "$HY2_LEGACY_CONFIG"

  HY2_WRITTEN_CONFIG="$HY2_LEGACY_CONFIG"
}

hy2_wg_generate_self_signed_cert() {
  local cert_path="$1"
  local key_path="$2"
  local cert_cn="$3"
  local cert_subject

  require_cmd openssl openssl || return 1
  backup_existing_file "$cert_path"
  backup_existing_file "$key_path"
  cert_subject="/CN=$cert_cn"
  if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || -n "${MSYSTEM:-}" ]]; then
    cert_subject="//CN=$cert_cn"
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$key_path" \
    -out "$cert_path" \
    -days 3650 \
    -subj "$cert_subject" >/dev/null 2>&1
  chmod 600 "$key_path"
  chmod 644 "$cert_path"
}

hy2_wg_write_service() {
  local service_name="$1"
  local mode="$2"
  local config_path="$3"
  local description="$4"
  local hy2_bin service_path

  hy2_bin="$(hy2_bin_path)"
  service_path="$HY2_SYSTEMD_SYSTEM_DIR/$service_name"
  backup_existing_file "$service_path"

  cat > "$service_path" <<EOF_SERVICE
[Unit]
Description=$description
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$hy2_bin $mode --config $config_path
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  chmod 644 "$service_path"
}

hy2_wg_start_service_if_requested() {
  local service_name="$1"
  local start_now="$2"

  require_cmd systemctl systemd || return 1
  systemctl daemon-reload

  if [[ "$start_now" == "true" ]]; then
    systemctl enable --now "$service_name"
    sleep 1
  else
    info_line "$service_name" "written but not started"
  fi
}

hy2_wg_foreign_post_tests() {
  local service_name="$1"
  local listen_port="$2"
  local wg_iface="$3"
  local wg_port="$4"

  echo
  line
  echo -e "${CYAN}Foreign Server Post-Setup Tests${NC}"

  if have_cmd systemctl && systemctl is-active --quiet "$service_name"; then
    pass_line "$service_name" "active"
  else
    fail_line "$service_name" "not active or systemctl unavailable"
  fi

  check_local_listener udp "$listen_port"

  if have_cmd ip && ip link show "$wg_iface" >/dev/null 2>&1; then
    pass_line "WireGuard interface $wg_iface" "exists"
  else
    fail_line "WireGuard interface $wg_iface" "not found"
  fi

  check_local_listener udp "$wg_port"

  echo
  echo -e "${YELLOW}WireGuard status${NC}"
  if have_cmd wg; then
    wg show "$wg_iface" 2>/dev/null || wg show || true
    echo
    echo -e "${YELLOW}Latest handshakes${NC}"
    wg show "$wg_iface" latest-handshakes 2>/dev/null || true
    echo
    echo -e "${YELLOW}Transfer stats${NC}"
    wg show "$wg_iface" transfer 2>/dev/null || true
  else
    warn_line "wg command" "suggest: $(install_hint wireguard-tools)"
  fi
}

hy2_wg_legacy_proven_post_tests() {
  local service_name="$1"
  local listen_port="$2"
  local wg_iface="$3"
  local wg_port="$4"
  local cert_cn="$5"

  echo
  line
  echo -e "${CYAN}Legacy Proven Foreign Mode Post-Setup Tests${NC}"

  if have_cmd systemctl && systemctl is-active --quiet "$service_name"; then
    pass_line "Hysteria service active" "$service_name"
  else
    fail_line "Hysteria service active" "$service_name not active or systemctl unavailable"
  fi

  check_local_listener udp "$listen_port"
  pass_line "config path" "$HY2_LEGACY_CONFIG"
  pass_line "cert path" "$HY2_LEGACY_CERT"
  pass_line "key path" "$HY2_LEGACY_KEY"

  if have_cmd ip && ip link show "$wg_iface" >/dev/null 2>&1; then
    pass_line "WireGuard interface exists" "$wg_iface"
  else
    fail_line "WireGuard interface exists" "$wg_iface not found"
  fi

  check_local_listener udp "$wg_port"
  echo
  echo "Now configure Iran client profile with SNI $cert_cn, insecure TLS yes, and set PasarGuard endpoint to IRAN_IP:IRAN_PORT."
}

hy2_wg_setup_foreign_server() {
  local listen_port auth_pass obfs_pass tls_choice cert_path key_path cert_cn
  local wg_port wg_iface confirm start_now service_name config_path tls_mode

  title
  echo -e "${CYAN}Hysteria2 OBFS -> WireGuard Forward > Foreign Server Mode${NC}"
  line
  echo

  hy2_prompt_non443_port "Hysteria listen UDP port" "8080" || {
    set_summary \
      "Foreign Hysteria2 listen port." \
      "UDP port 443 or an invalid port was refused." \
      "Rerun Foreign Server Mode with a non-443 UDP port such as 8080 or 8443." \
      "No server-side change was made."
    print_summary
    pause
    return
  }
  listen_port="$HY2_PROMPTED_PORT"

  auth_pass="$(prompt_secret_required "Auth password")"
  obfs_pass="$(prompt_secret_required "OBFS salamander password")"

  echo
  echo "TLS mode:"
  echo "1. Self-signed/insecure for private tunnel"
  echo "2. Existing certificate and key paths"
  read -r -p "Select TLS mode [1-2]: " tls_choice
  case "$tls_choice" in
    2)
      tls_mode="existing"
      read -r -p "Existing cert path: " cert_path
      read -r -p "Existing key path: " key_path
      if [[ ! -r "$cert_path" || ! -r "$key_path" ]]; then
        fail_line "TLS cert/key" "both paths must exist and be readable"
        pause
        return
      fi
      ;;
    *)
      tls_mode="self-signed"
      cert_cn="$(prompt_default "Self-signed cert CN/SNI placeholder" "viptrue-private-tunnel.local")"
      cert_cn="${cert_cn//\//-}"
      cert_path="$HY2_WG_CERT_DIR/foreign-server.crt"
      key_path="$HY2_WG_CERT_DIR/foreign-server.key"
      ;;
  esac

  wg_port="$(prompt_default "WireGuard local UDP port" "51820")"
  if ! valid_port "$wg_port"; then
    fail_line "WireGuard local UDP port" "ports must be 1-65535"
    pause
    return
  fi

  wg_iface="$(prompt_default "WireGuard interface name" "wg0")"
  if ! valid_iface "$wg_iface"; then
    fail_line "WireGuard interface name" "invalid interface name"
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Plan${NC}"
  echo "Config directory: $HY2_WG_DIR"
  echo "Hysteria UDP listen: $listen_port"
  echo "WireGuard target on this foreign server: 127.0.0.1:$wg_port ($wg_iface)"
  echo "Existing files will be backed up before overwrite."
  echo "Firewall command preview: ufw allow $listen_port/udp"
  echo
  read -r -p "Create foreign Hysteria2 config and systemd service now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      info_line "foreign setup" "cancelled before writing files"
      set_summary \
        "Foreign server Hysteria2 OBFS WireGuard plan." \
        "Setup was cancelled before writing files." \
        "Rerun Foreign Server Mode when ready to create the config/service." \
        "No server-side change was made."
      print_summary
      pause
      return
      ;;
  esac

  ensure_root || { pause; return; }
  ensure_hysteria2_ready || { pause; return; }
  ensure_hy2_wg_dirs

  if [[ "$tls_mode" == "self-signed" ]]; then
    hy2_wg_generate_self_signed_cert "$cert_path" "$key_path" "$cert_cn" || { pause; return; }
  fi

  service_name="$(hy2_wg_service_name "foreign")"
  hy2_wg_write_foreign_config "$listen_port" "$auth_pass" "$obfs_pass" "$tls_mode" "$cert_path" "$key_path"
  config_path="$HY2_WRITTEN_CONFIG"
  hy2_wg_write_service "$service_name" "server" "$config_path" "VIPTrue Hysteria2 OBFS WireGuard foreign server"
  {
    echo "wg_iface=$wg_iface"
    echo "wg_port=$wg_port"
  } > "$HY2_WG_DIR/foreign.meta"
  chmod 600 "$HY2_WG_DIR/foreign.meta" 2>/dev/null || true

  start_now="$(prompt_yes_no_value "Enable and start $service_name now?" "Y")"
  hy2_wg_start_service_if_requested "$service_name" "$start_now" || { pause; return; }
  hy2_wg_apply_ufw_rules "$listen_port"
  hy2_wg_foreign_post_tests "$service_name" "$listen_port" "$wg_iface" "$wg_port"

  set_summary \
    "Foreign Hysteria2 server config, service, firewall note, service/listener checks, and WireGuard status." \
    "Failures usually mean Hysteria2 is not active, UDP is blocked, or WireGuard is not listening locally." \
    "Fix the failed layer, then connect one PasarGuard test peer through the Iran endpoint." \
    "Yes: foreign server service/firewall/WireGuard may need action."
  print_summary
  pause
}

hy2_wg_setup_legacy_proven_foreign_server() {
  local listen_port auth_pass obfs_pass cert_cn masquerade_url wg_iface wg_port
  local confirm keep_cert start_now service_name config_path meta_path

  title
  echo -e "${CYAN}Hysteria2 OBFS -> WireGuard Forward > Legacy Proven Foreign Mode${NC}"
  line
  echo

  hy2_prompt_non443_port "Hysteria UDP listen port" "2087" || {
    set_summary \
      "Legacy proven Hysteria2 listen port." \
      "UDP port 443 or an invalid port was refused." \
      "Rerun Legacy Proven Foreign Mode with a non-443 UDP port such as 2087." \
      "No server-side change was made."
    print_summary
    pause
    return
  }
  listen_port="$HY2_PROMPTED_PORT"

  auth_pass="$(prompt_secret_required "Auth password")"
  obfs_pass="$(prompt_secret_required "OBFS salamander password")"
  cert_cn="$(prompt_default "Certificate CN/SNI" "$HY2_DEFAULT_LEGACY_SNI")"
  cert_cn="${cert_cn:-$HY2_DEFAULT_LEGACY_SNI}"
  cert_cn="${cert_cn//\//-}"
  masquerade_url="$(prompt_default "Masquerade proxy URL" "$HY2_DEFAULT_MASQUERADE_URL")"
  masquerade_url="${masquerade_url:-$HY2_DEFAULT_MASQUERADE_URL}"

  wg_iface="$(prompt_default "WireGuard interface name" "wg0")"
  if ! valid_iface "$wg_iface"; then
    fail_line "WireGuard interface name" "invalid interface name"
    pause
    return
  fi

  wg_port="$(prompt_default "WireGuard local UDP port" "51820")"
  if ! valid_port "$wg_port"; then
    fail_line "WireGuard local UDP port" "ports must be 1-65535"
    pause
    return
  fi

  service_name="$HY2_LEGACY_SERVICE_NAME"
  echo
  echo -e "${YELLOW}Plan${NC}"
  echo "Legacy directory: $HY2_LEGACY_DIR"
  echo "Config path: $HY2_LEGACY_CONFIG"
  echo "Cert/key: $HY2_LEGACY_CERT / $HY2_LEGACY_KEY"
  echo "Hysteria UDP listen: $listen_port"
  echo "Certificate CN/SNI: $cert_cn"
  echo "Masquerade proxy URL: $masquerade_url"
  echo "sniGuard: disable"
  echo "OBFS: salamander"
  echo "Service: $service_name"
  echo "WireGuard target on this foreign server: 127.0.0.1:$wg_port ($wg_iface)"
  echo "Existing files will be backed up before overwrite or regeneration."
  echo "Firewall command preview: ufw allow $listen_port/udp"
  echo
  read -r -p "Create legacy proven Hysteria2 config and service now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      info_line "legacy proven setup" "cancelled before writing files"
      set_summary \
        "Legacy proven foreign server setup plan." \
        "Setup was cancelled before writing files." \
        "Rerun Legacy Proven Foreign Mode when ready to create /etc/hysteria config/service." \
        "No server-side change was made."
      print_summary
      pause
      return
      ;;
  esac

  ensure_root || { pause; return; }
  ensure_hysteria2_ready || { pause; return; }
  mkdir -p "$HY2_LEGACY_DIR" "$HY2_SYSTEMD_SYSTEM_DIR"
  chmod 700 "$HY2_LEGACY_DIR" 2>/dev/null || true

  if [[ -f "$HY2_LEGACY_CERT" && -f "$HY2_LEGACY_KEY" ]]; then
    read -r -p "Existing cert/key found. Keep existing cert/key? [Y/n]: " keep_cert
    keep_cert="${keep_cert:-Y}"
    case "$keep_cert" in
      y|Y|yes|YES) pass_line "cert/key" "kept existing files" ;;
      *) hy2_wg_generate_self_signed_cert "$HY2_LEGACY_CERT" "$HY2_LEGACY_KEY" "$cert_cn" || { pause; return; } ;;
    esac
  else
    hy2_wg_generate_self_signed_cert "$HY2_LEGACY_CERT" "$HY2_LEGACY_KEY" "$cert_cn" || { pause; return; }
  fi

  hy2_wg_write_legacy_proven_config "$listen_port" "$auth_pass" "$obfs_pass" "$HY2_LEGACY_CERT" "$HY2_LEGACY_KEY" "$masquerade_url"
  config_path="$HY2_WRITTEN_CONFIG"
  hy2_wg_write_service "$service_name" "server" "$config_path" "VIPTrue Hysteria2 legacy proven foreign server"
  meta_path="$HY2_LEGACY_DIR/viptrue.meta"
  {
    echo "profile=legacy-proven-foreign"
    echo "cert_cn=$cert_cn"
    echo "masquerade_url=$masquerade_url"
    echo "wg_iface=$wg_iface"
    echo "wg_port=$wg_port"
  } > "$meta_path"
  chmod 600 "$meta_path" 2>/dev/null || true

  start_now="$(prompt_yes_no_value "Enable and start $service_name now?" "Y")"
  hy2_wg_start_service_if_requested "$service_name" "$start_now" || { pause; return; }
  hy2_wg_apply_ufw_rules "$listen_port"
  hy2_wg_legacy_proven_post_tests "$service_name" "$listen_port" "$wg_iface" "$wg_port" "$cert_cn"

  set_summary \
    "Legacy proven /etc/hysteria config, self-signed TLS, systemd service, firewall note, and post-setup tests." \
    "Failures usually mean Hysteria2 is not active, UDP is blocked, WireGuard is missing, or the listener/port does not match." \
    "Configure Iran client profile with the shown SNI, insecure TLS yes, matching auth/OBFS, and WireGuard forwarding." \
    "Yes: foreign server service/firewall/WireGuard and Iran client endpoint configuration are needed."
  print_summary
  pause
}

hy2_wg_iran_port_in_existing_config() {
  local port="$1"

  [[ -d "$HY2_WG_CLIENT_DIR" ]] || return 1
  grep -R -- "listen: 0.0.0.0:$port" "$HY2_WG_CLIENT_DIR" >/dev/null 2>&1
}

hy2_wg_port_already_selected() {
  local port="$1"
  shift
  local selected

  for selected in "$@"; do
    if [[ "$selected" == "$port" ]]; then
      return 0
    fi
  done

  return 1
}

hy2_wg_write_client_config() {
  local profile="$1"
  local foreign_host="$2"
  local foreign_port="$3"
  local iran_port="$4"
  local remote_wg_host="$5"
  local remote_wg_port="$6"
  local auth_pass="$7"
  local obfs_pass="$8"
  local tls_sni="$9"
  local insecure_tls="${10}"
  local config_path="$HY2_WG_CLIENT_DIR/$profile.yaml"
  local server_q auth_q obfs_q sni_q

  server_q="$(yaml_quote "$foreign_host:$foreign_port")"
  auth_q="$(yaml_quote "$auth_pass")"
  obfs_q="$(yaml_quote "$obfs_pass")"
  sni_q="$(yaml_quote "$tls_sni")"

  backup_existing_file "$config_path"
  {
    echo "server: $server_q"
    echo
    echo "auth: $auth_q"
    echo
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: $obfs_q"
    echo
    echo "tls:"
    if [[ -n "${tls_sni// /}" ]]; then
      echo "  sni: $sni_q"
    fi
    echo "  insecure: $insecure_tls"
    echo
    echo "udpForwarding:"
    echo "  - listen: 0.0.0.0:$iran_port"
    echo "    remote: $remote_wg_host:$remote_wg_port"
    echo "    timeout: 60s"
  } > "$config_path"
  chmod 600 "$config_path"

  HY2_WRITTEN_CONFIG="$config_path"
}

hy2_wg_iran_post_profile_tests() {
  local profile="$1"
  local foreign_host="$2"
  local foreign_port="$3"
  local iran_port="$4"
  local service_name

  service_name="$(hy2_wg_service_name "$profile")"
  echo
  line
  echo -e "${CYAN}Iran Profile Post-Setup Tests: $profile${NC}"

  if have_cmd systemctl && systemctl is-active --quiet "$service_name"; then
    pass_line "$service_name" "active"
  else
    fail_line "$service_name" "not active or systemctl unavailable"
  fi

  check_local_listener udp "$iran_port"

  if have_cmd nc; then
    if nc -zu -w2 "$foreign_host" "$foreign_port" >/dev/null 2>&1; then
      pass_line "foreign Hysteria UDP probe" "$foreign_host:$foreign_port accepted a best-effort UDP probe"
    else
      warn_line "foreign Hysteria UDP probe" "UDP reachability cannot be fully proven without WireGuard handshake traffic"
    fi
  else
    warn_line "foreign Hysteria UDP probe" "install netcat for a best-effort UDP probe"
  fi

  warn_line "UDP proof" "final proof requires a PasarGuard WireGuard user handshake"
  echo "Set WireGuard endpoint to IRAN_IP:$iran_port for one test user, then run handshake verification on the foreign server."
}

hy2_wg_setup_iran_server() {
  local count i profile foreign_host foreign_port iran_port remote_wg_host remote_wg_port
  local auth_pass obfs_pass tls_sni insecure_tls confirm start_now iran_public
  local preset_choice legacy_preset foreign_port_default tls_sni_default insecure_tls_default
  local remote_wg_host_default remote_wg_port_default
  local -a profiles=()
  local -a foreign_hosts=()
  local -a foreign_ports=()
  local -a iran_ports=()
  local -a remote_wg_hosts=()
  local -a remote_wg_ports=()
  local -a auth_passes=()
  local -a obfs_passes=()
  local -a tls_snis=()
  local -a insecure_tls_values=()
  local service_name config_path

  title
  echo -e "${CYAN}Hysteria2 OBFS -> WireGuard Forward > Iran Server Mode${NC}"
  line
  echo
  read -r -p "How many foreign servers to add? " count
  if ! [[ "$count" =~ ^[0-9]+$ ]] || ((count < 1 || count > 50)); then
    fail_line "foreign server count" "enter a number from 1 to 50"
    pause
    return
  fi

  for ((i = 1; i <= count; i++)); do
    echo
    echo -e "${YELLOW}Foreign profile $i of $count${NC}"
    profile="$(prompt_default "Profile name, example de1/nl1/tr1" "de$i")"
    if ! valid_profile_name "$profile"; then
      fail_line "profile name" "use 1-32 letters, numbers, dot, underscore, or dash"
      pause
      return
    fi

    echo "Foreign setup preset:"
    echo "1. Standard Hysteria2 OBFS WireGuard foreign mode"
    echo "2. Use Legacy Proven Foreign Mode"
    read -r -p "Select preset [1-2]: " preset_choice
    legacy_preset="false"
    foreign_port_default="8080"
    tls_sni_default=""
    insecure_tls_default="Y"
    remote_wg_host_default="127.0.0.1"
    remote_wg_port_default="51820"
    if [[ "$preset_choice" == "2" ]]; then
      legacy_preset="true"
      foreign_port_default="2087"
      tls_sni_default="$HY2_DEFAULT_LEGACY_SNI"
      insecure_tls_default="Y"
      info_line "legacy proven preset" "foreign port 2087, SNI $HY2_DEFAULT_LEGACY_SNI, insecure TLS true, masquerade $HY2_DEFAULT_MASQUERADE_URL"
    fi

    read -r -p "Foreign IP/domain: " foreign_host
    if [[ -z "${foreign_host// /}" ]]; then
      fail_line "foreign IP/domain" "value is required"
      pause
      return
    fi

    hy2_prompt_non443_port "Foreign Hysteria UDP port" "$foreign_port_default" || {
      set_summary \
        "Iran profile foreign Hysteria2 port." \
        "UDP port 443 or an invalid port was refused." \
        "Rerun Iran Server Mode with a non-443 foreign Hysteria UDP port." \
        "No server-side change was made."
      print_summary
      pause
      return
    }
    foreign_port="$HY2_PROMPTED_PORT"

    hy2_prompt_non443_port "Iran local UDP listen port" "3100$i" || {
      set_summary \
        "Iran profile local listen port." \
        "UDP port 443 or an invalid port was refused." \
        "Choose a unique non-443 Iran UDP listen port, for example 31001." \
        "No server-side change was made."
      print_summary
      pause
      return
    }
    iran_port="$HY2_PROMPTED_PORT"

    if hy2_wg_port_already_selected "$iran_port" "${iran_ports[@]}"; then
      fail_line "duplicate Iran UDP port" "$iran_port is already used in this setup plan"
      set_summary \
        "Iran local UDP listen ports." \
        "Duplicate Iran UDP port $iran_port was refused." \
        "Rerun Iran Server Mode with one unique Iran UDP listen port per foreign profile." \
        "No server-side change was made."
      print_summary
      pause
      return
    fi

    if [[ -n "$(list_listeners udp "$iran_port")" ]]; then
      fail_line "Iran UDP port $iran_port" "already listening locally"
      pause
      return
    fi

    if hy2_wg_iran_port_in_existing_config "$iran_port"; then
      fail_line "Iran UDP port $iran_port" "already appears in an existing generated client config"
      pause
      return
    fi

    remote_wg_host="$(prompt_default "Remote WireGuard host from foreign server view" "$remote_wg_host_default")"
    remote_wg_port="$(prompt_default "Remote WireGuard UDP port" "$remote_wg_port_default")"
    if ! valid_port "$remote_wg_port"; then
      fail_line "Remote WireGuard UDP port" "ports must be 1-65535"
      pause
      return
    fi

    auth_pass="$(prompt_secret_required "Auth password for $profile")"
    obfs_pass="$(prompt_secret_required "OBFS salamander password for $profile")"
    if [[ "$legacy_preset" == "true" ]]; then
      tls_sni="$(prompt_default "TLS SNI" "$tls_sni_default")"
      echo "Masquerade proxy URL on foreign side: $HY2_DEFAULT_MASQUERADE_URL"
    else
      read -r -p "TLS SNI if needed, empty=none: " tls_sni
    fi
    insecure_tls="$(prompt_yes_no_value "Use insecure TLS for this private tunnel?" "$insecure_tls_default")"

    profiles+=("$profile")
    foreign_hosts+=("$foreign_host")
    foreign_ports+=("$foreign_port")
    iran_ports+=("$iran_port")
    remote_wg_hosts+=("$remote_wg_host")
    remote_wg_ports+=("$remote_wg_port")
    auth_passes+=("$auth_pass")
    obfs_passes+=("$obfs_pass")
    tls_snis+=("$tls_sni")
    insecure_tls_values+=("$insecure_tls")
  done

  echo
  echo -e "${YELLOW}Plan${NC}"
  for ((i = 0; i < count; i++)); do
    echo "- ${profiles[$i]}: Iran UDP ${iran_ports[$i]} -> ${foreign_hosts[$i]}:${foreign_ports[$i]} -> ${remote_wg_hosts[$i]}:${remote_wg_ports[$i]}"
  done
  echo "Existing generated configs/services will be backed up before overwrite."
  echo
  read -r -p "Create Iran Hysteria2 client configs and services now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      info_line "Iran setup" "cancelled before writing files"
      set_summary \
        "Iran multi-profile Hysteria2 OBFS WireGuard plan." \
        "Setup was cancelled before writing files." \
        "Rerun Iran Server Mode when ready to create the configs/services." \
        "No server-side change was made."
      print_summary
      pause
      return
      ;;
  esac

  ensure_root || { pause; return; }
  ensure_hysteria2_ready || { pause; return; }
  ensure_hy2_wg_dirs
  start_now="$(prompt_yes_no_value "Enable and start all profile services now?" "Y")"

  for ((i = 0; i < count; i++)); do
    profile="${profiles[$i]}"
    service_name="$(hy2_wg_service_name "$profile")"
    hy2_wg_write_client_config \
      "$profile" \
      "${foreign_hosts[$i]}" \
      "${foreign_ports[$i]}" \
      "${iran_ports[$i]}" \
      "${remote_wg_hosts[$i]}" \
      "${remote_wg_ports[$i]}" \
      "${auth_passes[$i]}" \
      "${obfs_passes[$i]}" \
      "${tls_snis[$i]}" \
      "${insecure_tls_values[$i]}"
    config_path="$HY2_WRITTEN_CONFIG"
    hy2_wg_write_service "$service_name" "client" "$config_path" "VIPTrue Hysteria2 OBFS WireGuard Iran client $profile"
    hy2_wg_start_service_if_requested "$service_name" "$start_now" || { pause; return; }
  done

  hy2_wg_apply_ufw_rules "${iran_ports[@]}"
  iran_public="$(detect_public_ip)"

  for ((i = 0; i < count; i++)); do
    hy2_wg_iran_post_profile_tests "${profiles[$i]}" "${foreign_hosts[$i]}" "${foreign_ports[$i]}" "${iran_ports[$i]}"
    echo "Set PasarGuard WireGuard endpoint for ${profiles[$i]} to: $iran_public:${iran_ports[$i]}"
  done

  set_summary \
    "Iran Hysteria2 client configs/services, unique UDP listeners, firewall notes, and PasarGuard endpoint output." \
    "Failures usually mean the local Iran listener is not active, the foreign Hysteria UDP path is blocked, or credentials/SNI do not match." \
    "Set one PasarGuard test user endpoint to the printed IRAN_IP:IRAN_PORT and verify handshake on the foreign server." \
    "Yes: Iran service/firewall and foreign Hysteria/WireGuard may need action."
  print_summary
  pause
}

wg_latest_handshake_value() {
  local iface="$1"
  local peer="${2:-}"

  if [[ -n "$peer" ]]; then
    wg show "$iface" latest-handshakes 2>/dev/null | awk -v peer="$peer" '$1 == peer {print $2; found=1} END {if (!found) print 0}'
  else
    wg show "$iface" latest-handshakes 2>/dev/null | awk 'BEGIN {max=0} $2 > max {max=$2} END {print max+0}'
  fi
}

wg_transfer_total_value() {
  local iface="$1"
  local peer="${2:-}"

  if [[ -n "$peer" ]]; then
    wg show "$iface" transfer 2>/dev/null | awk -v peer="$peer" '$1 == peer {print $2 + $3; found=1} END {if (!found) print 0}'
  else
    wg show "$iface" transfer 2>/dev/null | awk 'BEGIN {sum=0} {sum += $2 + $3} END {print sum+0}'
  fi
}

hy2_wg_any_foreign_service_active() {
  have_cmd systemctl || return 1
  systemctl is-active --quiet "$(hy2_wg_service_name "foreign")"
}

hy2_wg_any_iran_listener_active() {
  local config port output
  local found="false"

  [[ -d "$HY2_WG_CLIENT_DIR" ]] || return 1
  while IFS= read -r -d '' config; do
    port="$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*0\.0\.0\.0:([0-9]+).*/\1/p' "$config" | head -n 1)"
    [[ -n "$port" ]] || continue
    output="$(list_listeners udp "$port")"
    if [[ -n "$output" ]]; then
      found="true"
      pass_line "Iran UDP listener $port" "active on this host"
    else
      fail_line "Iran UDP listener $port" "not active on this host"
    fi
  done < <(find "$HY2_WG_CLIENT_DIR" -maxdepth 1 -type f -name '*.yaml' -print0 2>/dev/null)

  [[ "$found" == "true" ]]
}

hy2_wg_wait_for_wireguard_handshake() {
  local wg_iface peer timeout start_ts start_hs start_transfer end_hs end_transfer
  local deadline now hysteria_ok iran_ok handshake_ok transfer_ok

  title
  echo -e "${CYAN}Hysteria2 OBFS -> WireGuard Forward > Wait for WireGuard Handshake${NC}"
  line
  echo

  wg_iface="$(prompt_default "Foreign WireGuard interface" "wg0")"
  read -r -p "Optional peer public key, empty=any peer: " peer
  timeout="$(prompt_default "Timeout seconds" "90")"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || ((timeout < 1 || timeout > 900)); then
    fail_line "timeout" "enter 1-900 seconds"
    pause
    return
  fi

  require_cmd wg wireguard-tools || { pause; return; }
  if ! wg show "$wg_iface" >/dev/null 2>&1; then
    fail_line "WireGuard interface $wg_iface" "wg show failed"
    pause
    return
  fi

  start_ts="$(date +%s)"
  start_hs="$(wg_latest_handshake_value "$wg_iface" "$peer")"
  start_transfer="$(wg_transfer_total_value "$wg_iface" "$peer")"
  deadline=$((start_ts + timeout))

  echo
  echo "Current latest handshake timestamp: $start_hs"
  echo "Current transfer byte total: $start_transfer"
  echo "Connect one PasarGuard WireGuard test user now."

  handshake_ok="false"
  transfer_ok="false"
  while true; do
    now="$(date +%s)"
    end_hs="$(wg_latest_handshake_value "$wg_iface" "$peer")"
    end_transfer="$(wg_transfer_total_value "$wg_iface" "$peer")"

    if ((end_hs > start_hs && end_hs >= start_ts - 5)); then
      handshake_ok="true"
    fi
    if ((end_transfer > start_transfer)); then
      transfer_ok="true"
    fi
    if [[ "$handshake_ok" == "true" && "$transfer_ok" == "true" ]]; then
      break
    fi
    if ((now >= deadline)); then
      break
    fi
    sleep 3
  done

  echo
  line
  echo -e "${CYAN}Real Confidence Test Result${NC}"
  if hy2_wg_any_foreign_service_active; then
    hysteria_ok="true"
    pass_line "Hysteria service" "$(hy2_wg_service_name "foreign") active"
  else
    hysteria_ok="false"
    fail_line "Hysteria service" "foreign service is not active on this host"
  fi

  if hy2_wg_any_iran_listener_active; then
    iran_ok="true"
  else
    iran_ok="false"
    warn_line "Iran UDP listener" "not found on this host; run Iran post-setup checks on the Iran server"
  fi

  if [[ "$handshake_ok" == "true" ]]; then
    pass_line "WireGuard handshake" "latest handshake changed from $start_hs to $end_hs"
  else
    fail_line "WireGuard handshake" "no recent handshake update detected"
  fi

  if [[ "$transfer_ok" == "true" ]]; then
    pass_line "transfer bytes" "increased from $start_transfer to $end_transfer"
  else
    fail_line "transfer bytes" "no byte increase detected"
  fi

  echo
  if [[ "$hysteria_ok" == "true" && "$iran_ok" == "true" && "$handshake_ok" == "true" && "$transfer_ok" == "true" ]]; then
    pass_line "final result" "Hysteria service active; Iran UDP listener active; WireGuard handshake updated; transfer bytes increased"
    set_summary \
      "Hysteria service, Iran listener, WireGuard handshake timestamp, and transfer byte movement." \
      "No failure detected in the checked layers." \
      "Keep this profile and repeat for each PasarGuard WireGuard node/profile." \
      "No additional server-side action needed for this profile."
  else
    fail_line "final result" "one or more layers failed"
    echo "Possible failed layer:"
    echo "- Iran listener"
    echo "- Hysteria service"
    echo "- Foreign Hysteria server"
    echo "- WireGuard handshake"
    echo "- endpoint/port mismatch"
    echo "- firewall/provider UDP block"
    set_summary \
      "Hysteria service, Iran listener if local, WireGuard handshake timestamp, and transfer byte movement." \
      "A failed layer above indicates the likely break point." \
      "Fix service/listener/endpoint/firewall settings, then rerun Wait for WireGuard Handshake." \
      "Yes: at least one server-side layer likely needs action."
  fi

  print_summary
  pause
}

valid_wg_public_key() {
  local value="$1"

  [[ "$value" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

hy2_wg_validate_timeout() {
  local label="$1"
  local timeout="$2"
  local max="${3:-900}"

  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || ((timeout < 1 || timeout > max)); then
    fail_line "$label" "enter 1-$max seconds"
    return 1
  fi
}

hy2_wg_peer_exists() {
  local iface="$1"
  local peer="$2"

  wg show "$iface" peers 2>/dev/null | grep -Fxq -- "$peer"
}

hy2_wg_iface_listen_port() {
  local iface="$1"

  wg show "$iface" listen-port 2>/dev/null | awk 'NR == 1 {print $1}'
}

hy2_wg_active_hysteria_service_name() {
  local service
  local -a candidates=(
    "$(hy2_wg_service_name "foreign")"
    "$HY2_LEGACY_SERVICE_NAME"
    "hysteria.service"
    "hysteria-server.service"
    "hysteria2.service"
    "hysteria2-server.service"
  )

  for service in "${candidates[@]}"; do
    if hy2_wg_service_active "$service"; then
      printf '%s\n' "$service"
      return 0
    fi
  done

  return 1
}

hy2_wg_synthetic_prepare_foreign_peer() {
  local wg_iface peer_pub allowed_ip label current_hs current_transfer

  title
  echo -e "${CYAN}Synthetic WireGuard Handshake Test > Foreign: prepare temporary WG peer${NC}"
  line
  echo

  wg_iface="$(prompt_default "WireGuard interface" "wg0")"
  read -r -p "Temporary test peer public key from Iran side: " peer_pub
  allowed_ip="$(prompt_default "Temporary allowed IP" "10.255.255.2/32")"
  read -r -p "Optional label/comment for display only: " label

  if ! valid_iface "$wg_iface"; then
    fail_line "WireGuard interface" "use 1-15 characters: letters, numbers, dot, underscore, colon, dash"
    pause
    return
  fi

  if ! valid_wg_public_key "$peer_pub"; then
    fail_line "temporary peer public key" "paste a WireGuard public key, not a private key"
    pause
    return
  fi

  if ! valid_cidr "$allowed_ip"; then
    fail_line "temporary allowed IP" "use IPv4/CIDR like 10.255.255.2/32"
    pause
    return
  fi

  ensure_root || { pause; return; }
  require_cmd wg wireguard-tools || { pause; return; }

  if ! wg show "$wg_iface" >/dev/null 2>&1; then
    fail_line "WireGuard interface $wg_iface" "wg show failed"
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Foreign WireGuard public key${NC}"
  wg show "$wg_iface" public-key

  echo
  info_line "temporary peer label" "${label:-none}"
  if wg set "$wg_iface" peer "$peer_pub" allowed-ips "$allowed_ip"; then
    pass_line "temporary peer added" "$peer_pub allowed-ips $allowed_ip"
  else
    fail_line "temporary peer added" "wg set failed"
    pause
    return
  fi

  echo
  echo "Rollback command:"
  echo "  wg set $wg_iface peer $peer_pub remove"

  current_hs="$(wg_latest_handshake_value "$wg_iface" "$peer_pub")"
  current_transfer="$(wg_transfer_total_value "$wg_iface" "$peer_pub")"
  if hy2_wg_peer_exists "$wg_iface" "$peer_pub"; then
    pass_line "peer presence" "peer is present on $wg_iface"
  else
    fail_line "peer presence" "peer was not found after wg set"
  fi

  if ((current_hs > 0)); then
    pass_line "current handshake" "$current_hs"
  else
    warn_line "current handshake" "none yet; run the Iran synthetic client"
  fi
  info_line "current transfer bytes" "$current_transfer"

  set_summary \
    "Foreign WireGuard interface, temporary public peer key, and allowed IP." \
    "No handshake yet is normal until the Iran synthetic client runs." \
    "Run Synthetic WireGuard Handshake Test -> Iran: generate/run temporary WG client." \
    "Yes: remove the temporary peer with the printed rollback command after testing."
  print_summary
  pause
}

hy2_wg_synthetic_safe_remove_key_file() {
  local key_file="$1"

  [[ -n "$key_file" ]] || return 0

  if [[ ! -e "$key_file" ]]; then
    warn_line "temporary key file" "$key_file not found"
    return 0
  fi

  case "$key_file" in
    "$HY2_WG_SYNTHETIC_TMP_DIR"/viptrue-wg-synthetic-*.key)
      rm -f -- "$key_file"
      pass_line "temporary key file removed" "$key_file"
      ;;
    *)
      fail_line "temporary key file cleanup" "refusing to delete non-viptrue temp path: $key_file"
      ;;
  esac
}

hy2_wg_synthetic_cleanup_iran_runtime() {
  local ifname="$1"
  local key_file="${2:-}"

  if have_cmd ip && ip link show "$ifname" >/dev/null 2>&1; then
    if ip link del dev "$ifname"; then
      pass_line "temporary interface removed" "$ifname"
    else
      fail_line "temporary interface removed" "ip link del dev $ifname failed"
    fi
  else
    warn_line "temporary interface" "$ifname not found"
  fi

  hy2_wg_synthetic_safe_remove_key_file "$key_file"
}

hy2_wg_synthetic_run_iran_client() {
  local iran_port foreign_public_key client_addr target_ip ifname timeout temp_key_file
  local old_umask temp_public_key confirm start_ts end_hs end_transfer cleanup_now
  local ping_ok udp_ok wg_ok

  title
  echo -e "${CYAN}Synthetic WireGuard Handshake Test > Iran: generate/run temporary WG client${NC}"
  line
  echo

  hy2_prompt_non443_port "Iran local Hysteria UDP listen port" "31001" || {
    set_summary \
      "Iran local Hysteria UDP listen port." \
      "UDP port 443 or an invalid port was refused." \
      "Rerun the synthetic Iran client with a valid non-443 Hysteria listener port." \
      "No server-side change was made."
    print_summary
    pause
    return
  }
  iran_port="$HY2_PROMPTED_PORT"

  read -r -p "Foreign WireGuard public key: " foreign_public_key
  client_addr="$(prompt_default "Temporary test client address" "10.255.255.2/32")"
  target_ip="$(prompt_default "Test target IP" "10.255.255.1")"
  ifname="$(prompt_default "Temporary interface name" "wg-viptest")"
  timeout="$(prompt_default "Timeout seconds" "30")"

  if ! valid_wg_public_key "$foreign_public_key"; then
    fail_line "Foreign WireGuard public key" "paste the public key from the foreign wg interface"
    pause
    return
  fi

  if ! valid_cidr "$client_addr"; then
    fail_line "Temporary test client address" "use IPv4/CIDR like 10.255.255.2/32"
    pause
    return
  fi

  if ! valid_ipv4 "$target_ip"; then
    fail_line "Test target IP" "use an IPv4 address like 10.255.255.1"
    pause
    return
  fi

  if ! valid_iface "$ifname"; then
    fail_line "Temporary interface name" "use 1-15 characters: letters, numbers, dot, underscore, colon, dash"
    pause
    return
  fi

  hy2_wg_validate_timeout "timeout" "$timeout" 300 || { pause; return; }
  ensure_root || { pause; return; }
  require_cmd wg wireguard-tools || { pause; return; }
  require_cmd ip iproute2 || { pause; return; }

  mkdir -p "$HY2_WG_SYNTHETIC_TMP_DIR"
  chmod 700 "$HY2_WG_SYNTHETIC_TMP_DIR" 2>/dev/null || true
  old_umask="$(umask)"
  umask 077
  if have_cmd mktemp; then
    temp_key_file="$(mktemp "$HY2_WG_SYNTHETIC_TMP_DIR/viptrue-wg-synthetic-${ifname}.XXXXXX.key")"
  else
    temp_key_file="$HY2_WG_SYNTHETIC_TMP_DIR/viptrue-wg-synthetic-${ifname}-$$.key"
    : > "$temp_key_file"
  fi
  if ! wg genkey > "$temp_key_file"; then
    umask "$old_umask"
    fail_line "temporary WireGuard keypair" "wg genkey failed"
    hy2_wg_synthetic_safe_remove_key_file "$temp_key_file"
    pause
    return
  fi
  umask "$old_umask"
  chmod 600 "$temp_key_file"
  temp_public_key="$(wg pubkey < "$temp_key_file")"

  echo
  echo -e "${YELLOW}Temporary public key for Foreign prepare mode${NC}"
  echo "$temp_public_key"
  info_line "private key" "stored at $temp_key_file with chmod 600; value is not printed"
  echo
  read -r -p "Has the foreign temporary peer been added now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      warn_line "synthetic client" "cancelled before creating interface"
      hy2_wg_synthetic_safe_remove_key_file "$temp_key_file"
      pause
      return
      ;;
  esac

  if ip link show "$ifname" >/dev/null 2>&1; then
    fail_line "temporary interface" "$ifname already exists; run cleanup first"
    hy2_wg_synthetic_safe_remove_key_file "$temp_key_file"
    pause
    return
  fi

  if ip link add dev "$ifname" type wireguard; then
    pass_line "temporary interface created" "$ifname"
  else
    fail_line "temporary interface created" "ip link add failed"
    hy2_wg_synthetic_safe_remove_key_file "$temp_key_file"
    pause
    return
  fi

  if ! ip addr add "$client_addr" dev "$ifname"; then
    fail_line "temporary interface address" "ip addr add $client_addr failed"
    hy2_wg_synthetic_cleanup_iran_runtime "$ifname" "$temp_key_file"
    pause
    return
  fi

  if ! wg set "$ifname" private-key "$temp_key_file" peer "$foreign_public_key" endpoint "127.0.0.1:$iran_port" allowed-ips "$target_ip/32" persistent-keepalive 5; then
    fail_line "temporary WireGuard peer" "wg set failed"
    hy2_wg_synthetic_cleanup_iran_runtime "$ifname" "$temp_key_file"
    pause
    return
  fi

  if ! ip link set up dev "$ifname"; then
    fail_line "temporary interface up" "ip link set up failed"
    hy2_wg_synthetic_cleanup_iran_runtime "$ifname" "$temp_key_file"
    pause
    return
  fi

  start_ts="$(date +%s)"
  ping_ok="false"
  udp_ok="false"
  if have_cmd ping; then
    if ping -c 3 -W 2 "$target_ip"; then
      ping_ok="true"
      pass_line "synthetic ping" "$target_ip replied"
    else
      warn_line "synthetic ping" "no reply; handshake may still be visible in wg counters"
    fi
  else
    warn_line "ping command" "install iputils-ping for ICMP trigger"
  fi

  if have_cmd nc; then
    if printf 'viptrue-wg-synthetic-test\n' | nc -u -w1 "$target_ip" 9 >/dev/null 2>&1; then
      udp_ok="true"
      pass_line "synthetic UDP packet" "sent to $target_ip:9"
    else
      warn_line "synthetic UDP packet" "nc send returned non-zero"
    fi
  else
    warn_line "nc command" "install netcat-openbsd for UDP trigger"
  fi

  sleep "$timeout"
  echo
  echo -e "${YELLOW}Temporary WireGuard status${NC}"
  wg show "$ifname" || true

  end_hs="$(wg_latest_handshake_value "$ifname" "$foreign_public_key")"
  end_transfer="$(wg_transfer_total_value "$ifname" "$foreign_public_key")"
  if ((end_hs >= start_ts - 5 && end_hs > 0)); then
    wg_ok="true"
    pass_line "synthetic handshake" "latest handshake timestamp $end_hs"
  else
    wg_ok="false"
    fail_line "synthetic handshake" "no recent handshake detected"
  fi

  if ((end_transfer > 0)); then
    pass_line "synthetic transfer bytes" "$end_transfer"
  else
    fail_line "synthetic transfer bytes" "no transfer bytes recorded"
  fi

  echo
  cleanup_now="$(prompt_yes_no_value "Remove temporary interface and key file now?" "Y")"
  if [[ "$cleanup_now" == "true" ]]; then
    hy2_wg_synthetic_cleanup_iran_runtime "$ifname" "$temp_key_file"
  else
    warn_line "temporary cleanup skipped" "remove later: ip link del dev $ifname; rm -f $temp_key_file"
  fi

  if [[ "$wg_ok" == "true" && ( "$ping_ok" == "true" || "$udp_ok" == "true" ) ]]; then
    pass_line "final result" "temporary client sent traffic and WireGuard handshake became recent"
  elif [[ "$wg_ok" == "true" ]]; then
    warn_line "final result" "handshake became recent, but traffic probe did not confirm application response"
  else
    fail_line "final result" "synthetic WireGuard handshake was not proven"
  fi

  set_summary \
    "Temporary Iran WireGuard client through local Hysteria listener 127.0.0.1:$iran_port." \
    "A failed handshake usually means the Hysteria client path, foreign peer setup, or WireGuard keys/ports do not match." \
    "Run Foreign: verify temporary handshake while the Iran test is running, then cleanup both sides." \
    "Yes: remove the temporary peer on the foreign server after the test."
  print_summary
  pause
}

hy2_wg_synthetic_verify_foreign_handshake() {
  local wg_iface peer_pub timeout start_ts start_hs start_transfer end_hs end_transfer
  local deadline now handshake_ok transfer_ok wg_port listener_output active_service
  local wg_port_ok hysteria_ok

  title
  echo -e "${CYAN}Synthetic WireGuard Handshake Test > Foreign: verify temporary handshake${NC}"
  line
  echo

  wg_iface="$(prompt_default "WireGuard interface" "wg0")"
  read -r -p "Temporary test peer public key: " peer_pub
  timeout="$(prompt_default "Timeout seconds" "60")"

  if ! valid_iface "$wg_iface"; then
    fail_line "WireGuard interface" "use 1-15 characters: letters, numbers, dot, underscore, colon, dash"
    pause
    return
  fi

  if ! valid_wg_public_key "$peer_pub"; then
    fail_line "temporary peer public key" "paste the public key from the Iran synthetic client"
    pause
    return
  fi

  hy2_wg_validate_timeout "timeout" "$timeout" 900 || { pause; return; }
  require_cmd wg wireguard-tools || { pause; return; }

  if ! wg show "$wg_iface" >/dev/null 2>&1; then
    fail_line "WireGuard interface $wg_iface" "wg show failed"
    pause
    return
  fi

  if ! hy2_wg_peer_exists "$wg_iface" "$peer_pub"; then
    fail_line "temporary peer" "peer missing on $wg_iface"
    echo "Run Foreign: prepare temporary WG peer first."
    pause
    return
  fi

  wg_port="$(hy2_wg_iface_listen_port "$wg_iface")"
  if [[ -n "$wg_port" && "$wg_port" != "0" ]]; then
    listener_output="$(list_listeners udp "$wg_port")"
    if [[ -n "$listener_output" ]]; then
      wg_port_ok="true"
      pass_line "WG port listening" "$wg_iface UDP $wg_port"
      printf '%s\n' "$listener_output"
    else
      wg_port_ok="false"
      fail_line "WG port listening" "no local UDP listener found for $wg_iface port $wg_port"
    fi
  else
    wg_port_ok="false"
    fail_line "WG port listening" "could not read listen-port for $wg_iface"
  fi

  if active_service="$(hy2_wg_active_hysteria_service_name)"; then
    hysteria_ok="true"
    pass_line "Hysteria service" "$active_service active"
  else
    hysteria_ok="false"
    fail_line "Hysteria service" "no active foreign/legacy Hysteria service detected"
  fi

  start_ts="$(date +%s)"
  start_hs="$(wg_latest_handshake_value "$wg_iface" "$peer_pub")"
  start_transfer="$(wg_transfer_total_value "$wg_iface" "$peer_pub")"
  deadline=$((start_ts + timeout))

  echo
  echo "Starting latest handshake timestamp: $start_hs"
  echo "Starting transfer byte total: $start_transfer"
  echo "Run the Iran synthetic client now if it is not already running."

  handshake_ok="false"
  transfer_ok="false"
  while true; do
    now="$(date +%s)"
    end_hs="$(wg_latest_handshake_value "$wg_iface" "$peer_pub")"
    end_transfer="$(wg_transfer_total_value "$wg_iface" "$peer_pub")"

    if ((end_hs > start_hs || (end_hs >= start_ts - 5 && end_hs > 0))); then
      handshake_ok="true"
    fi
    if ((end_transfer > start_transfer)); then
      transfer_ok="true"
    fi
    if [[ "$handshake_ok" == "true" && "$transfer_ok" == "true" ]]; then
      break
    fi
    if ((now >= deadline)); then
      break
    fi
    sleep 3
  done

  echo
  line
  echo -e "${CYAN}Synthetic Foreign Verification Result${NC}"
  if [[ "$handshake_ok" == "true" ]]; then
    pass_line "latest handshake" "changed/recent: $end_hs"
  else
    fail_line "latest handshake" "no recent handshake for temporary peer"
  fi

  if [[ "$transfer_ok" == "true" ]]; then
    pass_line "transfer bytes" "increased from $start_transfer to $end_transfer"
  else
    fail_line "transfer bytes" "did not increase from $start_transfer"
  fi

  if [[ "$wg_port_ok" == "true" && "$hysteria_ok" == "true" && "$handshake_ok" == "true" && "$transfer_ok" == "true" ]]; then
    pass_line "final result" "synthetic WireGuard traffic crossed the Hysteria2 OBFS path"
    set_summary \
      "Foreign temporary peer handshake timestamp and transfer byte movement." \
      "No failure detected in the checked synthetic path." \
      "Cleanup the temporary peer/interface, then repeat only when changing tunnel settings." \
      "Yes: remove the temporary peer from the foreign WireGuard interface."
  else
    fail_line "final result" "synthetic WireGuard handshake was not proven"
    echo "Diagnosis:"
    echo "- Iran local listener problem"
    echo "- Hysteria client problem"
    echo "- Foreign Hysteria server problem"
    echo "- Wrong auth/obfs/SNI/insecure setting"
    echo "- Foreign WG port mismatch"
    echo "- Firewall/provider UDP block"
    set_summary \
      "Foreign temporary peer, Hysteria service, WG listen port, handshake timestamp, and transfer bytes." \
      "One of the synthetic tunnel layers did not move traffic." \
      "Check Iran listener, Hysteria credentials/SNI/insecure settings, foreign WG port, and provider UDP filtering." \
      "Yes: at least one server-side layer likely needs action."
  fi

  print_summary
  pause
}

hy2_wg_synthetic_cleanup_foreign_peer() {
  local wg_iface peer_pub

  title
  echo -e "${CYAN}Synthetic WireGuard Handshake Test > Cleanup foreign temporary peer${NC}"
  line
  echo

  wg_iface="$(prompt_default "WireGuard interface" "wg0")"
  read -r -p "Temporary test peer public key: " peer_pub

  if ! valid_iface "$wg_iface"; then
    fail_line "WireGuard interface" "use 1-15 characters: letters, numbers, dot, underscore, colon, dash"
    pause
    return
  fi

  if ! valid_wg_public_key "$peer_pub"; then
    fail_line "temporary peer public key" "paste the temporary public key"
    pause
    return
  fi

  ensure_root || { pause; return; }
  require_cmd wg wireguard-tools || { pause; return; }

  if wg set "$wg_iface" peer "$peer_pub" remove; then
    pass_line "foreign temporary peer removed" "$peer_pub"
  else
    fail_line "foreign temporary peer removed" "wg set remove failed"
  fi

  if hy2_wg_peer_exists "$wg_iface" "$peer_pub"; then
    fail_line "foreign temporary peer confirmation" "peer is still present"
  else
    pass_line "foreign temporary peer confirmation" "peer no longer listed on $wg_iface"
  fi

  set_summary \
    "Foreign temporary WireGuard peer removal." \
    "If removal failed, the interface name or public key may be wrong." \
    "Rerun cleanup with the exact interface and public key printed by the Iran synthetic client." \
    "Maybe: manual wg peer removal may be needed."
  print_summary
  pause
}

hy2_wg_synthetic_cleanup_iran_prompt() {
  local ifname key_file

  title
  echo -e "${CYAN}Synthetic WireGuard Handshake Test > Cleanup Iran temporary interface/key${NC}"
  line
  echo

  ifname="$(prompt_default "Temporary interface name" "wg-viptest")"
  key_file="$(prompt_default "Temporary private key file path" "$HY2_WG_SYNTHETIC_TMP_DIR/viptrue-wg-synthetic-wg-viptest.key")"

  if ! valid_iface "$ifname"; then
    fail_line "Temporary interface name" "use 1-15 characters: letters, numbers, dot, underscore, colon, dash"
    pause
    return
  fi

  ensure_root || { pause; return; }
  hy2_wg_synthetic_cleanup_iran_runtime "$ifname" "$key_file"

  set_summary \
    "Iran temporary WireGuard interface and viptrue synthetic key file cleanup." \
    "If cleanup failed, the interface may not exist or the key path may not be a viptrue temp key." \
    "Confirm no wg-viptest interface remains before rerunning the synthetic client." \
    "Maybe: manual cleanup may be needed if a nonstandard key path was used."
  print_summary
  pause
}

hy2_wg_synthetic_cleanup_menu() {
  local choice

  while true; do
    title
    echo -e "${CYAN}Synthetic WireGuard Handshake Test > Cleanup temporary test${NC}"
    line
    echo
    echo "1. Foreign: remove temporary WG peer"
    echo "2. Iran: delete temporary interface/key"
    echo "3. Back"
    echo
    read -r -p "Enter your choice [1-3]: " choice

    case "$choice" in
      1) hy2_wg_synthetic_cleanup_foreign_peer ;;
      2) hy2_wg_synthetic_cleanup_iran_prompt ;;
      3) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

hy2_wg_synthetic_udp_probe_foreign() {
  local wg_port timeout listener_output

  title
  echo -e "${CYAN}Synthetic WireGuard Handshake Test > UDP Forward Probe > Foreign watcher${NC}"
  line
  echo

  wg_port="$(prompt_default "Foreign local WireGuard UDP port" "51820")"
  timeout="$(prompt_default "Watch timeout seconds" "20")"
  if ! valid_port "$wg_port"; then
    fail_line "Foreign local WireGuard UDP port" "ports must be 1-65535"
    pause
    return
  fi
  hy2_wg_validate_timeout "watch timeout" "$timeout" 300 || { pause; return; }

  warn_line "UDP probe scope" "UDP probe proves forwarding path only if packets are observed on Foreign; it does not prove WireGuard authentication."
  if have_cmd tcpdump; then
    if have_cmd timeout; then
      info_line "tcpdump watcher" "watching udp port $wg_port for up to $timeout seconds"
      timeout "$timeout" tcpdump -n -i any "udp port $wg_port" -c 5 || true
    else
      warn_line "timeout command" "not found; tcpdump will stop after 5 packets or Ctrl-C"
      tcpdump -n -i any "udp port $wg_port" -c 5 || true
    fi
  else
    warn_line "tcpdump" "not installed; using ss/journal fallback"
    listener_output="$(list_listeners udp "$wg_port")"
    if [[ -n "$listener_output" ]]; then
      pass_line "local UDP listener on $wg_port" "found"
      printf '%s\n' "$listener_output"
    else
      warn_line "local UDP listener on $wg_port" "not found"
    fi
    if have_cmd journalctl; then
      echo
      echo -e "${YELLOW}Recent Hysteria/WireGuard logs if available${NC}"
      journalctl -n 30 --no-pager 2>/dev/null | grep -Ei 'hysteria|wireguard|wg' || true
    fi
  fi

  set_summary \
    "Foreign UDP watcher/fallback on the WireGuard UDP port." \
    "No observed packet means Iran probe, Hysteria forwarding, service config, or provider UDP may be failing." \
    "Run the Iran UDP probe while the foreign watcher is active." \
    "Maybe: service, config, or firewall/provider changes may be needed."
  print_summary
  pause
}

hy2_wg_synthetic_udp_probe_iran() {
  local iran_port sent

  title
  echo -e "${CYAN}Synthetic WireGuard Handshake Test > UDP Forward Probe > Iran sender${NC}"
  line
  echo

  hy2_prompt_non443_port "Iran local Hysteria UDP listen port" "31001" || {
    set_summary \
      "Iran local Hysteria UDP listen port for UDP-only probe." \
      "UDP port 443 or an invalid port was refused." \
      "Rerun UDP Forward Probe with a valid non-443 local Hysteria listener port." \
      "No server-side change was made."
    print_summary
    pause
    return
  }
  iran_port="$HY2_PROMPTED_PORT"
  warn_line "UDP probe scope" "UDP probe proves forwarding path only if packets are observed on Foreign; it does not prove WireGuard authentication."

  sent="false"
  if have_cmd nc; then
    if printf 'viptrue-udp-forward-probe\n' | nc -u -w1 127.0.0.1 "$iran_port" >/dev/null 2>&1; then
      sent="true"
      pass_line "UDP probe packet" "sent with nc to 127.0.0.1:$iran_port"
    else
      warn_line "UDP probe packet" "nc returned non-zero"
    fi
  fi

  if [[ "$sent" == "false" ]]; then
    if (printf 'viptrue-udp-forward-probe\n' >"/dev/udp/127.0.0.1/$iran_port") 2>/dev/null; then
      sent="true"
      pass_line "UDP probe packet" "sent with bash /dev/udp to 127.0.0.1:$iran_port"
    else
      fail_line "UDP probe packet" "nc unavailable/failed and bash /dev/udp failed"
    fi
  fi

  set_summary \
    "Iran UDP-only probe to local Hysteria listener 127.0.0.1:$iran_port." \
    "This does not prove WireGuard authentication; it only helps check whether a UDP payload reaches the foreign WG port." \
    "Confirm packets on Foreign watcher, then run the synthetic WireGuard handshake test for real proof." \
    "Maybe: Iran Hysteria client/service or provider UDP may need attention."
  print_summary
  pause
}

hy2_wg_synthetic_udp_probe_menu() {
  local choice

  while true; do
    title
    echo -e "${CYAN}Synthetic WireGuard Handshake Test > UDP-only fallback probe${NC}"
    line
    echo
    echo "1. Foreign: watch WireGuard UDP port"
    echo "2. Iran: send UDP packet to local Hysteria listener"
    echo "3. Back"
    echo
    read -r -p "Enter your choice [1-3]: " choice

    case "$choice" in
      1) hy2_wg_synthetic_udp_probe_foreign ;;
      2) hy2_wg_synthetic_udp_probe_iran ;;
      3) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

hy2_wg_synthetic_menu() {
  local choice

  while true; do
    title
    echo -e "${CYAN}Synthetic WireGuard Handshake Test${NC}"
    line
    echo
    echo "1. Foreign: prepare temporary WG peer"
    echo "2. Iran: generate/run temporary WG client"
    echo "3. Foreign: verify temporary handshake"
    echo "4. Cleanup temporary test"
    echo "5. UDP-only fallback probe"
    echo "6. Back"
    echo
    read -r -p "Enter your choice [1-6]: " choice

    case "$choice" in
      1) hy2_wg_synthetic_prepare_foreign_peer ;;
      2) hy2_wg_synthetic_run_iran_client ;;
      3) hy2_wg_synthetic_verify_foreign_handshake ;;
      4) hy2_wg_synthetic_cleanup_menu ;;
      5) hy2_wg_synthetic_udp_probe_menu ;;
      6) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

hy2_wg_trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

hy2_wg_unquote() {
  local value

  value="$(hy2_wg_trim "$1")"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}"; value="${value//\'\'/\'}" ;;
  esac
  printf '%s\n' "$value"
}

hy2_wg_field_value() {
  local config="$1"
  local key="$2"
  local raw

  raw="$(sed -nE "s/^[[:space:]]*${key}:[[:space:]]*(.*)$/\1/p" "$config" 2>/dev/null | head -n 1)"
  hy2_wg_unquote "$raw"
}

hy2_wg_section_field_value() {
  local config="$1"
  local section="$2"
  local key="$3"

  awk -v section="$section" -v key="$key" '
    $0 ~ "^[[:space:]]*" section ":" {inside=1; next}
    inside && /^[^[:space:]]/ {inside=0}
    inside && $0 ~ "^[[:space:]]*" key ":" {
      sub("^[[:space:]]*" key ":[[:space:]]*", "")
      print
      exit
    }
  ' "$config" 2>/dev/null | while IFS= read -r value; do
    hy2_wg_unquote "$value"
  done
}

hy2_wg_extract_listen_port() {
  local config="$1"

  sed -nE 's/^[^[:alnum:]#-]*(-[[:space:]]*)?listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\2/p' "$config" 2>/dev/null | head -n 1
}

hy2_wg_extract_remote_target() {
  local config="$1"

  sed -nE 's/^[[:space:]]*remote:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$config" 2>/dev/null | head -n 1
}

hy2_wg_split_host_port() {
  local value="$1"
  local default_host="$2"
  local default_port="$3"
  local __host_var="$4"
  local __port_var="$5"
  local host port

  value="$(hy2_wg_unquote "$value")"
  if [[ "$value" == *:* ]]; then
    host="${value%:*}"
    port="${value##*:}"
  else
    host="${value:-$default_host}"
    port="$default_port"
  fi

  printf -v "$__host_var" '%s' "$host"
  printf -v "$__port_var" '%s' "$port"
}

hy2_wg_client_auth_secret() {
  local config="$1"

  sed -nE 's/^[[:space:]]*auth:[[:space:]]*(.*)$/\1/p' "$config" 2>/dev/null | head -n 1 | while IFS= read -r value; do
    hy2_wg_unquote "$value"
  done
}

hy2_wg_config_secret() {
  local config="$1"
  local section="$2"

  awk -v section="$section" '
    $0 ~ "^[[:space:]]*" section ":" {inside=1; next}
    inside && /^[^[:space:]]/ {inside=0}
    inside && /^[[:space:]]*password:/ {
      sub(/^[[:space:]]*password:[[:space:]]*/, "")
      print
      exit
    }
  ' "$config" 2>/dev/null | while IFS= read -r value; do
    hy2_wg_unquote "$value"
  done
}

hy2_wg_mask_secret_value() {
  local value="$1"
  local length

  if [[ -z "$value" ]]; then
    printf '<hidden>\n'
    return
  fi

  length="${#value}"
  if ((length <= 8)); then
    printf '<hidden>\n'
  else
    printf '%s...%s\n' "${value:0:4}" "${value:length-4:4}"
  fi
}

hy2_wg_sanitize_config() {
  local config="$1"

  sed -E \
    -e 's/^([[:space:]]*auth:[[:space:]]*).*/\1<hidden>/' \
    -e 's/^([[:space:]]*password:[[:space:]]*).*/\1<hidden>/' \
    "$config" 2>/dev/null
}

hy2_wg_service_path() {
  local service_name="$1"

  printf '%s/%s\n' "$HY2_SYSTEMD_SYSTEM_DIR" "$service_name"
}

hy2_wg_service_status_text() {
  local service_name="$1"

  if ! have_cmd systemctl; then
    printf 'unknown'
  elif systemctl is-active --quiet "$service_name" 2>/dev/null; then
    printf 'active'
  else
    printf 'inactive'
  fi
}

hy2_wg_is_client_profile() {
  [[ "$1" == "iran/client" ]]
}

hy2_wg_is_raw_legacy_profile() {
  [[ "$1" == "legacy-proven-foreign" ]]
}

hy2_wg_is_foreign_profile() {
  case "$1" in
    foreign|legacy-managed|legacy-proven-foreign) return 0 ;;
    *) return 1 ;;
  esac
}

hy2_wg_legacy_config_present() {
  [[ -f "$HY2_LEGACY_CONFIG" && -f "$HY2_LEGACY_CERT" && -f "$HY2_LEGACY_KEY" ]]
}

hy2_wg_legacy_service_name() {
  local profile="$1"

  hy2_wg_service_name "legacy-$profile"
}

hy2_wg_managed_legacy_profile_name() {
  local config="$1"
  local profile_dir

  profile_dir="$(dirname "$config")"
  basename "$profile_dir"
}

hy2_wg_foreign_meta_path_for_config() {
  local config="$1"
  local profile_dir

  if [[ "$config" == "$HY2_LEGACY_CONFIG" ]]; then
    printf '%s/viptrue.meta\n' "$HY2_LEGACY_DIR"
    return
  fi

  if [[ "$config" == "$HY2_WG_DIR/foreign-server.yaml" ]]; then
    printf '%s/foreign.meta\n' "$HY2_WG_DIR"
    return
  fi

  profile_dir="$(dirname "$config")"
  if [[ "$profile_dir" == "$HY2_WG_LEGACY_DIR"/* ]]; then
    printf '%s/profile.meta\n' "$profile_dir"
    return
  fi

  printf '%s/foreign.meta\n' "$HY2_WG_DIR"
}

hy2_wg_masquerade_url() {
  local config="$1"
  local url

  url="$(hy2_wg_section_field_value "$config" "proxy" "url")"
  printf '%s\n' "${url:-$HY2_DEFAULT_MASQUERADE_URL}"
}

hy2_wg_obfs_type() {
  local config="$1"
  local obfs_type

  obfs_type="$(hy2_wg_section_field_value "$config" "obfs" "type")"
  printf '%s\n' "${obfs_type:-unknown}"
}

hy2_wg_sni_guard() {
  local config="$1"
  local value

  value="$(hy2_wg_field_value "$config" "sniGuard")"
  printf '%s\n' "${value:-none}"
}

hy2_wg_service_file_exists() {
  local service_name="$1"
  local dir

  for dir in $HY2_SYSTEMD_SEARCH_DIRS; do
    [[ -f "$dir/$service_name" ]] && return 0
  done

  have_cmd systemctl && systemctl cat "$service_name" >/dev/null 2>&1
}

hy2_wg_service_references_config() {
  local service_name="$1"
  local config="$2"
  local dir

  for dir in $HY2_SYSTEMD_SEARCH_DIRS; do
    if [[ -f "$dir/$service_name" ]] && grep -Fq -- "$config" "$dir/$service_name" 2>/dev/null; then
      return 0
    fi
  done

  have_cmd systemctl && systemctl cat "$service_name" 2>/dev/null | grep -Fq -- "$config"
}

hy2_wg_detect_services_for_config() {
  local config="$1"
  local service service_file dir
  local known_services=(
    "$HY2_LEGACY_SERVICE_NAME"
    "hysteria.service"
    "hysteria-server.service"
    "hysteria2.service"
    "hysteria2-server.service"
  )

  {
    for service in "${known_services[@]}"; do
      if hy2_wg_service_file_exists "$service" || hy2_wg_service_references_config "$service" "$config"; then
        printf '%s\n' "$service"
      fi
    done

    if have_cmd systemctl; then
      while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        hy2_wg_service_references_config "$service" "$config" && printf '%s\n' "$service"
      done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}')
    fi

    for dir in $HY2_SYSTEMD_SEARCH_DIRS; do
      [[ -d "$dir" ]] || continue
      while IFS= read -r -d '' service_file; do
        if grep -Fq -- "$config" "$service_file" 2>/dev/null; then
          basename "$service_file"
        fi
      done < <(find "$dir" -maxdepth 1 -type f -name '*.service' -print0 2>/dev/null)
    done
  } | sort -u
}

hy2_wg_join_lines() {
  local value joined=""

  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    if [[ -n "$joined" ]]; then
      joined="$joined, $value"
    else
      joined="$value"
    fi
  done

  printf '%s\n' "$joined"
}

hy2_wg_service_active() {
  local service_name="$1"

  have_cmd systemctl && systemctl is-active --quiet "$service_name" 2>/dev/null
}

hy2_wg_each_managed_config() {
  [[ -f "$HY2_WG_DIR/foreign-server.yaml" ]] && printf '%s\n' "$HY2_WG_DIR/foreign-server.yaml"

  if [[ -d "$HY2_WG_CLIENT_DIR" ]]; then
    find "$HY2_WG_CLIENT_DIR" -maxdepth 1 -type f -name '*.yaml' -print 2>/dev/null
  fi

  if [[ -d "$HY2_WG_LEGACY_DIR" ]]; then
    find "$HY2_WG_LEGACY_DIR" -mindepth 2 -maxdepth 2 -type f -name 'config.yaml' -print 2>/dev/null
  fi
}

hy2_wg_archive_existing_path() {
  local path="$1"
  local archive_dir="$2"
  local destination

  [[ -e "$path" ]] || return 0
  mkdir -p "$archive_dir"
  destination="$archive_dir/$(basename "$path")"
  if [[ -e "$destination" ]]; then
    destination="$archive_dir/$(date +%Y%m%d-%H%M%S)-$(basename "$path")"
  fi
  mv "$path" "$destination"
  pass_line "archived existing file" "$path -> $destination"
}

hy2_wg_copy_legacy_config_for_import() {
  local source_config="$1"
  local dest_config="$2"
  local dest_cert="$3"
  local dest_key="$4"
  local line cert_q key_q

  cert_q="$(yaml_quote "$dest_cert")"
  key_q="$(yaml_quote "$dest_key")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([[:space:]]*)cert:[[:space:]]* ]]; then
      printf '%scert: %s\n' "${BASH_REMATCH[1]}" "$cert_q"
    elif [[ "$line" =~ ^([[:space:]]*)key:[[:space:]]* ]]; then
      printf '%skey: %s\n' "${BASH_REMATCH[1]}" "$key_q"
    else
      printf '%s\n' "$line"
    fi
  done < "$source_config" > "$dest_config"
}

HY2_PROFILE_NAMES=()
HY2_PROFILE_MODES=()
HY2_PROFILE_CONFIGS=()
HY2_PROFILE_SERVICES=()
HY2_PROFILE_LISTENS=()
HY2_PROFILE_TARGETS=()

HY2_SELECTED_NAME=""
HY2_SELECTED_MODE=""
HY2_SELECTED_CONFIG=""
HY2_SELECTED_SERVICE=""
HY2_SELECTED_LISTEN=""
HY2_SELECTED_TARGET=""

hy2_wg_add_profile() {
  HY2_PROFILE_NAMES+=("$1")
  HY2_PROFILE_MODES+=("$2")
  HY2_PROFILE_CONFIGS+=("$3")
  HY2_PROFILE_SERVICES+=("$4")
  HY2_PROFILE_LISTENS+=("$5")
  HY2_PROFILE_TARGETS+=("$6")
}

hy2_wg_collect_profiles() {
  local config profile service listen target server_host server_port remote_target
  local meta_wg_iface meta_wg_port legacy_services legacy_primary masquerade_url

  HY2_PROFILE_NAMES=()
  HY2_PROFILE_MODES=()
  HY2_PROFILE_CONFIGS=()
  HY2_PROFILE_SERVICES=()
  HY2_PROFILE_LISTENS=()
  HY2_PROFILE_TARGETS=()

  config="$HY2_WG_DIR/foreign-server.yaml"
  if [[ -f "$config" ]]; then
    service="$(hy2_wg_service_name "foreign")"
    listen="$(hy2_wg_extract_listen_port "$config")"
    meta_wg_iface="$(sed -nE 's/^wg_iface=(.*)$/\1/p' "$(hy2_wg_foreign_meta_path_for_config "$config")" 2>/dev/null | head -n 1)"
    meta_wg_port="$(sed -nE 's/^wg_port=(.*)$/\1/p' "$(hy2_wg_foreign_meta_path_for_config "$config")" 2>/dev/null | head -n 1)"
    target="WireGuard ${meta_wg_iface:-wg0}:${meta_wg_port:-51820}"
    hy2_wg_add_profile "foreign" "foreign" "$config" "$service" "${listen:-unknown}" "$target"
  fi

  if [[ -d "$HY2_WG_LEGACY_DIR" ]]; then
    while IFS= read -r -d '' config; do
      profile="$(hy2_wg_managed_legacy_profile_name "$config")"
      service="$(hy2_wg_legacy_service_name "$profile")"
      listen="$(hy2_wg_extract_listen_port "$config")"
      meta_wg_iface="$(sed -nE 's/^wg_iface=(.*)$/\1/p' "$(hy2_wg_foreign_meta_path_for_config "$config")" 2>/dev/null | head -n 1)"
      meta_wg_port="$(sed -nE 's/^wg_port=(.*)$/\1/p' "$(hy2_wg_foreign_meta_path_for_config "$config")" 2>/dev/null | head -n 1)"
      masquerade_url="$(hy2_wg_masquerade_url "$config")"
      target="WireGuard ${meta_wg_iface:-wg0}:${meta_wg_port:-51820}; masquerade: $masquerade_url"
      hy2_wg_add_profile "$profile" "legacy-managed" "$config" "$service" "${listen:-unknown}" "$target"
    done < <(find "$HY2_WG_LEGACY_DIR" -mindepth 2 -maxdepth 2 -type f -name 'config.yaml' -print0 2>/dev/null | sort -z)
  fi

  if [[ -d "$HY2_WG_CLIENT_DIR" ]]; then
    while IFS= read -r -d '' config; do
      profile="$(basename "$config" .yaml)"
      service="$(hy2_wg_service_name "$profile")"
      listen="$(hy2_wg_extract_listen_port "$config")"
      remote_target="$(hy2_wg_extract_remote_target "$config")"
      server_host="$(hy2_wg_field_value "$config" "server")"
      hy2_wg_split_host_port "$server_host" "FOREIGN_HOST" "8080" server_host server_port
      target="${remote_target:-127.0.0.1:51820} via $server_host:$server_port"
      hy2_wg_add_profile "$profile" "iran/client" "$config" "$service" "${listen:-unknown}" "$target"
    done < <(find "$HY2_WG_CLIENT_DIR" -maxdepth 1 -type f -name '*.yaml' -print0 2>/dev/null | sort -z)
  fi

  if hy2_wg_legacy_config_present; then
    legacy_services="$(hy2_wg_detect_services_for_config "$HY2_LEGACY_CONFIG")"
    legacy_primary="$(printf '%s\n' "$legacy_services" | head -n 1)"
    listen="$(hy2_wg_extract_listen_port "$HY2_LEGACY_CONFIG")"
    masquerade_url="$(hy2_wg_masquerade_url "$HY2_LEGACY_CONFIG")"
    target="legacy /etc/hysteria; masquerade: $masquerade_url"
    hy2_wg_add_profile "legacy-proven-foreign" "legacy-proven-foreign" "$HY2_LEGACY_CONFIG" "${legacy_primary:-none}" "${listen:-unknown}" "$target"
  fi
}

hy2_wg_print_profile_row() {
  local idx="$1"
  local name="$2"
  local mode="$3"
  local listen="$4"
  local target="$5"
  local service="$6"
  local status

  status="$(hy2_wg_service_status_text "$service")"
  printf '%2s. %-16s %-11s listen=%-8s service=%-32s status=%s\n' "$idx" "$name" "$mode" "$listen" "$service" "$status"
  printf '    target: %s\n' "$target"
}

hy2_wg_list_profiles() {
  local i count

  hy2_wg_collect_profiles
  count="${#HY2_PROFILE_NAMES[@]}"
  if ((count == 0)); then
    warn_line "profiles" "no generated Hysteria2 WireGuard profiles found under $HY2_WG_DIR"
    return 1
  fi

  for ((i = 0; i < count; i++)); do
    hy2_wg_print_profile_row \
      "$((i + 1))" \
      "${HY2_PROFILE_NAMES[$i]}" \
      "${HY2_PROFILE_MODES[$i]}" \
      "${HY2_PROFILE_LISTENS[$i]}" \
      "${HY2_PROFILE_TARGETS[$i]}" \
      "${HY2_PROFILE_SERVICES[$i]}"
  done
}

hy2_wg_select_profile() {
  local selected count

  hy2_wg_list_profiles || return 1
  count="${#HY2_PROFILE_NAMES[@]}"
  echo
  read -r -p "Select profile [1-$count]: " selected
  if ! [[ "$selected" =~ ^[0-9]+$ ]] || ((selected < 1 || selected > count)); then
    fail_line "profile selection" "invalid selection"
    return 1
  fi

  selected=$((selected - 1))
  HY2_SELECTED_NAME="${HY2_PROFILE_NAMES[$selected]}"
  HY2_SELECTED_MODE="${HY2_PROFILE_MODES[$selected]}"
  HY2_SELECTED_CONFIG="${HY2_PROFILE_CONFIGS[$selected]}"
  HY2_SELECTED_SERVICE="${HY2_PROFILE_SERVICES[$selected]}"
  HY2_SELECTED_LISTEN="${HY2_PROFILE_LISTENS[$selected]}"
  HY2_SELECTED_TARGET="${HY2_PROFILE_TARGETS[$selected]}"
}

hy2_wg_show_selected_profile_details() {
  local server_value server_host server_port remote_value remote_host remote_port
  local sni insecure auth_secret obfs_secret service_path cert_path key_path
  local sni_guard masquerade_url obfs_type legacy_services legacy_services_text meta_path wg_iface wg_port

  service_path="$(hy2_wg_service_path "$HY2_SELECTED_SERVICE")"
  echo -e "${YELLOW}Profile details${NC}"
  echo "Profile name: $HY2_SELECTED_NAME"
  echo "Mode: $HY2_SELECTED_MODE"
  echo "Listen port: $HY2_SELECTED_LISTEN"
  echo "Config path: $HY2_SELECTED_CONFIG"
  echo "Service name: $HY2_SELECTED_SERVICE"
  if [[ "$HY2_SELECTED_SERVICE" != "none" ]]; then
    echo "Service path: $service_path"
  else
    echo "Service path: not detected"
  fi
  echo "Service status: $(hy2_wg_service_status_text "$HY2_SELECTED_SERVICE")"

  if hy2_wg_is_client_profile "$HY2_SELECTED_MODE"; then
    server_value="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "server")"
    remote_value="$(hy2_wg_extract_remote_target "$HY2_SELECTED_CONFIG")"
    hy2_wg_split_host_port "$server_value" "" "" server_host server_port
    hy2_wg_split_host_port "$remote_value" "127.0.0.1" "51820" remote_host remote_port
    sni="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "sni")"
    insecure="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "insecure")"
    auth_secret="$(hy2_wg_client_auth_secret "$HY2_SELECTED_CONFIG")"
    obfs_secret="$(hy2_wg_config_secret "$HY2_SELECTED_CONFIG" "salamander")"
    echo "Foreign Hysteria server: ${server_host:-unknown}:${server_port:-unknown}"
    echo "WireGuard target: ${remote_host:-127.0.0.1}:${remote_port:-51820}"
    echo "TLS SNI/CN: ${sni:-none}"
    echo "Insecure TLS: ${insecure:-unknown}"
    echo "Auth password: $(hy2_wg_mask_secret_value "$auth_secret")"
    echo "OBFS salamander password: $(hy2_wg_mask_secret_value "$obfs_secret")"
  else
    cert_path="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "cert")"
    key_path="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "key")"
    sni_guard="$(hy2_wg_sni_guard "$HY2_SELECTED_CONFIG")"
    masquerade_url="$(hy2_wg_masquerade_url "$HY2_SELECTED_CONFIG")"
    obfs_type="$(hy2_wg_obfs_type "$HY2_SELECTED_CONFIG")"
    auth_secret="$(hy2_wg_config_secret "$HY2_SELECTED_CONFIG" "auth")"
    obfs_secret="$(hy2_wg_config_secret "$HY2_SELECTED_CONFIG" "salamander")"
    echo "Hysteria listen address/port: :$HY2_SELECTED_LISTEN"
    echo "TLS cert path: ${cert_path:-unknown}"
    echo "TLS key path: ${key_path:-unknown}"
    echo "sniGuard: $sni_guard"
    echo "Masquerade proxy URL: $masquerade_url"
    echo "OBFS type: $obfs_type"
    if hy2_wg_is_raw_legacy_profile "$HY2_SELECTED_MODE"; then
      legacy_services="$(hy2_wg_detect_services_for_config "$HY2_SELECTED_CONFIG")"
      legacy_services_text="$(printf '%s\n' "$legacy_services" | hy2_wg_join_lines)"
      echo "Related legacy services: ${legacy_services_text:-none detected}"
      echo "Managed action hint: import this profile before editing or deleting it from the toolbox."
    else
      meta_path="$(hy2_wg_foreign_meta_path_for_config "$HY2_SELECTED_CONFIG")"
      wg_iface="$(sed -nE 's/^wg_iface=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      wg_port="$(sed -nE 's/^wg_port=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      echo "WireGuard target hint: ${wg_iface:-wg0}:${wg_port:-51820}"
    fi
    echo "Auth password: $(hy2_wg_mask_secret_value "$auth_secret")"
    echo "OBFS salamander password: $(hy2_wg_mask_secret_value "$obfs_secret")"
  fi

  echo
  echo -e "${YELLOW}Sanitized config${NC}"
  hy2_wg_sanitize_config "$HY2_SELECTED_CONFIG"
}

hy2_wg_manage_list_profiles() {
  title
  echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards > List Profiles${NC}"
  line
  hy2_wg_list_profiles || true
  echo
  echo "Hint: If old tunnels conflict, use Delete Profile first."
  pause
}

hy2_wg_manage_show_profile() {
  title
  echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards > Show Profile Details${NC}"
  line
  hy2_wg_select_profile || { pause; return; }
  echo
  hy2_wg_show_selected_profile_details
  pause
}

hy2_wg_iran_port_in_existing_config_except() {
  local port="$1"
  local except_config="$2"
  local config existing_port

  [[ -d "$HY2_WG_CLIENT_DIR" ]] || return 1
  while IFS= read -r -d '' config; do
    [[ "$config" == "$except_config" ]] && continue
    existing_port="$(hy2_wg_extract_listen_port "$config")"
    if [[ "$existing_port" == "$port" ]]; then
      return 0
    fi
  done < <(find "$HY2_WG_CLIENT_DIR" -maxdepth 1 -type f -name '*.yaml' -print0 2>/dev/null)

  return 1
}

hy2_wg_existing_listener_conflicts_except() {
  local port="$1"
  local current_port="$2"

  [[ "$port" == "$current_port" ]] && return 1
  [[ -n "$(list_listeners udp "$port")" ]]
}

hy2_wg_validate_edit_port() {
  local label="$1"
  local port="$2"
  local forbid_443="$3"

  if ! valid_port "$port"; then
    fail_line "$label" "port must be 1-65535"
    return 1
  fi

  if [[ "$forbid_443" == "true" && "$port" == "443" ]]; then
    fail_line "$label" "UDP port 443 is forbidden for Hysteria2"
    return 1
  fi
}

hy2_wg_validate_config_required_fields() {
  local mode="$1"
  local config="$2"

  if [[ ! -s "$config" ]]; then
    fail_line "config validation" "config is empty or missing"
    return 1
  fi

  if [[ "$mode" == "iran/client" ]]; then
    if ! grep -q '^server:' "$config" || ! grep -q '^[[:space:]]*- listen:' "$config" || ! grep -q '^[[:space:]]*remote:' "$config"; then
      fail_line "config validation" "required client fields missing"
      return 1
    fi
  elif ! grep -q '^listen:' "$config" || ! grep -q '^[[:space:]]*type: salamander' "$config"; then
    fail_line "config validation" "required foreign server fields missing"
    return 1
  fi

  pass_line "config validation" "required fields found"
}

hy2_wg_edit_client_profile() {
  local server_value server_host server_port remote_value remote_host remote_port
  local current_listen current_sni current_insecure current_auth current_obfs
  local new_listen new_server_host new_server_port new_remote_host new_remote_port
  local new_sni new_insecure new_auth new_obfs confirm stop_confirm restart_confirm config_path service_path

  server_value="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "server")"
  remote_value="$(hy2_wg_extract_remote_target "$HY2_SELECTED_CONFIG")"
  hy2_wg_split_host_port "$server_value" "FOREIGN_HOST" "8080" server_host server_port
  hy2_wg_split_host_port "$remote_value" "127.0.0.1" "51820" remote_host remote_port
  current_listen="$(hy2_wg_extract_listen_port "$HY2_SELECTED_CONFIG")"
  current_sni="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "sni")"
  current_insecure="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "insecure")"
  current_auth="$(hy2_wg_client_auth_secret "$HY2_SELECTED_CONFIG")"
  current_obfs="$(hy2_wg_config_secret "$HY2_SELECTED_CONFIG" "salamander")"

  new_listen="$(prompt_default "Iran local UDP listen port" "${current_listen:-31001}")"
  hy2_wg_validate_edit_port "Iran local UDP listen port" "$new_listen" "true" || return 0
  if hy2_wg_iran_port_in_existing_config_except "$new_listen" "$HY2_SELECTED_CONFIG"; then
    fail_line "duplicate local Iran listen port" "$new_listen already belongs to another generated profile"
    return
  fi
  if hy2_wg_existing_listener_conflicts_except "$new_listen" "$current_listen"; then
    fail_line "local Iran listen port" "$new_listen is already listening locally"
    return
  fi

  new_server_host="$(prompt_default "Foreign Hysteria server host/domain" "$server_host")"
  new_server_port="$(prompt_default "Foreign Hysteria UDP port" "${server_port:-8080}")"
  hy2_wg_validate_edit_port "Foreign Hysteria UDP port" "$new_server_port" "true" || return 0
  new_remote_host="$(prompt_default "Remote WireGuard host" "${remote_host:-127.0.0.1}")"
  new_remote_port="$(prompt_default "Remote WireGuard UDP port" "${remote_port:-51820}")"
  hy2_wg_validate_edit_port "Remote WireGuard UDP port" "$new_remote_port" "false" || return 0
  read -r -p "TLS SNI / CN [${current_sni:-none}, empty keeps current]: " new_sni
  new_sni="${new_sni:-$current_sni}"
  new_insecure="$(prompt_yes_no_value "Use insecure TLS?" "${current_insecure:-true}")"

  echo "Leave secrets empty to keep the existing values."
  read -r -s -p "New auth password: " new_auth; echo
  new_auth="${new_auth:-$current_auth}"
  read -r -s -p "New OBFS salamander password: " new_obfs; echo
  new_obfs="${new_obfs:-$current_obfs}"
  if [[ -z "$new_auth" || -z "$new_obfs" ]]; then
    fail_line "secrets" "existing config did not contain reusable secrets; enter both values"
    return
  fi

  echo
  echo -e "${YELLOW}Edit plan${NC}"
  echo "Profile: $HY2_SELECTED_NAME"
  echo "Iran listen: $current_listen -> $new_listen"
  echo "Foreign Hysteria: $server_host:$server_port -> $new_server_host:$new_server_port"
  echo "WireGuard target: $remote_host:$remote_port -> $new_remote_host:$new_remote_port"
  echo
  read -r -p "Continue with edit? [y/N]: " confirm
  case "$confirm" in y|Y|yes|YES) ;; *) info_line "edit profile" "cancelled before writing files"; pause; return ;; esac

  ensure_root || { pause; return; }
  service_path="$(hy2_wg_service_path "$HY2_SELECTED_SERVICE")"
  read -r -p "Stop $HY2_SELECTED_SERVICE before editing? [y/N]: " stop_confirm
  case "$stop_confirm" in y|Y|yes|YES) systemctl stop "$HY2_SELECTED_SERVICE" 2>/dev/null || true ;; esac

  backup_existing_file "$HY2_SELECTED_CONFIG"
  [[ -f "$service_path" ]] && backup_existing_file "$service_path"
  ensure_hy2_wg_dirs
  hy2_wg_write_client_config \
    "$HY2_SELECTED_NAME" \
    "$new_server_host" \
    "$new_server_port" \
    "$new_listen" \
    "$new_remote_host" \
    "$new_remote_port" \
    "$new_auth" \
    "$new_obfs" \
    "$new_sni" \
    "$new_insecure"
  config_path="$HY2_WRITTEN_CONFIG"
  hy2_wg_write_service "$HY2_SELECTED_SERVICE" "client" "$config_path" "VIPTrue Hysteria2 OBFS WireGuard Iran client $HY2_SELECTED_NAME"
  hy2_wg_validate_config_required_fields "iran/client" "$config_path" || { pause; return; }
  systemctl daemon-reload
  read -r -p "Restart $HY2_SELECTED_SERVICE now? [Y/n]: " restart_confirm
  restart_confirm="${restart_confirm:-Y}"
  case "$restart_confirm" in y|Y|yes|YES) systemctl restart "$HY2_SELECTED_SERVICE" || true ;; esac
  systemctl status "$HY2_SELECTED_SERVICE" --no-pager -l 2>/dev/null || true
  echo
  echo "Next test: Manage Existing Hysteria2 WireGuard Forwards -> Test Profile"
  echo "If you entered the wrong WireGuard internal port, use Edit Profile and change Remote WireGuard UDP port."
}

hy2_wg_edit_foreign_profile() {
  local current_listen current_auth current_obfs cert_path key_path wg_iface wg_port
  local new_listen new_auth new_obfs new_wg_iface new_wg_port confirm stop_confirm restart_confirm service_path config_path
  local tls_mode meta_path masquerade_url

  if hy2_wg_is_raw_legacy_profile "$HY2_SELECTED_MODE"; then
    fail_line "edit legacy profile" "import the /etc/hysteria profile before editing it from this manager"
    echo "Use: Manage Existing Hysteria2 WireGuard Forwards -> Import legacy /etc/hysteria profile"
    return
  fi

  current_listen="$(hy2_wg_extract_listen_port "$HY2_SELECTED_CONFIG")"
  current_auth="$(hy2_wg_config_secret "$HY2_SELECTED_CONFIG" "auth")"
  current_obfs="$(hy2_wg_config_secret "$HY2_SELECTED_CONFIG" "salamander")"
  cert_path="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "cert")"
  key_path="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "key")"
  masquerade_url="$(hy2_wg_masquerade_url "$HY2_SELECTED_CONFIG")"
  tls_mode="existing"
  if grep -q '^[[:space:]]*sniGuard:[[:space:]]*disable' "$HY2_SELECTED_CONFIG"; then
    tls_mode="self-signed"
  fi
  meta_path="$(hy2_wg_foreign_meta_path_for_config "$HY2_SELECTED_CONFIG")"
  wg_iface="$(sed -nE 's/^wg_iface=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
  wg_port="$(sed -nE 's/^wg_port=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"

  new_listen="$(prompt_default "Hysteria listen UDP port" "${current_listen:-8080}")"
  hy2_wg_validate_edit_port "Hysteria listen UDP port" "$new_listen" "true" || return 0
  new_wg_iface="$(prompt_default "WireGuard interface name" "${wg_iface:-wg0}")"
  if ! valid_iface "$new_wg_iface"; then
    fail_line "WireGuard interface name" "invalid interface name"
    return
  fi
  new_wg_port="$(prompt_default "WireGuard local UDP port" "${wg_port:-51820}")"
  hy2_wg_validate_edit_port "WireGuard local UDP port" "$new_wg_port" "false" || return 0

  echo "Leave secrets empty to keep the existing values."
  read -r -s -p "New auth password: " new_auth; echo
  new_auth="${new_auth:-$current_auth}"
  read -r -s -p "New OBFS salamander password: " new_obfs; echo
  new_obfs="${new_obfs:-$current_obfs}"
  if [[ -z "$new_auth" || -z "$new_obfs" ]]; then
    fail_line "secrets" "existing config did not contain reusable secrets; enter both values"
    return
  fi

  echo
  echo -e "${YELLOW}Edit plan${NC}"
  echo "Profile: foreign"
  echo "Hysteria listen: $current_listen -> $new_listen"
  echo "WireGuard test hint: ${wg_iface:-wg0}:${wg_port:-51820} -> $new_wg_iface:$new_wg_port"
  read -r -p "Continue with edit? [y/N]: " confirm
  case "$confirm" in y|Y|yes|YES) ;; *) info_line "edit profile" "cancelled before writing files"; pause; return ;; esac

  ensure_root || { pause; return; }
  service_path="$(hy2_wg_service_path "$HY2_SELECTED_SERVICE")"
  read -r -p "Stop $HY2_SELECTED_SERVICE before editing? [y/N]: " stop_confirm
  case "$stop_confirm" in y|Y|yes|YES) systemctl stop "$HY2_SELECTED_SERVICE" 2>/dev/null || true ;; esac

  backup_existing_file "$HY2_SELECTED_CONFIG"
  [[ -f "$service_path" ]] && backup_existing_file "$service_path"
  hy2_wg_write_foreign_config "$new_listen" "$new_auth" "$new_obfs" "$tls_mode" "$cert_path" "$key_path" "$masquerade_url" "$HY2_SELECTED_CONFIG"
  config_path="$HY2_WRITTEN_CONFIG"
  hy2_wg_write_service "$HY2_SELECTED_SERVICE" "server" "$config_path" "VIPTrue Hysteria2 OBFS WireGuard foreign server"
  {
    echo "wg_iface=$new_wg_iface"
    echo "wg_port=$new_wg_port"
  } > "$meta_path"
  chmod 600 "$meta_path" 2>/dev/null || true
  hy2_wg_validate_config_required_fields "foreign" "$config_path" || { pause; return; }
  systemctl daemon-reload
  read -r -p "Restart $HY2_SELECTED_SERVICE now? [Y/n]: " restart_confirm
  restart_confirm="${restart_confirm:-Y}"
  case "$restart_confirm" in y|Y|yes|YES) systemctl restart "$HY2_SELECTED_SERVICE" || true ;; esac
  systemctl status "$HY2_SELECTED_SERVICE" --no-pager -l 2>/dev/null || true
  echo
  echo "Next test: Manage Existing Hysteria2 WireGuard Forwards -> Test Profile"
}

hy2_wg_manage_edit_profile() {
  title
  echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards > Edit Profile${NC}"
  line
  echo "Hint: If you entered the wrong WireGuard internal port, use Edit Profile and change Remote WireGuard UDP port."
  echo
  hy2_wg_select_profile || { pause; return; }
  echo

  if [[ "$HY2_SELECTED_MODE" == "iran/client" ]]; then
    hy2_wg_edit_client_profile
  else
    hy2_wg_edit_foreign_profile
  fi

  set_summary \
    "Selected profile edit validation, config/service backup, generated config validation, and optional restart." \
    "If edit failed, the invalid port, duplicate listener, or root/systemd step above identifies the likely issue." \
    "Rerun Edit Profile with corrected values, then Test Profile." \
    "Maybe: service restart and firewall/provider updates may be needed."
  print_summary
  pause
}

hy2_wg_archive_path_for() {
  local path="$1"
  local stamp="$2"
  local base

  base="$(basename "$path")"
  printf '%s/%s/%s\n' "$HY2_WG_ARCHIVE_DIR" "$stamp" "$base"
}

hy2_wg_manage_delete_profile() {
  local confirm stamp service_path archive_dir cert_path key_path meta_path destination

  title
  echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards > Delete Profile${NC}"
  line
  hy2_wg_select_profile || { pause; return; }
  echo
  if hy2_wg_is_raw_legacy_profile "$HY2_SELECTED_MODE"; then
    fail_line "delete legacy profile" "raw /etc/hysteria files are not archived by this manager"
    echo "Use Import legacy /etc/hysteria profile first; imported managed files can then be archived safely."
    pause
    return
  fi
  service_path="$(hy2_wg_service_path "$HY2_SELECTED_SERVICE")"
  cert_path=""
  key_path=""
  meta_path=""
  if hy2_wg_is_foreign_profile "$HY2_SELECTED_MODE"; then
    cert_path="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "cert")"
    key_path="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "key")"
    meta_path="$(hy2_wg_foreign_meta_path_for_config "$HY2_SELECTED_CONFIG")"
  fi

  echo -e "${YELLOW}Delete plan${NC}"
  echo "Profile: $HY2_SELECTED_NAME"
  echo "Config file: $HY2_SELECTED_CONFIG"
  echo "Systemd service file: $service_path"
  [[ -n "$cert_path" ]] && echo "Generated cert, if profile-specific: $cert_path"
  [[ -n "$key_path" ]] && echo "Generated key, if profile-specific: $key_path"
  [[ -n "$meta_path" ]] && echo "Metadata file: $meta_path"
  echo "Files will be moved to an archive directory, not hard-deleted."
  echo
  read -r -p "Type DELETE to archive this profile: " confirm
  if [[ "$confirm" != "DELETE" ]]; then
    fail_line "delete confirmation" "exact DELETE was not entered; no files moved"
    set_summary \
      "Delete profile confirmation." \
      "Deletion was refused because exact DELETE was not entered." \
      "Rerun Delete Profile and type DELETE only when ready." \
      "No server-side change was made."
    print_summary
    pause
    return
  fi

  ensure_root || { pause; return; }
  stamp="$(date +%Y%m%d-%H%M%S)-$HY2_SELECTED_NAME"
  archive_dir="$HY2_WG_ARCHIVE_DIR/$stamp"
  mkdir -p "$archive_dir"
  chmod 700 "$archive_dir" 2>/dev/null || true

  if have_cmd systemctl; then
    systemctl stop "$HY2_SELECTED_SERVICE" 2>/dev/null || true
    systemctl disable "$HY2_SELECTED_SERVICE" 2>/dev/null || true
  fi

  for path in "$HY2_SELECTED_CONFIG" "$service_path" "$cert_path" "$key_path" "$meta_path"; do
    [[ -n "$path" && -e "$path" ]] || continue
    destination="$(hy2_wg_archive_path_for "$path" "$stamp")"
    mv "$path" "$destination"
    pass_line "archived" "$path -> $destination"
  done

  have_cmd systemctl && systemctl daemon-reload
  echo
  echo "Rollback path: $archive_dir"
  set_summary \
    "Delete profile archive workflow." \
    "Profile files were moved to archive instead of hard-deleted." \
    "To roll back, move files from the archive path back to their original paths and run systemctl daemon-reload." \
    "Yes: restore/restart service if rollback is needed."
  print_summary
  pause
}

hy2_wg_manage_restart_profile() {
  title
  echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards > Restart Profile Service${NC}"
  line
  hy2_wg_select_profile || { pause; return; }
  echo
  if [[ "$HY2_SELECTED_SERVICE" == "none" ]]; then
    fail_line "restart profile" "no related service was detected for this profile"
    pause
    return
  fi
  ensure_root || { pause; return; }
  require_cmd systemctl systemd || { pause; return; }
  systemctl daemon-reload
  systemctl restart "$HY2_SELECTED_SERVICE"
  systemctl status "$HY2_SELECTED_SERVICE" --no-pager -l || true
  echo
  echo -e "${YELLOW}Recent logs${NC}"
  journalctl -u "$HY2_SELECTED_SERVICE" -n 40 --no-pager 2>/dev/null || true
  set_summary \
    "Profile service restart and recent journal logs." \
    "If restart failed, service status and journal output identify the likely issue." \
    "Fix config/service errors, then restart or Test Profile again." \
    "Maybe: server-side service/config action may be needed."
  print_summary
  pause
}

hy2_wg_manage_test_profile() {
  local server_value server_host server_port remote_value remote_host remote_port wg_iface wg_port meta_path

  title
  echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards > Test Profile${NC}"
  line
  hy2_wg_select_profile || { pause; return; }
  echo

  if hy2_wg_is_foreign_profile "$HY2_SELECTED_MODE"; then
    meta_path="$(hy2_wg_foreign_meta_path_for_config "$HY2_SELECTED_CONFIG")"
    wg_iface="$(sed -nE 's/^wg_iface=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
    wg_port="$(sed -nE 's/^wg_port=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
    hy2_wg_foreign_post_tests "$HY2_SELECTED_SERVICE" "$HY2_SELECTED_LISTEN" "${wg_iface:-wg0}" "${wg_port:-51820}"
    if hy2_wg_is_raw_legacy_profile "$HY2_SELECTED_MODE"; then
      warn_line "legacy management" "import this profile before editing or deleting it from the toolbox"
    fi
    echo
    echo "Optional next step: Hysteria2 OBFS -> WireGuard Forward -> Wait for WireGuard Handshake"
  else
    server_value="$(hy2_wg_field_value "$HY2_SELECTED_CONFIG" "server")"
    remote_value="$(hy2_wg_extract_remote_target "$HY2_SELECTED_CONFIG")"
    hy2_wg_split_host_port "$server_value" "FOREIGN_HOST" "8080" server_host server_port
    hy2_wg_split_host_port "$remote_value" "127.0.0.1" "51820" remote_host remote_port
    hy2_wg_iran_post_profile_tests "$HY2_SELECTED_NAME" "$server_host" "$server_port" "$HY2_SELECTED_LISTEN"
    echo "Remote WireGuard target through foreign server: $remote_host:$remote_port"
    warn_line "final proof" "requires WireGuard handshake traffic from a PasarGuard test user"
  fi

  set_summary \
    "Selected profile service, listener, and WireGuard/Hysteria target checks." \
    "Failures identify whether service, local listener, foreign path, or WireGuard target needs attention." \
    "Fix the failed layer, then run Test Profile or Wait for WireGuard Handshake again." \
    "Maybe: server-side service/firewall/WireGuard action may be needed."
  print_summary
  pause
}

hy2_wg_manage_import_legacy_profile() {
  local profile listen_port service_name dest_dir dest_config dest_cert dest_key meta_path service_path
  local legacy_services legacy_services_text wg_iface wg_port confirm start_now disable_old service active_ok stamp archive_dir

  title
  echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards > Import legacy /etc/hysteria profile${NC}"
  line
  echo

  if ! hy2_wg_legacy_config_present; then
    fail_line "legacy profile" "expected $HY2_LEGACY_CONFIG, $HY2_LEGACY_CERT, and $HY2_LEGACY_KEY"
    set_summary \
      "Legacy /etc/hysteria profile detection." \
      "The legacy config, cert, or key file was not found." \
      "Check the legacy paths or create a Hysteria2 profile before importing." \
      "No server-side change was made."
    print_summary
    pause
    return
  fi

  listen_port="$(hy2_wg_extract_listen_port "$HY2_LEGACY_CONFIG")"
  hy2_wg_validate_edit_port "Legacy Hysteria UDP listen port" "$listen_port" "true" || { pause; return; }

  profile="$(prompt_default "Managed legacy profile name" "legacy-proven-foreign")"
  if ! valid_profile_name "$profile"; then
    fail_line "profile name" "use 1-32 letters, numbers, dot, underscore, or dash"
    pause
    return
  fi

  wg_iface="$(prompt_default "WireGuard interface name for tests" "wg0")"
  if ! valid_iface "$wg_iface"; then
    fail_line "WireGuard interface name" "invalid interface name"
    pause
    return
  fi

  wg_port="$(prompt_default "WireGuard local UDP port for tests" "51820")"
  hy2_wg_validate_edit_port "WireGuard local UDP port" "$wg_port" "false" || { pause; return; }

  service_name="$(hy2_wg_legacy_service_name "$profile")"
  dest_dir="$HY2_WG_LEGACY_DIR/$profile"
  dest_config="$dest_dir/config.yaml"
  dest_cert="$dest_dir/server.crt"
  dest_key="$dest_dir/server.key"
  meta_path="$dest_dir/profile.meta"
  service_path="$(hy2_wg_service_path "$service_name")"
  legacy_services="$(hy2_wg_detect_services_for_config "$HY2_LEGACY_CONFIG")"
  legacy_services_text="$(printf '%s\n' "$legacy_services" | hy2_wg_join_lines)"

  echo -e "${YELLOW}Import plan${NC}"
  echo "Legacy config: $HY2_LEGACY_CONFIG"
  echo "Legacy cert/key: $HY2_LEGACY_CERT / $HY2_LEGACY_KEY"
  echo "Legacy listen port: $listen_port"
  echo "Related old service(s): ${legacy_services_text:-none detected}"
  echo "Managed directory: $dest_dir"
  echo "Managed service: $service_name"
  echo "Old files and old service will stay in place unless you explicitly disable the old service after import."
  echo "Existing managed files will be archived before replacement."
  echo
  read -r -p "Import this legacy profile now? [y/N]: " confirm
  case "$confirm" in y|Y|yes|YES) ;; *) info_line "legacy import" "cancelled before writing files"; pause; return ;; esac

  ensure_root || { pause; return; }
  require_cmd systemctl systemd || { pause; return; }
  ensure_hy2_wg_dirs
  mkdir -p "$dest_dir" "$HY2_SYSTEMD_SYSTEM_DIR"
  chmod 700 "$dest_dir" 2>/dev/null || true

  stamp="$(date +%Y%m%d-%H%M%S)-import-$profile"
  archive_dir="$HY2_WG_ARCHIVE_DIR/$stamp"
  mkdir -p "$archive_dir"
  chmod 700 "$archive_dir" 2>/dev/null || true
  cp -a "$HY2_LEGACY_CONFIG" "$archive_dir/source-config.yaml"
  cp -a "$HY2_LEGACY_CERT" "$archive_dir/source-server.crt"
  cp -a "$HY2_LEGACY_KEY" "$archive_dir/source-server.key"
  pass_line "legacy backup" "$archive_dir"

  hy2_wg_archive_existing_path "$dest_config" "$archive_dir"
  hy2_wg_archive_existing_path "$dest_cert" "$archive_dir"
  hy2_wg_archive_existing_path "$dest_key" "$archive_dir"
  hy2_wg_archive_existing_path "$meta_path" "$archive_dir"
  hy2_wg_archive_existing_path "$service_path" "$archive_dir"

  cp -a "$HY2_LEGACY_CERT" "$dest_cert"
  cp -a "$HY2_LEGACY_KEY" "$dest_key"
  hy2_wg_copy_legacy_config_for_import "$HY2_LEGACY_CONFIG" "$dest_config" "$dest_cert" "$dest_key"
  chmod 600 "$dest_config" "$dest_key" 2>/dev/null || true
  chmod 644 "$dest_cert" 2>/dev/null || true

  {
    echo "source_config=$HY2_LEGACY_CONFIG"
    echo "source_services=${legacy_services_text:-none}"
    echo "wg_iface=$wg_iface"
    echo "wg_port=$wg_port"
  } > "$meta_path"
  chmod 600 "$meta_path" 2>/dev/null || true

  hy2_wg_write_service "$service_name" "server" "$dest_config" "VIPTrue Hysteria2 legacy imported foreign server $profile"
  hy2_wg_validate_config_required_fields "foreign" "$dest_config" || { pause; return; }
  systemctl daemon-reload

  start_now="$(prompt_yes_no_value "Enable and start $service_name now?" "Y")"
  active_ok="false"
  if [[ "$start_now" == "true" ]]; then
    if systemctl enable --now "$service_name"; then
      sleep 1
      if hy2_wg_service_active "$service_name"; then
        active_ok="true"
        pass_line "$service_name" "active"
      else
        fail_line "$service_name" "not active after start attempt"
      fi
    else
      fail_line "$service_name" "systemctl enable/start failed"
    fi
  else
    info_line "$service_name" "written but not started"
  fi

  if [[ "$active_ok" == "true" && -n "${legacy_services_text:-}" ]]; then
    read -r -p "Disable old legacy service(s) now? [y/N]: " disable_old
    case "$disable_old" in
      y|Y|yes|YES)
        while IFS= read -r service; do
          [[ -n "$service" && "$service" != "$service_name" ]] || continue
          systemctl disable --now "$service" 2>/dev/null || true
          pass_line "old service disable attempted" "$service"
        done <<< "$legacy_services"
        ;;
      *) info_line "old legacy service" "left enabled/running unless you stop it manually" ;;
    esac
  else
    warn_line "old legacy service" "not disabled; managed service is not confirmed active or no old service was detected"
  fi

  echo
  echo "Imported profile path: $dest_dir"
  echo "Rollback archive: $archive_dir"
  echo "Next test: Manage Existing Hysteria2 WireGuard Forwards -> Test Profile"
  set_summary \
    "Legacy /etc/hysteria import into the managed Hysteria2 WireGuard directory." \
    "If import or start failed, the config/service output above identifies the failed layer." \
    "Run Test Profile, then Check legacy conflicts before moving traffic." \
    "Maybe: disable the old service only after the imported service is active and tested."
  print_summary
  pause
}

hy2_wg_manage_legacy_conflicts() {
  local legacy_port config port duplicate_found listener_output listener_count
  local legacy_services service legacy_active imported_active profile managed_service

  title
  echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards > Check legacy conflicts${NC}"
  line
  echo

  if ! hy2_wg_legacy_config_present; then
    fail_line "legacy profile" "expected $HY2_LEGACY_CONFIG, $HY2_LEGACY_CERT, and $HY2_LEGACY_KEY"
    pause
    return
  fi

  legacy_port="$(hy2_wg_extract_listen_port "$HY2_LEGACY_CONFIG")"
  if hy2_wg_validate_edit_port "Legacy Hysteria UDP listen port" "$legacy_port" "true"; then
    pass_line "legacy UDP listen port" "$legacy_port"
  fi

  duplicate_found="false"
  while IFS= read -r config; do
    [[ -n "$config" ]] || continue
    port="$(hy2_wg_extract_listen_port "$config")"
    [[ -n "$port" ]] || continue
    if [[ "$port" == "$legacy_port" ]]; then
      duplicate_found="true"
      fail_line "duplicate managed UDP listen port" "$config also uses UDP $legacy_port"
    fi
  done < <(hy2_wg_each_managed_config)

  if [[ "$duplicate_found" == "false" ]]; then
    pass_line "managed UDP listen ports" "no managed config duplicates legacy UDP $legacy_port"
  fi

  listener_output="$(list_listeners udp "$legacy_port")"
  listener_count="$(printf '%s\n' "$listener_output" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if ((listener_count > 1)); then
    fail_line "local UDP listeners" "multiple listeners appear on UDP $legacy_port"
    printf '%s\n' "$listener_output"
  elif ((listener_count == 1)); then
    pass_line "local UDP listener" "one listener appears on UDP $legacy_port"
    printf '%s\n' "$listener_output"
  else
    warn_line "local UDP listener" "no local listener found on UDP $legacy_port or listener tool unavailable"
  fi

  legacy_services="$(hy2_wg_detect_services_for_config "$HY2_LEGACY_CONFIG")"
  legacy_active="false"
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    if hy2_wg_service_active "$service"; then
      legacy_active="true"
      pass_line "active legacy service" "$service"
    fi
  done <<< "$legacy_services"
  [[ "$legacy_active" == "true" ]] || warn_line "active legacy service" "none detected active"

  imported_active="false"
  if [[ -d "$HY2_WG_LEGACY_DIR" ]]; then
    while IFS= read -r -d '' config; do
      profile="$(hy2_wg_managed_legacy_profile_name "$config")"
      managed_service="$(hy2_wg_legacy_service_name "$profile")"
      if hy2_wg_service_active "$managed_service"; then
        imported_active="true"
        pass_line "active imported service" "$managed_service"
      fi
    done < <(find "$HY2_WG_LEGACY_DIR" -mindepth 2 -maxdepth 2 -type f -name 'config.yaml' -print0 2>/dev/null)
  fi
  [[ "$imported_active" == "true" ]] || warn_line "active imported service" "none detected active"

  if [[ "$legacy_active" == "true" && "$imported_active" == "true" ]]; then
    fail_line "old/new service overlap" "old legacy service and imported managed service are active at the same time"
  else
    pass_line "old/new service overlap" "no active old/new overlap detected"
  fi

  set_summary \
    "Legacy config, duplicate UDP listen ports, local listeners, and old/new service overlap." \
    "Duplicate ports or simultaneous old/new active services can make the toolbox appear to import correctly while traffic still hits the wrong service." \
    "Stop or disable only the old service after the imported managed service is active and tested." \
    "Maybe: service disable or firewall/provider cleanup may be needed."
  print_summary
  pause
}

hy2_wg_manage_existing_menu() {
  while true; do
    title
    echo -e "${CYAN}Manage Existing Hysteria2 WireGuard Forwards${NC}"
    line
    echo
    echo "1. List profiles"
    echo "2. Show profile details"
    echo "3. Edit profile"
    echo "4. Delete profile"
    echo "5. Restart profile service"
    echo "6. Test profile"
    echo "7. Import legacy /etc/hysteria profile"
    echo "8. Check legacy conflicts"
    echo "9. Back"
    echo
    echo "Hint: If you entered the wrong WireGuard internal port, use Edit Profile and change Remote WireGuard UDP port."
    echo "Hint: If old tunnels conflict, use Delete Profile first."
    echo
    read -r -p "Enter your choice [1-9]: " choice

    case "$choice" in
      1) hy2_wg_manage_list_profiles ;;
      2) hy2_wg_manage_show_profile ;;
      3) hy2_wg_manage_edit_profile ;;
      4) hy2_wg_manage_delete_profile ;;
      5) hy2_wg_manage_restart_profile ;;
      6) hy2_wg_manage_test_profile ;;
      7) hy2_wg_manage_import_legacy_profile ;;
      8) hy2_wg_manage_legacy_conflicts ;;
      9) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

hy2_wg_forward_menu() {
  while true; do
    title
    echo -e "${CYAN}Hysteria2 OBFS -> WireGuard Forward${NC}"
    line
    echo
    echo "1. Foreign server mode"
    echo "2. Legacy Proven Foreign Mode (/etc/hysteria + Bing masquerade)"
    echo "3. Iran server mode"
    echo "4. Wait for WireGuard Handshake"
    echo "5. Synthetic WireGuard Handshake Test"
    echo "6. Manage Existing Hysteria2 WireGuard Forwards"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-6]: " choice

    case "$choice" in
      1) hy2_wg_setup_foreign_server ;;
      2) hy2_wg_setup_legacy_proven_foreign_server ;;
      3) hy2_wg_setup_iran_server ;;
      4) hy2_wg_wait_for_wireguard_handshake ;;
      5) hy2_wg_synthetic_menu ;;
      6) hy2_wg_manage_existing_menu ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

reverse_tls_sni_notes() {
  local local_port placeholder_domain

  title
  echo -e "${CYAN}Tunnel Manager > Reverse TLS / SNI Notes${NC}"
  line
  echo

  placeholder_domain="YOUR_DOMAIN.example"
  local_port="$(prompt_default "Local TLS listener port to check" "8443")"
  if ! valid_port "$local_port"; then
    fail_line "local listener port" "ports must be 1-65535"
    pause
    return
  fi

  echo -e "${YELLOW}Checklist${NC}"
  echo "[ ] DNS points to the Iran server or target server as intended."
  echo "[ ] CDN/proxy status is suitable for tunnel use, not accidentally intercepting unsupported traffic."
  echo "[ ] Local TCP listener exists on the expected port."
  echo "[ ] TLS handshake can be tested with openssl from a remote host."
  echo "[ ] SNI uses a reviewed placeholder during planning; do not paste real domains into logs."
  echo

  check_local_listener tcp "$local_port"

  echo
  if have_cmd openssl; then
    pass_line "openssl" "$(command -v openssl)"
  else
    warn_line "openssl" "suggest: $(install_hint openssl)"
  fi

  echo
  echo -e "${YELLOW}Placeholder commands${NC}"
  cat <<EOF_TLS
DNS review:
  dig +short $placeholder_domain

TLS handshake from a remote test host:
  openssl s_client -connect $placeholder_domain:$local_port -servername $placeholder_domain -brief

Local listener:
  ss -ltnp | grep ':$local_port'
EOF_TLS

  set_summary \
    "Reverse TLS/SNI checklist, local TCP listener, and openssl availability." \
    "DNS/CDN mismatch, no local listener, or TLS handshake failure are likely blockers." \
    "Verify DNS/CDN settings and test TLS from a remote host using placeholders first." \
    "Maybe: DNS, CDN/proxy mode, TLS certificate, or listener service may need server-side changes."
  print_summary
  pause
}

diagnostics_summary_screen() {
  title
  echo -e "${CYAN}Tunnel Manager > Diagnostics Summary${NC}"
  print_summary
  pause
}

exit_toolbox() {
  clear
  echo "Bye."
  exit 0
}

while true; do
  title
  echo -e "${CYAN}Tunnel Manager${NC}"
  line
  echo
  echo "1. Preflight checks"
  echo "2. Quality tests"
  echo "3. Port checks"
  echo "4. GRE helper"
  echo "5. WireGuard helper"
  echo "6. Hysteria2 helper"
  echo "7. Hysteria2 OBFS -> WireGuard Forward"
  echo "8. Reverse TLS / SNI notes"
  echo "9. Diagnostics summary"
  echo "0. Back"
  echo "99. Exit"
  echo
  read -r -p "Enter your choice [0-9,99]: " choice

  case "$choice" in
    1) preflight_checks ;;
    2) quality_tests ;;
    3) port_checks ;;
    4) gre_helper ;;
    5) wireguard_helper ;;
    6) hysteria2_helper ;;
    7) hy2_wg_forward_menu ;;
    8) reverse_tls_sni_notes ;;
    9) diagnostics_summary_screen ;;
    0) break ;;
    99) exit_toolbox ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
