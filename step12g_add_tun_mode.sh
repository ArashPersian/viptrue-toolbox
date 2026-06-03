#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

text = text.replace(
'''PROXY_CONFIG_FILE="$CONFIG_DIR/proxy-mode.json"''',
'''PROXY_CONFIG_FILE="$CONFIG_DIR/proxy-mode.json"
TUN_CONFIG_FILE="$CONFIG_DIR/tun-mode.json"'''
)

insert_before = '''
show_saved_links() {
'''

tun_functions = r'''
get_current_ssh_client_ip() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "$SSH_CONNECTION" | awk '{print $1}'
  else
    echo ""
  fi
}

generate_tun_config_from_active_link() {
  ensure_dirs

  if [[ ! -f "$ACTIVE_LINK_FILE" ]]; then
    echo -e "${RED}No active config link found.${NC}"
    return 1
  fi

  local link_type link ssh_client_ip

  link_type="$(get_active_link_type || true)"
  link="$(get_active_link_value || true)"
  ssh_client_ip="$(get_current_ssh_client_ip || true)"

  if [[ "$link_type" != "shadowsocks" ]]; then
    echo -e "${RED}TUN Mode currently supports ss:// links only.${NC}"
    echo "Active type: ${link_type:-UNKNOWN}"
    echo
    echo "We will add VLESS / VMess / Trojan / subscription support step by step."
    return 1
  fi

  python3 - "$link" "$TUN_CONFIG_FILE" "$ssh_client_ip" <<'PY2'
import base64
import ipaddress
import json
import socket
import sys
from urllib.parse import unquote

link = sys.argv[1].strip()
out_path = sys.argv[2]
ssh_client_ip = sys.argv[3].strip() if len(sys.argv) > 3 else ""

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

def resolve_ipv4(host):
    try:
        ipaddress.ip_address(host)
        return host
    except ValueError:
        pass

    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET)
        if infos:
            return infos[0][4][0]
    except Exception:
        return ""

    return ""

ss = parse_ss(link)
remote_ip = resolve_ipv4(ss["server"])

direct_rules = []

# جلوگیری از لوپ: خود سرور مقصد کانفیگ باید direct برود.
if remote_ip:
    direct_rules.append({
        "ip_cidr": [f"{remote_ip}/32"],
        "outbound": "direct"
    })

# جلوگیری از قطع SSH فعلی: IP کلاینت SSH فعلی direct شود.
if ssh_client_ip:
    try:
        ipaddress.ip_address(ssh_client_ip)
        direct_rules.append({
            "ip_cidr": [f"{ssh_client_ip}/32"],
            "outbound": "direct"
        })
    except ValueError:
        pass

config = {
    "log": {
        "level": "info",
        "timestamp": True
    },
    "dns": {
        "servers": [
            {
                "tag": "cf",
                "address": "1.1.1.1",
                "detour": "install-out"
            },
            {
                "tag": "local",
                "address": "local"
            }
        ],
        "final": "cf"
    },
    "inbounds": [
        {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "viptrue-tun0",
            "address": [
                "172.19.0.1/30"
            ],
            "auto_route": True,
            "strict_route": True,
            "stack": "mixed",
            "sniff": True
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
        "auto_detect_interface": True,
        "rules": direct_rules,
        "final": "install-out"
    }
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)

print(f"TUN config generated for Shadowsocks server: {ss['server']}:{ss['server_port']}")
if remote_ip:
    print(f"Remote server direct rule: {remote_ip}/32")
if ssh_client_ip:
    print(f"SSH client direct rule: {ssh_client_ip}/32")
PY2
}

write_tun_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF2
[Unit]
Description=VIPTrue Temporary TUN Tunnel for Installations
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${TUNNEL_DIR}
ExecStart=${SING_BOX_BIN} run -c ${TUN_CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
}

start_tun_mode() {
  title
  echo -e "${CYAN}Start TUN Mode${NC}"
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

  echo -e "${RED}Important:${NC}"
  echo "TUN Mode changes system routing temporarily."
  echo "It is better for apt/curl/git/docker installations, but must be stopped after use."
  echo
  echo "Safety rules:"
  echo "- PasarGuard files/services are not modified."
  echo "- Current SSH client IP will be routed direct to reduce disconnect risk."
  echo "- Remote config server IP will be routed direct to avoid tunnel loop."
  echo "- Service will NOT be enabled on boot."
  echo
  echo -e "${YELLOW}Current SSH client IP:${NC}"
  get_current_ssh_client_ip || true
  echo

  read -r -p "Start TUN Mode now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

      if ! generate_tun_config_from_active_link; then
        pause
        return
      fi

      echo
      echo -e "${YELLOW}Checking sing-box TUN config...${NC}"
      if ! "$SING_BOX_BIN" check -c "$TUN_CONFIG_FILE"; then
        echo -e "${RED}TUN config check failed. TUN not started.${NC}"
        pause
        return
      fi

      write_tun_systemd_service

      systemctl start "$SERVICE_NAME"

      sleep 3

      if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo
        echo -e "${GREEN}TUN Mode started successfully.${NC}"
        echo
        echo -e "${YELLOW}Testing normal curl through TUN:${NC}"
        local direct_or_tun_ip
        direct_or_tun_ip="$(curl -4fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
        echo "${direct_or_tun_ip:-FAILED}"
        echo
        echo "Now commands like these should use the tunnel automatically:"
        echo "apt update"
        echo "curl https://api.ipify.org"
        echo "git clone ..."
        echo "docker pull ..."
        echo
        echo "To stop:"
        echo "Temporary Tunnel / Proxy > Stop tunnel/proxy"
        echo
        echo -e "${YELLOW}Service status:${NC}"
        systemctl status "$SERVICE_NAME" --no-pager || true
      else
        echo -e "${RED}TUN service did not start.${NC}"
        echo
        journalctl -u "$SERVICE_NAME" -n 100 --no-pager || true
      fi
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}
'''

if insert_before not in text:
    raise SystemExit("Could not find insertion point before show_saved_links().")

if "start_tun_mode()" not in text:
    text = text.replace(insert_before, tun_functions + insert_before)

text = text.replace(
'''    8)
      coming_soon "Start TUN Mode"
      ;;''',
'''    8)
      start_tun_mode
      ;;'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add temporary TUN mode for installations' && git push"
