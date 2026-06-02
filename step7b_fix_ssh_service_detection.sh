#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/work/01-root-ssh.sh")
text = path.read_text()

old_restart = r'''restart_ssh() {
  if systemctl list-unit-files | grep -q '^ssh.service'; then
    systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd.service'; then
    systemctl restart sshd
  else
    echo -e "${RED}SSH service not found.${NC}"
    return 1
  fi
}'''

new_restart = r'''restart_ssh() {
  if systemctl status ssh >/dev/null 2>&1; then
    systemctl restart ssh
    return 0
  fi

  if systemctl status ssh.service >/dev/null 2>&1; then
    systemctl restart ssh.service
    return 0
  fi

  if systemctl status sshd >/dev/null 2>&1; then
    systemctl restart sshd
    return 0
  fi

  if systemctl status sshd.service >/dev/null 2>&1; then
    systemctl restart sshd.service
    return 0
  fi

  if command -v service >/dev/null 2>&1; then
    if service ssh status >/dev/null 2>&1; then
      service ssh restart
      return 0
    fi

    if service sshd status >/dev/null 2>&1; then
      service sshd restart
      return 0
    fi
  fi

  echo -e "${RED}SSH service not found.${NC}"
  echo
  echo "Debug:"
  systemctl list-units --type=service --all 2>/dev/null | grep -Ei 'ssh|sshd|dropbear' || true
  return 1
}'''

old_reload = r'''reload_ssh() {
  if systemctl list-unit-files | grep -q '^ssh.service'; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd.service'; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd
  else
    echo -e "${RED}SSH service not found.${NC}"
    return 1
  fi
}'''

new_reload = r'''reload_ssh() {
  if systemctl status ssh >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
    return 0
  fi

  if systemctl status ssh.service >/dev/null 2>&1; then
    systemctl reload ssh.service 2>/dev/null || systemctl restart ssh.service
    return 0
  fi

  if systemctl status sshd >/dev/null 2>&1; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd
    return 0
  fi

  if systemctl status sshd.service >/dev/null 2>&1; then
    systemctl reload sshd.service 2>/dev/null || systemctl restart sshd.service
    return 0
  fi

  if command -v service >/dev/null 2>&1; then
    if service ssh status >/dev/null 2>&1; then
      service ssh reload 2>/dev/null || service ssh restart
      return 0
    fi

    if service sshd status >/dev/null 2>&1; then
      service sshd reload 2>/dev/null || service sshd restart
      return 0
    fi
  fi

  echo -e "${RED}SSH service not found.${NC}"
  echo
  echo "Debug:"
  systemctl list-units --type=service --all 2>/dev/null | grep -Ei 'ssh|sshd|dropbear' || true
  return 1
}'''

if old_restart not in text:
    raise SystemExit("restart_ssh function not found or already changed.")

if old_reload not in text:
    raise SystemExit("reload_ssh function not found or already changed.")

text = text.replace(old_restart, new_restart)
text = text.replace(old_reload, new_reload)

path.write_text(text)
PY

chmod +x modules/work/01-root-ssh.sh
bash -n modules/work/01-root-ssh.sh

echo
echo "✅ Step 7B completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Fix SSH service detection for port changes' && git push"
