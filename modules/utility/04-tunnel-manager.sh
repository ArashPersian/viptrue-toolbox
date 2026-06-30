#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/ui.sh
source "$BASE_DIR/lib/ui.sh"

LAST_CHECKED="No diagnostics have been run yet."
LAST_ISSUE="Run a Tunnel Manager check first."
LAST_TUNNEL_STATE="Unknown."
LAST_ACTION="Start with Preflight Checks."
LAST_SERVER_ACTION="Unknown."

HY2_WG_DIR="${VIPTRUE_HY2_WG_DIR:-/etc/viptrue-hy2-wg-forward}"
HY2_WG_CLIENT_DIR="$HY2_WG_DIR/clients"
HY2_WG_CERT_DIR="$HY2_WG_DIR/certs"
HY2_WG_LEGACY_DIR="$HY2_WG_DIR/legacy"
HY2_WG_ARCHIVE_DIR="$HY2_WG_DIR/archive"
HY2_WG_AUTO_DIR="$HY2_WG_DIR/auto"
HY2_WG_AUTO_FOREIGN_DIR="$HY2_WG_AUTO_DIR/foreign"
HY2_WG_AUTO_IRAN_DIR="$HY2_WG_AUTO_DIR/iran"
HY2_WG_SERVICE_PREFIX="viptrue-hy2-wg"
HY2_AUTO_FOREIGN_SERVICE_PREFIX="viptrue-auto-hy2-foreign"
HY2_AUTO_IRAN_SERVICE_PREFIX="viptrue-auto-hy2-iran"
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
  LAST_TUNNEL_STATE="${5:-Unknown.}"
}

print_summary() {
  echo
  line
  echo -e "${CYAN}Diagnostics Summary${NC}"
  echo
  echo "Checked:"
  echo "  $LAST_CHECKED"
  echo
  echo "Result:"
  echo "  $LAST_ISSUE"
  echo
  echo "Tunnel state:"
  echo "  $LAST_TUNNEL_STATE"
  echo
  echo "Next:"
  echo "  $LAST_ACTION"
  echo
  echo "Server-side action:"
  echo "  $LAST_SERVER_ACTION"
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
  mkdir -p "$HY2_WG_CLIENT_DIR" "$HY2_WG_CERT_DIR" "$HY2_WG_LEGACY_DIR" "$HY2_WG_ARCHIVE_DIR" "$HY2_WG_AUTO_FOREIGN_DIR" "$HY2_WG_AUTO_IRAN_DIR"
  chmod 700 "$HY2_WG_DIR" "$HY2_WG_CLIENT_DIR" "$HY2_WG_CERT_DIR" "$HY2_WG_LEGACY_DIR" "$HY2_WG_ARCHIVE_DIR" "$HY2_WG_AUTO_DIR" "$HY2_WG_AUTO_FOREIGN_DIR" "$HY2_WG_AUTO_IRAN_DIR" 2>/dev/null || true
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
  local config_path="${11:-$HY2_WG_CLIENT_DIR/$profile.yaml}"
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

hy2_auto_service_name() {
  local role="$1"
  local profile="$2"

  case "$role" in
    foreign) printf '%s-%s.service\n' "$HY2_AUTO_FOREIGN_SERVICE_PREFIX" "$profile" ;;
    iran) printf '%s-%s.service\n' "$HY2_AUTO_IRAN_SERVICE_PREFIX" "$profile" ;;
  esac
}

hy2_auto_foreign_config_path() {
  local profile="$1"

  printf '%s/%s/config.yaml\n' "$HY2_WG_AUTO_FOREIGN_DIR" "$profile"
}

hy2_auto_iran_config_path() {
  local profile="$1"

  printf '%s/%s.yaml\n' "$HY2_WG_AUTO_IRAN_DIR" "$profile"
}

hy2_auto_meta_path() {
  local role="$1"
  local profile="$2"

  if [[ "$role" == "foreign" ]]; then
    printf '%s/%s/profile.meta\n' "$HY2_WG_AUTO_FOREIGN_DIR" "$profile"
  else
    printf '%s/%s.meta\n' "$HY2_WG_AUTO_IRAN_DIR" "$profile"
  fi
}

hy2_auto_random_secret() {
  local secret

  if have_cmd openssl; then
    secret="$(openssl rand -base64 32 2>/dev/null | tr '+/' '-_' | tr -d '=[:space:]' | cut -c1-32)"
  else
    secret="$(date +%s%N | sha256sum 2>/dev/null | awk '{print $1}' | cut -c1-32)"
  fi
  printf '%s\n' "$secret"
}

hy2_auto_detect_wg_iface() {
  local interfaces iface

  if have_cmd wg; then
    interfaces="$(wg show interfaces 2>/dev/null || true)"
    for iface in $interfaces; do
      [[ "$iface" == "wg0" ]] && { printf 'wg0\n'; return; }
    done
    for iface in $interfaces; do
      [[ -n "$iface" ]] && { printf '%s\n' "$iface"; return; }
    done
  fi

  printf 'wg0\n'
}

hy2_auto_detect_wg_port() {
  local iface="$1"
  local port

  if have_cmd wg; then
    port="$(wg show "$iface" listen-port 2>/dev/null | head -n 1 || true)"
    if valid_port "$port"; then
      printf '%s\n' "$port"
      return
    fi
  fi

  printf '51820\n'
}

hy2_auto_candidate_port() {
  local port
  local candidates=(2087 2086 8443 8080 2096 62000)

  for port in "${candidates[@]}"; do
    [[ "$port" == "443" ]] && continue
    if [[ -z "$(list_listeners udp "$port")" ]]; then
      printf '%s\n' "$port"
      return
    fi
  done

  printf '2087\n'
}

hy2_auto_print_recommendation() {
  local port="$1"
  local score=0
  local reasons=()

  [[ "$port" != "443" ]] && score=$((score + 20))
  if [[ -z "$(list_listeners udp "$port")" ]]; then
    score=$((score + 20))
    reasons+=("UDP $port is free locally")
  else
    reasons+=("UDP $port already has a local listener")
  fi
  score=$((score + 30))
  reasons+=("proven working profile: Hysteria2 OBFS salamander + Bing masquerade + self-signed/insecure TLS")
  reasons+=("lower detection risk wording only; no bypass success is promised")

  echo
  echo -e "${YELLOW}Recommended tunnel profile${NC}"
  echo "Profile: Hysteria2 OBFS salamander + Bing masquerade + self-signed/insecure TLS"
  echo "Recommended Hysteria UDP port: $port"
  echo "Score: $score"
  echo "Why selected:"
  printf '  - %s\n' "${reasons[@]}"
  echo "What was tested:"
  echo "  - local UDP port availability"
  echo "What was not proven:"
  echo "  - remote reachability, censorship behavior, and WireGuard authentication before setup tests run"
}

hy2_expert_print_generic_recommendation() {
  local port="$1"
  local score=0
  local reasons=()

  [[ "$port" != "443" ]] && score=$((score + 20))
  if [[ -z "$(list_listeners udp "$port")" ]]; then
    score=$((score + 20))
    reasons+=("UDP $port is free locally")
  else
    reasons+=("UDP $port already has a local listener")
  fi
  score=$((score + 30))
  reasons+=("proven working profile: Hysteria2 OBFS salamander + Bing masquerade + self-signed/insecure TLS")
  reasons+=("lower detection-risk wording only; no bypass success is promised")

  echo
  echo -e "${YELLOW}Recommended tunnel profile${NC}"
  echo "Profile: Hysteria2 OBFS salamander + Bing masquerade + self-signed/insecure TLS"
  echo "Recommended Hysteria UDP port: $port"
  echo "Score: $score"
  echo "Why selected:"
  printf '  - %s\n' "${reasons[@]}"
  echo "What was tested:"
  echo "  - local UDP port availability"
  echo "What was not proven:"
  echo "  - remote reachability, filtering behavior, and destination payload delivery before setup tests run"
}

hy2_auto_bundle_value() {
  local bundle="$1"
  local key="$2"
  local pair pair_key pair_value
  local -a fields=()

  bundle="${bundle#VIPTRUE_TUNNEL_BUNDLE=}"
  bundle="${bundle#VIPTRUE_TEST_PEER_BUNDLE=}"
  IFS=';' read -r -a fields <<< "$bundle"
  for pair in "${fields[@]}"; do
    pair_key="${pair%%=*}"
    pair_value="${pair#*=}"
    if [[ "$pair_key" == "$key" ]]; then
      printf '%s\n' "$pair_value"
      return 0
    fi
  done
}

hy2_auto_validate_tunnel_bundle() {
  local bundle="$1"
  local type foreign_host hy2_port wg_host wg_port sni insecure auth obfs

  type="$(hy2_auto_bundle_value "$bundle" "type")"
  foreign_host="$(hy2_auto_bundle_value "$bundle" "foreign_host")"
  hy2_port="$(hy2_auto_bundle_value "$bundle" "hy2_port")"
  wg_host="$(hy2_auto_bundle_value "$bundle" "wg_host")"
  wg_port="$(hy2_auto_bundle_value "$bundle" "wg_port")"
  sni="$(hy2_auto_bundle_value "$bundle" "sni")"
  insecure="$(hy2_auto_bundle_value "$bundle" "insecure")"
  auth="$(hy2_auto_bundle_value "$bundle" "auth")"
  obfs="$(hy2_auto_bundle_value "$bundle" "obfs")"

  case "$type" in
    udp-wg-hy2|udp-generic-hy2) ;;
    *) fail_line "bundle type" "expected udp-wg-hy2 or udp-generic-hy2"; return 1 ;;
  esac

  if [[ -z "${foreign_host// /}" ]]; then
    fail_line "bundle foreign_host" "missing"
    return 1
  fi
  if ! valid_port "$hy2_port"; then
    fail_line "bundle hy2_port" "invalid"
    return 1
  fi
  if [[ "$hy2_port" == "443" ]]; then
    fail_line "bundle hy2_port" "UDP port 443 is forbidden for Hysteria2"
    return 1
  fi
  if [[ -z "${wg_host// /}" ]]; then
    fail_line "bundle wg_host" "missing"
    return 1
  fi
  if ! valid_port "$wg_port"; then
    fail_line "bundle wg_port" "invalid"
    return 1
  fi
  if [[ -z "${sni// /}" || "$insecure" != "true" || -z "${auth// /}" || -z "${obfs// /}" ]]; then
    fail_line "bundle secrets/TLS" "missing sni, insecure=true, auth, or obfs"
    return 1
  fi

  pass_line "bundle validation" "$type for $foreign_host:$hy2_port"
}

hy2_auto_endpoint_hints() {
  local outbound local_ips route_src

  echo
  echo -e "${YELLOW}Iran public endpoint hints${NC}"
  outbound="$(detect_public_ip)"
  echo "Detected outbound public IP hint: $outbound"
  if have_cmd hostname; then
    local_ips="$(hostname -I 2>/dev/null | tr -s ' ' || true)"
    echo "Local IPv4 hints: ${local_ips:-unknown}"
  fi
  if have_cmd ip; then
    route_src="$(ip route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1)"
    echo "Default-route source hint: ${route_src:-unknown}"
  fi
  warn_line "endpoint confirmation" "enter the real inbound public IP/domain clients will use; do not rely only on api.ipify"
}

hy2_auto_service_logs_contain() {
  local service_name="$1"
  local pattern="$2"

  have_cmd journalctl || return 1
  journalctl -u "$service_name" -n 120 --no-pager 2>/dev/null | grep -Eiq "$pattern"
}

hy2_auto_quick_health_test() {
  local service_name="$1"
  local iran_port="$2"
  local score=0
  local listener_output

  echo
  line
  echo -e "${CYAN}Auto Quick Health Test${NC}"

  if hy2_wg_service_active "$service_name"; then
    score=$((score + 30))
    pass_line "service active" "$service_name"
  else
    fail_line "service active" "$service_name inactive or systemctl unavailable"
  fi

  listener_output="$(list_listeners udp "$iran_port")"
  if [[ -n "$listener_output" ]]; then
    score=$((score + 20))
    pass_line "local listener active" "UDP $iran_port"
  else
    fail_line "local listener active" "UDP $iran_port not detected"
  fi

  if hy2_auto_service_logs_contain "$service_name" 'connected to server'; then
    score=$((score + 25))
    pass_line "connected to server log" "found"
  else
    warn_line "connected to server log" "not found in recent journal"
  fi

  if hy2_auto_service_logs_contain "$service_name" 'UDP forwarding listening|udp forwarding listening'; then
    score=$((score + 25))
    pass_line "UDP forwarding listening log" "found"
  else
    warn_line "UDP forwarding listening log" "not found in recent journal"
  fi

  echo
  echo "Recommended tunnel profile: proven working profile"
  echo "Score: $score"
  echo "Why selected: service/listener/log health for the Hysteria2 OBFS WireGuard forward"
  echo "What was tested: service active, local listener, connected-to-server log, UDP-forwarding log"
  echo "What was not proven: WireGuard authentication unless the synthetic handshake test passes"
}

hy2_auto_print_udp_probe_commands() {
  local iran_port="$1"
  local wg_port="$2"

  echo
  echo -e "${YELLOW}UDP-only fallback probe${NC}"
  warn_line "UDP-only fallback" "forwarding-only; this does not prove WireGuard authentication"
  echo "Foreign watcher:"
  echo "  timeout 40 tcpdump -ni any udp port $wg_port"
  echo "Iran sender:"
  echo "  echo viptrue-test >/dev/udp/127.0.0.1/$iran_port"
}

hy2_auto_select_udp_purpose() {
  local traffic purpose_choice __purpose_var="$1"

  echo "Tunnel traffic type:"
  echo "1) UDP"
  echo "2) TCP"
  read -r -p "Select traffic type [1-2]: " traffic
  case "$traffic" in
    1|"") ;;
    2)
      warn_line "TCP auto tunnel" "planned/manual only in this PR; no TCP setup was performed"
      echo "Use Manual Tunnel Lab for TCP-oriented diagnostics until TCP Auto Wizard is added."
      return 1
      ;;
    *)
      fail_line "Tunnel traffic type" "choose 1 for UDP or 2 for TCP"
      return 1
      ;;
  esac

  echo
  echo "Tunnel purpose:"
  echo "1) WireGuard UDP forward"
  echo "2) Generic UDP forward"
  read -r -p "Select tunnel purpose [1-2]: " purpose_choice
  case "$purpose_choice" in
    1|"") printf -v "$__purpose_var" '%s' "udp-wg-hy2" ;;
    2) printf -v "$__purpose_var" '%s' "udp-generic-hy2" ;;
    *)
      fail_line "Tunnel purpose" "choose 1 for WireGuard UDP forward or 2 for Generic UDP forward"
      return 1
      ;;
  esac
}

hy2_auto_profile_name_or_default() {
  local prompt="$1"
  local default="$2"
  local value

  value="$(prompt_default "$prompt" "$default")"
  if ! valid_profile_name "$value"; then
    fail_line "profile name" "use 1-32 letters, numbers, dot, underscore, or dash"
    return 1
  fi
  printf '%s\n' "$value"
}

hy2_auto_value_safe_for_bundle() {
  local label="$1"
  local value="$2"

  if [[ -z "${value// /}" || "$value" == *";"* || "$value" == *"="* || "$value" == *[[:space:]]* ]]; then
    fail_line "$label" "must be non-empty and cannot contain spaces, semicolons, or equals signs"
    return 1
  fi
}

hy2_expert_bundle_dir() {
  if [[ "$EUID" -eq 0 && -d /root && -w /root ]]; then
    printf '/root\n'
  elif [[ -w "$BASE_DIR" ]]; then
    printf '%s\n' "$BASE_DIR"
  elif [[ -n "${HOME:-}" && -w "$HOME" ]]; then
    printf '%s\n' "$HOME"
  else
    printf '/tmp\n'
  fi
}

hy2_expert_save_bundle_file() {
  local kind="$1"
  local profile="$2"
  local bundle="$3"
  local dir path old_umask

  dir="$(hy2_expert_bundle_dir)"
  mkdir -p "$dir" 2>/dev/null || true
  path="$dir/viptrue-${kind}-bundle-${profile}.txt"
  old_umask="$(umask)"
  umask 077
  printf '%s\n' "$bundle" > "$path"
  umask "$old_umask"
  printf '%s\n' "$path"
}

hy2_auto_stop_conflicting_hysteria_services() {
  local config_path="$1"
  local service_name="$2"
  local services service confirm

  services="$(hy2_wg_detect_services_for_config "$config_path")"
  while IFS= read -r service; do
    [[ -n "$service" && "$service" != "$service_name" ]] || continue
    if hy2_wg_service_active "$service"; then
      warn_line "conflicting Hysteria service" "$service is active and references $config_path"
      read -r -p "Stop only $service before starting $service_name? [y/N]: " confirm
      case "$confirm" in
        y|Y|yes|YES)
          systemctl stop "$service" 2>/dev/null || true
          pass_line "conflicting service stop attempted" "$service"
          ;;
        *)
          fail_line "conflicting service" "left active; refusing to continue"
          return 1
          ;;
      esac
    fi
  done <<< "$services"
}

hy2_auto_stop_same_profile_service() {
  local service_name="$1"
  local confirm

  if hy2_wg_service_active "$service_name"; then
    warn_line "existing profile service" "$service_name is active"
    read -r -p "Stop only $service_name before replacing this profile? [y/N]: " confirm
    case "$confirm" in
      y|Y|yes|YES)
        systemctl stop "$service_name" 2>/dev/null || true
        pass_line "same-profile service stop attempted" "$service_name"
        ;;
      *)
        fail_line "same-profile service" "left active; refusing to replace this profile"
        return 1
        ;;
    esac
  fi
}

hy2_engine_registry_rows() {
  cat <<'EOF_ENGINE_REGISTRY'
hysteria2_obfs_udp|Hysteria2 OBFS UDP|UDP/QUIC|udp|normal|generic-forward|implemented/proven|high|high|medium/lower|hysteria,openssl|no|no|no|yes|yes|no|yes|local-port,hysteria-service,udp-probe|hysteria2-generic-builder|service-listener-udp-probe|Proven by real field test in this project with salamander OBFS, sniGuard disable, Bing masquerade, and non-443 UDP.
hysteria2_udp_forward|Hysteria2 UDP Forward|UDP/QUIC|udp|normal|generic-forward|implemented|high|high|medium|hysteria|no|no|no|yes|yes|no|yes|local-port,hysteria-service,udp-probe|manual-lab|service-listener-udp-probe|Plain Hysteria2 UDP forwarding profile; prefer OBFS proven profile first.
tuic_udp|TUIC UDP|UDP/QUIC|udp|normal|generic-forward|planned/external-required|medium|high|medium|tuic|no|no|no|yes|yes|no|yes|dependency-port-probe|not-implemented|manual-field-test|External engine candidate for future UDP work.
masque_connect_udp|MASQUE CONNECT-UDP|UDP/QUIC|udp|normal|generic-forward|research/planned|medium|medium|lower|external|yes|maybe|maybe|yes|yes|no|yes|research-only|not-implemented|manual-field-test|Research candidate; compatibility depends on client/server support.
amneziawg|AmneziaWG|UDP/QUIC|udp|normal|wireguard|planned/external-required|medium|high|medium/lower|awg|no|no|no|yes|yes|no|yes|dependency-port-probe|not-implemented|handshake-transfer|WireGuard-like engine; not required by generic scanner.
wireguard_over_hysteria|WireGuard over Hysteria2|UDP/QUIC|udp|normal|wireguard|implemented/proven|high|high|medium/lower|hysteria,wg,ip|no|no|no|yes|yes|no|yes|service-listener-handshake|manual-lab|synthetic-wg-handshake|Existing helper path; WireGuard is a destination example, not a scanner dependency.
udp_over_tcp_fallback|UDP over TCP Fallback|UDP/QUIC|udp|normal|emergency|scaffolded|medium|low|higher|nc|no|no|no|yes|yes|no|yes|dependency-port-probe|not-implemented|manual-payload|Fallback only; expect latency and reliability tradeoffs.
xray_vless_reality_tcp|Xray VLESS REALITY TCP|TCP/web-like|tcp|normal|xray|scaffolded/external-required|high|medium|lower|xray|yes|no|no|yes|yes|yes|no|dependency-tcp-probe|not-implemented|tcp-connect|Xray is treated as a destination/engine example; not required by generic scanner.
xray_xhttp|Xray XHTTP|TCP/web-like|tcp|normal|xray|scaffolded|high|medium|lower|xray|yes|no|maybe|yes|yes|yes|no|dependency-tcp-probe|not-implemented|tcp-http-probe|Candidate for web-like transport testing.
xray_grpc|Xray gRPC|TCP/web-like|tcp|normal|xray|scaffolded|medium|medium|lower|xray|yes|no|maybe|yes|yes|yes|no|dependency-tcp-probe|not-implemented|tcp-http2-probe|Useful when HTTP/2 style paths are viable.
xray_ws_httpupgrade_legacy|Xray WS HTTPUpgrade Legacy|TCP/web-like|tcp|normal|xray|planned/legacy|medium|medium|medium|xray|yes|no|maybe|yes|yes|yes|no|dependency-tcp-probe|not-implemented|tcp-http-probe|Legacy compatibility path; not preferred for new builds.
naiveproxy|NaiveProxy|TCP/web-like|tcp|normal|anti-dpi|planned/external-required|medium|medium|lower|naive|yes|no|no|yes|yes|yes|no|dependency-tcp-probe|not-implemented|http-connect-test|External engine candidate.
webtunnel|WebTunnel|TCP/web-like|tcp|normal|anti-dpi|planned/external-required|medium|medium|lower|webtunnel|yes|no|maybe|yes|yes|yes|no|dependency-tcp-probe|not-implemented|http-connect-test|External engine candidate for web-like paths.
obfs4|OBFS4|TCP/web-like|tcp|normal|anti-dpi|planned/external-required|medium|low|lower|obfs4proxy|no|no|no|yes|yes|yes|no|dependency-tcp-probe|not-implemented|tcp-connect|External engine candidate with lower speed expectation.
shadowtls|ShadowTLS|TCP/web-like|tcp|normal|anti-dpi|planned|medium|medium|lower|shadow-tls|yes|no|no|yes|yes|yes|no|dependency-tcp-probe|not-implemented|tls-handshake|Planned TLS-looking helper.
generic_tcp_forward|Generic TCP Forward|TCP/web-like|tcp|normal|generic-forward|scaffolded|medium|medium|medium|nc|no|no|no|yes|yes|yes|no|tcp-listener-probe|not-implemented|tcp-payload|Framework placeholder for a tested TCP forward engine.
waterwall_reverse_tls|WaterWall Reverse TLS|Reverse/Iran-specific|tcp|reverse|generic-forward|priority-next/scaffolded|high|medium|lower|waterwall|yes|no|no|yes|yes|yes|no|dependency-tcp-probe|not-implemented|reverse-tls-test|Priority-next reverse engine for Iran entry constraints.
reverse_ws_proxy|Reverse WS Proxy|Reverse/Iran-specific|tcp|reverse|generic-forward|priority-next/scaffolded|high|medium|lower|external|yes|no|maybe|yes|yes|yes|no|tcp-http-probe|not-implemented|reverse-ws-test|Priority-next reverse web socket shape.
reverse_grpc_proxy|Reverse gRPC Proxy|Reverse/Iran-specific|tcp|reverse|generic-forward|priority-next/scaffolded|high|medium|lower|external|yes|no|maybe|yes|yes|yes|no|tcp-http2-probe|not-implemented|reverse-grpc-test|Priority-next reverse HTTP/2 shape.
xray_reverse|Xray Reverse|Reverse/Iran-specific|tcp|reverse|xray|scaffolded|high|medium|lower|xray|yes|no|maybe|yes|yes|yes|no|dependency-tcp-probe|not-implemented|xray-reverse-test|Xray reverse mode scaffold.
reverse_ssh|Reverse SSH|Reverse/Iran-specific|tcp|reverse|bootstrap|scaffolded|medium|low|medium|ssh|no|no|no|yes|yes|yes|no|dependency-tcp-probe|not-implemented|ssh-reverse-test|Bootstrap/admin path, not a daily tunnel default.
chisel_reverse|Chisel Reverse|Reverse/Iran-specific|tcp|reverse|generic-forward|scaffolded|medium|medium|medium|chisel|no|no|no|yes|yes|yes|no|dependency-tcp-probe|not-implemented|reverse-tcp-test|External reverse tunnel candidate.
gost_reverse|GOST Reverse|Reverse/Iran-specific|both|reverse|generic-forward|scaffolded|medium|medium|medium|gost|no|no|no|yes|yes|yes|yes|dependency-port-probe|not-implemented|reverse-payload-test|External reverse tunnel candidate.
frp_rathole_reverse|FRP/Rathole Reverse|Reverse/Iran-specific|tcp|reverse|generic-forward|planned|medium|medium|medium|external|no|no|no|yes|yes|yes|no|dependency-tcp-probe|not-implemented|reverse-payload-test|Planned external reverse options.
cloudflare_clean_ip|Cloudflare Clean IP|CDN/operator-specific|tcp|normal|cdn|scaffolded/isp-specific|medium|medium|ISP-specific|curl|yes|yes|yes|yes|yes|yes|no|clean-ip-scan|not-implemented|http-tls-probe|ISP-specific and brittle; requires field test.
cloudflare_worker_proxy|Cloudflare Worker Proxy|CDN/operator-specific|tcp|normal|cdn|planned|medium|medium|ISP-specific|curl|yes|yes|yes|yes|yes|yes|no|worker-probe|not-implemented|http-probe|Planned operator-specific relay.
cloudflare_cdn_xhttp|Cloudflare CDN XHTTP|CDN/operator-specific|tcp|normal|cdn|planned|medium|medium|ISP-specific|xray,curl|yes|yes|yes|yes|yes|yes|no|cdn-http-probe|not-implemented|xhttp-test|Planned CDN-backed XHTTP shape.
cloudflare_cdn_ws_grpc|Cloudflare CDN WS/gRPC|CDN/operator-specific|tcp|normal|cdn|planned|medium|medium|ISP-specific|xray,curl|yes|yes|yes|yes|yes|yes|no|cdn-http2-probe|not-implemented|ws-grpc-test|Planned CDN-backed WS/gRPC shape.
arvancloud_relay|ArvanCloud Relay|CDN/operator-specific|tcp|normal|cdn|planned/iran-specific|medium|medium|ISP-specific|curl|yes|yes|no|yes|yes|yes|no|relay-probe|not-implemented|http-tls-probe|Iran-specific operator path requiring live testing.
ipv6_bypass|IPv6 Bypass|CDN/operator-specific|raw-ip|both|bootstrap|scaffolded/isp-specific|medium|high|ISP-specific|ip,ping|no|no|no|yes|yes|yes|yes|ipv6-route-probe|not-implemented|icmp-route-test|Only useful where IPv6 policy differs; field test required.
dnstt|DNSTT|DNS/emergency|dns|normal|emergency|emergency-only/planned|emergency|low|emergency|dnstt|yes|yes|no|yes|yes|yes|yes|dns-probe|not-implemented|dns-payload-test|DNS hard-mode only; noisy and low-speed.
slipstream_dns|Slipstream DNS|DNS/emergency|dns|normal|emergency|emergency-only/priority-research|emergency|low|emergency|external|yes|yes|no|yes|yes|yes|yes|dns-probe|not-implemented|dns-payload-test|Priority research emergency path, not daily default.
iodine|Iodine|DNS/emergency|dns|normal|emergency|emergency-only/legacy|emergency|low|emergency|iodine|yes|yes|no|yes|yes|yes|yes|dns-probe|not-implemented|dns-payload-test|Legacy DNS tunnel, emergency only.
dns2tcp|dns2tcp|DNS/emergency|dns|normal|emergency|emergency-only/insecure-warning|emergency|low|emergency|dns2tcp|yes|yes|no|yes|yes|yes|yes|dns-tcp-probe|not-implemented|dns-payload-test|Emergency-only with explicit insecure warning.
doh_bootstrap|DoH Bootstrap|DNS/emergency|tcp|normal|bootstrap|scaffolded|medium|low|medium|curl|yes|no|maybe|yes|yes|yes|no|https-dns-probe|not-implemented|https-probe|Bootstrap helper, not a full tunnel by itself.
dot_bootstrap|DoT Bootstrap|DNS/emergency|tcp|normal|bootstrap|scaffolded|medium|low|medium|openssl|yes|no|no|yes|yes|yes|no|tls-dns-probe|not-implemented|tls-probe|Bootstrap helper, not a full tunnel by itself.
doq_bootstrap|DoQ Bootstrap|DNS/emergency|udp|normal|bootstrap|research|medium|low|medium|external|yes|no|no|yes|yes|no|yes|quic-dns-probe|not-implemented|doq-probe|Research bootstrap candidate.
dns_scanner|DNS Scanner|DNS/emergency|dns|normal|bootstrap|scaffolded|medium|low|medium|getent,dig|yes|yes|no|no|yes|yes|yes|dns-capability-scan|not-implemented|dns-resolution-test|Scanner helper for resolver behavior.
dns_over_tcp_segmentation_probe|DNS-over-TCP Segmentation Probe|DNS/emergency|tcp|normal|anti-dpi|research|emergency|low|emergency|nc|yes|yes|no|yes|yes|yes|no|segmentation-probe|not-implemented|tcp-payload|Research-only anti-DPI probe.
gre|GRE|Raw-IP/kernel|raw-ip|normal|generic-forward|implemented/scaffolded|low|high|higher|ip|no|no|no|yes|no|no|no|kernel-module-route-probe|manual-lab|route-ping-test|Raw IP is often high-risk or blocked; use only when network allows.
gretap|GRETAP|Raw-IP/kernel|raw-ip|normal|generic-forward|planned|low|high|higher|ip|no|no|no|yes|no|no|no|kernel-module-route-probe|not-implemented|route-ping-test|Planned raw Ethernet tunnel.
ipip|IPIP|Raw-IP/kernel|raw-ip|normal|generic-forward|planned|low|high|higher|ip|no|no|no|yes|no|no|no|kernel-module-route-probe|not-implemented|route-ping-test|Planned raw IP tunnel.
sit_ipv6_in_ipv4|SIT IPv6-in-IPv4|Raw-IP/kernel|raw-ip|normal|bootstrap|planned|low|medium|higher|ip|no|no|no|yes|no|no|no|kernel-module-route-probe|not-implemented|route-ping-test|Planned IPv6 bootstrap tunnel.
vxlan|VXLAN|Raw-IP/kernel|udp|normal|generic-forward|planned|low|high|higher|ip|no|no|no|yes|no|no|yes|kernel-module-udp-probe|not-implemented|udp-route-test|Planned overlay; usually not first choice for Iran paths.
wireguard_site_to_site|WireGuard Site-to-Site|Raw-IP/kernel|udp|normal|wireguard|scaffolded|medium|high|medium|wg,ip|no|no|no|yes|no|no|yes|wg-handshake-probe|manual-lab|handshake-transfer|WireGuard is an example destination or separate engine, not required by the generic scanner.
zapret_style_desync|Zapret-style Desync|Spoof/desync/anti-DPI|tcp|normal|anti-dpi|research/external-required|medium|unknown|unknown|external|no|no|no|yes|yes|yes|no|research-only|not-implemented|field-test|Helper research only; no bypass success is promised.
udp2raw_style_wrapper|udp2raw-style Wrapper|Spoof/desync/anti-DPI|udp|normal|anti-dpi|planned/external-required|medium|medium|medium|udp2raw|no|no|no|yes|yes|no|yes|dependency-udp-probe|not-implemented|udp-payload-test|External wrapper candidate for UDP hard paths.
fake_packet_ttl_split_fragment|Fake Packet TTL Split Fragment|Spoof/desync/anti-DPI|both|normal|anti-dpi|research|medium|unknown|unknown|external|no|no|no|yes|yes|yes|yes|research-only|not-implemented|field-test|Research-only helper; requires careful legal and network review.
xray_fragment_noise|Xray Fragment/Noise|Spoof/desync/anti-DPI|tcp|normal|xray|scaffolded/xray-specific|medium|medium|medium|xray|yes|no|maybe|yes|yes|yes|no|xray-probe|not-implemented|xray-field-test|Xray-specific helper scaffold.
EOF_ENGINE_REGISTRY
}

hy2_engine_lookup() {
  local wanted="$1"
  local row engine_id

  while IFS= read -r row; do
    engine_id="${row%%|*}"
    if [[ "$engine_id" == "$wanted" ]]; then
      printf '%s\n' "$row"
      return 0
    fi
  done < <(hy2_engine_registry_rows)

  return 1
}

hy2_engine_dependency_available() {
  local dependencies="$1"
  local dep
  local -a dep_list=()

  [[ "$dependencies" == "none" || -z "$dependencies" ]] && return 0
  IFS=',' read -r -a dep_list <<< "$dependencies"
  for dep in "${dep_list[@]}"; do
    dep="${dep// /}"
    case "$dep" in
      ""|none) continue ;;
      external) return 1 ;;
    esac
    hy2_command_available_cached "$dep" || return 1
  done

  return 0
}

hy2_command_available_cached() {
  local cmd="$1"

  if [[ $'\n'"${HY2_CMD_CACHE_OK:-}" == *$'\n'"$cmd"$'\n'* ]]; then
    return 0
  fi
  if [[ $'\n'"${HY2_CMD_CACHE_FAIL:-}" == *$'\n'"$cmd"$'\n'* ]]; then
    return 1
  fi

  if have_cmd "$cmd"; then
    HY2_CMD_CACHE_OK="${HY2_CMD_CACHE_OK:-}${cmd}"$'\n'
    return 0
  fi

  HY2_CMD_CACHE_FAIL="${HY2_CMD_CACHE_FAIL:-}${cmd}"$'\n'
  return 1
}

hy2_engine_traffic_matches() {
  local engine_traffic="$1"
  local requested="$2"

  [[ "$requested" == "both" || "$engine_traffic" == "both" || "$engine_traffic" == "$requested" ]]
}

hy2_engine_buildable_now() {
  local engine_id="$1"
  local status="$2"
  local dependencies="$3"

  if [[ "$engine_id" == "hysteria2_obfs_udp" && "$status" == *implemented* ]]; then
    printf 'yes\n'
  elif [[ "$status" == *implemented* ]]; then
    printf 'manual\n'
  else
    printf 'not yet\n'
  fi
  : "$dependencies"
}

hy2_engine_short_name() {
  case "$1" in
    hysteria2_obfs_udp) printf 'Hysteria2 OBFS UDP\n' ;;
    hysteria2_udp_forward) printf 'Hysteria2 UDP FWD\n' ;;
    waterwall_reverse_tls) printf 'WaterWall RevTLS\n' ;;
    reverse_ws_proxy) printf 'Reverse WS Proxy\n' ;;
    reverse_grpc_proxy) printf 'Reverse gRPC Proxy\n' ;;
    wireguard_over_hysteria) printf 'WG over Hysteria2\n' ;;
    xray_vless_reality_tcp) printf 'Xray REALITY TCP\n' ;;
    xray_ws_httpupgrade_legacy) printf 'Xray WS Legacy\n' ;;
    cloudflare_clean_ip) printf 'Cloudflare CleanIP\n' ;;
    dns_over_tcp_segmentation_probe) printf 'DNS TCP Segment\n' ;;
    fake_packet_ttl_split_fragment) printf 'TTL Split Frag\n' ;;
    udp2raw_style_wrapper) printf 'udp2raw Wrapper\n' ;;
    wireguard_site_to_site) printf 'WG Site-to-Site\n' ;;
    *) printf '%s\n' "$2" | cut -c1-20 ;;
  esac
}

hy2_engine_short_speed() {
  case "$1" in
    high) printf 'HIGH\n' ;;
    medium) printf 'MED\n' ;;
    low) printf 'LOW\n' ;;
    *) printf 'UNK\n' ;;
  esac
}

hy2_engine_short_risk() {
  case "$1" in
    lower) printf 'LOW\n' ;;
    medium/lower) printf 'MED/LOW\n' ;;
    medium) printf 'MED\n' ;;
    higher) printf 'HIGHER\n' ;;
    ISP-specific) printf 'ISP\n' ;;
    emergency) printf 'EMRG\n' ;;
    *) printf 'UNK\n' ;;
  esac
}

hy2_engine_short_fit() {
  case "$1" in
    high) printf 'HIGH\n' ;;
    medium) printf 'MED\n' ;;
    low) printf 'LOW\n' ;;
    emergency) printf 'EMRG\n' ;;
    *) printf 'UNK\n' ;;
  esac
}

hy2_engine_ready_label() {
  local engine_id="$1"
  local status="$2"
  local use_case="$3"

  if [[ "$status" == *emergency-only* ]]; then
    printf 'EMRG\n'
  elif [[ "$use_case" == "wireguard" || "$use_case" == "xray" ]]; then
    printf 'APP\n'
  elif [[ "$engine_id" == "hysteria2_obfs_udp" ]]; then
    printf 'YES\n'
  elif [[ "$status" == *implemented* ]]; then
    printf 'MAN\n'
  elif [[ "$status" == *priority-next* ]]; then
    printf 'NEXT\n'
  elif [[ "$status" == *external-required* ]]; then
    printf 'EXT\n'
  else
    printf 'PLAN\n'
  fi
}

hy2_engine_category() {
  local ready="$1"
  local status="$2"

  case "$ready" in
    YES) printf 'buildable\n' ;;
    MAN) printf 'manual\n' ;;
    NEXT) printf 'priority\n' ;;
    EMRG) printf 'emergency\n' ;;
    APP) printf 'app\n' ;;
    EXT) printf 'planned\n' ;;
    *)
      if [[ "$status" == *planned* || "$status" == *research* || "$status" == *scaffolded* ]]; then
        printf 'planned\n'
      else
        printf 'planned\n'
      fi
      ;;
  esac
}

hy2_engine_note() {
  local engine_id="$1"
  local status="$2"
  local use_case="$3"
  local destination_listening="$4"

  if [[ "$engine_id" == "hysteria2_obfs_udp" ]]; then
    printf 'proven\n'
  elif [[ "$status" == *priority-next* ]]; then
    printf 'next\n'
  elif [[ "$status" == *emergency-only* ]]; then
    printf 'hard-mode\n'
  elif [[ "$use_case" == "wireguard" || "$use_case" == "xray" ]]; then
    printf 'app preset\n'
  elif [[ "$status" == *external-required* ]]; then
    printf 'external\n'
  elif [[ "$status" == *implemented* ]]; then
    printf 'manual\n'
  elif [[ "$destination_listening" == "false" ]]; then
    printf 'dest later\n'
  else
    printf 'planned\n'
  fi
}

hy2_destination_status_label() {
  case "$1" in
    true) printf 'detected\n' ;;
    false) printf 'not detected\n' ;;
    *) printf 'not checked\n' ;;
  esac
}

hy2_split_pipe_row() {
  local row="$1"
  local old_ifs

  HY2_PIPE_FIELDS=()
  old_ifs="$IFS"
  IFS='|'
  read -r -a HY2_PIPE_FIELDS <<< "$row"
  IFS="$old_ifs"
}

hy2_engine_score_row() {
  local row="$1"
  local requested_traffic="$2"
  local listen_port="$3"
  local destination_listening="$4"
  local engine_id display_name _family traffic _direction use_case status iran_fit speed risk dependencies
  local _requires_domain _requires_dns_zone _requires_cloudflare _requires_root _supports_multi_foreign
  local supports_generic_tcp supports_generic_udp probe_method build_method test_method notes
  local score=0 buildable dependency_ok="false" port_ok="unknown" ready category note short_name short_speed short_risk short_fit

  hy2_split_pipe_row "$row"
  engine_id="${HY2_PIPE_FIELDS[0]:-}"
  display_name="${HY2_PIPE_FIELDS[1]:-}"
  _family="${HY2_PIPE_FIELDS[2]:-}"
  traffic="${HY2_PIPE_FIELDS[3]:-}"
  _direction="${HY2_PIPE_FIELDS[4]:-}"
  use_case="${HY2_PIPE_FIELDS[5]:-}"
  status="${HY2_PIPE_FIELDS[6]:-}"
  iran_fit="${HY2_PIPE_FIELDS[7]:-}"
  speed="${HY2_PIPE_FIELDS[8]:-}"
  risk="${HY2_PIPE_FIELDS[9]:-}"
  dependencies="${HY2_PIPE_FIELDS[10]:-}"
  _requires_domain="${HY2_PIPE_FIELDS[11]:-}"
  _requires_dns_zone="${HY2_PIPE_FIELDS[12]:-}"
  _requires_cloudflare="${HY2_PIPE_FIELDS[13]:-}"
  _requires_root="${HY2_PIPE_FIELDS[14]:-}"
  _supports_multi_foreign="${HY2_PIPE_FIELDS[15]:-}"
  supports_generic_tcp="${HY2_PIPE_FIELDS[16]:-}"
  supports_generic_udp="${HY2_PIPE_FIELDS[17]:-}"
  probe_method="${HY2_PIPE_FIELDS[18]:-}"
  build_method="${HY2_PIPE_FIELDS[19]:-}"
  test_method="${HY2_PIPE_FIELDS[20]:-}"
  notes="${HY2_PIPE_FIELDS[21]:-}"
  : "$probe_method" "$build_method" "$test_method" "$notes"

  if ! hy2_engine_traffic_matches "$traffic" "$requested_traffic"; then
    ready="$(hy2_engine_ready_label "$engine_id" "$status" "$use_case")"
    category="$(hy2_engine_category "$ready" "$status")"
    short_name="$(hy2_engine_short_name "$engine_id" "$display_name")"
    printf '0|%s|%s|%s|%s|%s|%s|%s|%s|traffic|%s|%s|false|unknown\n' \
      "$engine_id" "$short_name" "$status" "$(hy2_engine_short_speed "$speed")" "$(hy2_engine_short_risk "$risk")" \
      "$(hy2_engine_short_fit "$iran_fit")" "$ready" "$category" "$traffic" "$use_case"
    return
  fi

  if hy2_engine_dependency_available "$dependencies"; then
    dependency_ok="true"
    score=$((score + 10))
  fi

  if [[ "$engine_id" == hysteria2_* || "$engine_id" == "wireguard_over_hysteria" ]]; then
    if [[ "$listen_port" == "443" ]]; then
      ready="$(hy2_engine_ready_label "$engine_id" "$status" "$use_case")"
      category="$(hy2_engine_category "$ready" "$status")"
      short_name="$(hy2_engine_short_name "$engine_id" "$display_name")"
      printf '0|%s|%s|blocked|%s|%s|%s|%s|%s|no 443|%s|%s|%s|blocked\n' \
        "$engine_id" "$short_name" "$(hy2_engine_short_speed "$speed")" "$(hy2_engine_short_risk "$risk")" \
        "$(hy2_engine_short_fit "$iran_fit")" "$ready" "$category" "$traffic" "$use_case" "$dependency_ok"
      return
    fi
  fi

  if valid_port "$listen_port"; then
    port_ok="${HY2_SCORE_PORT_OK:-unknown}"
  fi
  if [[ "$port_ok" == "free" ]]; then
    score=$((score + 10))
  fi

  if [[ "$status" == *implemented* ]]; then
    score=$((score + 20))
  elif [[ "$status" == *priority-next* ]]; then
    score=$((score + 18))
  elif [[ "$status" == *scaffolded* ]]; then
    score=$((score + 14))
  elif [[ "$status" == *planned* ]]; then
    score=$((score + 8))
  fi

  [[ "$status" == *proven* ]] && score=$((score + 10))
  [[ "$speed" == "high" ]] && score=$((score + 5))
  [[ "$iran_fit" == "high" ]] && score=$((score + 5))
  [[ "$risk" == "lower" || "$risk" == "medium/lower" ]] && score=$((score + 5))
  [[ "$destination_listening" == "true" && ( "$supports_generic_udp" == "yes" || "$supports_generic_tcp" == "yes" ) ]] && score=$((score + 5))

  if [[ "$use_case" == "wireguard" || "$use_case" == "xray" ]]; then
    score=$((score - 25))
    ((score < 0)) && score=0
  fi

  if [[ "$status" == *emergency-only* && "$score" -gt 55 ]]; then
    score=55
  fi

  buildable="$(hy2_engine_buildable_now "$engine_id" "$status" "$dependencies")"
  : "$buildable"

  ready="$(hy2_engine_ready_label "$engine_id" "$status" "$use_case")"
  category="$(hy2_engine_category "$ready" "$status")"
  note="$(hy2_engine_note "$engine_id" "$status" "$use_case" "$destination_listening")"
  short_name="$(hy2_engine_short_name "$engine_id" "$display_name")"
  short_speed="$(hy2_engine_short_speed "$speed")"
  short_risk="$(hy2_engine_short_risk "$risk")"
  short_fit="$(hy2_engine_short_fit "$iran_fit")"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$score" "$engine_id" "$short_name" "$status" "$short_speed" "$short_risk" "$short_fit" \
    "$ready" "$category" "$note" "$traffic" "$use_case" "$dependency_ok" "$port_ok"
}

hy2_engine_show_registry() {
  local engine_id _display_name family traffic _direction _use_case status iran_fit speed risk dependencies
  local _requires_domain _requires_dns_zone _requires_cloudflare _requires_root _supports_multi_foreign
  local _supports_generic_tcp _supports_generic_udp _probe_method _build_method _test_method notes
  local row count=0

  title
  echo -e "${CYAN}Auto Tunnel Expert > Engine Registry${NC}"
  line
  echo
  printf '%-34s %-24s %-9s %-16s %-22s %-8s %-13s %s\n' "Engine ID" "Family" "Traffic" "Status" "Iran fit/risk" "Build" "Dependencies" "Notes"
  line
  while IFS= read -r row; do
    hy2_split_pipe_row "$row"
    engine_id="${HY2_PIPE_FIELDS[0]:-}"
    _display_name="${HY2_PIPE_FIELDS[1]:-}"
    family="${HY2_PIPE_FIELDS[2]:-}"
    traffic="${HY2_PIPE_FIELDS[3]:-}"
    _direction="${HY2_PIPE_FIELDS[4]:-}"
    _use_case="${HY2_PIPE_FIELDS[5]:-}"
    status="${HY2_PIPE_FIELDS[6]:-}"
    iran_fit="${HY2_PIPE_FIELDS[7]:-}"
    speed="${HY2_PIPE_FIELDS[8]:-}"
    risk="${HY2_PIPE_FIELDS[9]:-}"
    dependencies="${HY2_PIPE_FIELDS[10]:-}"
    _requires_domain="${HY2_PIPE_FIELDS[11]:-}"
    _requires_dns_zone="${HY2_PIPE_FIELDS[12]:-}"
    _requires_cloudflare="${HY2_PIPE_FIELDS[13]:-}"
    _requires_root="${HY2_PIPE_FIELDS[14]:-}"
    _supports_multi_foreign="${HY2_PIPE_FIELDS[15]:-}"
    _supports_generic_tcp="${HY2_PIPE_FIELDS[16]:-}"
    _supports_generic_udp="${HY2_PIPE_FIELDS[17]:-}"
    _probe_method="${HY2_PIPE_FIELDS[18]:-}"
    _build_method="${HY2_PIPE_FIELDS[19]:-}"
    _test_method="${HY2_PIPE_FIELDS[20]:-}"
    notes="${HY2_PIPE_FIELDS[21]:-}"
    count=$((count + 1))
    printf '%-34s %-24s %-9s %-16s %-22s %-8s %-13s %s\n' \
      "$engine_id" "$family" "$traffic" "$status" "$iran_fit/$risk" \
      "$(hy2_engine_buildable_now "$engine_id" "$status" "$dependencies")" "$dependencies" "$notes"
  done < <(hy2_engine_registry_rows)
  line
  echo "Total registered engines: $count"
  echo "Detection-risk labels are metadata heuristics, not guarantees."
  pause
}

hy2_engine_explain_families() {
  title
  echo -e "${CYAN}Auto Tunnel Expert > Engine Families${NC}"
  line
  echo
  echo "UDP/QUIC: probe first; fast when UDP works, but QUIC/UDP may be filtered."
  echo "TCP/web-like: useful when TCP/TLS-like paths survive better than UDP."
  echo "Reverse/Iran-specific: foreign side dials back or holds a reverse path for constrained Iran entries."
  echo "CDN/operator-specific: can help on some ISPs, but clean-IP/CDN behavior is brittle and field-test dependent."
  echo "DNS/emergency: hard-mode only; low speed, noisy, and not a daily default."
  echo "Raw-IP/kernel: fast on friendly networks, but higher risk and often blocked."
  echo "Spoof/desync helpers: research/scaffold only here; no bypass success is promised."
  echo
  echo "Detection-risk heuristic:"
  echo "  - NaiveProxy/WebTunnel/REALITY/ReverseTLS: lower"
  echo "  - Hysteria2 OBFS: medium/lower when UDP works"
  echo "  - GRE/raw IP: higher"
  echo "  - DNS tunnel: emergency, noisy, low-speed"
  echo "  - Cloudflare clean IP: ISP-specific and brittle"
  echo
  echo "Recommended next implementation order:"
  echo "1. Hysteria2 generic UDP forward polish"
  echo "2. WaterWall Reverse TLS"
  echo "3. Reverse WS/gRPC"
  echo "4. Generic TCP forward via tested engine"
  echo "5. Cloudflare/CDN scan helpers"
  echo "6. DNS hard-mode research/scaffold"
  echo "7. spoof/desync helper research"
  pause
}

hy2_expert_print_probe_commands() {
  local traffic="$1"
  local iran_port="$2"
  local dest_port="$3"
  local destination_listening="$4"

  echo
  echo -e "${YELLOW}Forwarding proof commands${NC}"
  echo "These prove forwarding only, not application auth."
  if [[ "$traffic" == "udp" || "$traffic" == "both" ]]; then
    echo "UDP proof:"
    echo "  On Foreign:"
    echo "    timeout 40 tcpdump -ni any udp port $dest_port"
    echo
    echo "  On Iran:"
    echo "    echo viptrue-test >/dev/udp/127.0.0.1/$iran_port"
  fi
  if [[ "$traffic" == "tcp" || "$traffic" == "both" ]]; then
    if [[ "$destination_listening" != "true" ]]; then
      echo
      echo "TCP proof:"
      echo "  On Foreign, temporary listener:"
      echo "    nc -lk -p $dest_port"
    else
      echo
      echo "TCP proof:"
      echo "  On Foreign:"
      echo "    confirm the real TCP service is listening on $dest_port"
    fi
    echo
    echo "  On Iran:"
    echo "    nc -vz 127.0.0.1 $iran_port"
    echo "    printf 'viptrue-test\\n' | nc -w2 127.0.0.1 $iran_port"
  fi
}

hy2_expert_prepare_score_cache() {
  local traffic="$1"
  local listen_port="$2"
  local destination_listening="$3"
  local row key output rows

  key="$traffic|$listen_port|$destination_listening"
  if [[ "${HY2_SCORE_CACHE_KEY:-}" == "$key" && -n "${HY2_SCORE_CACHE:-}" ]]; then
    return 0
  fi

  if valid_port "$listen_port"; then
    if [[ -z "$(list_listeners udp "$listen_port")" ]]; then
      HY2_SCORE_PORT_OK="free"
    else
      HY2_SCORE_PORT_OK="busy"
    fi
  else
    HY2_SCORE_PORT_OK="unknown"
  fi

  rows=""
  while IFS= read -r row; do
    rows+="$(hy2_engine_score_row "$row" "$traffic" "$listen_port" "$destination_listening")"$'\n'
  done < <(hy2_engine_registry_rows)

  output="$(printf '%s' "$rows" | sort -t'|' -k1,1nr -k3,3)"
  HY2_SCORE_CACHE_KEY="$key"
  HY2_SCORE_CACHE="$output"
}

hy2_expert_scored_rows() {
  local traffic="$1"
  local listen_port="$2"
  local destination_listening="$3"

  hy2_expert_prepare_score_cache "$traffic" "$listen_port" "$destination_listening"
  printf '%s\n' "$HY2_SCORE_CACHE"
}

hy2_expert_ready_text() {
  case "$1" in
    YES) printf 'YES\n' ;;
    MAN) printf 'MANUAL\n' ;;
    NEXT) printf 'NOT YET\n' ;;
    PLAN|EXT|APP|EMRG) printf 'NOT YET\n' ;;
    *) printf 'UNKNOWN\n' ;;
  esac
}

hy2_expert_summary_risk_text() {
  case "$1" in
    MED/LOW) printf 'MEDIUM/LOWER\n' ;;
    MED) printf 'MEDIUM\n' ;;
    LOW) printf 'LOWER\n' ;;
    EMRG) printf 'EMERGENCY\n' ;;
    ISP) printf 'ISP-SPECIFIC\n' ;;
    HIGHER) printf 'HIGHER\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

hy2_expert_score_for_engine() {
  local engine_id="$1"
  local traffic="$2"
  local listen_port="$3"
  local destination_listening="$4"
  local row score row_engine _rest

  hy2_expert_prepare_score_cache "$traffic" "$listen_port" "$destination_listening"
  while IFS= read -r row; do
    hy2_split_pipe_row "$row"
    score="${HY2_PIPE_FIELDS[0]:-}"
    row_engine="${HY2_PIPE_FIELDS[1]:-}"
    _rest="${HY2_PIPE_FIELDS[*]:2}"
    if [[ "$row_engine" == "$engine_id" ]]; then
      printf '%s\n' "$row"
      return 0
    fi
  done < <(hy2_expert_scored_rows "$traffic" "$listen_port" "$destination_listening")

  return 1
}

hy2_expert_print_table_header() {
  printf '%-4s %-20s %-5s %-5s %-5s %-7s %-5s %s\n' "Rank" "Engine" "Ready" "Score" "Speed" "Risk" "Iran" "Note"
  line
}

hy2_expert_print_rank_row() {
  local rank="$1"
  local score="$2"
  local name="$3"
  local speed="$4"
  local risk="$5"
  local iran_fit="$6"
  local ready="$7"
  local note="$8"

  printf '%-4s %-20s %-5s %-5s %-5s %-7s %-5s %s\n' \
    "$rank" "$name" "$ready" "$score" "$speed" "$risk" "$iran_fit" "$note"
}

hy2_expert_group_matches() {
  local filter="$1"
  local category="$2"
  local ready="$3"
  local note="$4"

  case "$filter" in
    buildable) [[ "$category" == "buildable" && "$note" != "traffic" ]] ;;
    manual) [[ "$category" == "manual" && "$note" != "traffic" ]] ;;
    priority) [[ "$category" == "priority" && "$note" != "traffic" ]] ;;
    planned) [[ "$category" == "planned" ]] ;;
    emergency) [[ "$category" == "emergency" ]] ;;
    app) [[ "$category" == "app" ]] ;;
    compact) [[ "$note" != "traffic" && "$category" != "planned" && "$category" != "emergency" && "$category" != "app" ]] ;;
    all) [[ -n "$ready" ]] ;;
    *) return 1 ;;
  esac
}

hy2_expert_count_group() {
  local traffic="$1"
  local listen_port="$2"
  local destination_listening="$3"
  local filter="$4"
  local row score _engine_id _name _status _speed _risk _iran_fit ready category note _rest
  local count=0

  hy2_expert_prepare_score_cache "$traffic" "$listen_port" "$destination_listening"
  while IFS= read -r row; do
    hy2_split_pipe_row "$row"
    score="${HY2_PIPE_FIELDS[0]:-}"
    _engine_id="${HY2_PIPE_FIELDS[1]:-}"
    _name="${HY2_PIPE_FIELDS[2]:-}"
    _status="${HY2_PIPE_FIELDS[3]:-}"
    _speed="${HY2_PIPE_FIELDS[4]:-}"
    _risk="${HY2_PIPE_FIELDS[5]:-}"
    _iran_fit="${HY2_PIPE_FIELDS[6]:-}"
    ready="${HY2_PIPE_FIELDS[7]:-}"
    category="${HY2_PIPE_FIELDS[8]:-}"
    note="${HY2_PIPE_FIELDS[9]:-}"
    _rest="${HY2_PIPE_FIELDS[*]:10}"
    : "$score" "$_engine_id" "$_name" "$_status" "$_speed" "$_risk" "$_iran_fit" "$_rest"
    if hy2_expert_group_matches "$filter" "$category" "$ready" "$note"; then
      count=$((count + 1))
    fi
  done < <(hy2_expert_scored_rows "$traffic" "$listen_port" "$destination_listening")
  printf '%s\n' "$count"
}

hy2_expert_print_group() {
  local title_text="$1"
  local filter="$2"
  local traffic="$3"
  local listen_port="$4"
  local destination_listening="$5"
  local limit="${6:-0}"
  local row score _engine_id name _status speed risk iran_fit ready category note
  local count=0 printed=0

  echo
  echo -e "${CYAN}${title_text}${NC}"
  hy2_expert_print_table_header

  hy2_expert_prepare_score_cache "$traffic" "$listen_port" "$destination_listening"
  while IFS= read -r row; do
    hy2_split_pipe_row "$row"
    score="${HY2_PIPE_FIELDS[0]:-}"
    _engine_id="${HY2_PIPE_FIELDS[1]:-}"
    name="${HY2_PIPE_FIELDS[2]:-}"
    _status="${HY2_PIPE_FIELDS[3]:-}"
    speed="${HY2_PIPE_FIELDS[4]:-}"
    risk="${HY2_PIPE_FIELDS[5]:-}"
    iran_fit="${HY2_PIPE_FIELDS[6]:-}"
    ready="${HY2_PIPE_FIELDS[7]:-}"
    category="${HY2_PIPE_FIELDS[8]:-}"
    note="${HY2_PIPE_FIELDS[9]:-}"
    hy2_expert_group_matches "$filter" "$category" "$ready" "$note" || continue
    count=$((count + 1))
    if ((limit > 0 && printed >= limit)); then
      continue
    fi
    printed=$((printed + 1))
    hy2_expert_print_rank_row "$printed" "$score" "$name" "$speed" "$risk" "$iran_fit" "$ready" "$note"
  done < <(hy2_expert_scored_rows "$traffic" "$listen_port" "$destination_listening")

  if ((printed == 0)); then
    echo "none"
  elif ((limit > 0 && count > printed)); then
    echo "... $((count - printed)) more hidden"
  fi
}

hy2_expert_print_default_scan_view() {
  local traffic="$1"
  local listen_port="$2"
  local destination_listening="$3"

  echo
  echo -e "${CYAN}Compact scan view${NC}"
  echo "Default view hides the full registry so the recommendation stays readable."
  hy2_expert_print_group "BUILDABLE NOW" "buildable" "$traffic" "$listen_port" "$destination_listening" 3
  hy2_expert_print_group "MANUAL / IMPLEMENTED PRESETS" "manual" "$traffic" "$listen_port" "$destination_listening" 3
  hy2_expert_print_group "PRIORITY NEXT" "priority" "$traffic" "$listen_port" "$destination_listening" 3

  echo
  echo -e "${CYAN}EMERGENCY / HARD MODE${NC}"
  echo "Hidden by default. Select option 6 to inspect hard-mode engines."
  echo -e "${CYAN}PLANNED / EXTERNAL REQUIRED${NC}"
  echo "Hidden by default. Select option 3 for the full registry."
  echo -e "${CYAN}APPLICATION-SPECIFIC PRESETS${NC}"
  echo "WireGuard/Xray/application presets are hidden from generic default ranking."
}

hy2_expert_print_full_ranking() {
  local traffic="$1"
  local listen_port="$2"
  local destination_listening="$3"

  echo
  echo -e "${CYAN}Full 49-engine ranking${NC}"
  echo "Grouped by readiness so emergency and application-specific presets do not crowd the default view."
  hy2_expert_print_group "BUILDABLE NOW" "buildable" "$traffic" "$listen_port" "$destination_listening" 0
  hy2_expert_print_group "MANUAL / IMPLEMENTED PRESETS" "manual" "$traffic" "$listen_port" "$destination_listening" 0
  hy2_expert_print_group "PRIORITY NEXT" "priority" "$traffic" "$listen_port" "$destination_listening" 0
  hy2_expert_print_group "PLANNED / EXTERNAL REQUIRED" "planned" "$traffic" "$listen_port" "$destination_listening" 0
  hy2_expert_print_group "EMERGENCY / HARD MODE" "emergency" "$traffic" "$listen_port" "$destination_listening" 0
  hy2_expert_print_group "APPLICATION-SPECIFIC PRESETS" "app" "$traffic" "$listen_port" "$destination_listening" 0
  echo
  echo "Full ranking includes all registered engines."
}

hy2_expert_print_compact_ranking() {
  local traffic="$1"
  local listen_port="$2"
  local destination_listening="$3"

  hy2_expert_print_group "COMPACT RANKING" "compact" "$traffic" "$listen_port" "$destination_listening" 12
}

hy2_expert_recommended_engine_id() {
  case "$1" in
    tcp) printf 'waterwall_reverse_tls\n' ;;
    udp|both|*) printf 'hysteria2_obfs_udp\n' ;;
  esac
}

hy2_expert_tcp_recommended_engine_id() {
  printf 'waterwall_reverse_tls\n'
}

hy2_expert_print_recommendation_lines() {
  local row="$1"
  local score engine_id name _status speed risk iran_fit ready _category _note _traffic _use_case deps_ok port_ok

  hy2_split_pipe_row "$row"
  score="${HY2_PIPE_FIELDS[0]:-}"
  engine_id="${HY2_PIPE_FIELDS[1]:-}"
  name="${HY2_PIPE_FIELDS[2]:-}"
  _status="${HY2_PIPE_FIELDS[3]:-}"
  speed="${HY2_PIPE_FIELDS[4]:-}"
  risk="${HY2_PIPE_FIELDS[5]:-}"
  iran_fit="${HY2_PIPE_FIELDS[6]:-}"
  ready="${HY2_PIPE_FIELDS[7]:-}"
  _category="${HY2_PIPE_FIELDS[8]:-}"
  _note="${HY2_PIPE_FIELDS[9]:-}"
  _traffic="${HY2_PIPE_FIELDS[10]:-}"
  _use_case="${HY2_PIPE_FIELDS[11]:-}"
  deps_ok="${HY2_PIPE_FIELDS[12]:-}"
  port_ok="${HY2_PIPE_FIELDS[13]:-}"
  echo "  Engine:          $name"
  echo "  Engine ID:       $engine_id"
  echo "  Buildable now:   $(hy2_expert_ready_text "$ready")"
  echo "  Iran fit:        $iran_fit"
  echo "  Speed:           $speed"
  echo "  Detection risk:  $(hy2_expert_summary_risk_text "$risk")"
  echo "  Score:           $score"
  echo
  echo "Why selected:"
  if [[ "$engine_id" == "hysteria2_obfs_udp" ]]; then
    echo "  - Proven in this project."
    if [[ "$deps_ok" == "true" ]]; then
      echo "  - Dependencies are available."
    else
      echo "  - Dependencies can be installed before build."
    fi
    if [[ "$port_ok" == "free" ]]; then
      echo "  - Entry port is free."
    else
      echo "  - Entry port needs review before build."
    fi
    echo "  - Supports generic UDP forwarding."
    echo "  - Destination service is not required before tunnel build."
  elif [[ "$ready" == "NEXT" ]]; then
    echo "  - Priority-next engine for this traffic type."
    echo "  - Lower detection-risk profile by metadata."
    echo "  - Registered for the next implementation PR."
  else
    echo "  - Highest matching registry candidate for this traffic type."
  fi
}

hy2_expert_print_scan_summary_card() {
  local traffic="$1"
  local iran_host="$2"
  local iran_port="$3"
  local foreign_host="$4"
  local dest_host="$5"
  local dest_port="$6"
  local udp_status="$7"
  local tcp_status="$8"
  local destination_for_score="$9"
  local traffic_label rec_id rec_row udp_row tcp_row

  case "$traffic" in
    udp) traffic_label="UDP" ;;
    tcp) traffic_label="TCP" ;;
    both) traffic_label="Both" ;;
    *) traffic_label="$traffic" ;;
  esac

  line
  echo "AUTO TUNNEL EXPERT - SCAN RESULT"
  line
  echo
  echo "Route:"
  echo "  Iran Entry:      $iran_host:$iran_port"
  echo "  Foreign Exit:    $foreign_host"
  echo "  Destination:     $dest_host:$dest_port"
  echo "  Traffic:         $traffic_label"
  echo
  echo "Destination:"
  echo "  UDP listener:    $(hy2_destination_status_label "$udp_status")"
  echo "  TCP listener:    $(hy2_destination_status_label "$tcp_status")"
  echo "  Note: Destination app can be configured later."
  if [[ "$udp_status" == "false" || "$tcp_status" == "false" ]]; then
    echo "  Destination service is not listening yet."
    echo "  This is OK if the tunnel is being created before the app is configured."
  fi
  echo

  if [[ "$traffic" == "both" ]]; then
    hy2_expert_prepare_score_cache "udp" "$iran_port" "$udp_status"
    udp_row="$(hy2_expert_score_for_engine "$(hy2_expert_recommended_engine_id udp)" "udp" "$iran_port" "$udp_status")"
    hy2_expert_prepare_score_cache "tcp" "$iran_port" "$tcp_status"
    tcp_row="$(hy2_expert_score_for_engine "$(hy2_expert_tcp_recommended_engine_id)" "tcp" "$iran_port" "$tcp_status")"
    echo "Recommended:"
    echo "  Best UDP:"
    hy2_expert_print_recommendation_lines "$udp_row" | sed 's/^/    /'
    echo
    echo "  Best TCP:"
    hy2_expert_print_recommendation_lines "$tcp_row" | sed 's/^/    /'
    echo
    echo "Overall:"
    echo "  Build UDP now with Hysteria2 OBFS UDP."
    echo "  TCP engine implementation is next."
    echo
    echo "Next exact action:"
    echo "  Auto Tunnel Expert"
    echo "  -> Build Selected Tunnel From Scan Result"
    echo "  -> hysteria2_obfs_udp"
  else
    rec_id="$(hy2_expert_recommended_engine_id "$traffic")"
    hy2_expert_prepare_score_cache "$traffic" "$iran_port" "$destination_for_score"
    rec_row="$(hy2_expert_score_for_engine "$rec_id" "$traffic" "$iran_port" "$destination_for_score")"
    echo "Recommended:"
    hy2_expert_print_recommendation_lines "$rec_row"
    echo
    echo "Next exact action:"
    echo "  Auto Tunnel Expert"
    echo "  -> Build Selected Tunnel From Scan Result"
    echo "  -> $rec_id"
  fi
  echo
  line
}

hy2_expert_print_scan_bundle() {
  local role="$1"
  local traffic="$2"
  local profile="$3"
  local iran_host="$4"
  local iran_port="$5"
  local foreign_host="$6"
  local dest_host="$7"
  local dest_port="$8"
  local bundle path

  [[ "$role" == "foreign" ]] || return 0
  bundle="VIPTRUE_SCAN_BUNDLE=v1;role=foreign-probe;traffic=$traffic;profile=$profile;iran_host=$iran_host;iran_port=$iran_port;foreign_host=$foreign_host;dest_host=$dest_host;dest_port=$dest_port;suggested_engine=hysteria2_obfs_udp"
  path="$(hy2_expert_save_bundle_file "scan" "$profile" "$bundle")"
  echo
  echo -e "${YELLOW}Pairing Mode Bundle${NC}"
  echo "$bundle"
  echo
  echo "Bundle saved to:"
  echo "  $path"
  echo
  echo "Copy with:"
  echo "  cat $path"
  echo
  echo "This scan bundle does not contain auth/OBFS secrets."
}

hy2_expert_scan_options_menu() {
  local traffic="$1"
  local iran_port="$2"
  local dest_port="$3"
  local destination_for_score="$4"
  local destination_for_proof="$5"
  local recommended_engine="$6"
  local choice

  while true; do
    echo
    echo -e "${CYAN}Options${NC}"
    echo "1) Build recommended engine"
    echo "2) Show compact ranking"
    echo "3) Show full 49-engine ranking"
    echo "4) Show only buildable engines"
    echo "5) Show priority-next engines"
    echo "6) Show emergency/hard-mode engines"
    echo "7) Print forwarding proof commands"
    echo "0) Back"
    echo
    read -r -p "Select option [0-7]: " choice

    case "$choice" in
      1) hy2_expert_build_engine_by_id "$recommended_engine" ;;
      2) hy2_expert_print_compact_ranking "$traffic" "$iran_port" "$destination_for_score"; pause ;;
      3) hy2_expert_print_full_ranking "$traffic" "$iran_port" "$destination_for_score"; pause ;;
      4) hy2_expert_print_group "BUILDABLE NOW" "buildable" "$traffic" "$iran_port" "$destination_for_score" 0; pause ;;
      5) hy2_expert_print_group "PRIORITY NEXT" "priority" "$traffic" "$iran_port" "$destination_for_score" 0; pause ;;
      6) hy2_expert_print_group "EMERGENCY / HARD MODE" "emergency" "$traffic" "$iran_port" "$destination_for_score" 0; pause ;;
      7) hy2_expert_print_probe_commands "$traffic" "$iran_port" "$dest_port" "$destination_for_proof"; pause ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

hy2_expert_scan_best_tunnel() {
  local role_choice role traffic_choice traffic bundle iran_host iran_port foreign_host dest_host dest_port profile
  local dest_listener_output udp_status="unknown" tcp_status="unknown" destination_for_score="unknown" destination_for_proof="unknown"
  local default_foreign default_iran default_dest default_dest_port recommended_engine

  title
  echo -e "${CYAN}Auto Tunnel Expert > Scan Best Tunnel Between Two Servers${NC}"
  line
  echo
  warn_line "scope" "WireGuard and Xray are destination examples only; this scanner does not require wg0, WireGuard keys, xray, or PasarGuard."
  echo "Pairing Mode is implemented first. SSH Auto Mode is a future placeholder; no SSH credentials are collected in this PR."
  echo
  echo "This server role:"
  echo "1) Iran / Entry"
  echo "2) Foreign / Exit"
  read -r -p "Select role [1-2]: " role_choice
  case "$role_choice" in
    1|"") role="iran" ;;
    2) role="foreign" ;;
    *) fail_line "server role" "choose 1 or 2"; pause; return ;;
  esac

  if [[ "$role" == "iran" ]]; then
    read -r -p "Paste VIPTRUE_SCAN_BUNDLE from Foreign side if available, or press Enter: " bundle
  else
    bundle=""
  fi

  default_foreign="$(hy2_auto_bundle_value "$bundle" "foreign_host")"
  default_iran="$(hy2_auto_bundle_value "$bundle" "iran_host")"
  default_dest="$(hy2_auto_bundle_value "$bundle" "dest_host")"
  default_dest_port="$(hy2_auto_bundle_value "$bundle" "dest_port")"

  echo
  echo "Traffic type:"
  echo "1) UDP"
  echo "2) TCP"
  echo "3) Both"
  read -r -p "Select traffic [1-3]: " traffic_choice
  case "$traffic_choice" in
    1|"") traffic="udp" ;;
    2) traffic="tcp" ;;
    3) traffic="both" ;;
    *) fail_line "traffic type" "choose 1, 2, or 3"; pause; return ;;
  esac

  iran_host="$(prompt_default "Iran public IP/domain" "${default_iran:-IRAN_PUBLIC_IP}")"
  iran_port="$(prompt_default "Iran listen/input port" "51822")"
  foreign_host="$(prompt_default "Foreign public IP/domain" "${default_foreign:-FOREIGN_PUBLIC_IP}")"
  dest_host="$(prompt_default "Destination IP from foreign server point of view" "${default_dest:-127.0.0.1}")"
  dest_port="$(prompt_default "Destination port on foreign server" "${default_dest_port:-51820}")"
  profile="$(hy2_auto_profile_name_or_default "Optional profile name" "expert-scan")" || { pause; return; }

  if ! valid_port "$iran_port" || ! valid_port "$dest_port"; then
    fail_line "scan ports" "ports must be 1-65535"
    pause
    return
  fi

  if [[ "$dest_host" == "127.0.0.1" || "$dest_host" == "localhost" || "$dest_host" == "0.0.0.0" ]]; then
    if [[ "$traffic" == "udp" || "$traffic" == "both" ]]; then
      dest_listener_output="$(list_listeners udp "$dest_port")"
      if [[ -n "$dest_listener_output" ]]; then
        udp_status="true"
      else
        udp_status="false"
      fi
    fi
    if [[ "$traffic" == "tcp" || "$traffic" == "both" ]]; then
      dest_listener_output="$(list_listeners tcp "$dest_port")"
      if [[ -n "$dest_listener_output" ]]; then
        tcp_status="true"
      else
        tcp_status="false"
      fi
    fi
  fi

  case "$traffic" in
    udp)
      destination_for_score="$udp_status"
      destination_for_proof="$udp_status"
      ;;
    tcp)
      destination_for_score="$tcp_status"
      destination_for_proof="$tcp_status"
      ;;
    both)
      if [[ "$udp_status" == "false" || "$tcp_status" == "false" ]]; then
        destination_for_score="false"
      elif [[ "$udp_status" == "true" || "$tcp_status" == "true" ]]; then
        destination_for_score="true"
      else
        destination_for_score="unknown"
      fi
      destination_for_proof="$tcp_status"
      ;;
  esac

  recommended_engine="$(hy2_expert_recommended_engine_id "$traffic")"
  hy2_expert_print_scan_summary_card \
    "$traffic" "$iran_host" "$iran_port" "$foreign_host" "$dest_host" "$dest_port" \
    "$udp_status" "$tcp_status" "$destination_for_score"
  hy2_expert_print_default_scan_view "$traffic" "$iran_port" "$destination_for_score"
  hy2_expert_print_scan_bundle "$role" "$traffic" "$profile" "$iran_host" "$iran_port" "$foreign_host" "$dest_host" "$dest_port"

  echo
  echo "Forwarding proof commands are available."
  echo "Select option 7 to print them."
  echo
  echo "SSH credentials were not collected."
  echo "No tunnel was built yet."

  set_summary \
    "Adaptive scan completed for $traffic traffic." \
    "Recommended engine: $recommended_engine" \
    "Build recommended engine or inspect full ranking." \
    "Pairing Mode used. SSH credentials were not collected." \
    "No tunnel was built yet."
  print_summary
  hy2_expert_scan_options_menu "$traffic" "$iran_port" "$dest_port" "$destination_for_score" "$destination_for_proof" "$recommended_engine"
}

hy2_expert_validate_generic_bundle() {
  local bundle="$1"
  local raw engine type foreign_host hy2_port dest_host dest_port sni insecure auth obfs

  raw="${bundle#VIPTRUE_TUNNEL_BUNDLE=}"
  if [[ "$raw" != v2* ]]; then
    fail_line "v2 bundle" "expected VIPTRUE_TUNNEL_BUNDLE=v2"
    return 1
  fi

  engine="$(hy2_auto_bundle_value "$bundle" "engine")"
  type="$(hy2_auto_bundle_value "$bundle" "type")"
  foreign_host="$(hy2_auto_bundle_value "$bundle" "foreign_host")"
  hy2_port="$(hy2_auto_bundle_value "$bundle" "hy2_port")"
  dest_host="$(hy2_auto_bundle_value "$bundle" "dest_host")"
  dest_port="$(hy2_auto_bundle_value "$bundle" "dest_port")"
  sni="$(hy2_auto_bundle_value "$bundle" "sni")"
  insecure="$(hy2_auto_bundle_value "$bundle" "insecure")"
  auth="$(hy2_auto_bundle_value "$bundle" "auth")"
  obfs="$(hy2_auto_bundle_value "$bundle" "obfs")"

  if [[ "$engine" != "hysteria2_obfs_udp" || "$type" != "generic-udp-forward" ]]; then
    fail_line "v2 bundle engine/type" "expected hysteria2_obfs_udp generic-udp-forward"
    return 1
  fi
  if [[ -z "${foreign_host// /}" || -z "${dest_host// /}" ]]; then
    fail_line "v2 bundle hosts" "missing foreign_host or dest_host"
    return 1
  fi
  if ! valid_port "$hy2_port" || ! valid_port "$dest_port"; then
    fail_line "v2 bundle port" "invalid hy2_port or dest_port"
    return 1
  fi
  if [[ "$hy2_port" == "443" ]]; then
    fail_line "v2 bundle hy2_port" "UDP port 443 is forbidden for Hysteria2"
    return 1
  fi
  if [[ -z "${auth// /}" ]]; then
    fail_line "v2 bundle auth" "missing"
    return 1
  fi
  if [[ -z "${obfs// /}" ]]; then
    fail_line "v2 bundle obfs" "missing"
    return 1
  fi
  if [[ -z "${sni// /}" || "$insecure" != "true" ]]; then
    fail_line "v2 bundle TLS" "missing sni or insecure=true"
    return 1
  fi

  pass_line "v2 generic bundle" "$foreign_host:$hy2_port -> $dest_host:$dest_port"
}

hy2_expert_build_hysteria_generic_foreign() {
  local listen_port recommended_port foreign_host dest_host dest_port profile service_name profile_dir
  local config_path cert_path key_path auth_pass obfs_pass meta_path confirm start_now listener_output score=0
  local tunnel_bundle bundle_path

  title
  echo -e "${CYAN}Auto Tunnel Expert > Build Hysteria2 OBFS UDP Generic Forward > Foreign${NC}"
  line
  echo
  warn_line "bundle" "runtime bundle contains operational secrets; do not share publicly or commit it"
  recommended_port="$(hy2_auto_candidate_port)"
  hy2_expert_print_generic_recommendation "$recommended_port"
  foreign_host="$(prompt_default "Foreign public IP/domain" "$(detect_public_ip)")"
  hy2_prompt_non443_port "Foreign Hysteria UDP port" "$recommended_port" || { pause; return; }
  listen_port="$HY2_PROMPTED_PORT"
  dest_host="$(prompt_default "Destination IP from foreign server point of view" "127.0.0.1")"
  dest_port="$(prompt_default "Destination UDP port" "51820")"
  valid_port "$dest_port" || { fail_line "Destination UDP port" "ports must be 1-65535"; pause; return; }
  profile="$(hy2_auto_profile_name_or_default "Profile name" "hy2-generic")" || { pause; return; }
  hy2_auto_value_safe_for_bundle "Foreign public IP/domain" "$foreign_host" || { pause; return; }
  hy2_auto_value_safe_for_bundle "Destination host" "$dest_host" || { pause; return; }

  service_name="$(hy2_auto_service_name "foreign" "$profile")"
  profile_dir="$HY2_WG_AUTO_FOREIGN_DIR/$profile"
  config_path="$profile_dir/config.yaml"
  cert_path="$profile_dir/server.crt"
  key_path="$profile_dir/server.key"

  if [[ "$dest_host" == "127.0.0.1" || "$dest_host" == "localhost" || "$dest_host" == "0.0.0.0" ]]; then
    listener_output="$(list_listeners udp "$dest_port")"
    if [[ -n "$listener_output" ]]; then
      pass_line "destination UDP listener" "$dest_host:$dest_port"
    else
      warn_line "destination UDP listener" "$dest_host:$dest_port not detected; build can continue because the destination may be configured later"
    fi
  fi

  echo
  echo -e "${YELLOW}Plan${NC}"
  echo "Engine: hysteria2_obfs_udp"
  echo "Profile: $profile"
  echo "Service: $service_name"
  echo "Config path: $config_path"
  echo "Foreign Hysteria UDP listen: $listen_port"
  echo "Destination: $dest_host:$dest_port"
  echo "Masquerade SNI/CN: $HY2_DEFAULT_LEGACY_SNI"
  echo "Masquerade URL: $HY2_DEFAULT_MASQUERADE_URL"
  echo "Existing services on other ports will not be stopped."
  echo "Only the same profile service may be stopped, after confirmation."
  echo
  read -r -p "Create generic Foreign setup now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) info_line "generic foreign build" "cancelled before writing files"; pause; return ;;
  esac

  ensure_root || { pause; return; }
  ensure_hysteria2_ready || { pause; return; }
  require_cmd openssl openssl || { pause; return; }
  ensure_hy2_wg_dirs
  mkdir -p "$profile_dir" "$HY2_SYSTEMD_SYSTEM_DIR"
  chmod 700 "$profile_dir" 2>/dev/null || true

  listener_output="$(list_listeners udp "$listen_port")"
  if [[ -n "$listener_output" ]]; then
    warn_line "local UDP listener conflict" "UDP $listen_port already has a listener"
    printf '%s\n' "$listener_output"
    read -r -p "Continue without stopping unrelated listeners? [y/N]: " confirm
    case "$confirm" in
      y|Y|yes|YES) ;;
      *) fail_line "local UDP listener conflict" "left untouched; build cancelled"; pause; return ;;
    esac
  fi

  hy2_auto_stop_same_profile_service "$service_name" || { pause; return; }
  auth_pass="$(hy2_auto_random_secret)"
  obfs_pass="$(hy2_auto_random_secret)"
  hy2_wg_generate_self_signed_cert "$cert_path" "$key_path" "$HY2_DEFAULT_LEGACY_SNI" || { pause; return; }
  hy2_wg_write_foreign_config "$listen_port" "$auth_pass" "$obfs_pass" "self-signed" "$cert_path" "$key_path" "$HY2_DEFAULT_MASQUERADE_URL" "$config_path"
  hy2_wg_write_service "$service_name" "server" "$config_path" "VIPTrue Auto Hysteria2 OBFS generic foreign server $profile"

  meta_path="$(hy2_auto_meta_path "foreign" "$profile")"
  {
    echo "role=foreign/server"
    echo "protocol=udp"
    echo "engine=hysteria2_obfs_udp"
    echo "profile=$profile"
    echo "service_name=$service_name"
    echo "config_path=$config_path"
    echo "listen_port=$listen_port"
    echo "entry_port=$listen_port"
    echo "foreign_host=$foreign_host"
    echo "destination_host=$dest_host"
    echo "destination_port=$dest_port"
    echo "target_host=$dest_host"
    echo "target_port=$dest_port"
    echo "endpoint=$foreign_host:$listen_port"
    echo "sni=$HY2_DEFAULT_LEGACY_SNI"
    echo "masquerade_url=$HY2_DEFAULT_MASQUERADE_URL"
    echo "supports_multi_foreign=true"
  } > "$meta_path"
  chmod 600 "$meta_path" 2>/dev/null || true

  start_now="$(prompt_yes_no_value "Enable and start $service_name now?" "Y")"
  hy2_wg_start_service_if_requested "$service_name" "$start_now" || { pause; return; }
  hy2_wg_apply_ufw_rules "$listen_port"

  echo
  line
  echo -e "${CYAN}Generic Foreign Checks${NC}"
  if hy2_wg_service_active "$service_name"; then score=$((score + 30)); pass_line "service active" "$service_name"; else warn_line "service active" "$service_name not confirmed active"; fi
  if [[ -n "$(list_listeners udp "$listen_port")" ]]; then score=$((score + 20)); pass_line "UDP port listening" "$listen_port"; else warn_line "UDP port listening" "$listen_port not detected"; fi

  echo
  warn_line "VIPTRUE_TUNNEL_BUNDLE" "contains operational secrets; do not share publicly or commit it"
  echo "WARNING: This bundle contains operational secrets. Do not share publicly."
  tunnel_bundle="VIPTRUE_TUNNEL_BUNDLE=v2;engine=hysteria2_obfs_udp;type=generic-udp-forward;profile=$profile;foreign_host=$foreign_host;hy2_port=$listen_port;dest_host=$dest_host;dest_port=$dest_port;sni=$HY2_DEFAULT_LEGACY_SNI;insecure=true;auth=$auth_pass;obfs=$obfs_pass;masq=$HY2_DEFAULT_MASQUERADE_URL"
  bundle_path="$(hy2_expert_save_bundle_file "tunnel" "$profile" "$tunnel_bundle")"
  echo "$tunnel_bundle"
  echo
  echo "Bundle saved to:"
  echo "  $bundle_path"
  echo
  echo "Copy with:"
  echo "  cat $bundle_path"
  echo
  echo "Score: $score"
  echo "What was tested: local service/listener checks only."
  echo "What was not proven: Iran-to-Foreign connection and destination payload delivery."
  hy2_expert_print_probe_commands "udp" "IRAN_LISTEN_PORT" "$dest_port" "unknown"
  pause
}

hy2_expert_build_hysteria_generic_iran() {
  local default_port="${1:-51822}"
  local bundle profile_default profile foreign_host hy2_port dest_host dest_port sni auth obfs masq
  local iran_port endpoint service_name config_path meta_path confirm start_now remote_target

  title
  echo -e "${CYAN}Auto Tunnel Expert > Build Hysteria2 OBFS UDP Generic Forward > Iran${NC}"
  line
  echo
  warn_line "bundle" "runtime bundle contains operational secrets; do not paste it into logs or commit it"
  read -r -p "Paste VIPTRUE_TUNNEL_BUNDLE v2: " bundle
  hy2_expert_validate_generic_bundle "$bundle" || { pause; return; }

  profile_default="$(hy2_auto_bundle_value "$bundle" "profile")"
  profile_default="${profile_default:-hy2-generic}"
  profile="$(hy2_auto_profile_name_or_default "Profile name" "$profile_default")" || { pause; return; }
  foreign_host="$(hy2_auto_bundle_value "$bundle" "foreign_host")"
  hy2_port="$(hy2_auto_bundle_value "$bundle" "hy2_port")"
  dest_host="$(hy2_auto_bundle_value "$bundle" "dest_host")"
  dest_port="$(hy2_auto_bundle_value "$bundle" "dest_port")"
  sni="$(hy2_auto_bundle_value "$bundle" "sni")"
  auth="$(hy2_auto_bundle_value "$bundle" "auth")"
  obfs="$(hy2_auto_bundle_value "$bundle" "obfs")"
  masq="$(hy2_auto_bundle_value "$bundle" "masq")"

  hy2_prompt_non443_port "Iran local UDP listen/input port" "$default_port" || { pause; return; }
  iran_port="$HY2_PROMPTED_PORT"
  if [[ -n "$(list_listeners udp "$iran_port")" ]]; then
    fail_line "Iran local UDP listen port" "$iran_port already has an active listener; not stopping unrelated tunnels"
    pause
    return
  fi
  if hy2_wg_iran_port_in_existing_config "$iran_port"; then
    fail_line "Iran local UDP listen port" "$iran_port already appears in an existing generated client config; existing tunnels on other ports are preserved"
    pause
    return
  fi

  hy2_auto_endpoint_hints
  endpoint="$(prompt_default "Iran public endpoint IP/domain for clients" "$(detect_public_ip)")"
  if [[ -z "${endpoint// /}" ]]; then
    fail_line "Iran public endpoint" "value is required"
    pause
    return
  fi

  service_name="$(hy2_auto_service_name "iran" "$profile")"
  config_path="$(hy2_auto_iran_config_path "$profile")"
  remote_target="$dest_host:$dest_port"

  echo
  echo -e "${YELLOW}Plan${NC}"
  echo "Engine: hysteria2_obfs_udp"
  echo "Profile: $profile"
  echo "Service: $service_name"
  echo "Config path: $config_path"
  echo "Iran UDP $iran_port -> Foreign $foreign_host:$hy2_port -> $remote_target"
  echo "TLS SNI: $sni"
  echo "TLS insecure: true"
  echo "Masquerade URL from bundle: ${masq:-unknown}"
  echo "Existing tunnels on other ports will not be stopped."
  echo
  read -r -p "Create generic Iran setup now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) info_line "generic Iran build" "cancelled before writing files"; pause; return ;;
  esac

  ensure_root || { pause; return; }
  ensure_hysteria2_ready || { pause; return; }
  ensure_hy2_wg_dirs
  mkdir -p "$HY2_WG_AUTO_IRAN_DIR" "$HY2_SYSTEMD_SYSTEM_DIR"
  hy2_auto_stop_same_profile_service "$service_name" || { pause; return; }

  hy2_wg_write_client_config "$profile" "$foreign_host" "$hy2_port" "$iran_port" "$dest_host" "$dest_port" "$auth" "$obfs" "$sni" "true" "$config_path"
  hy2_wg_write_service "$service_name" "client" "$config_path" "VIPTrue Auto Hysteria2 OBFS generic Iran client $profile"
  meta_path="$(hy2_auto_meta_path "iran" "$profile")"
  {
    echo "role=iran/client"
    echo "protocol=udp"
    echo "engine=hysteria2_obfs_udp"
    echo "profile=$profile"
    echo "service_name=$service_name"
    echo "config_path=$config_path"
    echo "listen_port=$iran_port"
    echo "entry_port=$iran_port"
    echo "foreign_host=$foreign_host"
    echo "hy2_port=$hy2_port"
    echo "destination_host=$dest_host"
    echo "destination_port=$dest_port"
    echo "remote_target=$remote_target"
    echo "endpoint=$endpoint:$iran_port"
    echo "masquerade_url=$masq"
    echo "supports_multi_foreign=true"
  } > "$meta_path"
  chmod 600 "$meta_path" 2>/dev/null || true

  start_now="$(prompt_yes_no_value "Enable and start $service_name now?" "Y")"
  hy2_wg_start_service_if_requested "$service_name" "$start_now" || { pause; return; }
  hy2_wg_apply_ufw_rules "$iran_port"
  hy2_auto_quick_health_test "$service_name" "$iran_port"
  echo
  echo "Set client/application endpoint to: $endpoint:$iran_port"
  hy2_expert_print_probe_commands "udp" "$iran_port" "$dest_port" "unknown"
  pause
}

hy2_expert_build_engine_by_id() {
  local engine_id side_choice

  engine_id="$1"
  if [[ "$engine_id" != "hysteria2_obfs_udp" ]]; then
    warn_line "$engine_id" "Engine is registered but not implemented yet. Use Manual Tunnel Lab or wait for next engine PR."
    pause
    return
  fi

  echo
  echo "Build side:"
  echo "1) Foreign / Exit side bundle generator"
  echo "2) Iran / Entry side from bundle"
  read -r -p "Select side [1-2]: " side_choice
  case "$side_choice" in
    1|"") hy2_expert_build_hysteria_generic_foreign ;;
    2) hy2_expert_build_hysteria_generic_iran "51822" ;;
    *) fail_line "build side" "choose 1 or 2"; pause ;;
  esac
}

hy2_expert_build_selected_tunnel() {
  local engine_id

  title
  echo -e "${CYAN}Auto Tunnel Expert > Build Selected Tunnel From Scan Result${NC}"
  line
  echo
  echo "Only hysteria2_obfs_udp generic UDP forward is implemented in this PR."
  engine_id="$(prompt_default "Engine ID" "hysteria2_obfs_udp")"
  if ! hy2_engine_lookup "$engine_id" >/dev/null; then
    fail_line "engine registry" "$engine_id is not registered"
    pause
    return
  fi
  if [[ "$engine_id" != "hysteria2_obfs_udp" ]]; then
    warn_line "$engine_id" "Engine is registered but not implemented yet. Use Manual Tunnel Lab or wait for next engine PR."
    pause
    return
  fi

  hy2_expert_build_engine_by_id "$engine_id"
}

hy2_expert_add_foreign_to_iran() {
  title
  echo -e "${CYAN}Auto Tunnel Expert > Add Another Foreign Server To Existing Iran Entry${NC}"
  line
  echo
  warn_line "multi-foreign" "choose a new Iran listen port for the new foreign mapping; existing tunnels such as 51822 are preserved."
  echo "This uses the same v2 generic Hysteria2 bundle from the new Foreign/Exit server."
  hy2_expert_build_hysteria_generic_iran "51823"
}

auto_tunnel_expert_menu() {
  local choice

  while true; do
    title
    echo -e "${CYAN}Auto Tunnel Expert${NC}"
    line
    echo
    echo "1. Scan Best Tunnel Between Two Servers"
    echo "2. Build Selected Tunnel From Scan Result"
    echo "3. Add Another Foreign Server To Existing Iran Entry"
    echo "4. Show Engine Registry"
    echo "5. Explain Engine Families"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-5]: " choice

    case "$choice" in
      1) hy2_expert_scan_best_tunnel ;;
      2) hy2_expert_build_selected_tunnel ;;
      3) hy2_expert_add_foreign_to_iran ;;
      4) hy2_engine_show_registry ;;
      5) hy2_engine_explain_families ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

hy2_auto_foreign_setup() {
  local purpose listen_port recommended_port cert_cn masquerade_url wg_iface_default wg_iface
  local wg_port_default wg_port profile foreign_host target_host target_port auth_pass obfs_pass
  local bundle_type wg_pub service_name config_path meta_path confirm start_now score
  local listener_output

  title
  echo -e "${CYAN}Auto Tunnel Wizard > Foreign/Exit server setup${NC}"
  line
  echo

  hy2_auto_select_udp_purpose purpose || { pause; return; }
  recommended_port="$(hy2_auto_candidate_port)"
  hy2_auto_print_recommendation "$recommended_port"

  hy2_prompt_non443_port "Foreign Hysteria UDP listen port" "$recommended_port" || { pause; return; }
  listen_port="$HY2_PROMPTED_PORT"
  cert_cn="$(prompt_default "Masquerade SNI/CN" "$HY2_DEFAULT_LEGACY_SNI")"
  cert_cn="${cert_cn:-$HY2_DEFAULT_LEGACY_SNI}"
  cert_cn="${cert_cn//\//-}"
  masquerade_url="$(prompt_default "Masquerade URL" "$HY2_DEFAULT_MASQUERADE_URL")"
  masquerade_url="${masquerade_url:-$HY2_DEFAULT_MASQUERADE_URL}"

  profile="$(hy2_auto_profile_name_or_default "Optional profile name" "auto-foreign")" || { pause; return; }
  service_name="$(hy2_auto_service_name "foreign" "$profile")"
  bundle_type="$purpose"

  if [[ "$purpose" == "udp-wg-hy2" ]]; then
    wg_iface_default="$(hy2_auto_detect_wg_iface)"
    wg_iface="$(prompt_default "WireGuard interface" "$wg_iface_default")"
    valid_iface "$wg_iface" || { fail_line "WireGuard interface" "invalid interface name"; pause; return; }
    wg_port_default="$(hy2_auto_detect_wg_port "$wg_iface")"
    wg_port="$(prompt_default "WireGuard listen port" "$wg_port_default")"
    valid_port "$wg_port" || { fail_line "WireGuard listen port" "ports must be 1-65535"; pause; return; }
    target_host="127.0.0.1"
    target_port="$wg_port"
  else
    target_host="$(prompt_default "Foreign local UDP target host" "127.0.0.1")"
    target_port="$(prompt_default "Foreign local UDP target port" "51820")"
    valid_port "$target_port" || { fail_line "Foreign local UDP target port" "ports must be 1-65535"; pause; return; }
    wg_iface="none"
    wg_port="$target_port"
  fi

  foreign_host="$(prompt_default "Foreign public IP/domain for bundle" "$(detect_public_ip)")"
  hy2_auto_value_safe_for_bundle "Foreign public IP/domain" "$foreign_host" || { pause; return; }
  hy2_auto_value_safe_for_bundle "Masquerade SNI/CN" "$cert_cn" || { pause; return; }
  hy2_auto_value_safe_for_bundle "Masquerade URL" "$masquerade_url" || { pause; return; }

  echo
  echo -e "${YELLOW}Plan${NC}"
  echo "Role: Foreign/Exit server"
  echo "Profile: $profile"
  echo "Service: $service_name"
  echo "Config path: $HY2_LEGACY_CONFIG"
  echo "Hysteria UDP listen: $listen_port"
  echo "Proven profile: Hysteria2 OBFS salamander + Bing masquerade + self-signed/insecure TLS"
  echo "Masquerade SNI/CN: $cert_cn"
  echo "Masquerade URL: $masquerade_url"
  echo "Forward target for Iran client: $target_host:$target_port"
  [[ "$purpose" == "udp-wg-hy2" ]] && echo "WireGuard interface: $wg_iface"
  echo "Existing /etc/hysteria files and service files will be backed up before overwrite."
  echo "Only conflicting Hysteria services referencing this config are candidates for stop, after confirmation."
  echo
  read -r -p "Create Auto Foreign setup now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) info_line "Auto Foreign setup" "cancelled before writing files"; pause; return ;;
  esac

  ensure_root || { pause; return; }
  ensure_hysteria2_ready || { pause; return; }
  require_cmd openssl openssl || { pause; return; }
  if [[ "$purpose" == "udp-wg-hy2" ]]; then
    hy2_wg_synthetic_require_wg || { pause; return; }
  fi
  ensure_hy2_wg_dirs
  mkdir -p "$HY2_LEGACY_DIR" "$HY2_WG_AUTO_FOREIGN_DIR/$profile" "$HY2_SYSTEMD_SYSTEM_DIR"
  chmod 700 "$HY2_LEGACY_DIR" "$HY2_WG_AUTO_FOREIGN_DIR/$profile" 2>/dev/null || true

  listener_output="$(list_listeners udp "$listen_port")"
  if [[ -n "$listener_output" ]]; then
    warn_line "local UDP listener conflict" "UDP $listen_port already has a listener"
    printf '%s\n' "$listener_output"
  fi

  hy2_auto_stop_conflicting_hysteria_services "$HY2_LEGACY_CONFIG" "$service_name" || { pause; return; }
  hy2_auto_stop_same_profile_service "$service_name" || { pause; return; }

  auth_pass="$(hy2_auto_random_secret)"
  obfs_pass="$(hy2_auto_random_secret)"
  hy2_wg_generate_self_signed_cert "$HY2_LEGACY_CERT" "$HY2_LEGACY_KEY" "$cert_cn" || { pause; return; }
  hy2_wg_write_legacy_proven_config "$listen_port" "$auth_pass" "$obfs_pass" "$HY2_LEGACY_CERT" "$HY2_LEGACY_KEY" "$masquerade_url"
  config_path="$HY2_WRITTEN_CONFIG"
  hy2_wg_write_service "$service_name" "server" "$config_path" "VIPTrue Auto Hysteria2 OBFS foreign server $profile"

  meta_path="$(hy2_auto_meta_path "foreign" "$profile")"
  {
    echo "role=foreign/server"
    echo "profile=$profile"
    echo "service_name=$service_name"
    echo "config_path=$config_path"
    echo "listen_port=$listen_port"
    echo "purpose=$purpose"
    echo "wg_iface=$wg_iface"
    echo "wg_port=$wg_port"
    echo "target_host=$target_host"
    echo "target_port=$target_port"
    echo "sni=$cert_cn"
    echo "masquerade_url=$masquerade_url"
  } > "$meta_path"
  chmod 600 "$meta_path" 2>/dev/null || true

  start_now="$(prompt_yes_no_value "Enable and start $service_name now?" "Y")"
  hy2_wg_start_service_if_requested "$service_name" "$start_now" || { pause; return; }
  hy2_wg_apply_ufw_rules "$listen_port"

  score=0
  echo
  line
  echo -e "${CYAN}Auto Foreign Checks${NC}"
  if hy2_wg_service_active "$service_name"; then score=$((score + 30)); pass_line "service active" "$service_name"; else fail_line "service active" "$service_name inactive"; fi
  if [[ -n "$(list_listeners udp "$listen_port")" ]]; then score=$((score + 20)); pass_line "UDP port listening" "$listen_port"; else fail_line "UDP port listening" "$listen_port not detected"; fi
  if [[ "$purpose" == "udp-wg-hy2" ]]; then
    if have_cmd ip && ip link show "$wg_iface" >/dev/null 2>&1; then pass_line "WireGuard interface exists" "$wg_iface"; else fail_line "WireGuard interface exists" "$wg_iface not found"; fi
    check_local_listener udp "$wg_port"
    echo -e "${YELLOW}Foreign WireGuard public key${NC}"
    wg_pub="$(wg show "$wg_iface" public-key 2>/dev/null || true)"
    echo "${wg_pub:-unknown}"
  else
    wg_pub="none"
  fi

  echo
  warn_line "VIPTRUE_TUNNEL_BUNDLE" "contains operational secrets; do not share publicly or commit it"
  echo "VIPTRUE_TUNNEL_BUNDLE=v1;type=$bundle_type;profile=$profile;foreign_host=$foreign_host;hy2_port=$listen_port;wg_host=$target_host;wg_port=$target_port;wg_pub=${wg_pub:-none};sni=$cert_cn;insecure=true;auth=$auth_pass;obfs=$obfs_pass;masq=$masquerade_url"
  echo
  echo "Recommended tunnel profile: proven working profile"
  echo "Score: $score"
  echo "Why selected: proven working profile with local service/listener checks"
  echo "What was tested: Hysteria service, UDP listener, and WireGuard interface/listener when applicable"
  echo "What was not proven: Iran-side connection and WireGuard synthetic handshake until the Iran setup/tests run"

  set_summary \
    "Auto Foreign pairing bundle, service/listener checks, and WireGuard public key output." \
    "If service/listener checks failed, fix the foreign service or firewall before using the bundle." \
    "Paste the VIPTRUE_TUNNEL_BUNDLE into Auto Tunnel Wizard on the Iran/Entry server." \
    "Yes: Iran setup and tests are still required."
  print_summary
  pause
}

hy2_auto_iran_setup() {
  local purpose bundle profile_default profile foreign_host hy2_port wg_host wg_port wg_pub sni auth obfs masq
  local iran_port endpoint service_name config_path meta_path confirm start_now remote_target

  title
  echo -e "${CYAN}Auto Tunnel Wizard > Iran/Entry server setup${NC}"
  line
  echo

  hy2_auto_select_udp_purpose purpose || { pause; return; }
  read -r -p "Paste VIPTRUE_TUNNEL_BUNDLE: " bundle
  hy2_auto_validate_tunnel_bundle "$bundle" || { pause; return; }

  if [[ "$(hy2_auto_bundle_value "$bundle" "type")" != "$purpose" ]]; then
    fail_line "bundle purpose" "selected purpose does not match bundle type"
    pause
    return
  fi

  profile_default="$(hy2_auto_bundle_value "$bundle" "profile")"
  profile_default="${profile_default:-auto-wg}"
  profile="$(hy2_auto_profile_name_or_default "Profile name" "$profile_default")" || { pause; return; }
  foreign_host="$(hy2_auto_bundle_value "$bundle" "foreign_host")"
  hy2_port="$(hy2_auto_bundle_value "$bundle" "hy2_port")"
  wg_host="$(hy2_auto_bundle_value "$bundle" "wg_host")"
  wg_port="$(hy2_auto_bundle_value "$bundle" "wg_port")"
  wg_pub="$(hy2_auto_bundle_value "$bundle" "wg_pub")"
  sni="$(hy2_auto_bundle_value "$bundle" "sni")"
  auth="$(hy2_auto_bundle_value "$bundle" "auth")"
  obfs="$(hy2_auto_bundle_value "$bundle" "obfs")"
  masq="$(hy2_auto_bundle_value "$bundle" "masq")"

  hy2_prompt_non443_port "Iran local UDP listen port" "51822" || { pause; return; }
  iran_port="$HY2_PROMPTED_PORT"
  if [[ -n "$(list_listeners udp "$iran_port")" ]]; then
    fail_line "Iran local UDP listen port" "$iran_port already has an active listener; not stopping unrelated tunnels"
    pause
    return
  fi
  if hy2_wg_iran_port_in_existing_config "$iran_port"; then
    fail_line "Iran local UDP listen port" "$iran_port already appears in an existing generated client config; existing tunnels on other ports are preserved"
    pause
    return
  fi

  hy2_auto_endpoint_hints
  endpoint="$(prompt_default "Iran public endpoint IP/domain for PasarGuard output" "$(detect_public_ip)")"
  if [[ -z "${endpoint// /}" ]]; then
    fail_line "Iran public endpoint" "value is required"
    pause
    return
  fi

  service_name="$(hy2_auto_service_name "iran" "$profile")"
  config_path="$(hy2_auto_iran_config_path "$profile")"
  remote_target="$wg_host:$wg_port"

  echo
  echo -e "${YELLOW}Plan${NC}"
  echo "Role: Iran/Entry server"
  echo "Profile: $profile"
  echo "Service: $service_name"
  echo "Config path: $config_path"
  echo "Iran UDP $iran_port -> Foreign $foreign_host:$hy2_port -> $remote_target"
  echo "TLS SNI: $sni"
  echo "TLS insecure: true"
  echo "Masquerade URL from bundle: ${masq:-unknown}"
  echo "Existing services on other ports will not be stopped."
  echo
  read -r -p "Create Auto Iran setup now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) info_line "Auto Iran setup" "cancelled before writing files"; pause; return ;;
  esac

  ensure_root || { pause; return; }
  ensure_hysteria2_ready || { pause; return; }
  ensure_hy2_wg_dirs
  mkdir -p "$HY2_WG_AUTO_IRAN_DIR" "$HY2_SYSTEMD_SYSTEM_DIR"
  hy2_auto_stop_same_profile_service "$service_name" || { pause; return; }

  hy2_wg_write_client_config "$profile" "$foreign_host" "$hy2_port" "$iran_port" "$wg_host" "$wg_port" "$auth" "$obfs" "$sni" "true" "$config_path"
  hy2_wg_write_service "$service_name" "client" "$config_path" "VIPTrue Auto Hysteria2 OBFS Iran client $profile"
  meta_path="$(hy2_auto_meta_path "iran" "$profile")"
  {
    echo "role=iran/client"
    echo "profile=$profile"
    echo "service_name=$service_name"
    echo "config_path=$config_path"
    echo "listen_port=$iran_port"
    echo "foreign_host=$foreign_host"
    echo "hy2_port=$hy2_port"
    echo "remote_target=$remote_target"
    echo "endpoint=$endpoint"
    echo "wg_pub=$wg_pub"
  } > "$meta_path"
  chmod 600 "$meta_path" 2>/dev/null || true

  start_now="$(prompt_yes_no_value "Enable and start $service_name now?" "Y")"
  hy2_wg_start_service_if_requested "$service_name" "$start_now" || { pause; return; }
  hy2_wg_apply_ufw_rules "$iran_port"
  hy2_auto_quick_health_test "$service_name" "$iran_port"

  echo
  echo "Set PasarGuard WireGuard endpoint to: $endpoint:$iran_port"
  if [[ "$purpose" == "udp-wg-hy2" ]]; then
    echo
    echo "Synthetic WireGuard test options:"
    echo "1. Iran: use Auto Wizard -> Iran: generate/run synthetic test from bundle"
    echo "2. Foreign: use Auto Wizard -> Add temporary test peer from bundle"
    echo "3. Foreign cleanup removes the temporary peer after PASS/FAIL"
  fi
  hy2_auto_print_udp_probe_commands "$iran_port" "$wg_port"

  set_summary \
    "Auto Iran config/service, quick health checks, and final PasarGuard endpoint output." \
    "If quick health failed, service logs or local listener checks identify the first failed layer." \
    "Run the Auto synthetic WireGuard test to prove handshake and transfer bytes." \
    "Maybe: foreign peer test setup or firewall/provider action may still be needed."
  print_summary
  pause
}

hy2_auto_add_test_peer_from_bundle() {
  local bundle peer_pub allowed_ip wg_iface current_hs

  title
  echo -e "${CYAN}Auto Tunnel Wizard > Add temporary test peer from bundle${NC}"
  line
  echo
  read -r -p "Paste VIPTRUE_TEST_PEER_BUNDLE: " bundle
  peer_pub="$(hy2_auto_bundle_value "$bundle" "peer_pub")"
  allowed_ip="$(hy2_auto_bundle_value "$bundle" "allowed_ip")"
  allowed_ip="${allowed_ip:-10.255.255.2/32}"
  wg_iface="$(prompt_default "Foreign WireGuard interface" "$(hy2_auto_detect_wg_iface)")"

  if ! valid_wg_public_key "$peer_pub"; then
    fail_line "test peer public key" "missing or invalid"
    pause
    return
  fi
  if ! valid_cidr "$allowed_ip"; then
    fail_line "test peer allowed IP" "use IPv4/CIDR like 10.255.255.2/32"
    pause
    return
  fi
  valid_iface "$wg_iface" || { fail_line "WireGuard interface" "invalid"; pause; return; }

  hy2_wg_synthetic_require_wg || { pause; return; }
  ensure_root || { pause; return; }
  if wg set "$wg_iface" peer "$peer_pub" allowed-ips "$allowed_ip"; then
    pass_line "temporary test peer added" "$peer_pub allowed-ips $allowed_ip"
    echo "Cleanup command:"
    echo "  wg set $wg_iface peer $peer_pub remove"
  else
    fail_line "temporary test peer" "wg set failed"
    pause
    return
  fi
  current_hs="$(wg_latest_handshake_value "$wg_iface" "$peer_pub")"
  info_line "current handshake" "$current_hs"
  pause
}

hy2_auto_run_synthetic_from_bundle() {
  local bundle iran_port wg_pub open_now

  title
  echo -e "${CYAN}Auto Tunnel Wizard > Iran synthetic WireGuard test from bundle${NC}"
  line
  echo
  read -r -p "Paste VIPTRUE_TUNNEL_BUNDLE: " bundle
  hy2_auto_validate_tunnel_bundle "$bundle" || { pause; return; }
  if [[ "$(hy2_auto_bundle_value "$bundle" "type")" != "udp-wg-hy2" ]]; then
    fail_line "synthetic WireGuard test" "bundle is not a WireGuard UDP forward"
    pause
    return
  fi
  wg_pub="$(hy2_auto_bundle_value "$bundle" "wg_pub")"
  if ! valid_wg_public_key "$wg_pub"; then
    fail_line "foreign WireGuard public key" "bundle missing valid wg_pub"
    pause
    return
  fi
  iran_port="$(prompt_default "Iran local Hysteria UDP listen port" "51822")"
  if ! valid_port "$iran_port" || [[ "$iran_port" == "443" ]]; then
    fail_line "Iran local Hysteria UDP listen port" "use a valid non-443 UDP port"
    pause
    return
  fi
  echo
  echo "Use these values in the existing synthetic test prompts:"
  echo "  Iran local Hysteria UDP listen port: $iran_port"
  echo "  Foreign WireGuard public key: $wg_pub"
  echo "The synthetic test now prints VIPTRUE_TEST_PEER_BUNDLE for the foreign server."
  echo
  read -r -p "Open the guided Synthetic WireGuard test now? [Y/n]: " open_now
  case "${open_now:-Y}" in
    y|Y|yes|YES) hy2_wg_synthetic_run_iran_client ;;
    *) info_line "synthetic test" "not started" ;;
  esac
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

hy2_wg_install_apt_packages() {
  local packages=("$@")

  if ! have_cmd apt-get; then
    fail_line "package installer" "apt-get not found; install ${packages[*]} manually"
    return 1
  fi

  ensure_root || return 1
  apt-get update && apt-get install -y "${packages[@]}"
}

hy2_wg_synthetic_require_wg() {
  local install

  if have_cmd wg; then
    return 0
  fi

  read -r -p "wireguard-tools is required. Install it now? [y/N] " install
  case "$install" in
    y|Y|yes|YES)
      hy2_wg_install_apt_packages wireguard-tools iproute2 || return 1
      ;;
    *)
      fail_line "wireguard-tools" "required for Synthetic WireGuard Handshake Test"
      return 1
      ;;
  esac

  if have_cmd wg; then
    pass_line "wg command" "$(command -v wg)"
    return 0
  fi

  fail_line "wg command" "wireguard-tools install finished but wg is still unavailable"
  return 1
}

hy2_wg_synthetic_require_ip() {
  local install

  if have_cmd ip; then
    return 0
  fi

  read -r -p "iproute2 is required. Install it now? [y/N] " install
  case "$install" in
    y|Y|yes|YES)
      hy2_wg_install_apt_packages iproute2 || return 1
      ;;
    *)
      fail_line "iproute2" "required for temporary WireGuard interface management"
      return 1
      ;;
  esac

  if have_cmd ip; then
    pass_line "ip command" "$(command -v ip)"
    return 0
  fi

  fail_line "ip command" "iproute2 install finished but ip is still unavailable"
  return 1
}

hy2_wg_ipv4_octets_valid() {
  local ip="$1"
  local o1 o2 o3 o4
  local octet value

  IFS=. read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    value=$((10#$octet))
    ((value >= 0 && value <= 255)) || return 1
  done
}

hy2_wg_ipv4_is_public() {
  local ip="$1"
  local o1 o2 o3 o4
  local n1 n2 n3 n4

  hy2_wg_ipv4_octets_valid "$ip" || return 1
  IFS=. read -r o1 o2 o3 o4 <<< "$ip"
  n1=$((10#$o1))
  n2=$((10#$o2))
  n3=$((10#$o3))
  n4=$((10#$o4))

  ((n1 == 0)) && return 1
  ((n1 == 10)) && return 1
  ((n1 == 100 && n2 >= 64 && n2 <= 127)) && return 1
  ((n1 == 127)) && return 1
  ((n1 == 169 && n2 == 254)) && return 1
  ((n1 == 172 && n2 >= 16 && n2 <= 31)) && return 1
  ((n1 == 192 && n2 == 168)) && return 1
  ((n1 == 192 && n2 == 0 && n3 == 0)) && return 1
  ((n1 == 192 && n2 == 0 && n3 == 2)) && return 1
  ((n1 == 192 && n2 == 88 && n3 == 99)) && return 1
  ((n1 == 198 && (n2 == 18 || n2 == 19))) && return 1
  ((n1 == 198 && n2 == 51 && n3 == 100)) && return 1
  ((n1 == 203 && n2 == 0 && n3 == 113)) && return 1
  ((n1 == 255 && n2 == 255 && n3 == 255 && n4 == 255)) && return 1
  ((n1 >= 224)) && return 1

  return 0
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

  hy2_wg_synthetic_require_wg || { pause; return; }
  ensure_root || { pause; return; }

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
  warn_line "Test target IP" "normally keep the default 10.255.255.1 for the synthetic WG test"
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

  if ! valid_ipv4 "$target_ip" || ! hy2_wg_ipv4_octets_valid "$target_ip"; then
    fail_line "Test target IP" "use an IPv4 address like 10.255.255.1"
    pause
    return
  fi

  if hy2_wg_ipv4_is_public "$target_ip"; then
    warn_line "Test target IP" "This is usually not needed for synthetic WG test. Use default 10.255.255.1 unless you know why."
  fi

  if ! valid_iface "$ifname"; then
    fail_line "Temporary interface name" "use 1-15 characters: letters, numbers, dot, underscore, colon, dash"
    pause
    return
  fi

  hy2_wg_validate_timeout "timeout" "$timeout" 300 || { pause; return; }
  hy2_wg_synthetic_require_wg || { pause; return; }
  hy2_wg_synthetic_require_ip || { pause; return; }
  ensure_root || { pause; return; }

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
  echo
  echo "VIPTRUE_TEST_PEER_BUNDLE=v1;type=wg-test-peer;peer_pub=$temp_public_key;allowed_ip=$client_addr"
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
  hy2_wg_synthetic_require_wg || { pause; return; }

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

  hy2_wg_synthetic_require_wg || { pause; return; }
  ensure_root || { pause; return; }

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

  hy2_wg_synthetic_require_ip || { pause; return; }
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
  case "$1" in
    iran/client|auto-iran/client) return 0 ;;
    *) return 1 ;;
  esac
}

hy2_wg_is_raw_legacy_profile() {
  [[ "$1" == "legacy-proven-foreign" ]]
}

hy2_wg_is_foreign_profile() {
  case "$1" in
    foreign|legacy-managed|legacy-proven-foreign|auto-foreign/server|clean-foreign/server) return 0 ;;
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
  if [[ "$profile_dir" == "$HY2_WG_AUTO_FOREIGN_DIR"/* ]]; then
    printf '%s/profile.meta\n' "$profile_dir"
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

hy2_wg_profile_config_known() {
  local config="$1"
  local known

  for known in "${HY2_PROFILE_CONFIGS[@]}"; do
    [[ "$known" == "$config" ]] && return 0
  done

  return 1
}

hy2_wg_extract_service_config_path() {
  local service_file="$1"

  sed -nE 's/^ExecStart=.*--config[=[:space:]]+([^[:space:]]+).*/\1/p' "$service_file" 2>/dev/null | head -n 1
}

hy2_wg_each_managed_config() {
  [[ -f "$HY2_WG_DIR/foreign-server.yaml" ]] && printf '%s\n' "$HY2_WG_DIR/foreign-server.yaml"

  if [[ -d "$HY2_WG_CLIENT_DIR" ]]; then
    find "$HY2_WG_CLIENT_DIR" -maxdepth 1 -type f -name '*.yaml' -print 2>/dev/null
  fi

  if [[ -d "$HY2_WG_LEGACY_DIR" ]]; then
    find "$HY2_WG_LEGACY_DIR" -mindepth 2 -maxdepth 2 -type f -name 'config.yaml' -print 2>/dev/null
  fi

  if [[ -d "$HY2_WG_AUTO_FOREIGN_DIR" ]]; then
    find "$HY2_WG_AUTO_FOREIGN_DIR" -mindepth 2 -maxdepth 2 -type f -name 'config.yaml' -print 2>/dev/null
  fi

  if [[ -d "$HY2_WG_AUTO_IRAN_DIR" ]]; then
    find "$HY2_WG_AUTO_IRAN_DIR" -maxdepth 1 -type f -name '*.yaml' -print 2>/dev/null
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
HY2_PROFILE_PROTOCOLS=()
HY2_PROFILE_FOREIGN_HOSTS=()
HY2_PROFILE_DESTINATIONS=()
HY2_PROFILE_ENDPOINTS=()

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
  HY2_PROFILE_PROTOCOLS+=("${7:-unknown}")
  HY2_PROFILE_FOREIGN_HOSTS+=("${8:-unknown}")
  HY2_PROFILE_DESTINATIONS+=("${9:-$6}")
  HY2_PROFILE_ENDPOINTS+=("${10:-unknown}")
}

hy2_wg_collect_profiles() {
  local config profile service listen target server_host server_port remote_target
  local meta_wg_iface meta_wg_port legacy_services legacy_primary masquerade_url endpoint
  local meta_path service_file service_file_name service_config role
  local protocol foreign_host destination_host destination_port destination endpoint_suggestion

  HY2_PROFILE_NAMES=()
  HY2_PROFILE_MODES=()
  HY2_PROFILE_CONFIGS=()
  HY2_PROFILE_SERVICES=()
  HY2_PROFILE_LISTENS=()
  HY2_PROFILE_TARGETS=()
  HY2_PROFILE_PROTOCOLS=()
  HY2_PROFILE_FOREIGN_HOSTS=()
  HY2_PROFILE_DESTINATIONS=()
  HY2_PROFILE_ENDPOINTS=()

  config="$HY2_WG_DIR/foreign-server.yaml"
  if [[ -f "$config" ]]; then
    service="$(hy2_wg_service_name "foreign")"
    listen="$(hy2_wg_extract_listen_port "$config")"
    meta_wg_iface="$(sed -nE 's/^wg_iface=(.*)$/\1/p' "$(hy2_wg_foreign_meta_path_for_config "$config")" 2>/dev/null | head -n 1)"
    meta_wg_port="$(sed -nE 's/^wg_port=(.*)$/\1/p' "$(hy2_wg_foreign_meta_path_for_config "$config")" 2>/dev/null | head -n 1)"
    target="WireGuard ${meta_wg_iface:-wg0}:${meta_wg_port:-51820}"
    hy2_wg_add_profile "foreign" "foreign" "$config" "$service" "${listen:-unknown}" "$target" "udp" "local" "${meta_wg_iface:-wg0}:${meta_wg_port:-51820}" "foreign:${listen:-unknown}"
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
      hy2_wg_add_profile "$profile" "legacy-managed" "$config" "$service" "${listen:-unknown}" "$target" "udp" "legacy-local" "${meta_wg_iface:-wg0}:${meta_wg_port:-51820}" "foreign:${listen:-unknown}"
    done < <(find "$HY2_WG_LEGACY_DIR" -mindepth 2 -maxdepth 2 -type f -name 'config.yaml' -print0 2>/dev/null | sort -z)
  fi

  if [[ -d "$HY2_WG_AUTO_FOREIGN_DIR" ]]; then
    while IFS= read -r -d '' config; do
      profile="$(basename "$(dirname "$config")")"
      meta_path="$(hy2_auto_meta_path "foreign" "$profile")"
      service="$(sed -nE 's/^service_name=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      service="${service:-$(hy2_auto_service_name "foreign" "$profile")}"
      listen="$(hy2_wg_extract_listen_port "$config")"
      meta_wg_iface="$(sed -nE 's/^wg_iface=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      meta_wg_port="$(sed -nE 's/^wg_port=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      protocol="$(sed -nE 's/^protocol=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      protocol="${protocol:-udp}"
      foreign_host="$(sed -nE 's/^foreign_host=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      foreign_host="${foreign_host:-local}"
      destination_host="$(sed -nE 's/^destination_host=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      destination_host="${destination_host:-$(sed -nE 's/^target_host=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)}"
      destination_port="$(sed -nE 's/^destination_port=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      destination_port="${destination_port:-$(sed -nE 's/^target_port=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)}"
      destination="${destination_host:-${meta_wg_iface:-wg0}}:${destination_port:-${meta_wg_port:-51820}}"
      endpoint_suggestion="$(sed -nE 's/^endpoint=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      endpoint_suggestion="${endpoint_suggestion:-$foreign_host:${listen:-unknown}}"
      target="$destination; auto foreign"
      hy2_wg_add_profile "$profile" "auto-foreign/server" "$config" "$service" "${listen:-unknown}" "$target" "$protocol" "$foreign_host" "$destination" "$endpoint_suggestion"
    done < <(find "$HY2_WG_AUTO_FOREIGN_DIR" -mindepth 2 -maxdepth 2 -type f -name 'config.yaml' -print0 2>/dev/null | sort -z)
  fi

  if [[ -d "$HY2_WG_AUTO_IRAN_DIR" ]]; then
    while IFS= read -r -d '' config; do
      profile="$(basename "$config" .yaml)"
      meta_path="$(hy2_auto_meta_path "iran" "$profile")"
      service="$(sed -nE 's/^service_name=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      service="${service:-$(hy2_auto_service_name "iran" "$profile")}"
      listen="$(hy2_wg_extract_listen_port "$config")"
      remote_target="$(hy2_wg_extract_remote_target "$config")"
      server_host="$(hy2_wg_field_value "$config" "server")"
      endpoint="$(sed -nE 's/^endpoint=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      protocol="$(sed -nE 's/^protocol=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      protocol="${protocol:-udp}"
      foreign_host="$(sed -nE 's/^foreign_host=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      foreign_host="${foreign_host:-$server_host}"
      destination_host="$(sed -nE 's/^destination_host=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      destination_port="$(sed -nE 's/^destination_port=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
      destination="${destination_host:-${remote_target%:*}}:${destination_port:-${remote_target##*:}}"
      endpoint_suggestion="${endpoint:-unknown}"
      if [[ "$endpoint_suggestion" != *:* && "${listen:-unknown}" != "unknown" ]]; then
        endpoint_suggestion="$endpoint_suggestion:$listen"
      fi
      target="${remote_target:-$destination} via $server_host; endpoint suggestion: $endpoint_suggestion"
      hy2_wg_add_profile "$profile" "auto-iran/client" "$config" "$service" "${listen:-unknown}" "$target" "$protocol" "$foreign_host" "$destination" "$endpoint_suggestion"
    done < <(find "$HY2_WG_AUTO_IRAN_DIR" -maxdepth 1 -type f -name '*.yaml' -print0 2>/dev/null | sort -z)
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
      hy2_wg_add_profile "$profile" "iran/client" "$config" "$service" "${listen:-unknown}" "$target" "udp" "$server_host" "${remote_target:-127.0.0.1:51820}" "unknown:${listen:-unknown}"
    done < <(find "$HY2_WG_CLIENT_DIR" -maxdepth 1 -type f -name '*.yaml' -print0 2>/dev/null | sort -z)
  fi

  if hy2_wg_legacy_config_present; then
    legacy_services="$(hy2_wg_detect_services_for_config "$HY2_LEGACY_CONFIG")"
    legacy_primary="$(printf '%s\n' "$legacy_services" | head -n 1)"
    listen="$(hy2_wg_extract_listen_port "$HY2_LEGACY_CONFIG")"
    masquerade_url="$(hy2_wg_masquerade_url "$HY2_LEGACY_CONFIG")"
    target="legacy /etc/hysteria; masquerade: $masquerade_url"
    hy2_wg_add_profile "legacy-proven-foreign" "legacy-proven-foreign" "$HY2_LEGACY_CONFIG" "${legacy_primary:-none}" "${listen:-unknown}" "$target" "udp" "legacy-local" "unknown" "foreign:${listen:-unknown}"
  fi

  for dir in $HY2_SYSTEMD_SEARCH_DIRS; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' service_file; do
      service_file_name="$(basename "$service_file")"
      case "$service_file_name" in
        viptrue-clean-hy2-wg-*.service|viptrue-auto-hy2-*.service|viptrue-hy2-wg-*.service) ;;
        *) continue ;;
      esac
      service_config="$(hy2_wg_extract_service_config_path "$service_file")"
      [[ -n "$service_config" && -f "$service_config" ]] || continue
      hy2_wg_profile_config_known "$service_config" && continue
      profile="${service_file_name%.service}"
      listen="$(hy2_wg_extract_listen_port "$service_config")"
      remote_target="$(hy2_wg_extract_remote_target "$service_config")"
      if [[ "$service_file_name" == viptrue-auto-hy2-iran-*.service ]]; then
        profile="${profile#viptrue-auto-hy2-iran-}"
        role="auto-iran/client"
        server_host="$(hy2_wg_field_value "$service_config" "server")"
        target="${remote_target:-127.0.0.1:51820} via $server_host"
      elif [[ "$service_file_name" == viptrue-auto-hy2-foreign-*.service ]]; then
        profile="${profile#viptrue-auto-hy2-foreign-}"
        role="auto-foreign/server"
        meta_path="$(hy2_auto_meta_path "foreign" "$profile")"
        meta_wg_iface="$(sed -nE 's/^wg_iface=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
        meta_wg_port="$(sed -nE 's/^wg_port=(.*)$/\1/p' "$meta_path" 2>/dev/null | head -n 1)"
        target="WireGuard ${meta_wg_iface:-wg0}:${meta_wg_port:-51820}; auto foreign"
      elif grep -q '^server:' "$service_config" 2>/dev/null; then
        role="iran/client"
        server_host="$(hy2_wg_field_value "$service_config" "server")"
        target="${remote_target:-127.0.0.1:51820} via $server_host"
      else
        role="clean-foreign/server"
        target="foreign/server config: $service_config"
      fi
      hy2_wg_add_profile "$profile" "$role" "$service_config" "$service_file_name" "${listen:-unknown}" "$target" "udp" "${server_host:-local}" "${remote_target:-unknown}" "unknown:${listen:-unknown}"
    done < <(find "$dir" -maxdepth 1 -type f \( -name 'viptrue-clean-hy2-wg-*.service' -o -name 'viptrue-auto-hy2-*.service' -o -name 'viptrue-hy2-wg-*.service' \) -print0 2>/dev/null)
  done
}

hy2_wg_print_profile_row() {
  local idx="$1"
  local name="$2"
  local mode="$3"
  local listen="$4"
  local target="$5"
  local service="$6"
  local config="$7"
  local protocol="$8"
  local foreign_host="$9"
  local destination="${10}"
  local endpoint="${11}"
  local status

  status="$(hy2_wg_service_status_text "$service")"
  printf '%2s. %-16s role=%-20s protocol=%-7s entry=%-8s status=%s\n' "$idx" "$name" "$mode" "$protocol" "$listen" "$status"
  printf '    foreign: %-24s destination: %s\n' "$foreign_host" "$destination"
  printf '    service: %-32s config: %s\n' "$service" "$config"
  printf '    endpoint suggestion: %s\n' "$endpoint"
  printf '    target detail: %s\n' "$target"
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
      "${HY2_PROFILE_SERVICES[$i]}" \
      "${HY2_PROFILE_CONFIGS[$i]}" \
      "${HY2_PROFILE_PROTOCOLS[$i]}" \
      "${HY2_PROFILE_FOREIGN_HOSTS[$i]}" \
      "${HY2_PROFILE_DESTINATIONS[$i]}" \
      "${HY2_PROFILE_ENDPOINTS[$i]}"
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

auto_tunnel_wizard_menu() {
  local choice port

  while true; do
    title
    echo -e "${CYAN}Auto Tunnel Wizard${NC}"
    line
    echo
    echo "1. Foreign/Exit server setup"
    echo "2. Iran/Entry server setup"
    echo "3. Iran: generate/run synthetic test from bundle"
    echo "4. Foreign: add temporary test peer from bundle"
    echo "5. UDP-only fallback probe commands"
    echo "6. Auto scan / recommended settings"
    echo "7. Back"
    echo
    read -r -p "Enter your choice [1-7]: " choice

    case "$choice" in
      1) hy2_auto_foreign_setup ;;
      2) hy2_auto_iran_setup ;;
      3) hy2_auto_run_synthetic_from_bundle ;;
      4) hy2_auto_add_test_peer_from_bundle ;;
      5)
        port="$(prompt_default "Foreign local WireGuard UDP port" "51820")"
        valid_port "$port" || { fail_line "WireGuard UDP port" "ports must be 1-65535"; pause; continue; }
        hy2_prompt_non443_port "Iran local Hysteria UDP listen port" "51822" || { pause; continue; }
        hy2_auto_print_udp_probe_commands "$HY2_PROMPTED_PORT" "$port"
        pause
        ;;
      6)
        port="$(hy2_auto_candidate_port)"
        hy2_auto_print_recommendation "$port"
        pause
        ;;
      7) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

manual_tunnel_lab_menu() {
  while true; do
    title
    echo -e "${CYAN}Manual Tunnel Lab${NC}"
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
    echo "9. Legacy Proven Foreign Mode"
    echo "10. Iran Server Mode"
    echo "11. Manage Existing Hysteria2 WireGuard Forwards"
    echo "12. Synthetic WireGuard Handshake Test"
    echo "13. UDP-only fallback probe"
    echo "14. Back"
    echo
    read -r -p "Enter your choice [1-14]: " choice

    case "$choice" in
      1) preflight_checks ;;
      2) quality_tests ;;
      3) port_checks ;;
      4) gre_helper ;;
      5) wireguard_helper ;;
      6) hysteria2_helper ;;
      7) hy2_wg_forward_menu ;;
      8) reverse_tls_sni_notes ;;
      9) hy2_wg_setup_legacy_proven_foreign_server ;;
      10) hy2_wg_setup_iran_server ;;
      11) hy2_wg_manage_existing_menu ;;
      12) hy2_wg_synthetic_menu ;;
      13) hy2_wg_synthetic_udp_probe_menu ;;
      14) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

manage_existing_tunnels_menu() {
  hy2_wg_manage_existing_menu
}

test_existing_tunnels_menu() {
  while true; do
    title
    echo -e "${CYAN}Test Existing Tunnels${NC}"
    line
    echo
    echo "1. Test selected managed profile"
    echo "2. Wait for WireGuard Handshake"
    echo "3. Synthetic WireGuard Handshake Test"
    echo "4. UDP-only fallback probe"
    echo "5. Show Engine Registry / scoring notes"
    echo "6. Back"
    echo
    read -r -p "Enter your choice [1-6]: " choice

    case "$choice" in
      1) hy2_wg_manage_test_profile ;;
      2) hy2_wg_wait_for_wireguard_handshake ;;
      3) hy2_wg_synthetic_menu ;;
      4) hy2_wg_synthetic_udp_probe_menu ;;
      5) hy2_engine_explain_families ;;
      6) break ;;
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
  echo "1. Auto Tunnel Expert"
  echo "2. Manual Tunnel Lab"
  echo "3. Manage Existing Tunnels"
  echo "4. Test Existing Tunnels"
  echo "5. Diagnostics Summary"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-5]: " choice

  case "$choice" in
    1) auto_tunnel_expert_menu ;;
    2) manual_tunnel_lab_menu ;;
    3) manage_existing_tunnels_menu ;;
    4) test_existing_tunnels_menu ;;
    5) diagnostics_summary_screen ;;
    6|0) break ;;
    99) exit_toolbox ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
