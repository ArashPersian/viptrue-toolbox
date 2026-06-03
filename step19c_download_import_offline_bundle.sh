#!/usr/bin/env bash
set -Eeuo pipefail

cd ~/viptrue-toolbox

echo "0.1.3" > VERSION

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/03-offline-assets.sh")
text = path.read_text()

if 'REPO_SLUG=' not in text:
    text = text.replace(
        'SINGBOX_ASSETS_DIR="$ASSETS_DIR/sing-box"\n',
        'SINGBOX_ASSETS_DIR="$ASSETS_DIR/sing-box"\n'
        'REPO_SLUG="ArashPersian/viptrue-toolbox"\n'
    )

insert_before = "show_cached_assets() {"

func = r'''download_offline_bundle_from_release() {
  title
  echo -e "${CYAN}Download Offline Bundle from VIPTrue Release${NC}"
  line
  echo

  local version tag bundle url tmp_bundle
  version="$(cat "$BASE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  version="${version:-0.1.3}"
  tag="v$version"
  bundle="viptrue-offline-assets-${version}.tar.gz"

  echo "Repository:"
  echo "$REPO_SLUG"
  echo
  echo "Current local version:"
  echo "$version"
  echo
  echo "Default release tag:"
  echo "$tag"
  echo
  read -r -p "Enter release tag to download [default: $tag]: " input_tag
  tag="${input_tag:-$tag}"

  bundle="viptrue-offline-assets-${tag#v}.tar.gz"
  url="https://github.com/${REPO_SLUG}/releases/download/${tag}/${bundle}"

  echo
  echo "Download URL:"
  echo "$url"
  echo
  echo "Target:"
  echo "$BASE_DIR/$bundle"
  echo
  read -r -p "Download this offline bundle? [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled."
      pause
      return
      ;;
  esac

  apt-get update >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates tar gzip >/dev/null 2>&1 || true

  tmp_bundle="$(mktemp)"
  if ! curl -fL --connect-timeout 20 --max-time 180 "$url" -o "$tmp_bundle"; then
    echo -e "${RED}Download failed.${NC}"
    echo
    echo "Check that this asset exists in GitHub Release:"
    echo "$bundle"
    rm -f "$tmp_bundle"
    pause
    return
  fi

  mv "$tmp_bundle" "$BASE_DIR/$bundle"

  echo
  echo -e "${GREEN}Bundle downloaded:${NC}"
  ls -lh "$BASE_DIR/$bundle"
  echo

  read -r -p "Import this bundle now? [Y/n]: " import_now
  case "$import_now" in
    n|N|no|NO)
      pause
      return
      ;;
  esac

  import_offline_bundle_file "$BASE_DIR/$bundle"
}

import_offline_bundle_file() {
  local bundle_path="$1"

  if [[ ! -f "$bundle_path" ]]; then
    echo -e "${RED}Bundle not found:${NC}"
    echo "$bundle_path"
    return 1
  fi

  echo
  echo -e "${YELLOW}Importing bundle:${NC}"
  echo "$bundle_path"

  mkdir -p "$BASE_DIR/assets"

  tar -xzf "$bundle_path" -C "$BASE_DIR"

  echo
  echo -e "${GREEN}Bundle imported successfully.${NC}"
  echo

  show_cached_assets
}

import_offline_bundle_manual() {
  title
  echo -e "${CYAN}Import Offline Bundle from Local File${NC}"
  line
  echo

  echo "Example:"
  echo "$BASE_DIR/viptrue-offline-assets-0.1.2.tar.gz"
  echo
  read -r -p "Enter local bundle path: " bundle_path

  if [[ -z "${bundle_path// /}" ]]; then
    echo -e "${RED}Empty path.${NC}"
    pause
    return
  fi

  if import_offline_bundle_file "$bundle_path"; then
    :
  else
    pause
  fi
}

'''

if "download_offline_bundle_from_release()" not in text:
    text = text.replace(insert_before, func + "\n" + insert_before)

text = text.replace(
'''echo "2. Show cached assets"
  echo "3. Cache sing-box binary from official release"
  echo "4. Install sing-box from local cache"
  echo "5. Build portable offline bundle"
  echo "0. Back"''',
'''echo "2. Show cached assets"
  echo "3. Cache sing-box binary from official release"
  echo "4. Install sing-box from local cache"
  echo "5. Build portable offline bundle"
  echo "6. Download offline bundle from VIPTrue Release"
  echo "7. Import offline bundle from local file"
  echo "0. Back"'''
)

text = text.replace(
'''read -r -p "Enter your choice [0-5]: " choice''',
'''read -r -p "Enter your choice [0-7]: " choice'''
)

text = text.replace(
'''    5) build_offline_bundle ;;
    0) break ;;''',
'''    5) build_offline_bundle ;;
    6) download_offline_bundle_from_release ;;
    7) import_offline_bundle_manual ;;
    0) break ;;'''
)

path.write_text(text)
PY

chmod +x modules/utility/03-offline-assets.sh

find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 19-C completed successfully."
echo "Version is now:"
cat VERSION
echo
echo "Now run:"
echo "git add . && git commit -m 'Add offline bundle download and import from release' && git push"
