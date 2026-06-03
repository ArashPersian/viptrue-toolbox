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

safe_test_func = r'''
tun_firewall_safe_test() {
  title
  echo -e "${CYAN}Safe TUN Test without UFW${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  if [[ ! -x "$SING_BOX_BIN" ]]; then
    echo -e "${RED}sing-box is not installed.${NC}"
    echo "Run option 2 first."
    pause
    return
  fi

  echo -e "${RED}Important:${NC}"
  echo "This test will temporarily disable UFW, start TUN, test curl, then stop TUN."
  echo
  echo "Safety:"
  echo "- TUN service will be auto-stopped by watchdog after 60 seconds."
  echo "- UFW will be restored to its previous active/inactive state."
  echo "- PasarGuard will not be modified."
  echo "- SSH client IP direct rule is still used."
  echo

  echo -e "${YELLOW}Current UFW status:${NC}"
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
  else
    echo "UFW not installed."
  fi
  echo

  read -r -p "Run safe TUN test with UFW temporarily disabled? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      pause
      return
      ;;
  esac

  local ufw_was_active="no"
  local watchdog_pid=""

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      ufw_was_active="yes"
    fi
  fi

  echo
  echo -e "${YELLOW}Stopping any existing temp tunnel service...${NC}"
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  ip link delete viptrue-tun0 2>/dev/null || true

  if ! generate_tun_config_from_active_link; then
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Checking TUN config...${NC}"
  if ! "$SING_BOX_BIN" check -c "$TUN_CONFIG_FILE"; then
    echo -e "${RED}TUN config check failed.${NC}"
    pause
    return
  fi

  write_tun_systemd_service

  echo
  echo -e "${YELLOW}Starting safety watchdog for 60 seconds...${NC}"
  (
    sleep 60
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    ip link delete viptrue-tun0 2>/dev/null || true
    if [[ "$ufw_was_active" == "yes" ]] && command -v ufw >/dev/null 2>&1; then
      ufw --force enable >/dev/null 2>&1 || true
    fi
  ) &
  watchdog_pid="$!"

  if [[ "$ufw_was_active" == "yes" ]]; then
    echo
    echo -e "${YELLOW}Temporarily disabling UFW...${NC}"
    ufw disable || true
  else
    echo
    echo -e "${YELLOW}UFW was not active. No need to disable.${NC}"
  fi

  echo
  echo -e "${YELLOW}Starting TUN service...${NC}"
  systemctl start "$SERVICE_NAME"

  sleep 4

  echo
  echo -e "${YELLOW}Service status:${NC}"
  systemctl status "$SERVICE_NAME" --no-pager || true

  echo
  echo -e "${YELLOW}Routing while TUN is active:${NC}"
  echo "--- main table ---"
  ip route 2>/dev/null | sed -n '1,120p' || true
  echo
  echo "--- ip rules ---"
  ip rule 2>/dev/null || true
  echo
  echo "--- table 2022 ---"
  ip route show table 2022 2>/dev/null || true
  echo
  echo "--- table 2023 ---"
  ip route show table 2023 2>/dev/null || true
  echo

  echo -e "${YELLOW}Curl test without proxy env:${NC}"
  local test_ip=""
  test_ip="$(run_without_proxy_env curl -4fsS --connect-timeout 8 --max-time 25 https://api.ipify.org 2>/dev/null || true)"
  echo "${test_ip:-FAILED}"
  echo

  echo -e "${YELLOW}Recent logs:${NC}"
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true

  echo
  echo -e "${YELLOW}Stopping TUN service...${NC}"
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  ip link delete viptrue-tun0 2>/dev/null || true

  if [[ -n "$watchdog_pid" ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
  fi

  if [[ "$ufw_was_active" == "yes" ]] && command -v ufw >/dev/null 2>&1; then
    echo
    echo -e "${YELLOW}Re-enabling UFW...${NC}"
    ufw --force enable || true
  fi

  echo
  echo -e "${YELLOW}Final UFW status:${NC}"
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
  else
    echo "UFW not installed."
  fi

  echo
  if [[ -n "${test_ip:-}" ]]; then
    echo -e "${GREEN}Safe TUN test succeeded.${NC}"
    echo "TUN output IP: $test_ip"
  else
    echo -e "${RED}Safe TUN test failed.${NC}"
    echo "Since UFW was disabled during the test, the problem is probably not UFW."
  fi

  pause
}
'''

if "tun_firewall_safe_test()" not in text:
    text = text.replace(insert_before, safe_test_func + insert_before)

text = text.replace(
'''echo "14. TUN Diagnostics"''',
'''echo "14. TUN Diagnostics"
  echo "15. Safe TUN Test without UFW"'''
)

text = text.replace(
'''read -r -p "Enter your choice [0-14]: " choice''',
'''read -r -p "Enter your choice [0-15]: " choice'''
)

text = text.replace(
'''    14)
      tun_diagnostics
      ;;''',
'''    14)
      tun_diagnostics
      ;;
    15)
      tun_firewall_safe_test
      ;;'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-K completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add safe TUN test without UFW' && git push"
