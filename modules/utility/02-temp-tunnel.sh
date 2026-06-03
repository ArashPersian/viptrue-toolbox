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
SUB_LINKS_FILE="$SUBS_DIR/subscriptions.txt"
SUB_OUTBOUNDS_FILE="$OUTBOUNDS_DIR/subscription-outbounds.txt"
ACTIVE_LINK_FILE="$STATE_DIR/active-link.txt"
PROXY_CONFIG_FILE="$CONFIG_DIR/proxy-mode.json"
PROXY_ENV_FILE="$STATE_DIR/proxy-env.sh"
PROXY_SHELL_BIN="/usr/local/bin/viptrue-proxy-shell"
PROXY_RUN_BIN="/usr/local/bin/viptrue-proxy-run"
LINK_PROXY_TOOLS="$BASE_DIR/modules/utility/link_proxy_tools.py"

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
  echo "- vless:// VLESS"
  echo "- trojan:// Trojan"
  echo "- vmess:// VMess"
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
  echo -e "${CYAN}Saved Config Links / Subscriptions${NC}"
  line
  echo

  ensure_dirs

  python3 - "$RAW_LINKS_FILE" "$SUB_LINKS_FILE" "$SUB_OUTBOUNDS_FILE" <<'PY2'
import sys, re
from pathlib import Path
from urllib.parse import urlparse, unquote

raw_file = Path(sys.argv[1])
subs_file = Path(sys.argv[2])
sub_outbounds_file = Path(sys.argv[3])

def mask_link(link: str) -> str:
    link = re.sub(r'(://)[^:@/]+:[^@/]+@', r'\1***:***@', link)
    link = re.sub(r'(password=)[^&]+', r'\1***', link, flags=re.I)
    link = re.sub(r'(uuid=)[^&]+', r'\1***', link, flags=re.I)
    link = re.sub(r'(id=)[^&]+', r'\1***', link, flags=re.I)
    if link.startswith("vless://") or link.startswith("trojan://"):
        try:
            p = urlparse(link)
            safe = link.replace(p.username or "", "***", 1) if p.username else link
            return safe
        except Exception:
            return link
    return link

def parse_blocks(path: Path):
    if not path.exists():
        return []
    blocks = []
    current = {}
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            if current:
                blocks.append(current)
            current = {"id": line[1:-1]}
        elif "=" in line and current is not None:
            k, v = line.split("=", 1)
            current[k.strip()] = v.strip()
    if current:
        blocks.append(current)
    return blocks

print("Single links:")
raw = parse_blocks(raw_file)
if not raw:
    print("  None")
else:
    for b in raw:
        print(f"  [{b.get('id','')}] type={b.get('type','unknown')}")
        print(f"    link={mask_link(b.get('link',''))}")

print()
print("Subscriptions:")
subs = parse_blocks(subs_file)
if not subs:
    print("  None")
else:
    for b in subs:
        print(f"  [{b.get('id','')}] name={b.get('name','')}")
        print(f"    url={mask_link(b.get('url',''))}")

print()
print("Subscription outbounds:")
outs = parse_blocks(sub_outbounds_file)
if not outs:
    print("  None")
else:
    for b in outs[:80]:
        print(f"  [{b.get('id','')}] type={b.get('type','unknown')} source={b.get('source','')}")
        print(f"    link={mask_link(b.get('link',''))}")
    if len(outs) > 80:
        print(f"  ... and {len(outs)-80} more")
PY2

  echo
  echo -e "${YELLOW}Active link:${NC}"
  if [[ -f "$ACTIVE_LINK_FILE" ]]; then
    grep -E '^(id|type|source|sub_id)=' "$ACTIVE_LINK_FILE" || true
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

add_subscription_link() {
  title
  echo -e "${CYAN}Add Subscription Link${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  echo "Paste your subscription URL."
  echo "Supported extracted config types:"
  echo "- ss://"
  echo "- vless://"
  echo "- trojan://"
  echo "- vmess://"
  echo
  read -r -p "Subscription name, example Backup-Sub: " sub_name
  read -r -p "Subscription URL: " sub_url

  if [[ -z "${sub_url// /}" ]]; then
    echo -e "${RED}Empty subscription URL.${NC}"
    pause
    return
  fi

  local id
  id="$(date +%Y%m%d-%H%M%S)"

  {
    echo "[$id]"
    echo "name=${sub_name:-Subscription-$id}"
    echo "url=$sub_url"
    echo
  } >> "$SUB_LINKS_FILE"

  chmod 600 "$SUB_LINKS_FILE" 2>/dev/null || true

  echo
  echo -e "${GREEN}Subscription saved.${NC}"
  echo "ID: $id"
  echo
  echo "Now run:"
  echo "Config Links > Update subscriptions"
  echo

  pause
}

update_subscriptions() {
  title
  echo -e "${CYAN}Update Subscriptions${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  if [[ ! -f "$SUB_LINKS_FILE" ]]; then
    echo -e "${YELLOW}No subscription saved yet.${NC}"
    pause
    return
  fi

  apt-get update >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates >/dev/null 2>&1 || true

  local tmp_out
  tmp_out="$(mktemp)"
  : > "$tmp_out"

  python3 - "$SUB_LINKS_FILE" <<'PY2' | while IFS=$'\t' read -r sub_id sub_name sub_url; do
from pathlib import Path
import sys

path = Path(sys.argv[1])
current = {}
blocks = []

for line in path.read_text(errors="replace").splitlines():
    line = line.strip()
    if not line:
        continue
    if line.startswith("[") and line.endswith("]"):
        if current:
            blocks.append(current)
        current = {"id": line[1:-1]}
    elif "=" in line and current is not None:
        k, v = line.split("=", 1)
        current[k.strip()] = v.strip()
if current:
    blocks.append(current)

for b in blocks:
    print(f"{b.get('id','')}\t{b.get('name','')}\t{b.get('url','')}")
PY2
    [[ -n "${sub_id:-}" && -n "${sub_url:-}" ]] || continue

    echo
    echo -e "${YELLOW}Updating:${NC} $sub_name [$sub_id]"

    local tmp_body
    tmp_body="$(mktemp)"

    if curl -fsSL --connect-timeout 15 --max-time 45 "$sub_url" -o "$tmp_body"; then
      python3 - "$tmp_body" "$sub_id" "$sub_name" >> "$tmp_out" <<'PY3'
import sys, base64, re
from pathlib import Path

body_path = Path(sys.argv[1])
sub_id = sys.argv[2]
sub_name = sys.argv[3]

raw = body_path.read_text(errors="replace").strip()

def b64decode_padded(data: str):
    data = data.strip()
    data = re.sub(r'\s+', '', data)
    data = data.replace("-", "+").replace("_", "/")
    data += "=" * (-len(data) % 4)
    return base64.b64decode(data).decode("utf-8", errors="replace")

def detect_type(link):
    if link.startswith("ss://"):
        return "shadowsocks"
    if link.startswith("vless://"):
        return "vless"
    if link.startswith("trojan://"):
        return "trojan"
    if link.startswith("vmess://"):
        return "vmess"
    return "unknown"

def extract_links(text):
    supported = ("ss://", "vless://", "trojan://", "vmess://")
    found = []

    for line in text.replace("\r", "\n").split("\n"):
        line = line.strip()
        if not line:
            continue
        if line.startswith(supported):
            found.append(line)

    if found:
        return found

    # Try extracting links from mixed text/YAML-like content
    pattern = r'(ss://[^\s\'"]+|vless://[^\s\'"]+|trojan://[^\s\'"]+|vmess://[^\s\'"]+)'
    return re.findall(pattern, text)

candidates = [raw]

try:
    decoded = b64decode_padded(raw)
    candidates.insert(0, decoded)
except Exception:
    pass

links = []
seen = set()

for c in candidates:
    for link in extract_links(c):
        if link not in seen:
            seen.add(link)
            links.append(link)

count = 0
for link in links:
    typ = detect_type(link)
    if typ == "unknown":
        continue
    count += 1
    item_id = f"{sub_id}-{count:04d}"
    print(f"[{item_id}]")
    print("source=subscription")
    print(f"sub_id={sub_id}")
    print(f"sub_name={sub_name}")
    print(f"type={typ}")
    print(f"link={link}")
    print()

print(f"# Imported {count} links from {sub_name} [{sub_id}]", file=sys.stderr)
PY3
    else
      echo -e "${RED}Failed to download subscription:${NC} $sub_name"
    fi

    rm -f "$tmp_body"
  done

  mv "$tmp_out" "$SUB_OUTBOUNDS_FILE"
  chmod 600 "$SUB_OUTBOUNDS_FILE" 2>/dev/null || true

  echo
  echo -e "${GREEN}Subscriptions updated.${NC}"
  echo

  local total
  total="$(grep -c '^\[' "$SUB_OUTBOUNDS_FILE" 2>/dev/null || true)"
  echo "Imported outbounds: ${total:-0}"
  echo

  pause
}

select_active_outbound() {
  title
  echo -e "${CYAN}Select Active Outbound - Auto Real Delay Sort${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  if [[ ! -x "$SING_BOX_BIN" ]]; then
    echo -e "${RED}sing-box is not installed.${NC}"
    echo "Run Install / Update sing-box first."
    pause
    return
  fi

  if [[ ! -f "$LINK_PROXY_TOOLS" ]]; then
    echo -e "${RED}Helper not found:${NC}"
    echo "$LINK_PROXY_TOOLS"
    pause
    return
  fi

  local select_file
  select_file="$STATE_DIR/selectable-outbounds.tsv"

  echo "This will test configs with real HTTP delay through sing-box local proxy,"
  echo "then sort them like v2rayN real delay results."
  echo
  echo "Recommended:"
  echo "- 30 or 50 for fast test"
  echo "- 0 to test ALL configs"
  echo
  read -r -p "How many configs should be tested? [default: 50, 0 = all]: " test_count
  test_count="${test_count:-50}"

  if ! [[ "$test_count" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid number.${NC}"
    pause
    return
  fi

  echo
  python3 "$LINK_PROXY_TOOLS" select \
    --raw "$RAW_LINKS_FILE" \
    --sub "$SUB_OUTBOUNDS_FILE" \
    --out "$select_file" \
    --sing-box "$SING_BOX_BIN" \
    --test-count "$test_count" \
    --timeout 9

  if [[ ! -s "$select_file" ]]; then
    echo -e "${YELLOW}No outbound found.${NC}"
    echo "Add a single config or update subscriptions first."
    pause
    return
  fi

  read -r -p "Select number from sorted list: " selected

  if ! [[ "$selected" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid number.${NC}"
    pause
    return
  fi

  echo
  if ! python3 "$LINK_PROXY_TOOLS" activate \
    --select-file "$select_file" \
    --number "$selected" \
    --active-file "$ACTIVE_LINK_FILE"; then
    echo -e "${RED}Failed to activate selected outbound.${NC}"
    pause
    return
  fi

  echo
  echo -e "${GREEN}Active file saved correctly.${NC}"
  echo
  echo "Now check active file if needed:"
  echo "cat -A $ACTIVE_LINK_FILE"
  echo
  echo "Then start:"
  echo "Proxy Mode > Start Proxy Mode"
  echo

  pause
}

generate_proxy_config_from_active_link() {
  ensure_dirs

  if [[ ! -f "$ACTIVE_LINK_FILE" ]]; then
    echo -e "${RED}No active config link found.${NC}"
    return 1
  fi

  if [[ ! -f "$LINK_PROXY_TOOLS" ]]; then
    echo -e "${RED}Helper not found:${NC}"
    echo "$LINK_PROXY_TOOLS"
    return 1
  fi

  local link_type link
  link_type="$(get_active_link_type || true)"
  link="$(get_active_link_value || true)"

  link="${link//$'\r'/}"
  link="${link//$'\n'/}"
  link="$(printf '%s' "$link" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

  if [[ -z "${link// /}" ]]; then
    echo -e "${RED}Active link is empty.${NC}"
    echo
    echo "Debug active file:"
    cat -A "$ACTIVE_LINK_FILE" 2>/dev/null || true
    return 1
  fi

  case "$link" in
    ss://*|vless://*|trojan://*|vmess://*) ;;
    *)
      echo -e "${RED}Unsupported active link for Proxy Mode.${NC}"
      echo "Active type: ${link_type:-UNKNOWN}"
      echo
      echo "Detected link:"
      printf '%s\n' "$link" | cut -c1-160
      echo
      echo "Debug active file:"
      cat -A "$ACTIVE_LINK_FILE" 2>/dev/null || true
      echo
      echo "Supported:"
      echo "- ss://"
      echo "- vless://"
      echo "- trojan://"
      echo "- vmess://"
      return 1
      ;;
  esac

  python3 "$LINK_PROXY_TOOLS" generate \
    --link "$link" \
    --out "$PROXY_CONFIG_FILE" \
    --listen-port 19080 \
    --log-level info
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
      viptrue_main_menu
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
    echo -e "${CYAN}Config Links / Subscriptions${NC}"
    line
    echo
    echo "1. Add single config link"
    echo "2. Add subscription link"
    echo "3. Update subscriptions"
    echo "4. Select active outbound + auto real delay sort"
    echo "5. Show saved links"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-5]: " choice

    case "$choice" in
      1) add_single_config_link ;;
      2) add_subscription_link ;;
      3) update_subscriptions ;;
      4) select_active_outbound ;;
      5) show_saved_links ;;
      0) break ;;
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
