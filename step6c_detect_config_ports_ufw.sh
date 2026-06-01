#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"

cd "$PROJECT_DIR"

cat > modules/work/03-ufw-firewall.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

PG_ENV_FILE="/opt/pg-node/.env"

get_env_value() {
  local key="$1"

  if [[ -f "$PG_ENV_FILE" ]]; then
    awk -F= -v k="$key" '
      $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
        val=$0
        sub(/^[^=]*=/, "", val)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        gsub(/^"/, "", val)
        gsub(/"$/, "", val)
        gsub(/^'\''/, "", val)
        gsub(/'\''$/, "", val)
        print val
      }
    ' "$PG_ENV_FILE" | tail -n 1
  fi
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

ensure_ufw_installed() {
  if command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  echo -e "${YELLOW}UFW is not installed.${NC}"
  read -r -p "Install UFW now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      apt-get update
      apt-get install -y ufw
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      return 1
      ;;
  esac
}

get_ssh_port() {
  local port=""

  port="$(awk '
    /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
      print $2
      exit
    }
  ' /etc/ssh/sshd_config 2>/dev/null || true)"

  if [[ -z "$port" && -d /etc/ssh/sshd_config.d ]]; then
    port="$(awk '
      /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
        print $2
        exit
      }
    ' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
  fi

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

  echo "${port:-22}"
}

collect_pasarguard_ports() {
  local node_port api_port
  local tmp_file
  tmp_file="$(mktemp)"

  node_port="$(get_env_value "SERVICE_PORT" || true)"
  api_port="$(get_env_value "API_PORT" || true)"

  if is_valid_port "${node_port:-}"; then
    echo "${node_port}|tcp,udp|Node Port / SERVICE_PORT|${PG_ENV_FILE}" >> "$tmp_file"
  fi

  if is_valid_port "${api_port:-}"; then
    echo "${api_port}|tcp|API Port / API_PORT|${PG_ENV_FILE}" >> "$tmp_file"
  fi

  local scan_paths=(
    "/opt/pg-node"
    "/var/lib/pg-node"
    "/etc/pg-node"
    "/etc/xray"
    "/usr/local/etc/xray"
  )

  local path
  for path in "${scan_paths[@]}"; do
    [[ -e "$path" ]] || continue

    grep -RhsIE \
      '"port"[[:space:]]*:[[:space:]]*[0-9]+|^[[:space:]]*port[[:space:]]*[:=][[:space:]]*[0-9]+|PORT[[:space:]]*=[[:space:]]*[0-9]+' \
      "$path" 2>/dev/null \
      | grep -Eo '[0-9]{2,5}' \
      | while read -r port; do
          if is_valid_port "$port"; then
            if [[ "$port" != "${api_port:-}" ]]; then
              echo "${port}|tcp,udp|Detected config/inbound port|${path}" >> "$tmp_file"
            fi
          fi
        done
  done

  awk -F'|' '!seen[$1 FS $2]++' "$tmp_file" | sort -n -t'|' -k1,1

  rm -f "$tmp_file"
}

show_status() {
  title
  echo -e "${CYAN}UFW Firewall Status${NC}"
  line
  echo

  if ! command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}UFW is not installed.${NC}"
    echo
  else
    echo -e "${YELLOW}UFW status:${NC}"
    ufw status verbose || true
    echo

    echo -e "${YELLOW}UFW numbered rules:${NC}"
    ufw status numbered || true
    echo
  fi

  echo -e "${YELLOW}Detected SSH port:${NC}"
  get_ssh_port
  echo

  echo -e "${YELLOW}Listening TCP/UDP ports:${NC}"
  ss -tulpn || true
  echo

  echo -e "${YELLOW}PasarGuard .env values:${NC}"
  if [[ -f "$PG_ENV_FILE" ]]; then
    grep -E '^(SERVICE_PORT|API_PORT)[[:space:]]*=' "$PG_ENV_FILE" || true
  else
    echo "$PG_ENV_FILE not found."
  fi
  echo

  echo -e "${YELLOW}Detected PasarGuard/config ports:${NC}"
  collect_pasarguard_ports || true
  echo

  pause
}

allow_ssh_port() {
  title
  echo -e "${CYAN}Allow Current SSH Port${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  local ssh_port
  ssh_port="$(get_ssh_port)"

  echo -e "${YELLOW}Detected SSH port:${NC} $ssh_port"
  echo
  echo "This is important before enabling UFW, otherwise you may lock yourself out."
  echo

  read -r -p "Allow TCP port ${ssh_port}? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw allow "${ssh_port}/tcp"
      echo -e "${GREEN}Allowed SSH port ${ssh_port}/tcp.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

allow_pasarguard_ports() {
  title
  echo -e "${CYAN}Allow PasarGuard Node + Config Ports${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  local detected_ports
  detected_ports="$(collect_pasarguard_ports || true)"

  if [[ -z "$detected_ports" ]]; then
    echo -e "${RED}No PasarGuard/config ports were detected.${NC}"
    echo
    echo "Checked:"
    echo "- $PG_ENV_FILE"
    echo "- /opt/pg-node"
    echo "- /var/lib/pg-node"
    echo "- /etc/pg-node"
    echo "- /etc/xray"
    echo "- /usr/local/etc/xray"
    pause
    return
  fi

  echo -e "${YELLOW}Detected ports to allow:${NC}"
  echo
  echo "$detected_ports" | while IFS='|' read -r port proto label source; do
    echo "- Port: $port | Protocol: $proto | Type: $label | Source: $source"
  done
  echo

  echo -e "${YELLOW}Rules:${NC}"
  echo "- Node Port / SERVICE_PORT: TCP + UDP"
  echo "- API Port / API_PORT: TCP only"
  echo "- Detected config/inbound ports: TCP + UDP"
  echo

  read -r -p "Allow these ports in UFW? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      echo "$detected_ports" | while IFS='|' read -r port proto label source; do
        if [[ "$proto" == *"tcp"* ]]; then
          ufw allow "${port}/tcp"
          echo -e "${GREEN}Allowed ${port}/tcp  (${label})${NC}"
        fi

        if [[ "$proto" == *"udp"* ]]; then
          ufw allow "${port}/udp"
          echo -e "${GREEN}Allowed ${port}/udp  (${label})${NC}"
        fi
      done

      echo
      echo -e "${GREEN}Done.${NC}"
      ufw status numbered || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

allow_custom_tcp_port() {
  title
  echo -e "${CYAN}Allow Custom TCP Port${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  read -r -p "Enter TCP port to allow: " port

  if ! is_valid_port "$port"; then
    echo -e "${RED}Invalid port.${NC}"
    pause
    return
  fi

  read -r -p "Allow TCP port ${port}? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw allow "${port}/tcp"
      echo -e "${GREEN}Allowed ${port}/tcp.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

disable_ufw() {
  title
  echo -e "${CYAN}Disable UFW${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  echo -e "${YELLOW}Current UFW status:${NC}"
  ufw status verbose || true
  echo

  echo -e "${RED}Warning:${NC} This will disable UFW firewall."
  read -r -p "Disable UFW now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw disable
      echo -e "${GREEN}UFW disabled.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

enable_ufw_safely() {
  title
  echo -e "${CYAN}Enable UFW Safely${NC}"
  line
  echo

  ensure_ufw_installed || { pause; return; }

  local ssh_port
  ssh_port="$(get_ssh_port)"

  echo -e "${YELLOW}Before enabling UFW, this module will allow SSH port:${NC} $ssh_port"
  echo

  read -r -p "Continue and enable UFW? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      ufw allow "${ssh_port}/tcp"
      ufw --force enable
      echo -e "${GREEN}UFW enabled safely. SSH port ${ssh_port}/tcp is allowed.${NC}"
      echo
      ufw status verbose || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

while true; do
  title
  echo -e "${CYAN}UFW Firewall${NC}"
  echo
  echo "1. Show UFW status and ports"
  echo "2. Allow current SSH port"
  echo "3. Allow PasarGuard Node + config ports"
  echo "4. Allow custom TCP port"
  echo "5. Disable UFW"
  echo "6. Enable UFW safely"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-6]: " choice

  case "$choice" in
    1) show_status ;;
    2) allow_ssh_port ;;
    3) allow_pasarguard_ports ;;
    4) allow_custom_tcp_port ;;
    5) disable_ufw ;;
    6) enable_ufw_safely ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF

chmod +x modules/work/03-ufw-firewall.sh

bash -n modules/work/03-ufw-firewall.sh

echo
echo "✅ Step 6C completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Detect and allow PasarGuard config ports in UFW' && git push"
