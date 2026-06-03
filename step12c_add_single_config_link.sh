#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

# Add new paths after STATE_DIR definition
text = text.replace(
'''STATE_DIR="$TUNNEL_DIR/state"

SING_BOX_BIN="$BIN_DIR/sing-box"''',
'''STATE_DIR="$TUNNEL_DIR/state"
OUTBOUNDS_DIR="$TUNNEL_DIR/outbounds"
RAW_LINKS_FILE="$OUTBOUNDS_DIR/single-links.txt"
ACTIVE_LINK_FILE="$STATE_DIR/active-link.txt"

SING_BOX_BIN="$BIN_DIR/sing-box"'''
)

# Update ensure_dirs
text = text.replace(
'''ensure_dirs() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$SUBS_DIR" "$LOG_DIR" "$STATE_DIR"
}''',
'''ensure_dirs() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$SUBS_DIR" "$LOG_DIR" "$STATE_DIR" "$OUTBOUNDS_DIR"
}'''
)

insert_before = '''
show_status_logs() {
'''

new_functions = r'''
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
'''

text = text.replace(insert_before, new_functions + insert_before)

# Update show_status_logs to include active link
text = text.replace(
'''echo -e "${YELLOW}Service status:${NC}"''',
'''echo -e "${YELLOW}Active single link:${NC}"
  if [[ -f "$ACTIVE_LINK_FILE" ]]; then
    grep -E '^(id|type)=' "$ACTIVE_LINK_FILE" || true
    grep '^link=' "$ACTIVE_LINK_FILE" | sed -E \\
      -e 's#(://)[^:@/]+:[^@/]+@#\\1***:***@#g' \\
      -e 's#(password=)[^&]+#\\1***#Ig' \\
      -e 's#(uuid=)[^&]+#\\1***#Ig' \\
      -e 's#(id=)[^&]+#\\1***#Ig' || true
  else
    echo "None"
  fi
  echo

  echo -e "${YELLOW}Service status:${NC}"'''
)

# Replace menu option 3
text = text.replace(
'''    3)
      coming_soon "Add single config link"
      ;;''',
'''    3)
      add_single_config_link
      ;;'''
)

# Add a saved-links option by changing menu 10 to 11 and adding 10
text = text.replace(
'''echo "10. Show status/logs"''',
'''echo "10. Show saved links"
  echo "11. Show status/logs"'''
)

text = text.replace(
'''read -r -p "Enter your choice [0-10]: " choice''',
'''read -r -p "Enter your choice [0-11]: " choice'''
)

text = text.replace(
'''    10)
      show_status_logs
      ;;''',
'''    10)
      show_saved_links
      ;;
    11)
      show_status_logs
      ;;'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12C completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add single config link storage for temp tunnel' && git push"
