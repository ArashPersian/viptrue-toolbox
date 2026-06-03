#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

# Add proxy config path if not exists
text = text.replace(
'''ACTIVE_LINK_FILE="$STATE_DIR/active-link.txt"

SING_BOX_BIN="$BIN_DIR/sing-box"''',
'''ACTIVE_LINK_FILE="$STATE_DIR/active-link.txt"
PROXY_CONFIG_FILE="$CONFIG_DIR/proxy-mode.json"

SING_BOX_BIN="$BIN_DIR/sing-box"'''
)

insert_before = '''
show_saved_links() {
'''

proxy_functions = r'''
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
    echo
    echo "We will add VLESS / VMess / Trojan / subscription support step by step."
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

    method = password = server = port = None

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
            end = hostport.find("]")
            server = hostport[1:end]
            port = int(hostport[end+2:])
        else:
            server, port_s = hostport.rsplit(":", 1)
            port = int(port_s)

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
Description=VIPTrue Temporary Tunnel / Proxy for Installations
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${TUNNEL_DIR}
ExecStart=${SING_BOX_BIN} run -c ${PROXY_CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
}

start_proxy_mode() {
  title
  echo -e "${CYAN}Start Proxy Mode${NC}"
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

  if ss -ltnp 2>/dev/null | grep -q ':19080'; then
    echo -e "${RED}Port 19080 is already in use.${NC}"
    echo "Stop the existing process/service first."
    pause
    return
  fi

  echo "Proxy Mode will start a local-only proxy:"
  echo
  echo "HTTP/SOCKS mixed proxy:"
  echo "127.0.0.1:19080"
  echo
  echo "It will NOT modify PasarGuard."
  echo "It will NOT change system routes."
  echo "It will NOT start on boot automatically."
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
        echo
        echo "Use these commands for temporary installation traffic:"
        echo
        echo "export http_proxy=http://127.0.0.1:19080"
        echo "export https_proxy=http://127.0.0.1:19080"
        echo "export all_proxy=socks5h://127.0.0.1:19080"
        echo
        echo "Test:"
        echo "curl https://api.ipify.org"
        echo
        echo "Disable env proxy after finishing:"
        echo "unset http_proxy https_proxy all_proxy"
        echo
        echo -e "${YELLOW}Service status:${NC}"
        systemctl status "$SERVICE_NAME" --no-pager || true
      else
        echo -e "${RED}Proxy service did not start.${NC}"
        echo
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
      fi
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

stop_tunnel_proxy() {
  title
  echo -e "${CYAN}Stop Tunnel / Proxy${NC}"
  line
  echo

  ensure_root || return

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  echo -e "${GREEN}Temporary tunnel/proxy service stopped.${NC}"
  echo
  echo "Also run this in your current shell if you exported proxy variables:"
  echo
  echo "unset http_proxy https_proxy all_proxy"
  echo

  pause
}
'''

if insert_before not in text:
    raise SystemExit("Could not find insertion point before show_saved_links().")

if "start_proxy_mode()" not in text:
    text = text.replace(insert_before, proxy_functions + insert_before)

# Replace option 7 and 9 handlers
text = text.replace(
'''    7)
      coming_soon "Start Proxy Mode"
      ;;''',
'''    7)
      start_proxy_mode
      ;;'''
)

text = text.replace(
'''    9)
      coming_soon "Stop tunnel/proxy"
      ;;''',
'''    9)
      stop_tunnel_proxy
      ;;'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12E completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add proxy mode for temporary tunnel' && git push"
