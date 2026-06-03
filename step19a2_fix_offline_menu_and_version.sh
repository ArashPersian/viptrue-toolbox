#!/usr/bin/env bash
set -Eeuo pipefail

cd ~/viptrue-toolbox

# Ensure VERSION exists and is bumped
echo "0.1.1" > VERSION

# Ensure offline module exists
if [[ ! -f modules/utility/03-offline-assets.sh ]]; then
  echo "ERROR: modules/utility/03-offline-assets.sh not found."
  echo "Step 19-A did not fully create the offline module."
  exit 1
fi

chmod +x modules/utility/03-offline-assets.sh

# Fix version display in lib/ui.sh
python3 - <<'PY'
from pathlib import Path
import re

ui = Path("lib/ui.sh")
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

# Replace TOOLBOX_VERSION display with dynamic VERSION file
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

ui.write_text(text)
PY

# Force patch utility menu
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
        if "Utility Tools" in t and "Temporary Tunnel" in t:
            target = p
            break

if target is None:
    raise SystemExit("Could not find Utility menu file.")

text = target.read_text()
original = text

# Make sure visible option exists
if 'Offline Assets / Local Installer' not in text:
    text = text.replace(
        'echo "2. Temporary Tunnel / Proxy for Installations"',
        'echo "2. Temporary Tunnel / Proxy for Installations"\n  echo "3. Offline Assets / Local Installer"'
    )

# Fix prompt
text = text.replace(
    'read -r -p "Enter your choice [0-2]: " choice',
    'read -r -p "Enter your choice [0-3]: " choice'
)

# If option 3 handler missing, insert before 0) Back
if not re.search(r'(^|\n)\s*3\)', text):
    text = re.sub(
        r'(\n\s*0\)\s*\n\s*break\s*\n\s*;;)',
        r'\n    3)\n      bash "$BASE_DIR/modules/utility/03-offline-assets.sh"\n      ;;\1',
        text,
        count=1
    )

if text == original:
    print(f"No changes needed in {target}")
else:
    target.write_text(text)
    print(f"Patched: {target}")
PY

# Syntax check
find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 19-A2 completed successfully."
echo "Version:"
cat VERSION
echo
echo "Now run:"
echo "git add . && git commit -m 'Fix offline assets menu option and version display' && git push"
