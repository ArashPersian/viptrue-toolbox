#!/usr/bin/env bash
set -Eeuo pipefail

cd ~/viptrue-toolbox

echo "0.1.1" > VERSION

python3 - <<'PY'
from pathlib import Path

ui = Path("lib/ui.sh")
text = ui.read_text()

def replace_bash_function(src, func_name, new_func):
    marker = f"{func_name}()"
    start = src.find(marker)
    if start == -1:
        return src + "\n\n" + new_func.rstrip() + "\n"

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

get_version_func = r'''viptrue_get_version() {
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if [[ -f "$base_dir/VERSION" ]]; then
    tr -d '[:space:]' < "$base_dir/VERSION"
  else
    echo "${TOOLBOX_VERSION:-0.1.0}"
  fi
}'''

title_func = r'''title() {
  clear
  echo -e "${CYAN}"
  cat <<'EOF'
 __      ___ _____ _______             
 \ \    / (_)  __ \__   __|            
  \ \  / / _| |__) | | |_ __ _   _  ___ 
   \ \/ / | |  ___/  | | '__| | | |/ _ \
    \  /  | | |      | | |  | |_| |  __/
     \/   |_|_|      |_|_|   \__,_|\___|
EOF
  echo -e "${NC}"
  echo "VIPTrue Server Toolbox"
  echo -e "${GREEN}Version:${NC} $(viptrue_get_version)"
  line
}'''

text = replace_bash_function(text, "viptrue_get_version", get_version_func)
text = replace_bash_function(text, "title", title_func)

ui.write_text(text)
PY

# Remove accidental hardcoded version exports in menu/modules if present
grep -R "TOOLBOX_VERSION.*0.1.0" -n . --include="*.sh" || true

find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 19-A3 completed successfully."
echo "Current VERSION file:"
cat VERSION
echo
echo "Now run:"
echo "git add . && git commit -m 'Fix dynamic version display' && git push"
