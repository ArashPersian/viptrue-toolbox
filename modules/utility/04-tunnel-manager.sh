#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/ui.sh
source "$BASE_DIR/lib/ui.sh"

LAST_CHECKED="No diagnostics have been run yet."
LAST_ISSUE="Run a Tunnel Manager check first."
LAST_ACTION="Start with Preflight Checks."
LAST_SERVER_ACTION="Unknown."

HY2_WG_DIR="/etc/viptrue-hy2-wg-forward"
HY2_WG_CLIENT_DIR="$HY2_WG_DIR/clients"
HY2_WG_CERT_DIR="$HY2_WG_DIR/certs"
HY2_WG_SERVICE_PREFIX="viptrue-hy2-wg"
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
  mkdir -p "$HY2_WG_CLIENT_DIR" "$HY2_WG_CERT_DIR"
  chmod 700 "$HY2_WG_DIR" "$HY2_WG_CLIENT_DIR" "$HY2_WG_CERT_DIR" 2>/dev/null || true
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
  local config_path="$HY2_WG_DIR/foreign-server.yaml"
  local auth_q obfs_q cert_q key_q

  auth_q="$(yaml_quote "$auth_pass")"
  obfs_q="$(yaml_quote "$obfs_pass")"
  cert_q="$(yaml_quote "$cert_path")"
  key_q="$(yaml_quote "$key_path")"

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
    echo
    echo "disableUDP: false"
    echo "udpIdleTimeout: 60s"
  } > "$config_path"
  chmod 600 "$config_path"

  HY2_WRITTEN_CONFIG="$config_path"
}

hy2_wg_write_service() {
  local service_name="$1"
  local mode="$2"
  local config_path="$3"
  local description="$4"
  local hy2_bin service_path

  hy2_bin="$(hy2_bin_path)"
  service_path="/etc/systemd/system/$service_name"
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
    require_cmd openssl openssl || { pause; return; }
    backup_existing_file "$cert_path"
    backup_existing_file "$key_path"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$key_path" \
      -out "$cert_path" \
      -days 3650 \
      -subj "/CN=$cert_cn" >/dev/null 2>&1
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
  fi

  service_name="$(hy2_wg_service_name "foreign")"
  hy2_wg_write_foreign_config "$listen_port" "$auth_pass" "$obfs_pass" "$tls_mode" "$cert_path" "$key_path"
  config_path="$HY2_WRITTEN_CONFIG"
  hy2_wg_write_service "$service_name" "server" "$config_path" "VIPTrue Hysteria2 OBFS WireGuard foreign server"

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

    read -r -p "Foreign IP/domain: " foreign_host
    if [[ -z "${foreign_host// /}" ]]; then
      fail_line "foreign IP/domain" "value is required"
      pause
      return
    fi

    hy2_prompt_non443_port "Foreign Hysteria UDP port" "8080" || {
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

    remote_wg_host="$(prompt_default "Remote WireGuard host from foreign server view" "127.0.0.1")"
    remote_wg_port="$(prompt_default "Remote WireGuard UDP port" "51820")"
    if ! valid_port "$remote_wg_port"; then
      fail_line "Remote WireGuard UDP port" "ports must be 1-65535"
      pause
      return
    fi

    auth_pass="$(prompt_secret_required "Auth password for $profile")"
    obfs_pass="$(prompt_secret_required "OBFS salamander password for $profile")"
    read -r -p "TLS SNI if needed, empty=none: " tls_sni
    insecure_tls="$(prompt_yes_no_value "Use insecure TLS for this private tunnel?" "Y")"

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

hy2_wg_forward_menu() {
  while true; do
    title
    echo -e "${CYAN}Hysteria2 OBFS -> WireGuard Forward${NC}"
    line
    echo
    echo "1. Foreign server mode"
    echo "2. Iran server mode"
    echo "3. Wait for WireGuard Handshake"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-3]: " choice

    case "$choice" in
      1) hy2_wg_setup_foreign_server ;;
      2) hy2_wg_setup_iran_server ;;
      3) hy2_wg_wait_for_wireguard_handshake ;;
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
