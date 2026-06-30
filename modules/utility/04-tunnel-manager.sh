#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/ui.sh
source "$BASE_DIR/lib/ui.sh"

LAST_CHECKED="No diagnostics have been run yet."
LAST_ISSUE="Run a Tunnel Manager check first."
LAST_ACTION="Start with Preflight Checks."
LAST_SERVER_ACTION="Unknown."

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
  echo "7. Reverse TLS / SNI notes"
  echo "8. Diagnostics summary"
  echo "0. Back"
  echo "99. Exit"
  echo
  read -r -p "Enter your choice [0-8,99]: " choice

  case "$choice" in
    1) preflight_checks ;;
    2) quality_tests ;;
    3) port_checks ;;
    4) gre_helper ;;
    5) wireguard_helper ;;
    6) hysteria2_helper ;;
    7) reverse_tls_sni_notes ;;
    8) diagnostics_summary_screen ;;
    0) break ;;
    99) exit_toolbox ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
