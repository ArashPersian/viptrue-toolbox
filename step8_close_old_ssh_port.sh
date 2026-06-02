#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/work/01-root-ssh.sh")
text = path.read_text()

if 'SSH_STATE_FILE=' not in text:
    text = text.replace(
        'source "$BASE_DIR/lib/ui.sh"\n',
        'source "$BASE_DIR/lib/ui.sh"\n\nSSH_STATE_FILE="/opt/viptrue-toolbox/state/ssh-port-change.env"\n'
    )

old_success = '''echo -e "${YELLOW}Backup file:${NC} ${backup_file}"
        echo
        echo "Now open a NEW terminal and test:"
        echo
        echo "ssh root@YOUR_SERVER_IP -p ${new_port}"
        echo
        echo "If the new connection works, you can later remove/deny the old SSH port from UFW."'''

new_success = '''echo -e "${YELLOW}Backup file:${NC} ${backup_file}"
        echo

        mkdir -p "$(dirname "$SSH_STATE_FILE")"
        {
          echo "OLD_SSH_PORT=${current_port}"
          echo "NEW_SSH_PORT=${new_port}"
          echo "CHANGED_AT=$(date -Is)"
        } > "$SSH_STATE_FILE"

        echo "Now open a NEW terminal and test:"
        echo
        echo "ssh root@YOUR_SERVER_IP -p ${new_port}"
        echo
        echo "After successful login with the new port, run this toolbox again and use:"
        echo "Root / SSH Preparation > Close old SSH port in UFW"'''

if old_success not in text:
    raise SystemExit("Could not find success block in change_ssh_port. File may have changed.")

text = text.replace(old_success, new_success)

close_func = r'''
get_current_session_ssh_port() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "$SSH_CONNECTION" | awk '{print $4}'
  else
    echo ""
  fi
}

close_old_ssh_port_in_ufw() {
  title
  echo -e "${CYAN}Close Old SSH Port in UFW${NC}"
  line
  echo

  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return
  fi

  if [[ ! -f "$SSH_STATE_FILE" ]]; then
    echo -e "${YELLOW}No saved SSH port change state was found.${NC}"
    echo
    echo "Expected file:"
    echo "$SSH_STATE_FILE"
    echo
    echo "This option works after you change SSH port using this toolbox."
    pause
    return
  fi

  # shellcheck disable=SC1090
  source "$SSH_STATE_FILE"

  local old_port="${OLD_SSH_PORT:-}"
  local new_port="${NEW_SSH_PORT:-}"
  local session_port

  session_port="$(get_current_session_ssh_port)"

  echo -e "${YELLOW}Saved SSH port change:${NC}"
  echo "Old SSH port: ${old_port:-UNKNOWN}"
  echo "New SSH port: ${new_port:-UNKNOWN}"
  echo
  echo -e "${YELLOW}Current SSH session server port:${NC}"
  echo "${session_port:-UNKNOWN}"
  echo

  if ! is_valid_port "${old_port:-}" || ! is_valid_port "${new_port:-}"; then
    echo -e "${RED}Saved port values are invalid.${NC}"
    pause
    return
  fi

  if [[ -n "$session_port" && "$session_port" != "$new_port" ]]; then
    echo -e "${RED}Safety check failed.${NC}"
    echo
    echo "You are not connected through the new SSH port yet."
    echo "Current session port: $session_port"
    echo "Expected new port: $new_port"
    echo
    echo "Open a new terminal first and connect with:"
    echo "ssh root@YOUR_SERVER_IP -p ${new_port}"
    echo
    echo "Then run this option again from the new SSH session."
    pause
    return
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}UFW is not installed. Nothing to close in UFW.${NC}"
    pause
    return
  fi

  echo -e "${RED}Warning:${NC}"
  echo "This will close old SSH port ${old_port}/tcp in UFW."
  echo "The new SSH port ${new_port}/tcp will be allowed before closing the old one."
  echo
  read -r -p "Continue? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw allow "${new_port}/tcp" || true

      # Remove old allow rule if it exists.
      ufw --force delete allow "${old_port}/tcp" >/dev/null 2>&1 || true

      # Add explicit deny for old port.
      ufw deny "${old_port}/tcp" || true

      echo
      echo -e "${GREEN}Old SSH port closed in UFW.${NC}"
      echo
      echo "Old SSH port: ${old_port}/tcp -> denied"
      echo "New SSH port: ${new_port}/tcp -> allowed"
      echo

      ufw status numbered || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}
'''

if 'close_old_ssh_port_in_ufw()' not in text:
    marker = '\nwhile true; do\n'
    text = text.replace(marker, close_func + marker)

text = text.replace(
    'echo "5. Change SSH port"\n  echo "0. Back"',
    'echo "5. Change SSH port"\n  echo "6. Close old SSH port in UFW"\n  echo "0. Back"'
)

text = text.replace(
    'read -r -p "Enter your choice [0-5]: " choice',
    'read -r -p "Enter your choice [0-6]: " choice'
)

text = text.replace(
    '''    5)
      change_ssh_port
      ;;
    0)''',
    '''    5)
      change_ssh_port
      ;;
    6)
      close_old_ssh_port_in_ufw
      ;;
    0)'''
)

path.write_text(text)
PY

chmod +x modules/work/01-root-ssh.sh
bash -n modules/work/01-root-ssh.sh

echo
echo "✅ Step 8 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add close old SSH port option' && git push"

