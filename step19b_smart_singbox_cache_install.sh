#!/usr/bin/env bash
set -Eeuo pipefail

cd ~/viptrue-toolbox

echo "0.1.2" > VERSION

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

if 'SINGBOX_ASSETS_DIR=' not in text:
    text = text.replace(
        'SING_BOX_BIN="$BIN_DIR/sing-box"\n',
        'SING_BOX_BIN="$BIN_DIR/sing-box"\n'
        'SINGBOX_ASSETS_DIR="$BASE_DIR/assets/sing-box"\n'
    )

def replace_bash_function(src, func_name, new_func):
    marker = f"{func_name}()"
    start = src.find(marker)
    if start == -1:
        raise SystemExit(f"Function not found: {func_name}")

    brace_start = src.find("{", start)
    if brace_start == -1:
        raise SystemExit(f"Opening brace not found: {func_name}")

    depth = 0
    i = brace_start
    in_single = False
    in_double = False
    escape = False

    while i < len(src):
        ch = src[i]

        if escape:
            escape = False
            i += 1
            continue

        if ch == "\\":
            escape = True
            i += 1
            continue

        if ch == "'" and not in_double:
            in_single = not in_single
            i += 1
            continue

        if ch == '"' and not in_single:
            in_double = not in_double
            i += 1
            continue

        if not in_single and not in_double:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    while end < len(src) and src[end] in "\n\r":
                        end += 1
                    return src[:start] + new_func.rstrip() + "\n\n" + src[end:]

        i += 1

    raise SystemExit(f"Could not find function end: {func_name}")

new_func = r'''install_singbox_isolated() {
  title
  echo -e "${CYAN}Install / Update sing-box${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  local arch version asset url tmpdir extracted_dir choice
  arch="$(detect_arch)"

  if [[ -z "$arch" ]]; then
    echo -e "${RED}Unsupported architecture:${NC} $(uname -m)"
    pause
    return
  fi

  echo -e "${YELLOW}Detected architecture:${NC} $arch"
  echo

  local cached_version=""
  local cached_asset=""

  if [[ -f "$SINGBOX_ASSETS_DIR/VERSION" ]]; then
    cached_version="$(cat "$SINGBOX_ASSETS_DIR/VERSION" | tr -d '[:space:]')"
    cached_asset="$SINGBOX_ASSETS_DIR/sing-box-${cached_version}-linux-${arch}.tar.gz"
  fi

  if [[ -n "$cached_version" && -f "$cached_asset" ]]; then
    echo -e "${GREEN}Local cache found:${NC}"
    echo "$cached_asset"
    echo
  else
    echo -e "${YELLOW}No matching local cache found for arch:${NC} $arch"
    echo
  fi

  echo "1. Smart install: local cache first, online latest fallback"
  echo "2. Force install from local cache"
  echo "3. Online install latest official release"
  echo "4. Online install custom version"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-4]: " choice

  install_from_cache_inner() {
    local cv ca td ed

    cv="$(cat "$SINGBOX_ASSETS_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    ca="$SINGBOX_ASSETS_DIR/sing-box-${cv}-linux-${arch}.tar.gz"

    if [[ -z "$cv" || ! -f "$ca" ]]; then
      echo -e "${RED}No valid local cache found.${NC}"
      echo "Expected:"
      echo "$ca"
      return 1
    fi

    echo
    echo -e "${YELLOW}Installing sing-box from local cache...${NC}"
    echo "$ca"

    mkdir -p "$BIN_DIR" "$STATE_DIR"

    td="$(mktemp -d)"
    tar -xzf "$ca" -C "$td"

    ed="$(find "$td" -maxdepth 1 -type d -name "sing-box-${cv}-linux-${arch}" | head -n 1)"

    if [[ -z "$ed" || ! -f "$ed/sing-box" ]]; then
      echo -e "${RED}sing-box binary not found inside cached archive.${NC}"
      rm -rf "$td"
      return 1
    fi

    cp "$ed/sing-box" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    echo "$cv" > "$STATE_DIR/sing-box.version"

    rm -rf "$td"

    echo
    echo -e "${GREEN}sing-box installed from local cache.${NC}"
    "$SING_BOX_BIN" version || true
    return 0
  }

  install_online_inner() {
    local mode="$1"

    if [[ "$mode" == "latest" ]]; then
      echo -e "${YELLOW}Fetching latest sing-box version...${NC}"
      version="$(get_latest_singbox_version || true)"
    else
      read -r -p "Enter version, example 1.13.12: " version
      version="${version#v}"
    fi

    if [[ -z "${version:-}" ]]; then
      echo -e "${RED}Could not detect sing-box version.${NC}"
      return 1
    fi

    asset="sing-box-${version}-linux-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"

    echo
    echo -e "${YELLOW}Online download URL:${NC}"
    echo "$url"
    echo
    echo "Install target:"
    echo "$SING_BOX_BIN"
    echo
    read -r -p "Continue online install? [y/N]: " confirm

    case "$confirm" in
      y|Y|yes|YES) ;;
      *)
        echo -e "${YELLOW}Cancelled.${NC}"
        return 1
        ;;
    esac

    apt-get update
    apt-get install -y curl tar gzip ca-certificates

    tmpdir="$(mktemp -d)"
    curl -fL "$url" -o "$tmpdir/sing-box.tar.gz"
    tar -xzf "$tmpdir/sing-box.tar.gz" -C "$tmpdir"

    extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -name "sing-box-${version}-linux-${arch}" | head -n 1)"

    if [[ -z "$extracted_dir" || ! -f "$extracted_dir/sing-box" ]]; then
      echo -e "${RED}sing-box binary not found after extraction.${NC}"
      rm -rf "$tmpdir"
      return 1
    fi

    mkdir -p "$BIN_DIR" "$STATE_DIR"
    cp "$extracted_dir/sing-box" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    echo "$version" > "$STATE_DIR/sing-box.version"

    rm -rf "$tmpdir"

    echo
    echo -e "${GREEN}sing-box installed successfully from online release.${NC}"
    "$SING_BOX_BIN" version || true
    return 0
  }

  case "$choice" in
    1)
      if install_from_cache_inner; then
        :
      else
        echo
        echo -e "${YELLOW}Local cache failed or not available. Falling back to online latest.${NC}"
        echo
        install_online_inner latest || true
      fi
      ;;
    2)
      install_from_cache_inner || true
      ;;
    3)
      install_online_inner latest || true
      ;;
    4)
      install_online_inner custom || true
      ;;
    0)
      return
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      ;;
  esac

  pause
}'''

text = replace_bash_function(text, "install_singbox_isolated", new_func)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh

find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

python3 -m py_compile modules/utility/link_proxy_tools.py

echo
echo "✅ Step 19-B completed successfully."
echo "Version is now:"
cat VERSION
echo
echo "Now run:"
echo "git add . && git commit -m 'Use local sing-box cache before online install and bump version to 0.1.2' && git push"
