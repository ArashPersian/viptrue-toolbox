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
RAW_LINKS_FILE="$OUTBOUNDS_DIR/single-links.txt"
ACTIVE_LINK_FILE="$STATE_DIR/active-link.txt"

SING_BOX_BIN="$BIN_DIR/sing-box"
SERVICE_NAME="viptrue-temp-tunnel"

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

detect_arch() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    armv7l|armv7)
      echo "armv7"
      ;;
    i386|i686)
      echo "386"
      ;;
    *)
      echo ""
      ;;
  esac
}

get_latest_singbox_version() {
  curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"v?([^"]+)".*/\1/'
}

install_singbox_isolated() {
  title
  echo -e "${CYAN}Install / Update sing-box Isolated${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  local arch version asset url tmpdir extracted_dir

  arch="$(detect_arch)"

  if [[ -z "$arch" ]]; then
    echo -e "${RED}Unsupported architecture:${NC} $(uname -m)"
    pause
    return
  fi

  echo -e "${YELLOW}Detected architecture:${NC} $arch"
  echo

  echo "Choose version:"
  echo "1. Latest stable from GitHub releases"
  echo "2. Custom version"
  echo "0. Cancel"
  echo
  read -r -p "Enter your choice [0-2]: " version_choice

  case "$version_choice" in
    1)
      echo -e "${YELLOW}Fetching latest sing-box version...${NC}"
      version="$(get_latest_singbox_version || true)"
      ;;
    2)
      read -r -p "Enter version, example 1.13.12: " version
      version="${version#v}"
      ;;
    0)
      echo -e "${YELLOW}Cancelled.${NC}"
      pause
      return
      ;;
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
  echo "It will NOT modify PasarGuard or system sing-box service."
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
      echo
      "$SING_BOX_BIN" version || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
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
    vless://*) echo "vless" ;;
    vmess://*) echo "vmess" ;;
    trojan://*) echo "trojan" ;;
    ss://*) echo "shadowsocks" ;;
    hysteria2://*|hy2://*) echo "hysteria2" ;;
    tuic://*) echo "tuic" ;;
    wireguard://*|wg://*) echo "wireguard" ;;
    socks://*|socks5://*) echo "socks" ;;
    http://*|https://*) echo "http_or_subscription" ;;
    *) echo "unknown" ;;
  esac
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
  echo "Supported/planned types:"
  echo "vless:// vmess:// trojan:// ss:// hysteria2:// tuic:// wireguard:// socks://"
  echo
  echo "Note:"
  echo "This step only stores and identifies the link."
  echo "It does NOT start proxy or TUN yet."
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
    echo "We will add more parsers step by step."
    pause
    return
  fi

  if [[ "$link_type" == "http_or_subscription" ]]; then
    echo -e "${YELLOW}This looks like HTTP/HTTPS.${NC}"
    echo "If this is a subscription link, use Add subscription link later."
    echo
    read -r -p "Store it as a single link anyway? [y/N]: " confirm_http
    case "$confirm_http" in
      y|Y|yes|YES) ;;
      *)
        echo -e "${YELLOW}Cancelled.${NC}"
        pause
        return
        ;;
    esac
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
  echo -e "${GREEN}Single config link saved.${NC}"
  echo
  echo "ID:"
  echo "$id"
  echo
  echo "Active link file:"
  echo "$ACTIVE_LINK_FILE"
  echo

  pause
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

relay_test_active_link() {
  title
  echo -e "${CYAN}Relay Test Active Config Link${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  if [[ ! -x "$SING_BOX_BIN" ]]; then
    echo -e "${RED}sing-box is not installed.${NC}"
    echo "Run option 2 first: Install / Update sing-box"
    pause
    return
  fi

  if [[ ! -f "$ACTIVE_LINK_FILE" ]]; then
    echo -e "${RED}No active config link found.${NC}"
    echo "Run option 3 first: Add single config link"
    pause
    return
  fi

  local link_type link
  link_type="$(get_active_link_type || true)"
  link="$(get_active_link_value || true)"

  if [[ -z "${link:-}" ]]; then
    echo -e "${RED}Active link is empty.${NC}"
    pause
    return
  fi

  echo -e "${YELLOW}Active link type:${NC} ${link_type:-UNKNOWN}"
  echo -e "${YELLOW}Relay test mode:${NC} temporary local SOCKS/HTTP mixed inbound"
  echo
  echo "Local test proxy:"
  echo "127.0.0.1:19080"
  echo

  if [[ "$link_type" != "shadowsocks" ]]; then
    echo -e "${YELLOW}This first relay-test version currently supports ss:// links only.${NC}"
    echo "Next steps will add VLESS / VMess / Trojan / Hysteria2 / TUIC / subscription parsing."
    pause
    return
  fi

  local test_dir test_config test_log result_ip direct_ip pid

  test_dir="$TUNNEL_DIR/relay-test"
  test_config="$test_dir/test-config.json"
  test_log="$test_dir/test.log"

  mkdir -p "$test_dir"

  python3 - "$link" "$test_config" <<'PY2'
import base64
import json
import sys
from urllib.parse import urlparse, unquote

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

    # Remove fragment.
    if "#" in raw:
        raw, _frag = raw.split("#", 1)

    # Remove query/plugin for this first simple relay test.
    if "?" in raw:
        raw, _query = raw.split("?", 1)

    raw = unquote(raw)

    method = password = server = port = None

    # Format A:
    # ss://base64(method:password)@host:port
    if "@" in raw:
        userinfo, hostport = raw.rsplit("@", 1)

        try:
            decoded_userinfo = b64decode_padded(userinfo)
        except Exception:
            decoded_userinfo = userinfo

        if ":" not in decoded_userinfo:
            raise ValueError("Cannot parse Shadowsocks method/password")

        method, password = decoded_userinfo.split(":", 1)

        if hostport.startswith("["):
            # IPv6 format [addr]:port
            end = hostport.find("]")
            server = hostport[1:end]
            port = int(hostport[end+2:])
        else:
            server, port_s = hostport.rsplit(":", 1)
            port = int(port_s)

    # Format B:
    # ss://base64(method:password@host:port)
    else:
        decoded = b64decode_padded(raw)
        if "@" not in decoded:
            raise ValueError("Cannot parse Shadowsocks base64 body")

        userinfo, hostport = decoded.rsplit("@", 1)
        method, password = userinfo.split(":", 1)

        if hostport.startswith("["):
            end = hostport.find("]")
            server = hostport[1:end]
            port = int(hostport[end+2:])
        else:
            server, port_s = hostport.rsplit(":", 1)
            port = int(port_s)

    if not all([method, password, server, port]):
        raise ValueError("Incomplete Shadowsocks link")

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
            "tag": "local-mixed",
            "listen": "127.0.0.1",
            "listen_port": 19080
        }
    ],
    "outbounds": [
        {
            "type": "shadowsocks",
            "tag": "relay-out",
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
        "final": "relay-out"
    }
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)

print(f"Parsed Shadowsocks server: {ss['server']}:{ss['server_port']}")
print(f"Method: {ss['method']}")
PY2

  echo
  echo -e "${YELLOW}Testing generated sing-box config...${NC}"
  if ! "$SING_BOX_BIN" check -c "$test_config"; then
    echo -e "${RED}sing-box config check failed.${NC}"
    echo
    cat "$test_config" | sed -E 's/"password": ".*"/"password": "***"/g'
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Starting temporary relay test service...${NC}"
  rm -f "$test_log"

  "$SING_BOX_BIN" run -c "$test_config" > "$test_log" 2>&1 &
  pid="$!"

  sleep 2

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    echo -e "${RED}Temporary sing-box process exited early.${NC}"
    echo
    echo "Logs:"
    cat "$test_log" || true
    pause
    return
  fi

  if ! ss -ltnp 2>/dev/null | grep -q ':19080'; then
    echo -e "${RED}Local test proxy did not listen on 127.0.0.1:19080.${NC}"
    kill "$pid" >/dev/null 2>&1 || true
    echo
    cat "$test_log" || true
    pause
    return
  fi

  echo -e "${GREEN}Local relay proxy is running.${NC}"
  echo

  direct_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  result_ip="$(curl -4fsS --max-time 15 --socks5-hostname 127.0.0.1:19080 https://api.ipify.org 2>/dev/null || true)"

  echo -e "${YELLOW}Direct server public IP:${NC}"
  echo "${direct_ip:-FAILED}"
  echo

  echo -e "${YELLOW}Relay public IP through config:${NC}"
  echo "${result_ip:-FAILED}"
  echo

  echo -e "${YELLOW}HTTP connectivity test through relay:${NC}"
  if curl -fsS --max-time 15 --socks5-hostname 127.0.0.1:19080 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n '1,10p'; then
    echo
    echo -e "${GREEN}Relay HTTP test succeeded.${NC}"
  else
    echo -e "${RED}Relay HTTP test failed.${NC}"
  fi

  echo
  echo -e "${YELLOW}Stopping temporary relay test...${NC}"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true

  echo
  if [[ -n "${result_ip:-}" ]]; then
    echo -e "${GREEN}Relay test completed.${NC}"
  else
    echo -e "${RED}Relay test failed or no outbound IP was returned.${NC}"
    echo
    echo "Logs:"
    tail -n 80 "$test_log" || true
  fi

  pause
}

show_saved_links() {
  title
  echo -e "${CYAN}Saved Single Config Links${NC}"
  line
  echo

  ensure_dirs

  if [[ ! -f "$RAW_LINKS_FILE" ]]; then
    echo -e "${YELLOW}No single config links saved yet.${NC}"
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

show_status_logs() {
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy Status${NC}"
  line
  echo

  echo -e "${YELLOW}Directory:${NC}"
  echo "$TUNNEL_DIR"
  echo

  echo -e "${YELLOW}sing-box binary:${NC}"
  if [[ -x "$SING_BOX_BIN" ]]; then
    echo "$SING_BOX_BIN"
    "$SING_BOX_BIN" version || true
  else
    echo "Not installed"
  fi
  echo

  echo -e "${YELLOW}Active single link:${NC}"
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

  echo -e "${YELLOW}Service status:${NC}"
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || echo "Service not created yet."
  echo

  echo -e "${YELLOW}Recent logs:${NC}"
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
  echo

  pause
}

show_plan() {
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  line
  echo

  echo -e "${YELLOW}Purpose:${NC}"
  echo "Temporarily route server installation traffic through a VPN/proxy config."
  echo
  echo "Example use cases:"
  echo "- apt update / apt install"
  echo "- curl / wget downloads"
  echo "- git clone"
  echo "- docker pull"
  echo "- npm / pip / go install"
  echo

  echo -e "${YELLOW}Planned modes:${NC}"
  echo
  echo "1. Proxy Mode"
  echo "   Creates local HTTP/SOCKS proxy."
  echo "   Safer, but only works for apps that use proxy settings."
  echo
  echo "2. TUN Mode"
  echo "   Routes most server traffic through the selected outbound config."
  echo "   Better for installation tasks, but must be started/stopped carefully."
  echo

  echo -e "${YELLOW}Isolation rules:${NC}"
  echo "- Uses separate directory:"
  echo "  $TUNNEL_DIR"
  echo
  echo "- Uses separate service:"
  echo "  ${SERVICE_NAME}.service"
  echo
  echo "- Will NOT modify PasarGuard files:"
  echo "  /opt/pg-node"
  echo "  /var/lib/pg-node"
  echo "  pg-node-service"
  echo

  echo -e "${YELLOW}Current status:${NC}"
  if [[ -x "$SING_BOX_BIN" ]]; then
    echo "sing-box installed:"
    "$SING_BOX_BIN" version || true
  else
    echo "sing-box is not installed yet."
  fi
  echo

  pause
}

coming_soon() {
  local item="$1"
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  line
  echo
  echo -e "${YELLOW}${item}${NC}"
  echo
  echo "This feature is not implemented yet."
  echo "We will add it step by step after approval."
  echo
  pause
}

while true; do
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  echo
  echo "1. Show plan"
  echo "2. Install / Update sing-box"
  echo "3. Add single config link"
  echo "4. Add subscription link"
  echo "5. Update subscription"
  echo "6. Select active outbound"
  echo "7. Start Proxy Mode"
  echo "8. Start TUN Mode"
  echo "9. Stop tunnel/proxy"
  echo "10. Show saved links"
  echo "11. Show status/logs"
  echo "12. Relay test active link"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-12]: " choice

  case "$choice" in
    1)
      show_plan
      ;;
    2)
      install_singbox_isolated
      ;;
    3)
      add_single_config_link
      ;;
    4)
      coming_soon "Add subscription link"
      ;;
    5)
      coming_soon "Update subscription"
      ;;
    6)
      coming_soon "Select active outbound"
      ;;
    7)
      coming_soon "Start Proxy Mode"
      ;;
    8)
      coming_soon "Start TUN Mode"
      ;;
    9)
      coming_soon "Stop tunnel/proxy"
      ;;
    10)
      show_saved_links
      ;;
    11)
      show_status_logs
      ;;
    12)
      relay_test_active_link
      ;;
    0)
      break
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      sleep 1
      ;;
  esac
done
