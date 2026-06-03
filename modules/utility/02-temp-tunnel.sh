#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

TUNNEL_DIR="/opt/viptrue-temp-tunnel"
BIN_DIR="$TUNNEL_DIR/bin"
CONFIG_DIR="$TUNNEL_DIR/config"
SUBS_DIR="$TUNNEL_DIR/subscriptions"
LOG_DIR="$TUNNEL_DIR/logs"
STATE_DIR="$TUNNEL_DIR/state"
OUTBOUNDS_DIR="$TUNNEL_DIR/outbounds"

SING_BOX_BIN="$BIN_DIR/sing-box"
SERVICE_NAME="viptrue-temp-tunnel"

RAW_LINKS_FILE="$OUTBOUNDS_DIR/single-links.txt"
ACTIVE_LINK_FILE="$STATE_DIR/active-link.txt"
PROXY_CONFIG_FILE="$CONFIG_DIR/proxy-mode.json"
PROXY_ENV_FILE="$STATE_DIR/proxy-env.sh"
PROXY_SHELL_BIN="/usr/local/bin/viptrue-proxy-shell"
PROXY_RUN_BIN="/usr/local/bin/viptrue-proxy-run"

exit_toolbox() {
  clear
  echo "Bye."
  exit 0
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return 1
  fi
}

ensure_dirs() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$SUBS_DIR" "$LOG_DIR" "$STATE_DIR" "$OUTBOUNDS_DIR"
}

run_without_proxy_env() {
  env \
    -u http_proxy \
    -u https_proxy \
    -u all_proxy \
    -u HTTP_PROXY \
    -u HTTPS_PROXY \
    -u ALL_PROXY \
    "$@"
}

detect_arch() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    i386|i686) echo "386" ;;
    *) echo "" ;;
  esac
}

get_latest_singbox_version() {
  curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"v?([^"]+)".*/\1/'
}

mask_link() {
  local link="$1"

  echo "$link" | sed -E \
    -e 's#(://)[^:@/]+:[^@/]+@#\1***:***@#g' \
    -e 's#(password=)[^&]+#\1***#Ig' \
    -e 's#(uuid=)[^&]+#\1***#Ig' \
    -e 's#(id=)[^&]+#\1***#Ig'
}

detect_link_type() {
  local link="$1"

  case "$link" in
    ss://*) echo "shadowsocks" ;;
    vless://*) echo "vless" ;;
    vmess://*) echo "vmess" ;;
    trojan://*) echo "trojan" ;;
    hysteria2://*|hy2://*) echo "hysteria2" ;;
    tuic://*) echo "tuic" ;;
    wireguard://*|wg://*) echo "wireguard" ;;
    socks://*|socks5://*) echo "socks" ;;
    http://*|https://*) echo "http_or_subscription" ;;
    *) echo "unknown" ;;
  esac
}

get_active_link_value() {
  if [[ -f "$ACTIVE_LINK_FILE" ]]; then
    grep '^link=' "$ACTIVE_LINK_FILE" | tail -n 1 | cut -d= -f2-
  fi
}

get_active_link_type() {
  if [[ -f "$ACTIVE_LINK_FILE" ]]; then
    grep '^type=' "$ACTIVE_LINK_FILE" | tail -n 1 | cut -d= -f2-
  fi
}

cleanup_tun_leftovers() {
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  ip link delete viptrue-tun0 2>/dev/null || true

  ip route flush table 2022 2>/dev/null || true
  ip route flush table 2023 2>/dev/null || true

  ip rule del lookup 2022 2>/dev/null || true
  ip rule del lookup 2023 2>/dev/null || true
  ip rule del fwmark 0x2023 lookup 2022 2>/dev/null || true
  ip rule del fwmark 0x2024 goto 9002 2>/dev/null || true

  if command -v nft >/dev/null 2>&1; then
    nft list tables 2>/dev/null | awk '/sing-box|singbox|viptrue/ {print $2, $3}' | while read -r family table; do
      [[ -n "${family:-}" && -n "${table:-}" ]] || continue
      nft delete table "$family" "$table" 2>/dev/null || true
    done
  fi
}

show_plan() {
  title
  echo -e "${CYAN}Temporary Proxy for Installations${NC}"
  line
  echo

  echo -e "${YELLOW}Purpose:${NC}"
  echo "Use a temporary proxy/VPN config for installation commands on this server."
  echo
  echo "Recommended safe mode:"
  echo "- Proxy Mode"
  echo "- Open proxied shell"
  echo
  echo "Example:"
  echo "1. Start Proxy Mode"
  echo "2. Open proxied shell"
  echo "3. Run apt/curl/wget/git/docker commands"
  echo "4. exit"
  echo "5. Stop Proxy Mode"
  echo

  echo -e "${YELLOW}Current decision:${NC}"
  echo "TUN Mode is disabled/experimental for now because it can change server routes and disconnect SSH."
  echo

  pause
}

install_singbox_isolated() {
  title
  echo -e "${CYAN}Install / Update sing-box${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  local arch version asset url tmpdir extracted_dir version_choice

  arch="$(detect_arch)"
  if [[ -z "$arch" ]]; then
    echo -e "${RED}Unsupported architecture:${NC} $(uname -m)"
    pause
    return
  fi

  echo -e "${YELLOW}Detected architecture:${NC} $arch"
  echo
  echo "1. Latest stable from GitHub releases"
  echo "2. Custom version"
  echo "0. Back"
  echo "99. Exit toolbox"
  echo
  read -r -p "Enter your choice [0-2,99]: " version_choice

  case "$version_choice" in
    1)
      echo -e "${YELLOW}Fetching latest sing-box version...${NC}"
      version="$(get_latest_singbox_version || true)"
      ;;
    2)
      read -r -p "Enter version, example 1.13.12: " version
      version="${version#v}"
      ;;
    0) return ;;
    99) exit_toolbox ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      pause
      return
      ;;
  esac

  if [[ -z "${version:-}" ]]; then
    echo -e "${RED}Could not detect sing-box version.${NC}"
    pause
    return
  fi

  asset="sing-box-${version}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"

  echo
  echo -e "${YELLOW}Install target:${NC}"
  echo "$SING_BOX_BIN"
  echo
  echo -e "${YELLOW}Download URL:${NC}"
  echo "$url"
  echo
  echo "This installs sing-box only inside:"
  echo "$TUNNEL_DIR"
  echo
  read -r -p "Continue install/update? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      apt-get update
      apt-get install -y curl tar gzip ca-certificates

      tmpdir="$(mktemp -d)"
      curl -fL "$url" -o "$tmpdir/sing-box.tar.gz"
      tar -xzf "$tmpdir/sing-box.tar.gz" -C "$tmpdir"

      extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -name "sing-box-${version}-linux-${arch}" | head -n 1)"

      if [[ -z "$extracted_dir" || ! -f "$extracted_dir/sing-box" ]]; then
        echo -e "${RED}sing-box binary not found after extraction.${NC}"
        rm -rf "$tmpdir"
        pause
        return
      fi

      cp "$extracted_dir/sing-box" "$SING_BOX_BIN"
      chmod +x "$SING_BOX_BIN"
      echo "$version" > "$STATE_DIR/sing-box.version"

      rm -rf "$tmpdir"

      echo
      echo -e "${GREEN}sing-box installed successfully.${NC}"
      "$SING_BOX_BIN" version || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

add_single_config_link() {
  title
  echo -e "${CYAN}Add Single Config Link${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  echo "Paste one config link."
  echo
  echo "Currently fully supported for proxy test/start:"
  echo "- ss:// Shadowsocks"
  echo
  echo "Stored/planned:"
  echo "- vless:// vmess:// trojan:// hysteria2:// tuic:// wireguard://"
  echo
  read -r -p "Config link: " link

  if [[ -z "${link// /}" ]]; then
    echo -e "${RED}Empty link.${NC}"
    pause
    return
  fi

  local link_type
  link_type="$(detect_link_type "$link")"

  echo
  echo -e "${YELLOW}Detected type:${NC} $link_type"
  echo -e "${YELLOW}Masked link:${NC}"
  mask_link "$link"
  echo

  if [[ "$link_type" == "unknown" ]]; then
    echo -e "${RED}Unknown or unsupported link type.${NC}"
    pause
    return
  fi

  local id
  id="$(date +%Y%m%d-%H%M%S)"

  {
    echo "[$id]"
    echo "type=$link_type"
    echo "link=$link"
    echo
  } >> "$RAW_LINKS_FILE"

  {
    echo "id=$id"
    echo "type=$link_type"
    echo "link=$link"
  } > "$ACTIVE_LINK_FILE"

  chmod 600 "$RAW_LINKS_FILE" "$ACTIVE_LINK_FILE" 2>/dev/null || true

  echo
  echo -e "${GREEN}Single config link saved and set as active.${NC}"
  echo "ID: $id"
  echo

  pause
}

show_saved_links() {
  title
  echo -e "${CYAN}Saved Config Links${NC}"
  line
  echo

  ensure_dirs

  if [[ ! -f "$RAW_LINKS_FILE" ]]; then
    echo -e "${YELLOW}No config links saved yet.${NC}"
    pause
    return
  fi

  awk '
    /^\[/ {print ""; print $0; next}
    /^type=/ {print $0; next}
    /^link=/ {
      val=$0
      sub(/^link=/, "", val)
      gsub(/:\/\/[^:@\/]+:[^@\/]+@/, "://***:***@", val)
      gsub(/password=[^&]+/, "password=***", val)
      gsub(/uuid=[^&]+/, "uuid=***", val)
      gsub(/id=[^&]+/, "id=***", val)
      print "link=" val
      next
    }
  ' "$RAW_LINKS_FILE"
  echo

  echo -e "${YELLOW}Active link:${NC}"
  if [[ -f "$ACTIVE_LINK_FILE" ]]; then
    grep -E '^(id|type)=' "$ACTIVE_LINK_FILE" || true
    grep '^link=' "$ACTIVE_LINK_FILE" | sed -E \
      -e 's#(://)[^:@/]+:[^@/]+@#\1***:***@#g' \
      -e 's#(password=)[^&]+#\1***#Ig' \
      -e 's#(uuid=)[^&]+#\1***#Ig' \
      -e 's#(id=)[^&]+#\1***#Ig' || true
  else
    echo "None"
  fi
  echo

  pause
}

generate_proxy_config_from_active_link() {
  ensure_dirs

  if [[ ! -f "$ACTIVE_LINK_FILE" ]]; then
    echo -e "${RED}No active config link found.${NC}"
    return 1
  fi

  local link_type link
  link_type="$(get_active_link_type || true)"
  link="$(get_active_link_value || true)"

  if [[ "$link_type" != "shadowsocks" ]]; then
    echo -e "${RED}Proxy Mode currently supports ss:// links only.${NC}"
    echo "Active type: ${link_type:-UNKNOWN}"
    return 1
  fi

  python3 - "$link" "$PROXY_CONFIG_FILE" <<'PY2'
import base64
import json
import sys
from urllib.parse import unquote

link = sys.argv[1].strip()
out_path = sys.argv[2]

def b64decode_padded(data: str) -> str:
    data = data.strip()
    data = data.replace("-", "+").replace("_", "/")
    data += "=" * (-len(data) % 4)
    return base64.b64decode(data).decode("utf-8", errors="replace")

def parse_ss(uri: str):
    if not uri.startswith("ss://"):
        raise ValueError("Not an ss:// link")

    raw = uri[5:]

    if "#" in raw:
        raw, _frag = raw.split("#", 1)

    if "?" in raw:
        raw, _query = raw.split("?", 1)

    raw = unquote(raw)

    if "@" in raw:
        userinfo, hostport = raw.rsplit("@", 1)
        try:
            decoded_userinfo = b64decode_padded(userinfo)
        except Exception:
            decoded_userinfo = userinfo

        method, password = decoded_userinfo.split(":", 1)

        if hostport.startswith("["):
            end = hostport.find("]")
            server = hostport[1:end]
            port = int(hostport[end+2:])
        else:
            server, port_s = hostport.rsplit(":", 1)
            port = int(port_s)
    else:
        decoded = b64decode_padded(raw)
        userinfo, hostport = decoded.rsplit("@", 1)
        method, password = userinfo.split(":", 1)

        if hostport.startswith("["):
            end = hostport.find("]")
            server = hostport[1:end]
            port = int(hostport[end+2:])
        else:
            server, port_s = hostport.rsplit(":", 1)
            port = int(port_s)

    return {
        "method": method,
        "password": password,
        "server": server,
        "server_port": int(port),
    }

ss = parse_ss(link)

config = {
    "log": {
        "level": "info",
        "timestamp": True
    },
    "inbounds": [
        {
            "type": "mixed",
            "tag": "local-install-proxy",
            "listen": "127.0.0.1",
            "listen_port": 19080
        }
    ],
    "outbounds": [
        {
            "type": "shadowsocks",
            "tag": "install-out",
            "server": ss["server"],
            "server_port": ss["server_port"],
            "method": ss["method"],
            "password": ss["password"]
        },
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "route": {
        "final": "install-out"
    }
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)

print(f"Proxy config generated for Shadowsocks server: {ss['server']}:{ss['server_port']}")
PY2
}

write_proxy_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF2
[Unit]
Description=VIPTrue Temporary Proxy for Installations
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${TUNNEL_DIR}
ExecStart=${SING_BOX_BIN} run -c ${PROXY_CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
UnsetEnvironment=http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
}

write_proxy_helpers() {
  ensure_dirs

  cat > "$PROXY_ENV_FILE" <<'EOF2'
export http_proxy="http://127.0.0.1:19080"
export https_proxy="http://127.0.0.1:19080"
export all_proxy="socks5h://127.0.0.1:19080"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export ALL_PROXY="$all_proxy"
EOF2

  chmod 600 "$PROXY_ENV_FILE"

  cat > "$PROXY_SHELL_BIN" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail

if ! systemctl is-active --quiet ${SERVICE_NAME}; then
  echo "VIPTrue temporary proxy service is not active."
  echo "Start Proxy Mode from toolbox first."
  exit 1
fi

source "$PROXY_ENV_FILE"

echo
echo "VIPTrue proxied shell is active."
echo "Commands in this shell will use:"
echo "  http_proxy=\$http_proxy"
echo "  https_proxy=\$https_proxy"
echo "  all_proxy=\$all_proxy"
echo
echo "Test:"
echo "  curl https://api.ipify.org"
echo
echo "Type 'exit' to leave this proxied shell."
echo

exec "\${SHELL:-/bin/bash}"
EOF2

  chmod +x "$PROXY_SHELL_BIN"

  cat > "$PROXY_RUN_BIN" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail

if ! systemctl is-active --quiet ${SERVICE_NAME}; then
  echo "VIPTrue temporary proxy service is not active."
  echo "Start Proxy Mode from toolbox first."
  exit 1
fi

source "$PROXY_ENV_FILE"

if [[ "\$#" -eq 0 ]]; then
  echo "Usage:"
  echo "  viptrue-proxy-run <command>"
  echo
  echo "Example:"
  echo "  viptrue-proxy-run curl https://api.ipify.org"
  echo "  viptrue-proxy-run apt update"
  exit 1
fi

exec "\$@"
EOF2

  chmod +x "$PROXY_RUN_BIN"
}

remove_proxy_helpers() {
  rm -f "$PROXY_ENV_FILE" "$PROXY_SHELL_BIN" "$PROXY_RUN_BIN" 2>/dev/null || true
}

run_proxy_ip_test() {
  echo
  echo -e "${YELLOW}Connectivity test:${NC}"
  echo

  local direct_ip proxy_ip

  direct_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  proxy_ip="$(curl -4fsS --max-time 15 -x http://127.0.0.1:19080 https://api.ipify.org 2>/dev/null || true)"

  echo "Direct server IP:"
  echo "${direct_ip:-FAILED}"
  echo

  echo "Proxy IP:"
  echo "${proxy_ip:-FAILED}"
  echo

  if [[ -n "${proxy_ip:-}" ]]; then
    echo -e "${GREEN}Proxy curl test succeeded.${NC}"
  else
    echo -e "${RED}Proxy curl test failed.${NC}"
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
  fi
}

relay_test_active_link() {
  title
  echo -e "${CYAN}Relay Test Active Link${NC}"
  line
  echo

  ensure_root || return

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  if ! generate_proxy_config_from_active_link; then
    pause
    return
  fi

  if [[ ! -x "$SING_BOX_BIN" ]]; then
    echo -e "${RED}sing-box is not installed.${NC}"
    pause
    return
  fi

  echo -e "${YELLOW}Checking config...${NC}"
  if ! "$SING_BOX_BIN" check -c "$PROXY_CONFIG_FILE"; then
    echo -e "${RED}Config check failed.${NC}"
    pause
    return
  fi

  write_proxy_systemd_service
  systemctl start "$SERVICE_NAME"
  sleep 2

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    run_proxy_ip_test
  else
    echo -e "${RED}Relay service failed to start.${NC}"
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
  fi

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  pause
}

start_proxy_mode() {
  title
  echo -e "${CYAN}Start Proxy Mode${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  cleanup_tun_leftovers

  if [[ ! -x "$SING_BOX_BIN" ]]; then
    echo -e "${RED}sing-box is not installed.${NC}"
    echo "Run Install / Update sing-box first."
    pause
    return
  fi

  if ss -ltnp 2>/dev/null | grep -q ':19080'; then
    echo -e "${RED}Port 19080 is already in use.${NC}"
    echo "Stop existing proxy/tunnel first."
    pause
    return
  fi

  echo "Proxy Mode will start a local-only proxy:"
  echo
  echo "127.0.0.1:19080"
  echo
  echo "This is safe and does NOT change system routing."
  echo "PasarGuard will not be modified."
  echo
  read -r -p "Start Proxy Mode now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

      if ! generate_proxy_config_from_active_link; then
        pause
        return
      fi

      echo
      echo -e "${YELLOW}Checking sing-box config...${NC}"
      if ! "$SING_BOX_BIN" check -c "$PROXY_CONFIG_FILE"; then
        echo -e "${RED}Config check failed. Proxy not started.${NC}"
        pause
        return
      fi

      write_proxy_systemd_service
      systemctl start "$SERVICE_NAME"
      sleep 2

      if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo
        echo -e "${GREEN}Proxy Mode started successfully.${NC}"
        write_proxy_helpers
        run_proxy_ip_test
        echo
        echo "Use:"
        echo "  viptrue-proxy-shell"
        echo
        echo "Or:"
        echo "  viptrue-proxy-run curl https://api.ipify.org"
        echo "  viptrue-proxy-run apt update"
      else
        echo -e "${RED}Proxy service did not start.${NC}"
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
      fi
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

stop_proxy_mode() {
  title
  echo -e "${CYAN}Stop Proxy / Cleanup${NC}"
  line
  echo

  ensure_root || return

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  remove_proxy_helpers
  cleanup_tun_leftovers

  echo -e "${GREEN}Temporary proxy/tunnel stopped and cleaned.${NC}"
  echo
  echo "If you manually exported proxy variables, run:"
  echo "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
  echo

  pause
}

open_proxied_shell() {
  title
  echo -e "${CYAN}Open Proxied Shell${NC}"
  line
  echo

  if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "${RED}Proxy Mode is not active.${NC}"
    echo "Start Proxy Mode first."
    pause
    return
  fi

  write_proxy_helpers

  echo "This will open a new shell with proxy variables already exported."
  echo "Type 'exit' to leave the proxied shell."
  echo
  read -r -p "Open proxied shell now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      "$PROXY_SHELL_BIN"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

show_status_logs() {
  title
  echo -e "${CYAN}Temporary Proxy Status / Logs${NC}"
  line
  echo

  echo -e "${YELLOW}Directory:${NC}"
  echo "$TUNNEL_DIR"
  echo

  echo -e "${YELLOW}sing-box:${NC}"
  if [[ -x "$SING_BOX_BIN" ]]; then
    "$SING_BOX_BIN" version || true
  else
    echo "Not installed"
  fi
  echo

  echo -e "${YELLOW}Active link:${NC}"
  if [[ -f "$ACTIVE_LINK_FILE" ]]; then
    grep -E '^(id|type)=' "$ACTIVE_LINK_FILE" || true
    grep '^link=' "$ACTIVE_LINK_FILE" | sed -E \
      -e 's#(://)[^:@/]+:[^@/]+@#\1***:***@#g' \
      -e 's#(password=)[^&]+#\1***#Ig' \
      -e 's#(uuid=)[^&]+#\1***#Ig' \
      -e 's#(id=)[^&]+#\1***#Ig' || true
  else
    echo "None"
  fi
  echo

  echo -e "${YELLOW}Service:${NC}"
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || echo "Service not created yet."
  echo

  echo -e "${YELLOW}Recent logs:${NC}"
  journalctl -u "$SERVICE_NAME" -n 100 --no-pager 2>/dev/null || true
  echo

  pause
}

tun_experimental_menu() {
  while true; do
  viptrue_should_exit_toolbox
    title
    echo -e "${CYAN}TUN Mode - Experimental / Disabled${NC}"
    line
    echo

    echo -e "${RED}TUN Mode is disabled for now.${NC}"
    echo
    echo "Reason:"
    echo "- On this VPS, TUN route changes can disconnect SSH."
    echo "- We will later test another core or safer TUN method."
    echo
    echo "Safe alternative now:"
    echo "- Use Proxy Mode + Open proxied shell."
    echo
    echo "1. Cleanup old TUN leftovers"
    echo "0. Back"
    echo "99. Exit toolbox"
    echo
    read -r -p "Enter your choice [0-1,99]: " choice

    case "$choice" in
      1)
        ensure_root || continue
        cleanup_tun_leftovers
        echo -e "${GREEN}TUN leftovers cleaned.${NC}"
        pause
        ;;
      0)
        break
        ;;
      99)
        exit_toolbox
        ;;    99)
      viptrue_exit_toolbox
      ;;

      *)
        echo -e "${RED}Invalid choice.${NC}"
        sleep 1
        ;;
    esac
  done
}

config_links_menu() {
  while true; do
    title
    echo -e "${CYAN}Config Links${NC}"
    line
    echo
    echo "1. Add single config link"
    echo "2. Show saved links"
    echo "3. Relay test active link"
    echo "0. Back"
    echo "99. Exit toolbox"
    echo
    read -r -p "Enter your choice [0-3,99]: " choice

    case "$choice" in
      1) add_single_config_link ;;
      2) show_saved_links ;;
      3) relay_test_active_link ;;
      0) break ;;
      99) exit_toolbox ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

proxy_mode_menu() {
  while true; do
    title
    echo -e "${CYAN}Proxy Mode${NC}"
    line
    echo
    echo "1. Start Proxy Mode"
    echo "2. Open proxied shell"
    echo "3. Relay/IP test"
    echo "4. Stop Proxy / Cleanup"
    echo "5. Status / Logs"
    echo "0. Back"
    echo "99. Exit toolbox"
    echo
    read -r -p "Enter your choice [0-5,99]: " choice

    case "$choice" in
      1) start_proxy_mode ;;
      2) open_proxied_shell ;;
      3) run_proxy_ip_test; pause ;;
      4) stop_proxy_mode ;;
      5) show_status_logs ;;
      0) break ;;
      99) exit_toolbox ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

while true; do
  title
  echo -e "${CYAN}Temporary Proxy for Installations${NC}"
  echo
  echo "1. Show plan"
  echo "2. Install / Update sing-box"
  echo "3. Config Links"
  echo "4. Proxy Mode"
  echo "5. TUN Mode - Experimental / Disabled"
  echo "6. Status / Logs"
  echo "0. Back"
  echo "99. Exit toolbox"
  echo
  line
  read -r -p "Enter your choice [0-6,99]: " choice

  case "$choice" in
    1) show_plan ;;
    2) install_singbox_isolated ;;
    3) config_links_menu ;;
    4) proxy_mode_menu ;;
    5) tun_experimental_menu ;;
    6) show_status_logs ;;
    0) break ;;
    99) exit_toolbox ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
