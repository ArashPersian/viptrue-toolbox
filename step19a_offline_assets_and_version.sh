#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p scripts modules/utility assets/sing-box

# Set new version
echo "0.1.1" > VERSION

# Add version helper
cat > scripts/bump-version.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

VERSION_FILE="VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "0.1.0" > "$VERSION_FILE"
fi

current="$(cat "$VERSION_FILE" | tr -d '[:space:]')"

IFS='.' read -r major minor patch <<< "$current"

major="${major:-0}"
minor="${minor:-1}"
patch="${patch:-0}"

mode="${1:-patch}"

case "$mode" in
  patch)
    patch=$((patch + 1))
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  set)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: ./scripts/bump-version.sh set 0.1.2"
      exit 1
    fi
    echo "$2" > "$VERSION_FILE"
    echo "Version set to $2"
    exit 0
    ;;
  *)
    echo "Usage:"
    echo "  ./scripts/bump-version.sh patch"
    echo "  ./scripts/bump-version.sh minor"
    echo "  ./scripts/bump-version.sh major"
    echo "  ./scripts/bump-version.sh set 0.1.2"
    exit 1
    ;;
esac

new="${major}.${minor}.${patch}"
echo "$new" > "$VERSION_FILE"
echo "Version bumped: $current -> $new"
EOF

chmod +x scripts/bump-version.sh

# Make ui.sh read VERSION file dynamically if possible
python3 - <<'PY'
from pathlib import Path
import re

ui = Path("lib/ui.sh")
if not ui.exists():
    raise SystemExit("lib/ui.sh not found")

text = ui.read_text()

if "viptrue_get_version()" not in text:
    text += r'''

viptrue_get_version() {
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$base_dir/VERSION" ]]; then
    cat "$base_dir/VERSION" | tr -d '[:space:]'
  else
    echo "${TOOLBOX_VERSION:-0.1.0}"
  fi
}
'''

# Replace common Version echo patterns if they exist
text = re.sub(
    r'echo -e "\$\{GREEN\}Version:\$\{NC\} \$\{TOOLBOX_VERSION:-[^}]+\}"',
    'echo -e "${GREEN}Version:${NC} $(viptrue_get_version)"',
    text
)

text = re.sub(
    r'echo -e "\$\{GREEN\}Version:\$\{NC\} .*?"',
    'echo -e "${GREEN}Version:${NC} $(viptrue_get_version)"',
    text
)

text = re.sub(
    r'echo "Version: \$\{TOOLBOX_VERSION:-[^}]+\}"',
    'echo "Version: $(viptrue_get_version)"',
    text
)

ui.write_text(text)
PY

# Add Offline Assets module
cat > modules/utility/03-offline-assets.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$BASE_DIR/lib/ui.sh"

ASSETS_DIR="$BASE_DIR/assets"
SINGBOX_ASSETS_DIR="$ASSETS_DIR/sing-box"

TUNNEL_DIR="/opt/viptrue-temp-tunnel"
SINGBOX_TARGET_DIR="$TUNNEL_DIR/bin"
SINGBOX_TARGET_BIN="$SINGBOX_TARGET_DIR/sing-box"

detect_arch() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    i386|i686) echo "386" ;;
    *) echo "" ;;
  esac
}

latest_singbox_version() {
  curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"v?([^"]+)".*/\1/'
}

show_arch() {
  title
  echo -e "${CYAN}System Architecture${NC}"
  line
  echo
  echo "uname -m:"
  uname -m
  echo
  echo "VIPTrue detected arch:"
  detect_arch
  echo
  echo "Most Ubuntu VPS servers are:"
  echo "x86_64 -> amd64"
  echo
  pause
}

cache_singbox_binary() {
  title
  echo -e "${CYAN}Cache sing-box Binary from Official Release${NC}"
  line
  echo

  mkdir -p "$SINGBOX_ASSETS_DIR"

  local arch version asset url checksum_file
  arch="$(detect_arch)"

  if [[ -z "$arch" ]]; then
    echo -e "${RED}Unsupported architecture:${NC} $(uname -m)"
    pause
    return
  fi

  echo "Detected arch: $arch"
  echo
  echo "1. Latest stable"
  echo "2. Custom version"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-2]: " choice

  case "$choice" in
    1)
      echo "Fetching latest version..."
      version="$(latest_singbox_version || true)"
      ;;
    2)
      read -r -p "Enter sing-box version, example 1.13.12: " version
      version="${version#v}"
      ;;
    0)
      return
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      pause
      return
      ;;
  esac

  if [[ -z "${version:-}" ]]; then
    echo -e "${RED}Could not determine version.${NC}"
    pause
    return
  fi

  asset="sing-box-${version}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"

  echo
  echo "Download:"
  echo "$url"
  echo
  read -r -p "Download and cache this asset? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      pause
      return
      ;;
  esac

  apt-get update
  apt-get install -y curl ca-certificates tar gzip sha256sum coreutils 2>/dev/null || apt-get install -y curl ca-certificates tar gzip coreutils

  curl -fL "$url" -o "$SINGBOX_ASSETS_DIR/$asset"

  checksum_file="$SINGBOX_ASSETS_DIR/SHA256SUMS"
  (
    cd "$SINGBOX_ASSETS_DIR"
    sha256sum "$asset" >> "$checksum_file"
  )

  echo "$version" > "$SINGBOX_ASSETS_DIR/VERSION"
  echo "$arch" > "$SINGBOX_ASSETS_DIR/ARCH"

  echo
  echo -e "${GREEN}Cached successfully:${NC}"
  echo "$SINGBOX_ASSETS_DIR/$asset"
  echo
  echo "SHA256:"
  tail -n 1 "$checksum_file"
  echo

  pause
}

install_singbox_from_cache() {
  title
  echo -e "${CYAN}Install sing-box from Local Cache${NC}"
  line
  echo

  local arch version asset tmpdir extracted_dir
  arch="$(detect_arch)"

  if [[ -f "$SINGBOX_ASSETS_DIR/VERSION" ]]; then
    version="$(cat "$SINGBOX_ASSETS_DIR/VERSION" | tr -d '[:space:]')"
  else
    echo -e "${RED}No cached VERSION found.${NC}"
    echo "Run: Cache sing-box binary first."
    pause
    return
  fi

  asset="sing-box-${version}-linux-${arch}.tar.gz"

  if [[ ! -f "$SINGBOX_ASSETS_DIR/$asset" ]]; then
    echo -e "${RED}Cached asset not found:${NC}"
    echo "$SINGBOX_ASSETS_DIR/$asset"
    echo
    echo "Available assets:"
    ls -lah "$SINGBOX_ASSETS_DIR" || true
    pause
    return
  fi

  echo "Install from:"
  echo "$SINGBOX_ASSETS_DIR/$asset"
  echo
  echo "Install target:"
  echo "$SINGBOX_TARGET_BIN"
  echo
  read -r -p "Install now? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      pause
      return
      ;;
  esac

  mkdir -p "$SINGBOX_TARGET_DIR"

  tmpdir="$(mktemp -d)"
  tar -xzf "$SINGBOX_ASSETS_DIR/$asset" -C "$tmpdir"

  extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -name "sing-box-${version}-linux-${arch}" | head -n 1)"

  if [[ -z "$extracted_dir" || ! -f "$extracted_dir/sing-box" ]]; then
    echo -e "${RED}sing-box binary not found inside archive.${NC}"
    rm -rf "$tmpdir"
    pause
    return
  fi

  cp "$extracted_dir/sing-box" "$SINGBOX_TARGET_BIN"
  chmod +x "$SINGBOX_TARGET_BIN"

  mkdir -p "$TUNNEL_DIR/state"
  echo "$version" > "$TUNNEL_DIR/state/sing-box.version"

  rm -rf "$tmpdir"

  echo
  echo -e "${GREEN}sing-box installed from local cache.${NC}"
  "$SINGBOX_TARGET_BIN" version || true
  echo

  pause
}

build_offline_bundle() {
  title
  echo -e "${CYAN}Build Portable Offline Bundle${NC}"
  line
  echo

  mkdir -p "$ASSETS_DIR"

  local bundle_name
  bundle_name="viptrue-offline-assets-$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo 0.1.0).tar.gz"

  echo "This will create:"
  echo "$BASE_DIR/$bundle_name"
  echo
  echo "Included:"
  echo "- assets/sing-box/"
  echo "- VERSION"
  echo
  read -r -p "Build bundle? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      pause
      return
      ;;
  esac

  tar -czf "$BASE_DIR/$bundle_name" \
    -C "$BASE_DIR" \
    VERSION \
    assets/sing-box

  echo
  echo -e "${GREEN}Bundle created:${NC}"
  echo "$BASE_DIR/$bundle_name"
  echo
  ls -lh "$BASE_DIR/$bundle_name"
  echo

  pause
}

show_cached_assets() {
  title
  echo -e "${CYAN}Cached Offline Assets${NC}"
  line
  echo

  echo "Assets directory:"
  echo "$ASSETS_DIR"
  echo

  if [[ -d "$SINGBOX_ASSETS_DIR" ]]; then
    echo "sing-box assets:"
    ls -lah "$SINGBOX_ASSETS_DIR"
  else
    echo "No sing-box assets cached yet."
  fi

  echo
  pause
}

while true; do
  title
  echo -e "${CYAN}Offline Assets / Local Installer${NC}"
  line
  echo
  echo "1. Show system architecture"
  echo "2. Show cached assets"
  echo "3. Cache sing-box binary from official release"
  echo "4. Install sing-box from local cache"
  echo "5. Build portable offline bundle"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-5]: " choice

  case "$choice" in
    1) show_arch ;;
    2) show_cached_assets ;;
    3) cache_singbox_binary ;;
    4) install_singbox_from_cache ;;
    5) build_offline_bundle ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
EOF

chmod +x modules/utility/03-offline-assets.sh

# Patch Utility menu to include Offline Assets
python3 - <<'PY'
from pathlib import Path
import re

candidates = [
    Path("menus/utility.sh"),
    Path("modules/utility.sh"),
    Path("menus/work.sh"),
]

target = None
for p in candidates:
    if p.exists():
        t = p.read_text()
        if "Temporary Tunnel" in t or "Temporary Proxy" in t or "Factory" in t:
            target = p
            break

if target is None:
    raise SystemExit("Could not find Utility menu file.")

text = target.read_text()
original = text

if "Offline Assets / Local Installer" not in text:
    text = text.replace(
        'echo "2. Temporary Tunnel / Proxy for Installations"',
        'echo "2. Temporary Tunnel / Proxy for Installations"\n  echo "3. Offline Assets / Local Installer"'
    )

    text = text.replace(
        'read -r -p "Enter your choice [0-2]: " choice',
        'read -r -p "Enter your choice [0-3]: " choice'
    )

    text = re.sub(
        r'(\s*2\)\s*\n\s*bash .*02-temp-tunnel\.sh\s*\n\s*;;)',
        r'\1\n    3)\n      bash "$BASE_DIR/modules/utility/03-offline-assets.sh"\n      ;;',
        text,
        count=1
    )

if text == original:
    print(f"No changes applied to {target}; maybe already patched or structure is different.")
else:
    target.write_text(text)
    print(f"Patched utility menu: {target}")
PY

# Syntax checks
find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 19-A completed successfully."
echo "Version is now: $(cat VERSION)"
echo
echo "Now run:"
echo "git add ."
echo "git commit -m 'Add offline assets installer and bump version to 0.1.1'"
echo "git push"
