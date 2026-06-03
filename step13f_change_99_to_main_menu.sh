#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p lib

# Clean and simplify ui exit helpers
python3 - <<'PY'
from pathlib import Path
import re

ui = Path("lib/ui.sh")
text = ui.read_text() if ui.exists() else """#!/usr/bin/env bash

NC='\\033[0m'
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
CYAN='\\033[0;36m'

line() {
  echo "============================================================"
}

pause() {
  read -r -p "Press Enter to continue..."
}
"""

# Remove old global exit flag blocks completely
text = re.sub(
    r'\n?# VIPTrue global exit flag\..*?viptrue_should_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
    "\n",
    text,
    flags=re.S
)

text = re.sub(
    r'\n?# Global exit flag:.*?viptrue_should_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
    "\n",
    text,
    flags=re.S
)

text = re.sub(
    r'\n?viptrue_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
    "\n",
    text,
    flags=re.S
)

text = re.sub(
    r'\n?viptrue_should_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
    "\n",
    text,
    flags=re.S
)

# New simple behavior:
# In submenus: exits current submenu process and returns upward.
# In practice with our current structure, this returns to Main Menu.
text += r'''

viptrue_main_menu() {
  clear
  exit 0
}

# Backward compatibility for old handlers.
viptrue_exit_toolbox() {
  viptrue_main_menu
}

viptrue_should_exit_toolbox() {
  true
}
'''

ui.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path
import re

targets = []
for folder in ["menus", "modules"]:
    p = Path(folder)
    if p.exists():
        targets.extend(p.rglob("*.sh"))

for name in ["toolbox.sh", "main.sh", "viptrue-toolbox.sh"]:
    p = Path(name)
    if p.exists():
        targets.append(p)

changed = []

for path in targets:
    text = path.read_text()
    original = text

    # Rename visible menu item
    text = text.replace("99. Exit toolbox", "99. Main Menu")

    # Replace old handler call with main menu helper
    text = text.replace("viptrue_exit_toolbox", "viptrue_main_menu")

    # Remove forced global-exit loop checks if previous patches added them
    text = text.replace("  viptrue_should_exit_toolbox\n", "")
    text = text.replace("viptrue_should_exit_toolbox\n", "")

    # If menu has 99 item but no handler, add it safely
    if "99. Main Menu" in text and not re.search(r'(^|\n)\s*99\)', text):
        text = re.sub(
            r'(case\s+"\$choice"\s+in\s*\n)',
            r'\1    99)\n      viptrue_main_menu\n      ;;\n',
            text,
            count=1
        )

    if text != original:
        path.write_text(text)
        changed.append(str(path))

print("Changed files:")
for f in changed:
    print("-", f)
PY

# Syntax check
find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 13-F completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Rename exit 99 to main menu and simplify handler' && git push"
