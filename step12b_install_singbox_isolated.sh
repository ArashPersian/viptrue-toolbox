#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

cat > modules/utility/02-temp-tunnel.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export TOOLBOX_VERSION="${TOOLBOX_VERSION:-0.1.0}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

TUNNEL_DIR="/opt/viptrue-temp-tunnel"
BIN_DIR="$TUNNEL_DIR/bin"
CONFIG_DIR="$TUNNEL_DIR/config"
SUBS_DIR="$TUNNEL_DIR/subscriptions"
LOG_DIR="$TUNNEL_DIR/logs"
STATE_DIR="$TUNNEL_DIR/state"

SING_BOX_BIN="$BIN_DIR/sing-box"
SERVICE_NAME="viptrue-temp-tunnel"

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}This module must be run as root.${NC}"
    pause
    return 1
  fi
}

ensure_dirs() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$SUBS_DIR" "$LOG_DIR" "$STATE_DIR"
}

detect_arch() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    armv7l|armv7)
      echo "armv7"
      ;;
    i386|i686)
      echo "386"
      ;;
    *)
      echo ""
      ;;
  esac
}

get_latest_singbox_version() {
  curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"v?([^"]+)".*/\1/'
}

install_singbox_isolated() {
  title
  echo -e "${CYAN}Install / Update sing-box Isolated${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  local arch version asset url tmpdir extracted_dir

  arch="$(detect_arch)"

  if [[ -z "$arch" ]]; then
    echo -e "${RED}Unsupported architecture:${NC} $(uname -m)"
    pause
    return
  fi

  echo -e "${YELLOW}Detected architecture:${NC} $arch"
  echo

  echo "Choose version:"
  echo "1. Latest stable from GitHub releases"
  echo "2. Custom version"
  echo "0. Cancel"
  echo
  read -r -p "Enter your choice [0-2]: " version_choice

  case "$version_choice" in
    1)
      echo -e "${YELLOW}Fetching latest sing-box version...${NC}"
      version="$(get_latest_singbox_version || true)"
      ;;
    2)
      read -r -p "Enter version, example 1.13.12: " version
      version="${version#v}"
      ;;
    0)
      echo -e "${YELLOW}Cancelled.${NC}"
      pause
      return
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      pause
      return
      ;;
  esac

  if [[ -z "${version:-}" ]]; then
    echo -e "${RED}Could not detect sing-box version.${NC}"
    pause
    return
  fi

  asset="sing-box-${version}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"

  echo
  echo -e "${YELLOW}Install target:${NC}"
  echo "$SING_BOX_BIN"
  echo
  echo -e "${YELLOW}Download URL:${NC}"
  echo "$url"
  echo
  echo "This installs sing-box only inside:"
  echo "$TUNNEL_DIR"
  echo
  echo "It will NOT modify PasarGuard or system sing-box service."
  echo

  read -r -p "Continue install/update? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      apt-get update
      apt-get install -y curl tar gzip ca-certificates

      tmpdir="$(mktemp -d)"
      curl -fL "$url" -o "$tmpdir/sing-box.tar.gz"

      tar -xzf "$tmpdir/sing-box.tar.gz" -C "$tmpdir"

      extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -name "sing-box-${version}-linux-${arch}" | head -n 1)"

      if [[ -z "$extracted_dir" || ! -f "$extracted_dir/sing-box" ]]; then
        echo -e "${RED}sing-box binary not found after extraction.${NC}"
        rm -rf "$tmpdir"
        pause
        return
      fi

      cp "$extracted_dir/sing-box" "$SING_BOX_BIN"
      chmod +x "$SING_BOX_BIN"

      echo "$version" > "$STATE_DIR/sing-box.version"

      rm -rf "$tmpdir"

      echo
      echo -e "${GREEN}sing-box installed successfully.${NC}"
      echo
      "$SING_BOX_BIN" version || true
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac

  pause
}

show_status_logs() {
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy Status${NC}"
  line
  echo

  echo -e "${YELLOW}Directory:${NC}"
  echo "$TUNNEL_DIR"
  echo

  echo -e "${YELLOW}sing-box binary:${NC}"
  if [[ -x "$SING_BOX_BIN" ]]; then
    echo "$SING_BOX_BIN"
    "$SING_BOX_BIN" version || true
  else
    echo "Not installed"
  fi
  echo

  echo -e "${YELLOW}Service status:${NC}"
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || echo "Service not created yet."
  echo

  echo -e "${YELLOW}Recent logs:${NC}"
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
  echo

  pause
}

show_plan() {
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  line
  echo

  echo -e "${YELLOW}Purpose:${NC}"
  echo "Temporarily route server installation traffic through a VPN/proxy config."
  echo
  echo "Example use cases:"
  echo "- apt update / apt install"
  echo "- curl / wget downloads"
  echo "- git clone"
  echo "- docker pull"
  echo "- npm / pip / go install"
  echo

  echo -e "${YELLOW}Planned modes:${NC}"
  echo
  echo "1. Proxy Mode"
  echo "   Creates local HTTP/SOCKS proxy."
  echo "   Safer, but only works for apps that use proxy settings."
  echo
  echo "2. TUN Mode"
  echo "   Routes most server traffic through the selected outbound config."
  echo "   Better for installation tasks, but must be started/stopped carefully."
  echo

  echo -e "${YELLOW}Isolation rules:${NC}"
  echo "- Uses separate directory:"
  echo "  $TUNNEL_DIR"
  echo
  echo "- Uses separate service:"
  echo "  ${SERVICE_NAME}.service"
  echo
  echo "- Will NOT modify PasarGuard files:"
  echo "  /opt/pg-node"
  echo "  /var/lib/pg-node"
  echo "  pg-node-service"
  echo

  echo -e "${YELLOW}Current status:${NC}"
  if [[ -x "$SING_BOX_BIN" ]]; then
    echo "sing-box installed:"
    "$SING_BOX_BIN" version || true
  else
    echo "sing-box is not installed yet."
  fi
  echo

  pause
}

coming_soon() {
  local item="$1"
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  line
  echo
  echo -e "${YELLOW}${item}${NC}"
  echo
  echo "This feature is not implemented yet."
  echo "We will add it step by step after approval."
  echo
  pause
}

while true; do
  title
  echo -e "${CYAN}Temporary Tunnel / Proxy for Installations${NC}"
  echo
  echo "1. Show plan"
  echo "2. Install / Update sing-box"
  echo "3. Add single config link"
  echo "4. Add subscription link"
  echo "5. Update subscription"
  echo "6. Select active outbound"
  echo "7. Start Proxy Mode"
  echo "8. Start TUN Mode"
  echo "9. Stop tunnel/proxy"
  echo "10. Show status/logs"
  echo "0. Back"
  echo
  line
  read -r -p "Enter your choice [0-10]: " choice

  case "$choice" in
    1)
      show_plan
      ;;
    2)
      install_singbox_isolated
      ;;
    3)
      coming_soon "Add single config link"
      ;;
    4)
      coming_soon "Add subscription link"
      ;;
    5)
      coming_soon "Update subscription"
      ;;
    6)
      coming_soon "Select active outbound"
      ;;
    7)
      coming_soon "Start Proxy Mode"
      ;;
    8)
      coming_soon "Start TUN Mode"
      ;;
    9)
      coming_soon "Stop tunnel/proxy"
      ;;
    10)
      show_status_logs
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

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12B completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add isolated sing-box installer for temp tunnel' && git push"
