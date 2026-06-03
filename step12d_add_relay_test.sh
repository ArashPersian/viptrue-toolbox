#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

insert_before = '''
show_saved_links() {
'''

relay_functions = r'''
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
'''

if insert_before not in text:
    raise SystemExit("Could not find insertion point before show_saved_links().")

text = text.replace(insert_before, relay_functions + insert_before)

text = text.replace(
'''echo "11. Show status/logs"''',
'''echo "11. Show status/logs"
  echo "12. Relay test active link"'''
)

text = text.replace(
'''read -r -p "Enter your choice [0-11]: " choice''',
'''read -r -p "Enter your choice [0-12]: " choice'''
)

text = text.replace(
'''    11)
      show_status_logs
      ;;''',
'''    11)
      show_status_logs
      ;;
    12)
      relay_test_active_link
      ;;'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12D completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add relay test for active shadowsocks link' && git push"
