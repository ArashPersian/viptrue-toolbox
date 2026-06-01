#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/work/03-ufw-firewall.sh")
text = path.read_text()

old = r'''get_ssh_port() {
  local port=""

  port="$(awk '
    /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
      print $2
      exit
    }
  ' /etc/ssh/sshd_config 2>/dev/null || true)"

  if [[ -z "$port" ]]; then
    port="$(ss -tulpn 2>/dev/null | awk '
      /sshd/ && /LISTEN/ {
        split($5,a,":")
        print a[length(a)]
        exit
      }
    ' || true)"
  fi

  echo "${port:-22}"
}'''

new = r'''get_ssh_port() {
  local port=""

  # 1) Read active Port from main sshd_config.
  port="$(awk '
    /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
      print $2
      exit
    }
  ' /etc/ssh/sshd_config 2>/dev/null || true)"

  # 2) Read active Port from sshd_config.d snippets if main config has no active Port.
  if [[ -z "$port" && -d /etc/ssh/sshd_config.d ]]; then
    port="$(awk '
      /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
        print $2
        exit
      }
    ' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
  fi

  # 3) Detect only real public SSH listening ports.
  # Ignore localhost-only ports like 127.0.0.1:6010 or [::1]:6010 from X11 forwarding.
  if [[ -z "$port" ]]; then
    port="$(ss -ltnp 2>/dev/null | awk '
      /sshd/ && /LISTEN/ {
        addr=$4

        if (addr ~ /^127\.0\.0\.1:/) next
        if (addr ~ /^\[::1\]:/) next
        if (addr ~ /^localhost:/) next

        n=split(addr,a,":")
        p=a[n]

        if (p ~ /^[0-9]+$/) {
          print p
          exit
        }
      }
    ' || true)"
  fi

  # 4) Safe default.
  echo "${port:-22}"
}'''

if old not in text:
    raise SystemExit("Old get_ssh_port function not found. File may have changed.")

path.write_text(text.replace(old, new))
PY

chmod +x modules/work/03-ufw-firewall.sh

bash -n modules/work/03-ufw-firewall.sh

echo
echo "✅ Step 6B completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Fix SSH port detection in UFW menu' && git push"
