#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

# Add helper paths after PROXY_CONFIG_FILE if not exists
text = text.replace(
'''PROXY_CONFIG_FILE="$CONFIG_DIR/proxy-mode.json"

SING_BOX_BIN="$BIN_DIR/sing-box"''',
'''PROXY_CONFIG_FILE="$CONFIG_DIR/proxy-mode.json"
PROXY_ENV_FILE="$STATE_DIR/proxy-env.sh"
PROXY_SHELL_BIN="/usr/local/bin/viptrue-proxy-shell"
PROXY_RUN_BIN="/usr/local/bin/viptrue-proxy-run"

SING_BOX_BIN="$BIN_DIR/sing-box"'''
)

insert_before = '''
show_saved_links() {
'''

helper_functions = r'''
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
  echo "Start it from toolbox first."
  exit 1
fi

source "$PROXY_ENV_FILE"

echo
echo "VIPTrue proxied shell is active."
echo "Proxy:"
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
  echo "Start it from toolbox first."
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
    echo
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
  fi
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
  echo
  echo "Inside that shell, commands like these will use proxy:"
  echo "curl, wget, git, apt, pip, npm"
  echo
  echo "To leave proxied shell, type:"
  echo "exit"
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
'''

if insert_before not in text:
    raise SystemExit("Insertion point not found.")

if "write_proxy_helpers()" not in text:
    text = text.replace(insert_before, helper_functions + insert_before)

# Add helper calls after Proxy Mode started successfully
old_success = '''echo -e "${GREEN}Proxy Mode started successfully.${NC}"
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
        echo -e "${YELLOW}Service status:${NC}"'''

new_success = '''echo -e "${GREEN}Proxy Mode started successfully.${NC}"
        echo

        write_proxy_helpers
        run_proxy_ip_test

        echo
        echo "Helper commands created:"
        echo
        echo "1. Open proxied shell:"
        echo "   viptrue-proxy-shell"
        echo
        echo "2. Run one command through proxy:"
        echo "   viptrue-proxy-run curl https://api.ipify.org"
        echo "   viptrue-proxy-run apt update"
        echo
        echo "Inside toolbox you can also use:"
        echo "Temporary Tunnel / Proxy > Open proxied shell"
        echo
        echo -e "${YELLOW}Service status:${NC}"'''

if old_success in text:
    text = text.replace(old_success, new_success)
else:
    print("Warning: start_proxy_mode success block not found; helpers may already be applied.")

# Modify stop function to remove helpers
old_stop = '''systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  echo -e "${GREEN}Temporary tunnel/proxy service stopped.${NC}"
  echo
  echo "Also run this in your current shell if you exported proxy variables:"
  echo
  echo "unset http_proxy https_proxy all_proxy"
  echo'''

new_stop = '''systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  remove_proxy_helpers

  echo -e "${GREEN}Temporary tunnel/proxy service stopped.${NC}"
  echo
  echo "Proxy helper files removed."
  echo "If you manually exported variables in your current shell, run:"
  echo
  echo "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
  echo'''

if old_stop in text:
    text = text.replace(old_stop, new_stop)
else:
    print("Warning: stop_tunnel_proxy block not found; it may already be modified.")

# Add menu item 13
text = text.replace(
'''echo "12. Relay test active link"''',
'''echo "12. Relay test active link"
  echo "13. Open proxied shell"'''
)

text = text.replace(
'''read -r -p "Enter your choice [0-12]: " choice''',
'''read -r -p "Enter your choice [0-13]: " choice'''
)

text = text.replace(
'''    12)
      relay_test_active_link
      ;;''',
'''    12)
      relay_test_active_link
      ;;
    13)
      open_proxied_shell
      ;;'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12F completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add auto proxy helpers and proxied shell' && git push"
