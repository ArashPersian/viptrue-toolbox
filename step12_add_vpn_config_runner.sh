#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p menus modules/utility

cat > menus/utility.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

while true; do
  title
  echo -e "${CYAN}Utility Tools${NC}"
  echo
  echo "1. Server Factory-like Reset"
  echo "2. Isolated VPN Config Runner"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-2]: " choice

  case "$choice" in
    1)
      bash "$BASE_DIR/modules/utility/01-factory-reset.sh"
      ;;
    2)
      bash "$BASE_DIR/modules/utility/02-vpn-runner.sh"
      ;;
    0)
      break
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      sleep 1
      ;;
  esac
done
EOF

cat > modules/utility/02-vpn-runner.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

RUNNER_DIR="/opt/viptrue-vpn-runner"
BIN_DIR="$RUNNER_DIR/bin"
CONFIG_DIR="$RUNNER_DIR/configs"
LOG_DIR="$RUNNER_DIR/logs"
XRAY_BIN="$BIN_DIR/xray"
CONFIG_FILE="$CONFIG_DIR/xray-config.json"
SERVICE_NAME="viptrue-xray-runner"
PG_ENV_FILE="/opt/pg-node/.env"

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return 1
  fi
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

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

setup_dirs() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR"
}

get_arch_asset() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64)
      echo "Xray-linux-64.zip"
      ;;
    aarch64|arm64)
      echo "Xray-linux-arm64-v8a.zip"
      ;;
    armv7l|armv7)
      echo "Xray-linux-arm32-v7a.zip"
      ;;
    *)
      echo ""
      ;;
  esac
}

install_xray_local() {
  title
  echo -e "${CYAN}Install / Update Local Xray Binary${NC}"
  line
  echo

  ensure_root || return
  setup_dirs

  local asset url tmpdir

  asset="$(get_arch_asset)"

  if [[ -z "$asset" ]]; then
    echo -e "${RED}Unsupported CPU architecture:${NC} $(uname -m)"
    pause
    return
  fi

  url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"
  tmpdir="$(mktemp -d)"

  echo "This installs Xray locally for VIPTrue VPN Runner only."
  echo "It will NOT install or modify system xray.service."
  echo
  echo "Download:"
  echo "$url"
  echo
  read -r -p "Continue? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      apt-get update
      apt-get install -y curl unzip ca-certificates

      curl -fL "$url" -o "$tmpdir/xray.zip"
      unzip -o "$tmpdir/xray.zip" -d "$tmpdir/xray"

      if [[ ! -f "$tmpdir/xray/xray" ]]; then
        echo -e "${RED}xray binary not found in downloaded archive.${NC}"
        rm -rf "$tmpdir"
        pause
        return
      fi

      cp "$tmpdir/xray/xray" "$XRAY_BIN"
      chmod +x "$XRAY_BIN"

      cp "$tmpdir/xray/geoip.dat" "$BIN_DIR/geoip.dat" 2>/dev/null || true
      cp "$tmpdir/xray/geosite.dat" "$BIN_DIR/geosite.dat" 2>/dev/null || true

      rm -rf "$tmpdir"

      echo
      echo -e "${GREEN}Local Xray installed:${NC}"
      "$XRAY_BIN" version || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

collect_config_ports() {
  local file="${1:-$CONFIG_FILE}"

  [[ -f "$file" ]] || return 0

  grep -aEho '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$file" 2>/dev/null \
    | grep -Eo '[0-9]{1,5}' \
    | while read -r port; do
        if is_valid_port "$port"; then
          echo "$port"
        fi
      done | sort -n -u
}

collect_listening_ports() {
  ss -H -tuln 2>/dev/null | awk '{print $5}' | awk -F: '{print $NF}' | tr -d '[]' \
    | grep -E '^[0-9]+$' | sort -n -u
}

show_pasarguard_ports() {
  local node_port api_port
  node_port="$(get_env_value "SERVICE_PORT" || true)"
  api_port="$(get_env_value "API_PORT" || true)"

  echo "PasarGuard SERVICE_PORT / Node Port: ${node_port:-UNKNOWN}"
  echo "PasarGuard API_PORT: ${api_port:-UNKNOWN}"
}

scan_port_conflicts() {
  local file="${1:-$CONFIG_FILE}"
  local node_port api_port ports conflicts=0

  node_port="$(get_env_value "SERVICE_PORT" || true)"
  api_port="$(get_env_value "API_PORT" || true)"
  ports="$(collect_config_ports "$file" || true)"

  if [[ -z "$ports" ]]; then
    echo -e "${YELLOW}No ports detected inside config.${NC}"
    return 0
  fi

  echo -e "${YELLOW}Detected config ports:${NC}"
  echo "$ports"
  echo

  echo -e "${YELLOW}PasarGuard protected ports:${NC}"
  show_pasarguard_ports
  echo

  echo "$ports" | while read -r port; do
    if [[ -n "${node_port:-}" && "$port" == "$node_port" ]]; then
      echo -e "${RED}CONFLICT:${NC} config port $port equals PasarGuard SERVICE_PORT."
    fi

    if [[ -n "${api_port:-}" && "$port" == "$api_port" ]]; then
      echo -e "${RED}CONFLICT:${NC} config port $port equals PasarGuard API_PORT."
    fi
  done

  for port in $ports; do
    if [[ -n "${node_port:-}" && "$port" == "$node_port" ]]; then
      conflicts=1
    fi
    if [[ -n "${api_port:-}" && "$port" == "$api_port" ]]; then
      conflicts=1
    fi

    if collect_listening_ports | grep -qx "$port"; then
      if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${RED}CONFLICT:${NC} port $port is already listening on this server."
        conflicts=1
      fi
    fi
  done

  if [[ "$conflicts" -eq 1 ]]; then
    return 1
  fi

  echo -e "${GREEN}No hard port conflicts detected.${NC}"
  return 0
}

import_xray_config() {
  title
  echo -e "${CYAN}Import Xray/V2Ray JSON Config${NC}"
  line
  echo

  ensure_root || return
  setup_dirs

  echo "Enter the full path of your Xray/V2Ray JSON config."
  echo "Example: /root/config.json"
  echo
  read -r -p "Config path: " source_config

  if [[ ! -f "$source_config" ]]; then
    echo -e "${RED}File not found:${NC} $source_config"
    pause
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    if ! jq empty "$source_config" >/dev/null 2>&1; then
      echo -e "${RED}Invalid JSON config.${NC}"
      pause
      return
    fi
  else
    echo -e "${YELLOW}jq not installed. JSON syntax check skipped.${NC}"
  fi

  echo
  echo -e "${YELLOW}Scanning port conflicts before import...${NC}"
  if ! scan_port_conflicts "$source_config"; then
    echo
    echo -e "${RED}Import refused because of port conflict with PasarGuard or active service.${NC}"
    echo "Change config ports first, then import again."
    pause
    return
  fi

  cp "$source_config" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"

  echo
  echo -e "${GREEN}Config imported to:${NC}"
  echo "$CONFIG_FILE"
  echo

  pause
}

validate_xray_config() {
  title
  echo -e "${CYAN}Validate Xray Config${NC}"
  line
  echo

  if [[ ! -x "$XRAY_BIN" ]]; then
    echo -e "${RED}Local Xray binary not found.${NC}"
    echo "Run option 2 first."
    pause
    return 1
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Config file not found:${NC} $CONFIG_FILE"
    pause
    return 1
  fi

  echo -e "${YELLOW}Port conflict scan:${NC}"
  if ! scan_port_conflicts "$CONFIG_FILE"; then
    echo
    echo -e "${RED}Validation stopped because of port conflict.${NC}"
    pause
    return 1
  fi

  echo
  echo -e "${YELLOW}Testing Xray config:${NC}"
  if "$XRAY_BIN" run -test -config "$CONFIG_FILE"; then
    echo -e "${GREEN}Xray config test passed.${NC}"
  else
    echo -e "${RED}Xray config test failed.${NC}"
    pause
    return 1
  fi

  pause
}

write_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF2
[Unit]
Description=VIPTrue Isolated Xray/V2Ray Config Runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${RUNNER_DIR}
Environment=XRAY_LOCATION_ASSET=${BIN_DIR}
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
}

allow_runner_ports_ufw() {
  local ports
  ports="$(collect_config_ports "$CONFIG_FILE" || true)"

  if [[ -z "$ports" ]]; then
    return
  fi

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      echo
      echo -e "${YELLOW}UFW is active.${NC}"
      echo "Detected runner config ports:"
      echo "$ports"
      echo
      read -r -p "Allow these ports as TCP+UDP in UFW? [y/N]: " confirm

      case "$confirm" in
        y|Y|yes|YES)
          for port in $ports; do
            ufw allow "${port}/tcp" || true
            ufw allow "${port}/udp" || true
            echo -e "${GREEN}Allowed ${port}/tcp and ${port}/udp.${NC}"
          done
          ;;
        *)
          echo -e "${YELLOW}UFW port allow skipped.${NC}"
          ;;
      esac
    fi
  fi
}

start_runner() {
  title
  echo -e "${CYAN}Start Isolated VPN Runner${NC}"
  line
  echo

  ensure_root || return

  if [[ ! -x "$XRAY_BIN" ]]; then
    echo -e "${RED}Local Xray binary not found.${NC}"
    echo "Run option 2 first."
    pause
    return
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Config file not found:${NC} $CONFIG_FILE"
    echo "Run option 3 first."
    pause
    return
  fi

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  echo -e "${YELLOW}Checking conflicts...${NC}"
  if ! scan_port_conflicts "$CONFIG_FILE"; then
    echo
    echo -e "${RED}Runner will not start because of port conflict.${NC}"
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Testing config...${NC}"
  if ! "$XRAY_BIN" run -test -config "$CONFIG_FILE"; then
    echo -e "${RED}Xray config test failed. Runner not started.${NC}"
    pause
    return
  fi

  allow_runner_ports_ufw
  write_systemd_service

  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"

  sleep 1

  echo
  systemctl status "$SERVICE_NAME" --no-pager || true
  echo
  echo -e "${GREEN}Runner start command completed.${NC}"

  pause
}

stop_runner() {
  title
  echo -e "${CYAN}Stop Isolated VPN Runner${NC}"
  line
  echo

  ensure_root || return

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  echo -e "${GREEN}Runner stopped.${NC}"

  pause
}

show_status() {
  title
  echo -e "${CYAN}Isolated VPN Runner Status${NC}"
  line
  echo

  echo -e "${YELLOW}Runner directory:${NC}"
  echo "$RUNNER_DIR"
  echo

  echo -e "${YELLOW}Local Xray binary:${NC}"
  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" version || true
  else
    echo "Not installed"
  fi
  echo

  echo -e "${YELLOW}Config file:${NC}"
  if [[ -f "$CONFIG_FILE" ]]; then
    echo "$CONFIG_FILE"
    echo
    echo "Detected config ports:"
    collect_config_ports "$CONFIG_FILE" || true
  else
    echo "Not imported"
  fi
  echo

  echo -e "${YELLOW}PasarGuard ports:${NC}"
  show_pasarguard_ports
  echo

  echo -e "${YELLOW}Service status:${NC}"
  systemctl status "$SERVICE_NAME" --no-pager || true
  echo

  pause
}

show_logs() {
  title
  echo -e "${CYAN}Isolated VPN Runner Logs${NC}"
  line
  echo

  journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true

  pause
}

remove_runner() {
  title
  echo -e "${CYAN}Remove Isolated VPN Runner${NC}"
  line
  echo

  ensure_root || return

  echo -e "${RED}This removes only VIPTrue VPN Runner service/config/binary.${NC}"
  echo "It will NOT touch PasarGuard."
  echo
  read -r -p "Continue? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload
      rm -rf "$RUNNER_DIR"
      echo -e "${GREEN}VIPTrue VPN Runner removed.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

show_plan() {
  title
  echo -e "${CYAN}Isolated VPN Config Runner Plan${NC}"
  line
  echo

  echo "Purpose:"
  echo "- Run extra VPN configs on the same server without touching PasarGuard."
  echo
  echo "Isolation method:"
  echo "- Separate directory: $RUNNER_DIR"
  echo "- Separate systemd service: ${SERVICE_NAME}.service"
  echo "- Separate local Xray binary"
  echo "- Separate config file"
  echo
  echo "Safety checks:"
  echo "- Detect config ports"
  echo "- Compare against PasarGuard SERVICE_PORT and API_PORT"
  echo "- Refuse start on hard port conflict"
  echo "- Do not modify pg-node-service"
  echo
  echo "Currently supported:"
  echo "- Xray/V2Ray JSON configs"
  echo
  echo "Planned later:"
  echo "- WireGuard"
  echo "- Hysteria2"
  echo "- TUIC"
  echo "- Sing-box"
  echo

  pause
}

while true; do
  title
  echo -e "${CYAN}Isolated VPN Config Runner${NC}"
  echo
  echo "1. Show runner plan"
  echo "2. Install / Update local Xray binary"
  echo "3. Import Xray/V2Ray JSON config"
  echo "4. Validate config and scan conflicts"
  echo "5. Start runner"
  echo "6. Stop runner"
  echo "7. Show runner status"
  echo "8. Show runner logs"
  echo "9. Remove runner only"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-9]: " choice

  case "$choice" in
    1) show_plan ;;
    2) install_xray_local ;;
    3) import_xray_config ;;
    4) validate_xray_config ;;
    5) start_runner ;;
    6) stop_runner ;;
    7) show_status ;;
    8) show_logs ;;
    9) remove_runner ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF

chmod +x menus/utility.sh modules/utility/02-vpn-runner.sh

bash -n menus/utility.sh
bash -n modules/utility/02-vpn-runner.sh

echo
echo "✅ Step 12 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add isolated VPN config runner utility' && git push"
