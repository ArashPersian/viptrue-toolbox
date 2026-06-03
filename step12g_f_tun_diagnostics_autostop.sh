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

diag_functions = r'''
tun_diagnostics() {
  title
  echo -e "${CYAN}TUN Diagnostics${NC}"
  line
  echo

  echo -e "${YELLOW}Service status:${NC}"
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true
  echo

  echo -e "${YELLOW}Recent service logs:${NC}"
  journalctl -u "$SERVICE_NAME" -n 120 --no-pager 2>/dev/null || true
  echo

  echo -e "${YELLOW}Interfaces:${NC}"
  ip addr show 2>/dev/null | sed -n '1,160p' || true
  echo

  echo -e "${YELLOW}Routes:${NC}"
  ip route 2>/dev/null || true
  echo

  echo -e "${YELLOW}Rules:${NC}"
  ip rule 2>/dev/null || true
  echo

  echo -e "${YELLOW}DNS / resolv.conf:${NC}"
  cat /etc/resolv.conf 2>/dev/null || true
  echo

  echo -e "${YELLOW}Test 1 - direct IP through current routing:${NC}"
  curl -4fsS --connect-timeout 5 --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n '1,8p' || echo "FAILED"
  echo

  echo -e "${YELLOW}Test 2 - domain through current routing:${NC}"
  curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "FAILED"
  echo

  echo -e "${YELLOW}Test 3 - DNS resolve:${NC}"
  getent hosts api.ipify.org 2>/dev/null || echo "FAILED"
  echo

  echo -e "${YELLOW}Active TUN config path:${NC}"
  echo "$TUN_CONFIG_FILE"
  echo

  if [[ -f "$TUN_CONFIG_FILE" ]]; then
    echo -e "${YELLOW}TUN config preview without password:${NC}"
    sed -E 's/"password": ".*"/"password": "***"/g' "$TUN_CONFIG_FILE" | sed -n '1,220p'
  else
    echo "TUN config not found."
  fi
  echo

  pause
}
'''

if "tun_diagnostics()" not in text:
    text = text.replace(insert_before, diag_functions + insert_before)

old = '''direct_or_tun_ip="$(curl -4fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
        echo "${direct_or_tun_ip:-FAILED}"
        echo
        echo "Now commands like these should use the tunnel automatically:"'''

new = '''direct_or_tun_ip="$(curl -4fsS --connect-timeout 5 --max-time 15 https://api.ipify.org 2>/dev/null || true)"
        echo "${direct_or_tun_ip:-FAILED}"
        echo

        if [[ -z "${direct_or_tun_ip:-}" ]]; then
          echo -e "${RED}TUN curl test failed. Auto-stopping TUN to keep server safe.${NC}"
          systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
          echo
          echo "Run option 14. TUN Diagnostics to inspect the reason."
          pause
          return
        fi

        echo "Now commands like these should use the tunnel automatically:"'''

if old in text:
    text = text.replace(old, new)
else:
    print("Warning: expected TUN curl block not found; maybe already changed.")

text = text.replace(
'''echo "13. Open proxied shell"''',
'''echo "13. Open proxied shell"
  echo "14. TUN Diagnostics"'''
)

text = text.replace(
'''read -r -p "Enter your choice [0-13]: " choice''',
'''read -r -p "Enter your choice [0-14]: " choice'''
)

text = text.replace(
'''    13)
      open_proxied_shell
      ;;''',
'''    13)
      open_proxied_shell
      ;;
    14)
      tun_diagnostics
      ;;'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-F completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add TUN diagnostics and auto stop on failed test' && git push"
