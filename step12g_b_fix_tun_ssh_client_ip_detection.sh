#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

old = r'''get_current_ssh_client_ip() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "$SSH_CONNECTION" | awk '{print $1}'
  else
    echo ""
  fi
}'''

new = r'''get_current_ssh_client_ip() {
  local ip=""

  # Method 1: Standard OpenSSH environment variable.
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="$(echo "$SSH_CONNECTION" | awk '{print $1}')"
  fi

  # Method 2: who am i / who -m output, common in sudo/root sessions.
  if [[ -z "$ip" ]]; then
    ip="$(who am i 2>/dev/null | sed -nE 's/.*\(([^)]+)\).*/\1/p' | head -n 1 || true)"
  fi

  if [[ -z "$ip" ]]; then
    ip="$(who -m 2>/dev/null | sed -nE 's/.*\(([^)]+)\).*/\1/p' | head -n 1 || true)"
  fi

  # Method 3: Detect established sshd connections and choose the remote peer IP.
  if [[ -z "$ip" ]]; then
    ip="$(ss -tnp 2>/dev/null | awk '
      /ESTAB/ && /sshd/ {
        peer=$5
        split(peer,a,":")
        candidate=a[1]

        # IPv6 bracket cleanup
        gsub(/^\[/, "", candidate)
        gsub(/\]$/, "", candidate)

        # Ignore local/private server-side values if possible
        if (candidate != "" && candidate !~ /^127\./ && candidate != "::1") {
          print candidate
          exit
        }
      }
    ' || true)"
  fi

  # Return only IPv4/IPv6-looking values.
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$ip" =~ : ]]; then
    echo "$ip"
  else
    echo ""
  fi
}'''

if old not in text:
    raise SystemExit("Old get_current_ssh_client_ip function not found. File may have changed.")

text = text.replace(old, new)
path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-B completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Fix SSH client IP detection for TUN mode' && git push"
