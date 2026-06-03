#!/usr/bin/env bash
set -Eeuo pipefail

cd ~/viptrue-toolbox

# Restore current toolbox version
echo "0.1.3" > VERSION

python3 - <<'PY'
from pathlib import Path
import re

path = Path("modules/utility/03-offline-assets.sh")
text = path.read_text()

# Replace build_offline_bundle function safely
def replace_bash_function(src, func_name, new_func):
    marker = f"{func_name}()"
    start = src.find(marker)
    if start == -1:
        raise SystemExit(f"Function not found: {func_name}")

    brace_start = src.find("{", start)
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

new_build = r'''build_offline_bundle() {
  title
  echo -e "${CYAN}Build Portable Offline Bundle${NC}"
  line
  echo

  mkdir -p "$ASSETS_DIR"

  local version bundle_name
  version="$(cat "$BASE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  version="${version:-0.1.3}"

  bundle_name="viptrue-offline-assets-${version}.tar.gz"

  # Store asset bundle version INSIDE assets, not root VERSION.
  # This prevents offline bundle import from downgrading toolbox VERSION.
  echo "$version" > "$ASSETS_DIR/OFFLINE_BUNDLE_VERSION"

  echo "This will create:"
  echo "$BASE_DIR/$bundle_name"
  echo
  echo "Included:"
  echo "- assets/sing-box/"
  echo "- assets/OFFLINE_BUNDLE_VERSION"
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
    assets/sing-box \
    assets/OFFLINE_BUNDLE_VERSION

  echo
  echo -e "${GREEN}Bundle created:${NC}"
  echo "$BASE_DIR/$bundle_name"
  echo
  ls -lh "$BASE_DIR/$bundle_name"
  echo

  pause
}'''

new_import = r'''import_offline_bundle_file() {
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

  # Important:
  # Bundle must not overwrite root VERSION.
  # If an old bundle contains VERSION, extract it to temp first and only copy assets.
  local tmpdir
  tmpdir="$(mktemp -d)"

  tar -xzf "$bundle_path" -C "$tmpdir"

  if [[ -d "$tmpdir/assets" ]]; then
    cp -a "$tmpdir/assets/." "$BASE_DIR/assets/"
  else
    echo -e "${RED}Invalid bundle: assets directory not found.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi

  rm -rf "$tmpdir"

  echo
  echo -e "${GREEN}Bundle imported successfully.${NC}"
  echo "Toolbox VERSION was not overwritten."
  echo

  show_cached_assets
}'''

text = replace_bash_function(text, "build_offline_bundle", new_build)
text = replace_bash_function(text, "import_offline_bundle_file", new_import)

path.write_text(text)
PY

chmod +x modules/utility/03-offline-assets.sh

find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 19-D completed successfully."
echo "Version is now:"
cat VERSION
echo
echo "Now run:"
echo "git add . && git commit -m 'Prevent offline bundle import from overwriting toolbox version' && git push"
